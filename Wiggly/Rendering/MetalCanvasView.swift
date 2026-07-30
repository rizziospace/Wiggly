import CoreImage
import MetalKit
import SwiftUI
import UIKit

final class AnimatedMetalView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
    var document = WiggleDocument.blank() {
        didSet {
            if oldValue.id != document.id || oldValue.modifiedAt != document.modifiedAt {
                cachedDocumentFrame = nil
                committedStrokePreview = nil
                updatePreferredFrameRate()
                requestDisplay()
            }
        }
    }
    var brush = BrushSettings.preset(.wiggle)
    var inputPolicy = CanvasInputPolicy.pencilOnly
    var isErasing = false
    var isSelecting = false
    var isAnimationPlaying = true {
        didSet {
            guard oldValue != isAnimationPlaying else { return }
            cachedDocumentFrame = nil
            configureDisplayMode()
        }
    }
    var isTransformingImage = false {
        didSet {
            if oldValue != isTransformingImage { updateGestureAvailability() }
        }
    }
    var selectedStrokeID: UUID?
    var onStroke: ((AnimatedStroke) -> Void)?
    var onErase: ((CGPoint) -> Void)?
    var onSelect: ((CGPoint) -> Void)?
    var onPickColor: ((CodableColor) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onImageTransformBegan: (() -> Void)?
    var onImageTransformChanged: ((Double, CGPoint) -> Void)?
    var onImageTransformEnded: (() -> Void)?
    var surroundingColor = CIColor(red: 0.075, green: 0.072, blue: 0.085, alpha: 1) {
        didSet {
            clearColor = MTLClearColorMake(
                Double(surroundingColor.red),
                Double(surroundingColor.green),
                Double(surroundingColor.blue),
                Double(surroundingColor.alpha)
            )
        }
    }

    private var samples: [StrokeSample] = []
    private var committedStrokePreview: AnimatedStroke?
    private var startedAt: TimeInterval = 0
    private var displayStart = CACurrentMediaTime()
    private var cachedDocumentFrame: CGImage?
    private var cachedDocumentRenderSize = CGSize.zero
    private var lastDocumentFrameTime: TimeInterval = 0
    private var ciContext: CIContext!
    private var commandQueue: MTLCommandQueue!
    private var panGesture: UIPanGestureRecognizer!
    private var imagePanGesture: UIPanGestureRecognizer!
    private var rotateGesture: UIRotationGestureRecognizer!
    private var zoom: CGFloat = 1
    private var rotation: CGFloat = 0
    private var offset: CGPoint = .zero
    private var pinchCumulativeScale: CGFloat = 1
    private var pinchStartedAt: TimeInterval = 0
    private var isPinching = false
    private var isRotating = false
    private var activeImageTransformGestures = 0
    private var colorSamplingFrame: CGImage?
    private var colorPickIndicator: CAShapeLayer?
    private var lastPickedColor: CodableColor?

    override init(frame: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)
        guard let metalDevice else { return }
        commandQueue = metalDevice.makeCommandQueue()
        ciContext = CIContext(mtlDevice: metalDevice)
        delegate = self
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 30
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.075, 0.072, 0.085, 1)
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "animatedCanvas"
        addGestures()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addGestures() {
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        panGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = self
        addGestureRecognizer(panGesture)

        imagePanGesture = UIPanGestureRecognizer(target: self, action: #selector(imagePanned(_:)))
        imagePanGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        imagePanGesture.minimumNumberOfTouches = 1
        imagePanGesture.maximumNumberOfTouches = 2
        imagePanGesture.delegate = self
        imagePanGesture.isEnabled = false
        addGestureRecognizer(imagePanGesture)

        let colorPick = UILongPressGestureRecognizer(target: self, action: #selector(colorPicked(_:)))
        colorPick.minimumPressDuration = 0.35
        colorPick.allowableMovement = 18
        colorPick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        colorPick.cancelsTouchesInView = true
        colorPick.delegate = self
        addGestureRecognizer(colorPick)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self
        addGestureRecognizer(pinch)

        rotateGesture = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        rotateGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        rotateGesture.delegate = self
        addGestureRecognizer(rotateGesture)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerUndo(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.numberOfTapsRequired = 1
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.cancelsTouchesInView = true
        undoTap.delegate = self
        addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(threeFingerRedo(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.numberOfTapsRequired = 1
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.cancelsTouchesInView = true
        redoTap.delegate = self
        addGestureRecognizer(redoTap)
    }

    private func updateGestureAvailability() {
        guard panGesture != nil, imagePanGesture != nil, rotateGesture != nil else { return }
        panGesture.isEnabled = !isTransformingImage
        imagePanGesture.isEnabled = isTransformingImage
        rotateGesture.isEnabled = !isTransformingImage
    }

    private func configureDisplayMode() {
        enableSetNeedsDisplay = !isAnimationPlaying
        isPaused = !isAnimationPlaying
        updatePreferredFrameRate()
        requestDisplay()
    }

    private func updatePreferredFrameRate() {
        guard isAnimationPlaying else { return }
        let sampleCount = document.layers.reduce(0) { layerTotal, layer in
            layerTotal + layer.strokes.reduce(0) { $0 + $1.samples.count }
        }
        preferredFramesPerSecond = sampleCount > 20_000 ? 15 : (sampleCount > 8_000 ? 24 : 30)
    }

    private func requestDisplay() {
        if !isAnimationPlaying { setNeedsDisplay() }
    }

    private func beginImageTransformGesture() {
        if activeImageTransformGestures == 0 { onImageTransformBegan?() }
        activeImageTransformGestures += 1
    }

    private func endImageTransformGesture() {
        guard activeImageTransformGestures > 0 else { return }
        activeImageTransformGestures -= 1
        if activeImageTransformGestures == 0 { onImageTransformEnded?() }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer is UITapGestureRecognizer || otherGestureRecognizer is UITapGestureRecognizer {
            return false
        }
        return true
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        offset.x += translation.x
        offset.y += translation.y
        gesture.setTranslation(.zero, in: self)
        requestDisplay()
    }

    @objc private func imagePanned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginImageTransformGesture()
            gesture.setTranslation(.zero, in: self)
        case .changed:
            let translation = gesture.translation(in: self)
            let viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
            let start = canvasPoint(from: viewCenter)
            let end = canvasPoint(from: CGPoint(
                x: viewCenter.x + translation.x,
                y: viewCenter.y + translation.y
            ))
            onImageTransformChanged?(1, CGPoint(x: end.x - start.x, y: end.y - start.y))
            gesture.setTranslation(.zero, in: self)
        case .ended, .cancelled:
            endImageTransformGesture()
        default:
            break
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let location = gesture.location(in: self)
        if isTransformingImage {
            switch gesture.state {
            case .began:
                beginImageTransformGesture()
                gesture.scale = 1
            case .changed:
                onImageTransformChanged?(Double(gesture.scale), .zero)
                gesture.scale = 1
            case .ended, .cancelled:
                endImageTransformGesture()
            default:
                break
            }
            return
        }
        switch gesture.state {
        case .began:
            isPinching = true
            pinchStartedAt = CACurrentMediaTime()
            pinchCumulativeScale = 1
            gesture.scale = 1
        case .changed:
            let anchor = canvasPoint(from: location)
            let delta = gesture.scale
            pinchCumulativeScale *= delta
            zoom = min(8, max(0.25, zoom * delta))
            align(canvasPoint: anchor, withViewPoint: location)
            gesture.scale = 1
            requestDisplay()
        case .ended:
            let duration = CACurrentMediaTime() - pinchStartedAt
            let wasQuickClose = duration < 0.18
                && pinchCumulativeScale < 0.5
                && gesture.velocity < -4
                && !isRotating
            isPinching = false
            if wasQuickClose { resetCanvasTransform() }
        default:
            isPinching = false
        }
    }

    @objc private func rotated(_ gesture: UIRotationGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            isRotating = true
            gesture.rotation = 0
        case .changed:
            let anchor = canvasPoint(from: location)
            rotation += gesture.rotation
            align(canvasPoint: anchor, withViewPoint: location)
            gesture.rotation = 0
            requestDisplay()
        default:
            isRotating = false
        }
    }

    private func resetCanvasTransform() {
        zoom = 1
        rotation = 0
        offset = .zero
        requestDisplay()
    }

    @objc private func twoFingerUndo(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onUndo?()
    }

    @objc private func threeFingerRedo(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onRedo?()
    }

    @objc private func colorPicked(_ gesture: UILongPressGestureRecognizer) {
        guard !isTransformingImage else { return }
        switch gesture.state {
        case .began:
            samples.removeAll(keepingCapacity: true)
            colorSamplingFrame = makeColorSamplingFrame()
            lastPickedColor = nil
            updateColorPick(at: gesture.location(in: self))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            requestDisplay()
        case .changed:
            updateColorPick(at: gesture.location(in: self))
        case .ended, .cancelled, .failed:
            finishColorPick()
        default:
            break
        }
    }

    private func makeColorSamplingFrame() -> CGImage? {
        let maxDimension: CGFloat = 768
        let sourceWidth = CGFloat(document.width)
        let sourceHeight = CGFloat(document.height)
        let scale = min(1, maxDimension / max(sourceWidth, sourceHeight))
        let elapsed = CACurrentMediaTime() - displayStart
        let phase = isAnimationPlaying
            ? elapsed.truncatingRemainder(dividingBy: 3) / 3
            : 0
        return AnimatedDrawingRenderer.image(
            document: document,
            phase: phase,
            outputSize: CGSize(
                width: max(1, sourceWidth * scale),
                height: max(1, sourceHeight * scale)
            )
        )
    }

    private func updateColorPick(at viewPoint: CGPoint) {
        let canvasLocation = canvasPoint(from: viewPoint)
        guard let frame = colorSamplingFrame,
              let pickedColor = sampledColor(at: canvasLocation, from: frame) else { return }

        updateColorPickIndicator(color: pickedColor, at: viewPoint)
        if pickedColor != lastPickedColor {
            lastPickedColor = pickedColor
            onPickColor?(pickedColor)
        }
    }

    private func sampledColor(at point: CGPoint, from image: CGImage) -> CodableColor? {
        let sourceWidth = CGFloat(document.width)
        let sourceHeight = CGFloat(document.height)
        guard point.x >= 0, point.y >= 0,
              point.x < sourceWidth, point.y < sourceHeight,
              let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let x = min(image.width - 1, max(0, Int(point.x / sourceWidth * CGFloat(image.width))))
        let y = min(image.height - 1, max(0, Int(point.y / sourceHeight * CGFloat(image.height))))
        let offset = y * image.bytesPerRow + x * 4
        let alpha = Double(bytes[offset + 3]) / 255
        guard alpha > 0.02 else { return nil }
        return CodableColor(
            red: min(1, Double(bytes[offset]) / 255 / alpha),
            green: min(1, Double(bytes[offset + 1]) / 255 / alpha),
            blue: min(1, Double(bytes[offset + 2]) / 255 / alpha),
            alpha: alpha
        )
    }

    private func updateColorPickIndicator(color: CodableColor, at point: CGPoint) {
        let indicator: CAShapeLayer
        if let colorPickIndicator {
            indicator = colorPickIndicator
        } else {
            indicator = CAShapeLayer()
            indicator.path = UIBezierPath(ovalIn: CGRect(x: -24, y: -24, width: 48, height: 48)).cgPath
            indicator.strokeColor = UIColor.white.cgColor
            indicator.lineWidth = 4
            indicator.shadowColor = UIColor.black.cgColor
            indicator.shadowOpacity = 0.45
            indicator.shadowRadius = 6
            indicator.shadowOffset = CGSize(width: 0, height: 3)
            layer.addSublayer(indicator)
            colorPickIndicator = indicator
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.position = CGPoint(
            x: min(bounds.width - 28, max(28, point.x)),
            y: min(bounds.height - 28, max(28, point.y - 58))
        )
        indicator.fillColor = UIColor(
            red: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        ).cgColor
        CATransaction.commit()
    }

    private func finishColorPick() {
        colorSamplingFrame = nil
        lastPickedColor = nil
        colorPickIndicator?.removeFromSuperlayer()
        colorPickIndicator = nil
    }

    private var fittedRect: CGRect {
        let canvasAspect = CGFloat(document.width) / CGFloat(document.height)
        let viewAspect = bounds.width / max(1, bounds.height)
        let size: CGSize
        if canvasAspect > viewAspect {
            size = CGSize(width: bounds.width * 0.88, height: bounds.width * 0.88 / canvasAspect)
        } else {
            size = CGSize(width: bounds.height * 0.88 * canvasAspect, height: bounds.height * 0.88)
        }
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func canvasPoint(from viewPoint: CGPoint) -> CGPoint {
        let rect = fittedRect
        var point = CGPoint(
            x: viewPoint.x - bounds.midX - offset.x,
            y: viewPoint.y - bounds.midY - offset.y
        )
        let cosine = Foundation.cos(-rotation)
        let sine = Foundation.sin(-rotation)
        point = CGPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
        point.x /= zoom
        point.y /= zoom
        point.x += rect.width / 2
        point.y += rect.height / 2
        return CGPoint(
            x: point.x / rect.width * CGFloat(document.width),
            y: point.y / rect.height * CGFloat(document.height)
        )
    }

    private func viewPoint(fromCanvasPoint canvasPoint: CGPoint) -> CGPoint {
        let rect = fittedRect
        var point = CGPoint(
            x: canvasPoint.x / CGFloat(document.width) * rect.width - rect.width / 2,
            y: canvasPoint.y / CGFloat(document.height) * rect.height - rect.height / 2
        )
        point.x *= zoom
        point.y *= zoom
        let cosine = Foundation.cos(rotation)
        let sine = Foundation.sin(rotation)
        point = CGPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
        return CGPoint(
            x: bounds.midX + offset.x + point.x,
            y: bounds.midY + offset.y + point.y
        )
    }

    private func align(canvasPoint: CGPoint, withViewPoint target: CGPoint) {
        let current = viewPoint(fromCanvasPoint: canvasPoint)
        offset.x += target.x - current.x
        offset.y += target.y - current.y
    }

    private func accepts(_ touch: UITouch) -> Bool {
        touch.type == .pencil || (touch.type == .direct && inputPolicy == .pencilAndFinger)
    }

    private func hasMultipleDirectTouches(_ event: UIEvent?) -> Bool {
        let directTouches = event?.allTouches?.filter { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled }
        return (directTouches?.count ?? 0) > 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isTransformingImage else { return }
        guard let touch = touches.first(where: accepts) else { return }
        if touch.type == .direct && hasMultipleDirectTouches(event) { return }
        let point = canvasPoint(from: touch.location(in: self))
        if isErasing {
            onErase?(point)
        } else if isSelecting {
            onSelect?(point)
        } else {
            samples.removeAll(keepingCapacity: true)
            startedAt = touch.timestamp
            append(touch)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isTransformingImage else { return }
        guard let touch = touches.first(where: accepts) else { return }
        if touch.type == .direct && hasMultipleDirectTouches(event) {
            samples.removeAll()
            return
        }
        if isErasing {
            onErase?(canvasPoint(from: touch.location(in: self)))
        } else if !isSelecting {
            for coalesced in event?.coalescedTouches(for: touch) ?? [touch] {
                append(coalesced)
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isTransformingImage else {
            samples.removeAll()
            return
        }
        guard touches.contains(where: accepts), samples.count > 1, !isErasing, !isSelecting else {
            samples.removeAll()
            return
        }
        let completedStroke = AnimatedStroke(samples: samples, brush: brush)
        committedStrokePreview = completedStroke
        samples.removeAll(keepingCapacity: true)
        onStroke?(completedStroke)
        requestDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        samples.removeAll()
        requestDisplay()
    }

    private func append(_ touch: UITouch) {
        let location = canvasPoint(from: touch.location(in: self))
        let maximum = max(touch.maximumPossibleForce, 1)
        let pressure = touch.type == .pencil ? touch.force / maximum : 0.5
        let tilt = 1 - touch.altitudeAngle / (.pi / 2)
        let azimuth = touch.azimuthAngle(in: self)
        var candidate = StrokeSample(
            x: location.x,
            y: location.y,
            pressure: pressure,
            tilt: tilt,
            azimuth: azimuth,
            timestamp: touch.timestamp - startedAt
        )
        if let last = samples.last {
            let distance = hypot(last.x - candidate.x, last.y - candidate.y)
            guard distance >= max(1, brush.spacing * 0.2) else { return }
            let response = 1.0 - min(0.9, brush.smoothing * 0.85)
            candidate.x = last.x + (candidate.x - last.x) * response
            candidate.y = last.y + (candidate.y - last.y) * response
            candidate.pressure = last.pressure + (candidate.pressure - last.pressure) * response
        }
        samples.append(candidate)
        requestDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - displayStart
        let phase = isAnimationPlaying
            ? elapsed.truncatingRemainder(dividingBy: 3) / 3
            : 0
        let rect = fittedRect
        let nativeScale = contentScaleFactor
        let longestSide = max(1, max(rect.width, rect.height))
        let renderLimit: CGFloat = preferredFramesPerSecond <= 15 ? 1024 : 1440
        let renderScale = max(1, min(nativeScale, renderLimit / longestSide))
        let displayScale = nativeScale / renderScale
        let renderSize = CGSize(
            width: max(1, rect.width * renderScale),
            height: max(1, rect.height * renderScale)
        )
        let activeStroke = samples.count > 1
            ? AnimatedStroke(samples: samples, brush: brush)
            : committedStrokePreview

        let sizeChanged = abs(cachedDocumentRenderSize.width - renderSize.width) > 1
            || abs(cachedDocumentRenderSize.height - renderSize.height) > 1
        let canAdvanceDocumentAnimation = isAnimationPlaying
        let frameInterval = 1.0 / Double(max(1, preferredFramesPerSecond))
        if cachedDocumentFrame == nil
            || sizeChanged
            || (canAdvanceDocumentAnimation && currentTime - lastDocumentFrameTime >= frameInterval) {
            cachedDocumentFrame = autoreleasepool {
                AnimatedDrawingRenderer.image(
                    document: document,
                    phase: phase,
                    outputSize: renderSize,
                    showTransparencyGrid: true
                )
            }
            cachedDocumentRenderSize = renderSize
            lastDocumentFrameTime = currentTime
        }
        guard let documentFrame = cachedDocumentFrame else { return }

        var image = CIImage(cgImage: documentFrame)
        if let activeStroke {
            var previewDocument = document
            previewDocument.layers.removeAll(keepingCapacity: true)
            if let previewFrame = autoreleasepool(invoking: {
                AnimatedDrawingRenderer.image(
                    document: previewDocument,
                    phase: phase,
                    outputSize: renderSize,
                    transparent: true,
                    previewStroke: activeStroke
                )
            }) {
                image = CIImage(cgImage: previewFrame).composited(over: image)
            }
        }
        image = image.transformed(by: CGAffineTransform(
            translationX: -renderSize.width / 2,
            y: -renderSize.height / 2
        ))
        image = image.transformed(by: CGAffineTransform(
            scaleX: displayScale * zoom,
            y: displayScale * zoom
        ))
        image = image.transformed(by: CGAffineTransform(rotationAngle: -rotation))
        image = image.transformed(by: CGAffineTransform(
            translationX: drawableSize.width / 2 + offset.x * nativeScale,
            y: drawableSize.height / 2 - offset.y * nativeScale
        ))

        let outputBounds = CGRect(origin: .zero, size: drawableSize)
        let background = CIImage(color: surroundingColor)
            .cropped(to: outputBounds)
        let composited = image.composited(over: background)

        ciContext.render(
            composited,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: outputBounds,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct MetalCanvas: UIViewRepresentable {
    @ObservedObject var editor: EditorModel

    func makeUIView(context: Context) -> AnimatedMetalView {
        let view = AnimatedMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        connect(view)
        return view
    }

    func updateUIView(_ view: AnimatedMetalView, context: Context) {
        connect(view)
    }

    private func connect(_ view: AnimatedMetalView) {
        view.document = editor.document
        view.brush = editor.selectedBrush
        view.inputPolicy = editor.inputPolicy
        view.isErasing = editor.eraserMode
        view.isSelecting = editor.selectionMode
        view.isAnimationPlaying = editor.isAnimationPlaying
        view.isTransformingImage = editor.imageTransformMode && editor.canTransformSelectedImage
        view.selectedStrokeID = editor.selectedStrokeID
        view.onStroke = { [weak editor] in editor?.addStroke($0) }
        view.onErase = { [weak editor] in
            editor?.erase(at: $0, radius: max(20, editor?.selectedBrush.size ?? 20))
        }
        view.onSelect = { [weak editor] in editor?.select(at: $0) }
        view.onPickColor = { [weak editor] in editor?.selectedBrush.color = $0 }
        view.onUndo = { [weak editor] in editor?.undo() }
        view.onRedo = { [weak editor] in editor?.redo() }
        view.onImageTransformBegan = { [weak editor] in editor?.beginImageTransformGesture() }
        view.onImageTransformChanged = { [weak editor] scale, translation in
            editor?.updateSelectedImageTransform(scaleDelta: scale, translation: translation)
        }
        view.onImageTransformEnded = { [weak editor] in editor?.endImageTransformGesture() }
    }
}
