import CoreImage
import MetalKit
import os
import SwiftUI
import UIKit

final class AnimatedMetalView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
    var document = WiggleDocument.blank() {
        didSet {
            if oldValue.id != document.id || oldValue.modifiedAt != document.modifiedAt {
                refreshRenderingDocument()
                committedStrokePreview = nil
                if forceContinuousDisplay {
                    forceContinuousDisplay = false
                    configureDisplayMode()
                }
                // A committed edit (undo, redo, new stroke) must be reflected on
                // screen. Whatever the previous display mode, make sure the
                // Metal loop is actively drawing so the change is never left
                // visually stuck until the next touch.
                if isPaused, isAnimationPlaying, isAppActive, window != nil {
                    isPaused = false
                }
                requestDisplay()
                updateTransformOverlay()
            }
        }
    }
    var brush = BrushSettings.preset(.dashed) {
        didSet {
            guard oldValue != brush else { return }
            // A freshly created layer has no strokes to classify, so which
            // backend it gets depends on the brush currently selected. Switching
            // brushes must therefore re-derive the layer groups (e.g. an empty
            // layer becomes a dashed/star/dryOutline GPU group only while that
            // brush is active) and drop every cached frame so the next draw
            // re-rasters through the right path.
            requestDisplay()
        }
    }
    /// Global StreamLine-style smoothing applied on top of each brush's own
    /// smoothing setting. Every brush is at least this smooth.
    var globalSmoothing: Double = 0 {
        didSet {
            guard globalSmoothing != oldValue else { return }
            pointSmoother.reset(amount: effectiveSmoothing)
        }
    }
    var inputPolicy = CanvasInputPolicy.pencilOnly
    var isErasing = false
    var isSelecting = false
    var isDrawingBlocked = false
    var onDrawBlocked: (() -> Void)?
    var isAnimationPlaying = true {
        didSet {
            guard oldValue != isAnimationPlaying else { return }
            configureDisplayMode()
        }
    }
    var animationPlaybackSpeed: Double = 1 {
        didSet {
            guard oldValue != animationPlaybackSpeed else { return }
            displayStart = CACurrentMediaTime()
            requestDisplay()
        }
    }
    var isStrokeAnimationRandomized = false {
        didSet {
            guard oldValue != isStrokeAnimationRandomized else { return }
            dashedRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            dryOutlineRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            starRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            particleRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            particleCloudRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            scribblesRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            proceduralBrushRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            checkerRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            outlineFillRenderer?.setStrokePhaseRandomized(isStrokeAnimationRandomized)
            refreshRenderingDocument()
            committedStrokePreview = nil
            requestDisplay()
        }
    }
    var isTransformingImage = false {
        didSet {
            if oldValue != isTransformingImage {
                updateGestureAvailability()
                updateTransformOverlay()
            }
        }
    }
    var transformTargetLayerIDs: Set<UUID> = [] {
        didSet { updateTransformOverlay() }
    }
    var selectedStrokeID: UUID?
    var onStroke: ((AnimatedStroke) -> Void)?
    var onErase: ((CGPoint) -> Void)?
    var onSelect: ((CGPoint) -> Void)?
    var onColorPickBegan: (() -> Void)?
    var onPickColor: ((CodableColor) -> Void)?
    var onColorPickEnded: ((Bool) -> Void)?
    var onCanvasInteraction: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onImageTransformBegan: (() -> Void)?
    var onImageTransformChanged: ((Double, CGPoint) -> Void)?
    var onImageTransformEnded: (() -> Void)?
    var canvasInsetFactor: CGFloat = 0.88
    var canvasFillsView = false
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
    private var activeStrokeID = UUID()
    private var committedStrokePreview: AnimatedStroke?
    private var startedAt: TimeInterval = 0
    private var pointSmoother = StrokePointSmoother()
    // QuickShape (Procreate-style) hold-to-straighten state.
    private var isStroking = false
    private var primaryTouch: UITouch?
    private var lastPencilStrokeEndedAt: CFTimeInterval = -.infinity
    private let pencilGestureCooldown: CFTimeInterval = 0.3
    private var holdWorkItem: DispatchWorkItem?
    private var shapeLock: ShapeFit?
    private var shapeLockedSamples: [StrokeSample]?
    private var shapePerfectSamples: [StrokeSample]?
    private var lockedRawEndPoint: StrokeSample?
    private var shapeLockedKind: QuickShapeKind?
    private var shapeLockedCenter: CGPoint?
    private var shapeLockedBaseSamples: [StrokeSample]?
    private var shapeLockedRefPoint: CGPoint?
    private let holdLockDuration: TimeInterval = 0.6
    private var displayStart = CACurrentMediaTime()
    private var sourceSampleCount = 0
    private var cpuGridSignature: Int?
    private var cpuLayerSignatures: [UUID: Int] = [:]
    private var cpuLayerOrder: [UUID] = []
    private var documentContainsGPUAnimation = false
    private var documentContainsFadedCPUAnimation = false
    private var renderedGPUKinds: Set<BrushKind> = []
    private struct VisibleLayerRenderState {
        var id: UUID
        var hasCPUContent: Bool
        var hasAnimatedCPUContent: Bool
        var hasFadedCPUContent: Bool
        var hasGPUStroke: Bool
    }
    // One compositing step in the mixed path, in document order. Either a merged
    // CPU-only run (one bitmap covering many layers) or a single GPU layer (its
    // CPU bitmap, then its GPU strokes).
    private struct CompositeUnit {
        var runID: [UUID]?
        var layerID: UUID?
        var runImage: CGImage?
        var layerImage: CGImage?
    }
    // Derived once when the document changes. The 60 fps draw loop must not
    // repeatedly scan every stroke merely to decide which cached paths to use.
    private var visibleLayerRenderStates: [VisibleLayerRenderState] = []
    private var visibleCPULayerIDs: Set<UUID> = []
    private var animatedCPULayerIDs: Set<UUID> = []
    private var documentContainsAnimatedCPUContent = false
    // Committed content is baked once into a static bitmap and only re-rasterized
    // when the document or canvas size changes, so per-frame cost stays
    // O(live stroke) no matter how many strokes the canvas holds. GPU-eligible
    // strokes are excluded and drawn by the Metal brush renderers instead.
    private var bakedCanvasFrame: CGImage?
    private var bakedCanvasRenderSize = CGSize.zero
    private var lastCommittedFrameTime: TimeInterval = 0
    private var cpuLayerAnimationRasterTask: Task<Void, Never>?
    private var cpuRunAnimationRasterTask: Task<Void, Never>?
    private var cpuCanvasAnimationRasterTask: Task<Void, Never>?
    private var latestRequestedRenderSize = CGSize.zero
    // Per-layer committed CPU rasters used when a document mixes CPU and GPU
    // strokes, so GPU strokes can be interleaved in document order instead of
    // drawn over all CPU content. bakedGridFrame is the transparency grid /
    // document background; bakedLayerFrames is each layer's CPU-only content.
    private var bakedGridFrame: CGImage?
    private var bakedLayerFrames: [UUID: CGImage] = [:]
    // Contiguous runs of CPU-only layers in the mixed path. Each run is
    // rasterized as a single merged bitmap, so consecutive CPU layers cost one
    // texture upload + one composite instead of one per layer. Layers that
    // contain GPU strokes stay per-layer in bakedLayerFrames because their CPU
    // content must interleave with their GPU strokes to keep z-order correct.
    private var cpuRuns: [[UUID]] = []
    private var cpuRunFrames: [[UUID]: CGImage] = [:]
    private var cpuRunSignatures: [[UUID]: Int] = [:]
    private var needsRunRebakes: Set<[UUID]> = []
    // Bumped on every document change so the mixed-path base cache can tell
    // when committed content needs re-encoding.
    private var documentVersion = 0
    // Async-only invalidation: a committed CPU edit keeps its previous baked
    // frame visible while the replacement is rasterized off the main thread,
    // so committing never blocks the draw loop. The flags tell draw() which
    // stale content needs re-baking (the whole canvas for the pure-CPU path,
    // specific layers for the mixed path).
    private var needsCommittedRebake = false
    private var needsLayerRebakes: Set<UUID> = []
    // The baked content plus viewport transform is rendered once into a
    // persistent offscreen texture and blitted into the drawable every frame,
    // so per-frame cost is a GPU copy + the live/GPU stroke encodes instead of
    // a full-screen Core Image composite + texture upload. The base is static
    // while drawing a GPU brush, so blit-only frames dominate.
    // The CPU-only path caches its fully-composited committed frame (baked CG
    // content + viewport transform) in an offscreen texture, keyed on content +
    // viewport. While a stroke is drawn each frame is a blit plus the live
    // stroke instead of a full-screen Core Image composite.
    private struct CPUBaseKey: Equatable {
        var contentHash: Int
        var contentVersion: Int
        var drawableWidth: Int
        var drawableHeight: Int
        var zoom: CGFloat
        var rotation: CGFloat
        var offset: CGPoint
        var surroundingRed: CGFloat
        var surroundingGreen: CGFloat
        var surroundingBlue: CGFloat
        var surroundingAlpha: CGFloat
    }

    private struct MixedCacheKey: Equatable {
        var contentHash: Int
        var contentVersion: Int
        var drawableWidth: Int
        var drawableHeight: Int
        var zoom: CGFloat
        var rotation: CGFloat
        var offset: CGPoint
        var surroundingRed: CGFloat
        var surroundingGreen: CGFloat
        var surroundingBlue: CGFloat
        var surroundingAlpha: CGFloat
    }

    private var cpuBaseTexture: MTLTexture?
    private var cpuBaseKey: CPUBaseKey?
    // The mixed path (committed CPU runs + GPU strokes) caches its fully-encoded
    // committed scene in an offscreen texture keyed on content + viewport. While
    // a stroke is drawn (viewport, content, and phase all static) each frame is
    // just a blit plus the live stroke, instead of re-encoding every heavy GPU
    // fragment shader — which scales badly when zoomed in. Re-encoded whenever
    // the document, zoom/rotation/offset, drawable size, or an async CPU frame
    // swap changes. Playback invalidates each frame because the scene animates.
    private var mixedBaseTexture: MTLTexture?
    private var mixedBaseKey: MixedCacheKey?
    // Forces continuous redraw while a stroke is in progress so the live stroke
    // animates even when the animation playback toggle is off.
    private var forceContinuousDisplay = false
    // iOS rejects command-buffer submission once the process is inactive.
    // Keep the MTKView loop explicitly tied to application/window lifecycle
    // instead of relying on UIKit to pause it quickly enough on its own.
    private var isAppActive = true
    private var commandQueue: MTLCommandQueue!
    private var dashedRenderer: MetalDashedRenderer?
    private var dryOutlineRenderer: MetalDryOutlineRenderer?
    private var starRenderer: MetalStarRenderer?
    private var particleRenderer: MetalParticleRenderer?
    private var particleCloudRenderer: MetalParticleCloudRenderer?
    private var scribblesRenderer: MetalScribblesRenderer?
    private var proceduralBrushRenderer: MetalProceduralBrushRenderer?
    private var checkerRenderer: MetalCheckerRenderer?
    private var outlineFillRenderer: MetalOutlineFillRenderer?
    private var textureCompositor: MetalTextureCompositor?
    private var panGesture: UIPanGestureRecognizer!
    private var imagePanGesture: UIPanGestureRecognizer!
    private var transformHandlePanGesture: UIPanGestureRecognizer!
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
    private let transformBoxLayer = CAShapeLayer()
    private var transformHandleLayers: [CAShapeLayer] = []
    private var transformCanvasBounds: CGRect?
    private var transformViewCorners: [CGPoint] = []
    private var activeTransformHandle: Int?
    private var previousHandleDistance: CGFloat = 1
    private var importedImageSizes: [UUID: (dataCount: Int, size: CGSize)] = [:]
    private let performanceLog = OSLog(subsystem: "com.wiggly.canvas", category: "CanvasPerformance")

    override init(frame: CGRect, device: MTLDevice?) {
        let metalDevice = device ?? MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: metalDevice)
        guard let metalDevice else { return }
        commandQueue = metalDevice.makeCommandQueue()
        delegate = self
        framebufferOnly = false
        enableSetNeedsDisplay = false
        isPaused = false
        preferredFramesPerSecond = 30
        colorPixelFormat = .bgra8Unorm
        dashedRenderer = MetalDashedRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        dryOutlineRenderer = MetalDryOutlineRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        starRenderer = MetalStarRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        particleRenderer = MetalParticleRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        particleCloudRenderer = MetalParticleCloudRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        scribblesRenderer = MetalScribblesRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        proceduralBrushRenderer = MetalProceduralBrushRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        checkerRenderer = MetalCheckerRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        outlineFillRenderer = MetalOutlineFillRenderer(device: metalDevice, pixelFormat: colorPixelFormat)
        textureCompositor = MetalTextureCompositor(device: metalDevice, pixelFormat: colorPixelFormat)
        clearColor = MTLClearColorMake(0.075, 0.072, 0.085, 1)
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "animatedCanvas"
        isAppActive = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        refreshRenderingDocument()
        addGestures()
        addTransformOverlay()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, isAppActive else {
            isPaused = true
            return
        }
        configureDisplayMode()
    }

    @objc private func appWillResignActive() {
        suspendGPUDisplay()
    }

    @objc private func appDidEnterBackground() {
        suspendGPUDisplay()
    }

    @objc private func appDidBecomeActive() {
        isAppActive = true
        displayStart = CACurrentMediaTime()
        guard window != nil else { return }
        configureDisplayMode()
    }

    private func suspendGPUDisplay() {
        isAppActive = false
        isPaused = true
    }

    private var canSubmitGPUWork: Bool {
        isAppActive
            && window != nil
            && UIApplication.shared.applicationState == .active
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

        transformHandlePanGesture = UIPanGestureRecognizer(target: self, action: #selector(transformHandlePanned(_:)))
        transformHandlePanGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        transformHandlePanGesture.minimumNumberOfTouches = 1
        transformHandlePanGesture.maximumNumberOfTouches = 1
        transformHandlePanGesture.delegate = self
        transformHandlePanGesture.isEnabled = false
        addGestureRecognizer(transformHandlePanGesture)
        imagePanGesture.require(toFail: transformHandlePanGesture)

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
        guard panGesture != nil,
              imagePanGesture != nil,
              transformHandlePanGesture != nil,
              rotateGesture != nil else { return }
        panGesture.isEnabled = !isTransformingImage
        imagePanGesture.isEnabled = isTransformingImage
        transformHandlePanGesture.isEnabled = isTransformingImage
        rotateGesture.isEnabled = !isTransformingImage
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTransformOverlay()
    }

    private func configureDisplayMode() {
        guard isAppActive, window != nil else {
            isPaused = true
            return
        }
        enableSetNeedsDisplay = !isAnimationPlaying
        isPaused = !isAnimationPlaying
        updatePreferredFrameRate()
        requestDisplay()
    }

    private func updatePreferredFrameRate() {
        if !forceContinuousDisplay && isAnimationPlaying && documentContainsGPUAnimation {
            preferredFramesPerSecond = 60
        } else {
            preferredFramesPerSecond = 30
        }
    }

    private func refreshRenderingDocument() {
        let previouslyContainedGPUAnimation = documentContainsGPUAnimation
        let previouslyContainedFadedCPUAnimation = documentContainsFadedCPUAnimation
        var currentGPUKinds: Set<BrushKind> = []
        var renderStates: [VisibleLayerRenderState] = []
        renderStates.reserveCapacity(document.layers.count)
        var totalSamples = 0
        var hasAnimatedCPUContent = false
        for layer in document.layers {
            totalSamples += layer.strokes.reduce(0) { $0 + $1.samples.count }
            guard document.isLayerEffectivelyVisible(layer) else { continue }
            var hasCPUStroke = false
            var hasAnimatedCPUStroke = false
            var hasGPUStroke = false
            var hasFadedCPUStroke = false
            for stroke in layer.strokes {
                if stroke.usesGPUAnimatedRenderer {
                    hasGPUStroke = true
                    currentGPUKinds.insert(stroke.brush.kind)
                } else {
                    hasCPUStroke = true
                    hasAnimatedCPUStroke = hasAnimatedCPUStroke || stroke.brush.kind != .solidColor
                    hasFadedCPUStroke = hasFadedCPUStroke || stroke.brush.kind == .faded
                }
            }
            let hasAnimatedFill = (layer.fills ?? []).contains {
                !($0.animatedMaskFrames?.isEmpty ?? true)
                    || !($0.animatedContours?.isEmpty ?? true)
            }
            let layerHasAnimatedCPU = hasAnimatedCPUStroke || hasAnimatedFill
            hasAnimatedCPUContent = hasAnimatedCPUContent || layerHasAnimatedCPU
            renderStates.append(VisibleLayerRenderState(
                id: layer.id,
                hasCPUContent: layer.imageData != nil
                    || !(layer.fills ?? []).isEmpty
                    || hasCPUStroke,
                hasAnimatedCPUContent: layerHasAnimatedCPU,
                hasFadedCPUContent: hasFadedCPUStroke,
                hasGPUStroke: hasGPUStroke
            ))
        }
        sourceSampleCount = totalSamples
        visibleLayerRenderStates = renderStates
        visibleCPULayerIDs = Set(renderStates.lazy.filter(\.hasCPUContent).map(\.id))
        animatedCPULayerIDs = Set(renderStates.lazy.filter(\.hasAnimatedCPUContent).map(\.id))
        documentContainsAnimatedCPUContent = hasAnimatedCPUContent
        documentContainsGPUAnimation = !currentGPUKinds.isEmpty
        documentContainsFadedCPUAnimation = renderStates.contains(where: \.hasFadedCPUContent)
        // Brush kernels depend on every original sample for curvature, pressure,
        // texture, and motion. Keep the geometry lossless and optimize the
        // raster frame rate/resolution instead.
        let rendererKindsToUpdate = currentGPUKinds.union(renderedGPUKinds)
        if rendererKindsToUpdate.contains(.dashed) { dashedRenderer?.update(document: document) }
        if rendererKindsToUpdate.contains(.dryOutline) { dryOutlineRenderer?.update(document: document) }
        if rendererKindsToUpdate.contains(.star) { starRenderer?.update(document: document) }
        if rendererKindsToUpdate.contains(.particle) { particleRenderer?.update(document: document) }
        if rendererKindsToUpdate.contains(.particleCloud) { particleCloudRenderer?.update(document: document) }
        if rendererKindsToUpdate.contains(.scribbles) { scribblesRenderer?.update(document: document) }
        if !rendererKindsToUpdate.isDisjoint(with: MetalProceduralBrushRenderer.supportedKinds) {
            proceduralBrushRenderer?.update(document: document)
        }
        if rendererKindsToUpdate.contains(.checker) { checkerRenderer?.update(document: document) }
        if rendererKindsToUpdate.contains(.outlineFill) { outlineFillRenderer?.update(document: document) }
        renderedGPUKinds = currentGPUKinds
        // A newly committed GPU stroke does not change any CPU raster. Preserve
        // the expensive CPU frames in that common case instead of rebuilding
        // every imported image/static layer after each Pencil-up.
        let newGridSignature = Self.makeCPUGridSignature(document)
        let newLayerSignatures = Dictionary(uniqueKeysWithValues: document.layers.map { layer in
            (layer.id, Self.makeCPULayerSignature(layer, document: document))
        })
        let newLayerOrder = document.layers.map(\.id)
        let renderPathChanged = previouslyContainedGPUAnimation != documentContainsGPUAnimation
            || previouslyContainedFadedCPUAnimation != documentContainsFadedCPUAnimation
        let gridChanged = cpuGridSignature != newGridSignature
        let layerOrderChanged = cpuLayerOrder != newLayerOrder
        let changedLayerIDs = Set(newLayerSignatures.compactMap { id, signature in
            cpuLayerSignatures[id] == signature ? nil : id
        })
        let removedLayerIDs = Set(cpuLayerSignatures.keys).subtracting(newLayerSignatures.keys)
        let cpuDocumentChanged = gridChanged || layerOrderChanged
            || !changedLayerIDs.isEmpty || !removedLayerIDs.isEmpty

        cpuGridSignature = newGridSignature
        cpuLayerSignatures = newLayerSignatures
        cpuLayerOrder = newLayerOrder

        // Group contiguous CPU-only layers into runs (merged into one bitmap in
        // the mixed path) and detect which runs changed since last frame.
        let newRuns = Self.computeCPURuns(renderStates)
        let newRunSet = Set(newRuns)
        var newRunSignatures: [[UUID]: Int] = [:]
        var newNeedsRunRebakes: Set<[UUID]> = []
        for run in newRuns {
            var signature = 0
            for id in run { signature ^= newLayerSignatures[id] ?? 0 }
            newRunSignatures[run] = signature
            if cpuRunSignatures[run] != signature { newNeedsRunRebakes.insert(run) }
        }

        cpuRuns = newRuns

        if renderPathChanged || gridChanged {
            bakedCanvasFrame = nil
            bakedCanvasRenderSize = .zero
            bakedGridFrame = nil
            bakedLayerFrames.removeAll(keepingCapacity: true)
            needsCommittedRebake = false
            needsLayerRebakes.removeAll(keepingCapacity: true)
            cpuRunFrames.removeAll(keepingCapacity: true)
            cpuRunSignatures = newRunSignatures
            needsRunRebakes = newNeedsRunRebakes
        } else {
            for id in removedLayerIDs {
                bakedLayerFrames[id] = nil
                needsLayerRebakes.remove(id)
            }
            // GPU layers keep per-layer frames; CPU-only layers invalidate their
            // merged run instead (they were already folded into needsRunRebakes).
            for id in changedLayerIDs where renderStates.first(where: { $0.id == id })?.hasGPUStroke == true {
                needsLayerRebakes.insert(id)
            }
            for run in Set(cpuRunFrames.keys).subtracting(newRunSet) {
                cpuRunFrames[run] = nil
                cpuRunSignatures[run] = nil
            }
            cpuRunSignatures = newRunSignatures
            needsRunRebakes = newNeedsRunRebakes
            if cpuDocumentChanged { needsCommittedRebake = true }
        }
        documentVersion += 1
        updatePreferredFrameRate()
    }

    /// Contiguous runs of visible CPU-only layers. Layers holding GPU strokes
    /// break a run because they must be composed per layer (with their CPU
    /// content under their GPU strokes for z-order). A layer containing Faded
    /// is also isolated: its cached CPU frame can then advance without
    /// re-rasterizing every heavy static layer around it.
    private static func computeCPURuns(_ states: [VisibleLayerRenderState]) -> [[UUID]] {
        var runs: [[UUID]] = []
        var current: [UUID] = []
        for state in states {
            if state.hasCPUContent && !state.hasGPUStroke && state.hasFadedCPUContent {
                if !current.isEmpty {
                    runs.append(current)
                    current = []
                }
                runs.append([state.id])
            } else if state.hasCPUContent && !state.hasGPUStroke {
                current.append(state.id)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// A cheap content signature for the portion rendered by Core Graphics.
    /// It intentionally ignores GPU stroke geometry and editor-only metadata.
    private static func makeCPUGridSignature(_ document: WiggleDocument) -> Int {
        var hasher = Hasher()
        hasher.combine(document.width)
        hasher.combine(document.height)
        hasher.combine(document.background)
        hasher.combine(document.resolvedBackgroundVisible)
        return hasher.finalize()
    }

    private static func makeCPULayerSignature(
        _ layer: DrawingLayer,
        document: WiggleDocument
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(document.width)
        hasher.combine(document.height)
        hasher.combine(document.isLayerEffectivelyVisible(layer))
        hasher.combine(layer.opacity)
        hasher.combine(layer.resolvedContentScale)
        hasher.combine(layer.resolvedContentOffset.x)
        hasher.combine(layer.resolvedContentOffset.y)
        hasher.combine(layer.imageData?.count ?? 0)
        hasher.combine(layer.resolvedImageScale)
        hasher.combine(layer.resolvedImageOffset.x)
        hasher.combine(layer.resolvedImageOffset.y)
        for fill in layer.fills ?? [] {
            hasher.combine(fill.id)
            hasher.combine(fill.color)
            hasher.combine(fill.samples.count)
            hasher.combine(fill.samples.first)
            hasher.combine(fill.samples.last)
            hasher.combine(fill.maskData?.count ?? 0)
            hasher.combine(fill.animatedMaskFrames?.map(\.count) ?? [])
            hasher.combine(fill.animatedContours?.map(\.count) ?? [])
        }
        for stroke in layer.strokes where !stroke.usesGPUAnimatedRenderer {
            hasher.combine(stroke.id)
            hasher.combine(stroke.brush)
            hasher.combine(stroke.samples.count)
            hasher.combine(stroke.samples.first)
            hasher.combine(stroke.samples.last)
        }
        return hasher.finalize()
    }

    /// Rebuilds only animated CPU layers away from the UI thread. The currently
    /// cached frame remains visible until the replacement is ready, preventing a
    /// Core Graphics pass from blocking Pencil delivery every animation tick.
    private func scheduleMixedCPUAnimationRaster(
        document snapshot: WiggleDocument,
        layers: [DrawingLayer],
        validLayerIDs: Set<UUID>,
        phase: Double,
        renderSize: CGSize,
        randomizeStrokePhase: Bool,
        version: Int
    ) -> Bool {
        guard cpuLayerAnimationRasterTask == nil, !layers.isEmpty else { return false }
        cpuLayerAnimationRasterTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> [UUID: CGImage] in
                var result: [UUID: CGImage] = [:]
                for layer in layers {
                    if Task.isCancelled { break }
                    var single = layer
                    single.strokes = layer.strokes.filter { !$0.usesGPUAnimatedRenderer }
                    var layerDocument = snapshot
                    layerDocument.layers = [single]
                    result[layer.id] = autoreleasepool {
                        AnimatedDrawingRenderer.image(
                            document: layerDocument,
                            phase: phase,
                            outputSize: renderSize,
                            transparent: true,
                            showTransparencyGrid: false,
                            randomizeStrokePhase: randomizeStrokePhase
                        )
                    }
                }
                return result
            }.value

            guard let self else { return }
            self.cpuLayerAnimationRasterTask = nil
            guard self.documentVersion == version,
                  abs(self.latestRequestedRenderSize.width - renderSize.width) <= 1,
                  abs(self.latestRequestedRenderSize.height - renderSize.height) <= 1 else {
                self.requestDisplay()
                return
            }
            self.bakedLayerFrames = self.bakedLayerFrames.filter { validLayerIDs.contains($0.key) }
            for (id, frame) in rendered { self.bakedLayerFrames[id] = frame }
            for id in rendered.keys { self.needsLayerRebakes.remove(id) }
            self.bakedCanvasRenderSize = renderSize
            self.lastCommittedFrameTime = CACurrentMediaTime()

            self.requestDisplay()
        }
        return true
    }

    /// Rebuilds merged CPU-only runs away from the UI thread. Each run is one
    /// bitmap covering several layers, so the same stale-visible-then-swap
    /// strategy as scheduleMixedCPUAnimationRaster applies per run.
    private func scheduleRunCPUAnimationRaster(
        document snapshot: WiggleDocument,
        runs: [[UUID]],
        validRuns: Set<[UUID]>,
        phase: Double,
        renderSize: CGSize,
        randomizeStrokePhase: Bool,
        version: Int
    ) -> Bool {
        guard cpuRunAnimationRasterTask == nil, !runs.isEmpty else { return false }
        cpuRunAnimationRasterTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) { () -> [[UUID]: CGImage] in
                var result: [[UUID]: CGImage] = [:]
                for run in runs {
                    if Task.isCancelled { break }
                    var runDocument = snapshot
                    runDocument.layers = run.compactMap { id in snapshot.layers.first { $0.id == id } }
                    result[run] = autoreleasepool {
                        AnimatedDrawingRenderer.image(
                            document: runDocument,
                            phase: phase,
                            outputSize: renderSize,
                            transparent: true,
                            showTransparencyGrid: false,
                            randomizeStrokePhase: randomizeStrokePhase
                        )
                    }
                }
                return result
            }.value

            guard let self else { return }
            self.cpuRunAnimationRasterTask = nil
            guard self.documentVersion == version,
                  abs(self.latestRequestedRenderSize.width - renderSize.width) <= 1,
                  abs(self.latestRequestedRenderSize.height - renderSize.height) <= 1 else {
                self.requestDisplay()
                return
            }
            self.cpuRunFrames = self.cpuRunFrames.filter { validRuns.contains($0.key) }
            for (run, frame) in rendered { self.cpuRunFrames[run] = frame }
            for run in rendered.keys { self.needsRunRebakes.remove(run) }
            self.bakedCanvasRenderSize = renderSize
            self.lastCommittedFrameTime = CACurrentMediaTime()

            self.requestDisplay()
        }
        return true
    }

    private func scheduleCanvasCPUAnimationRaster(
        document snapshot: WiggleDocument,
        phase: Double,
        renderSize: CGSize,
        randomizeStrokePhase: Bool,
        version: Int
    ) -> Bool {
        guard cpuCanvasAnimationRasterTask == nil else { return false }
        cpuCanvasAnimationRasterTask = Task { [weak self] in
            let frame = await Task.detached(priority: .userInitiated) {
                autoreleasepool {
                    AnimatedDrawingRenderer.image(
                        document: snapshot,
                        phase: phase,
                        outputSize: renderSize,
                        showTransparencyGrid: true,
                        randomizeStrokePhase: randomizeStrokePhase
                    )
                }
            }.value

            guard let self else { return }
            self.cpuCanvasAnimationRasterTask = nil
            guard self.documentVersion == version,
                  abs(self.latestRequestedRenderSize.width - renderSize.width) <= 1,
                  abs(self.latestRequestedRenderSize.height - renderSize.height) <= 1 else {
                self.requestDisplay()
                return
            }
            self.bakedCanvasFrame = frame
            self.bakedCanvasRenderSize = renderSize
            self.needsCommittedRebake = false
            self.lastCommittedFrameTime = CACurrentMediaTime()

            self.requestDisplay()
        }
        return true
    }

    private func requestDisplay() {
        guard isAppActive, window != nil else { return }
        if isAnimationPlaying {
            // When animating the view must keep redrawing. If the display loop
            // ever ended up paused (e.g. a stray mode change), bring it back so
            // the canvas never stays visually frozen until the next stroke.
            if isPaused { isPaused = false }
        } else {
            setNeedsDisplay()
        }
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

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Pencil owns the canvas until its stroke ends. Palm/finger recognizers
        // must never cancel, replace, or undo an in-flight Pencil stroke.
        if isStroking { return false }
        if gestureRecognizer is UITapGestureRecognizer,
           CACurrentMediaTime() - lastPencilStrokeEndedAt < pencilGestureCooldown {
            return false
        }
        guard gestureRecognizer === transformHandlePanGesture else { return true }
        guard isTransformingImage, !transformViewCorners.isEmpty else { return false }
        let location = gestureRecognizer.location(in: self)
        guard let nearest = transformViewCorners.enumerated().min(by: {
            Foundation.hypot($0.element.x - location.x, $0.element.y - location.y)
                < Foundation.hypot($1.element.x - location.x, $1.element.y - location.y)
        }) else { return false }
        let distance = Foundation.hypot(nearest.element.x - location.x, nearest.element.y - location.y)
        guard distance <= 34 else { return false }
        activeTransformHandle = nearest.offset
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

    @objc private func transformHandlePanned(_ gesture: UIPanGestureRecognizer) {
        guard activeTransformHandle != nil, let bounds = transformCanvasBounds else { return }
        let selectionCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let centerInView = viewPoint(fromCanvasPoint: selectionCenter)
        let location = gesture.location(in: self)
        let distance = max(1, Foundation.hypot(location.x - centerInView.x, location.y - centerInView.y))

        switch gesture.state {
        case .began:
            previousHandleDistance = distance
            beginImageTransformGesture()
        case .changed:
            let scale = min(1.2, max(0.8, distance / max(1, previousHandleDistance)))
            let canvasCenter = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
            let translation = CGPoint(
                x: (selectionCenter.x - canvasCenter.x) * (1 - scale),
                y: (selectionCenter.y - canvasCenter.y) * (1 - scale)
            )
            onImageTransformChanged?(Double(scale), translation)
            previousHandleDistance = distance
        case .ended, .cancelled, .failed:
            endImageTransformGesture()
            activeTransformHandle = nil
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
        guard gesture.state == .ended,
              CACurrentMediaTime() - lastPencilStrokeEndedAt >= pencilGestureCooldown else { return }
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
            onColorPickBegan?()
            updateColorPick(at: gesture.location(in: self))
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            requestDisplay()
        case .changed:
            updateColorPick(at: gesture.location(in: self))
        case .ended:
            updateColorPick(at: gesture.location(in: self))
            finishColorPick(commit: true)
        case .cancelled, .failed:
            finishColorPick(commit: false)
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
            ? AnimationTiming.phase(at: elapsed * animationPlaybackSpeed)
            : 0
        return AnimatedDrawingRenderer.image(
            document: document,
            phase: phase,
            outputSize: CGSize(
                width: max(1, sourceWidth * scale),
                height: max(1, sourceHeight * scale)
            ),
            randomizeStrokePhase: isStrokeAnimationRandomized
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

    private func finishColorPick(commit: Bool) {
        onColorPickEnded?(commit)
        colorSamplingFrame = nil
        lastPickedColor = nil
        colorPickIndicator?.removeFromSuperlayer()
        colorPickIndicator = nil
    }

    private func addTransformOverlay() {
        transformBoxLayer.fillColor = UIColor.clear.cgColor
        transformBoxLayer.strokeColor = UIColor.systemBlue.cgColor
        transformBoxLayer.lineWidth = 2
        transformBoxLayer.lineDashPattern = [6, 4]
        transformBoxLayer.shadowColor = UIColor.black.cgColor
        transformBoxLayer.shadowOpacity = 0.35
        transformBoxLayer.shadowRadius = 2
        transformBoxLayer.isHidden = true
        layer.addSublayer(transformBoxLayer)

        transformHandleLayers = (0..<4).map { _ in
            let handle = CAShapeLayer()
            handle.fillColor = UIColor.white.cgColor
            handle.strokeColor = UIColor.systemBlue.cgColor
            handle.lineWidth = 2.5
            handle.shadowColor = UIColor.black.cgColor
            handle.shadowOpacity = 0.4
            handle.shadowRadius = 2
            handle.isHidden = true
            layer.addSublayer(handle)
            return handle
        }
    }

    private func updateTransformOverlay() {
        guard transformBoxLayer.superlayer != nil else { return }
        guard isTransformingImage, let canvasBounds = selectedContentBounds() else {
            transformCanvasBounds = nil
            transformViewCorners = []
            transformBoxLayer.isHidden = true
            transformHandleLayers.forEach { $0.isHidden = true }
            return
        }

        transformCanvasBounds = canvasBounds
        let canvasCorners = [
            CGPoint(x: canvasBounds.minX, y: canvasBounds.minY),
            CGPoint(x: canvasBounds.maxX, y: canvasBounds.minY),
            CGPoint(x: canvasBounds.maxX, y: canvasBounds.maxY),
            CGPoint(x: canvasBounds.minX, y: canvasBounds.maxY)
        ]
        let corners = canvasCorners.map(viewPoint(fromCanvasPoint:))
        transformViewCorners = corners

        let path = CGMutablePath()
        path.move(to: corners[0])
        corners.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transformBoxLayer.frame = bounds
        transformBoxLayer.path = path
        transformBoxLayer.isHidden = false
        for (index, handle) in transformHandleLayers.enumerated() {
            let point = corners[index]
            let radius: CGFloat = 8
            handle.frame = bounds
            handle.path = UIBezierPath(
                ovalIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            ).cgPath
            handle.isHidden = false
        }
        CATransaction.commit()
    }

    private func selectedContentBounds() -> CGRect? {
        var selectionBounds = CGRect.null
        let canvasCenter = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)

        for layer in document.layers where transformTargetLayerIDs.contains(layer.id) {
            var rawBounds = CGRect.null

            for stroke in layer.strokes {
                let margin = CGFloat(stroke.brush.size + stroke.brush.motionAmount) / 2
                for sample in stroke.samples {
                    rawBounds = rawBounds.union(CGRect(
                        x: sample.x - margin,
                        y: sample.y - margin,
                        width: margin * 2,
                        height: margin * 2
                    ))
                }
            }

            for fill in layer.fills ?? [] {
                for sample in fill.samples {
                    rawBounds = rawBounds.union(CGRect(x: sample.x, y: sample.y, width: 0.5, height: 0.5))
                }
            }

            if let data = layer.imageData, let imageSize = importedImageSize(for: layer.id, data: data) {
                let canvasSize = CGSize(width: document.width, height: document.height)
                let fittedScale = min(
                    canvasSize.width / max(1, imageSize.width),
                    canvasSize.height / max(1, imageSize.height)
                ) * layer.resolvedImageScale
                let size = CGSize(width: imageSize.width * fittedScale, height: imageSize.height * fittedScale)
                let imageOffset = layer.resolvedImageOffset
                rawBounds = rawBounds.union(CGRect(
                    x: canvasCenter.x - size.width / 2 + imageOffset.x,
                    y: canvasCenter.y - size.height / 2 + imageOffset.y,
                    width: size.width,
                    height: size.height
                ))
            }

            guard !rawBounds.isNull else { continue }
            let scale = CGFloat(layer.resolvedContentScale)
            let contentOffset = layer.resolvedContentOffset
            let transformed = CGRect(
                x: canvasCenter.x + (rawBounds.minX - canvasCenter.x) * scale + contentOffset.x,
                y: canvasCenter.y + (rawBounds.minY - canvasCenter.y) * scale + contentOffset.y,
                width: rawBounds.width * scale,
                height: rawBounds.height * scale
            )
            selectionBounds = selectionBounds.union(transformed)
        }

        guard !selectionBounds.isNull, selectionBounds.width > 0, selectionBounds.height > 0 else { return nil }
        return selectionBounds.insetBy(dx: -4, dy: -4)
    }

    private func importedImageSize(for layerID: UUID, data: Data) -> CGSize? {
        if let cached = importedImageSizes[layerID], cached.dataCount == data.count {
            return cached.size
        }
        guard let size = UIImage(data: data)?.size else { return nil }
        importedImageSizes[layerID] = (data.count, size)
        return size
    }

    private var fittedRect: CGRect {
        if canvasFillsView {
            return bounds
        }
        let canvasAspect = CGFloat(document.width) / CGFloat(document.height)
        let viewAspect = bounds.width / max(1, bounds.height)
        let inset = min(1, max(0.25, canvasInsetFactor))
        let size: CGSize
        if canvasAspect > viewAspect {
            size = CGSize(width: bounds.width * inset, height: bounds.width * inset / canvasAspect)
        } else {
            size = CGSize(width: bounds.height * inset * canvasAspect, height: bounds.height * inset)
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
        onCanvasInteraction?()
        guard !isTransformingImage else { return }
        // A second finger while a shape is locked confirms (perfects) it.
        if isStroking, shapeLock != nil,
           touches.contains(where: { $0.type == .direct }),
           !touches.contains(where: { $0 === primaryTouch }) {
            confirmQuickShape()
            return
        }
        // Ignore every additional contact while a stroke owns the canvas. This
        // is especially important in Pencil + finger mode, where a palm touch
        // must not clear samples and become the new primary touch.
        if isStroking { return }
        guard let touch = touches.first(where: accepts) else { return }
        if touch.type == .direct && hasMultipleDirectTouches(event) {
            // A second finger belongs to a gesture (undo/redo/pinch/confirm),
            // never a drawing stroke. Tear down any stroke this touch sequence
            // may have started so no stale isStroking/primaryTouch/hold-lock
            // survives the gesture and leaves the canvas non-responsive.
            if isStroking {
                samples.removeAll(keepingCapacity: true)
                isStroking = false
                primaryTouch = nil
                holdWorkItem?.cancel()
                holdWorkItem = nil
            }
            return
        }
        if isDrawingBlocked {
            onDrawBlocked?()
            return
        }
        let point = canvasPoint(from: touch.location(in: self))
        if isErasing {
            onErase?(point)
        } else if isSelecting {
            onSelect?(point)
        } else {
            samples.removeAll(keepingCapacity: true)
            activeStrokeID = UUID()
            startedAt = touch.timestamp
            pointSmoother.reset(amount: effectiveSmoothing)
            isStroking = true
            primaryTouch = touch
            append(touch)
            scheduleHoldLock()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !isTransformingImage else { return }
        // While a shape is locked, moving the pencil drives the shape
        // (endpoint for a line, rotation/size for closed shapes) Procreate-style.
        // Any movement on the confirm finger is ignored. Nothing reverts to
        // freehand here — the lock holds until the pencil lifts.
        if shapeLock != nil, isStroking, !isErasing, !isSelecting {
            if let primaryTouch, touches.contains(where: { $0 === primaryTouch }) {
                manipulateLockedShape(to: canvasPoint(from: primaryTouch.location(in: self)))
            }
            return
        }
        let touch: UITouch?
        if isStroking, let primaryTouch {
            touch = touches.first(where: { $0 === primaryTouch })
        } else {
            touch = touches.first(where: accepts)
        }
        guard let touch else { return }
        if touch.type == .direct && hasMultipleDirectTouches(event) {
            // Two-finger drawing is cleared; a second finger is only used to
            // confirm a locked shape, which never reaches this branch.
            samples.removeAll()
            return
        }
        if isDrawingBlocked {
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
            isStroking = false
            primaryTouch = nil
            return
        }
        // Lifting the primary pencil while a shape is locked commits the shape.
        if isStroking, shapeLock != nil, let primary = primaryTouch,
           touches.contains(where: { $0 === primary }) {
            if primary.type == .pencil { lastPencilStrokeEndedAt = CACurrentMediaTime() }
            commitQuickShape()
            return
        }
        // A confirm (second) finger lifting must not disturb the primary stroke.
        if isStroking, shapeLock != nil, let primary = primaryTouch,
           !touches.contains(where: { $0 === primary }) {
            return
        }
        guard let primaryTouch,
              touches.contains(where: { $0 === primaryTouch }),
              samples.count > 1,
              !isErasing,
              !isSelecting else {
            // An unrelated finger lifted while Pencil still owns the stroke.
            if self.primaryTouch != nil,
               !touches.contains(where: { $0 === self.primaryTouch }) {
                return
            }
            samples.removeAll()
            isStroking = false
            primaryTouch = nil
            holdWorkItem?.cancel()
            holdWorkItem = nil
            return
        }
        var completedStroke = AnimatedStroke(id: activeStrokeID, samples: samples, brush: brush)
        completedStroke.isPreview = true
        committedStrokePreview = completedStroke
        if primaryTouch.type == .pencil { lastPencilStrokeEndedAt = CACurrentMediaTime() }
        samples.removeAll(keepingCapacity: true)
        isStroking = false
        self.primaryTouch = nil
        onStroke?(completedStroke)
        requestDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Gesture recognizers may cancel only their direct (finger/palm) touches.
        // Do not let that cancellation destroy an unrelated active Pencil stroke.
        if let primaryTouch, !touches.contains(where: { $0 === primaryTouch }) { return }
        if primaryTouch?.type == .pencil { lastPencilStrokeEndedAt = CACurrentMediaTime() }
        samples.removeAll()
        isStroking = false
        primaryTouch = nil
        holdWorkItem?.cancel()
        holdWorkItem = nil
        shapeLock = nil
        shapeLockedSamples = nil
        shapePerfectSamples = nil
        lockedRawEndPoint = nil
        shapeLockedKind = nil
        shapeLockedCenter = nil
        shapeLockedBaseSamples = nil
        shapeLockedRefPoint = nil
        if forceContinuousDisplay {
            forceContinuousDisplay = false
            configureDisplayMode()
        }
        requestDisplay()
    }

    private var effectiveSmoothing: Double {
        min(1, max(0, max(brush.smoothing, globalSmoothing)))
    }

    private func append(_ touch: UITouch) {
        let location = canvasPoint(from: touch.location(in: self))
        let maximum = max(touch.maximumPossibleForce, 1)
        let pressure = touch.type == .pencil ? touch.force / maximum : 0.5
        let tilt = 1 - touch.altitudeAngle / (.pi / 2)
        let azimuth = touch.azimuthAngle(in: self)
        let raw = StrokeSample(
            x: location.x,
            y: location.y,
            pressure: pressure,
            tilt: tilt,
            azimuth: azimuth,
            timestamp: touch.timestamp - startedAt
        )
        // StreamLine-style windowed smoothing: average the recent raw input so
        // high-frequency jitter is averaged out while the stroke still tracks
        // the pencil (weights favor the newest point to keep lag low).
        let candidate = pointSmoother.push(raw)
        if let last = samples.last {
            let distance = hypot(last.x - candidate.x, last.y - candidate.y)
            guard distance >= max(1, brush.spacing * 0.2) else { return }
        }
        samples.append(candidate)
        scheduleHoldLock()
        requestDisplay()
    }

    // MARK: - QuickShape (hold-to-straighten)

    private func scheduleHoldLock() {
        holdWorkItem?.cancel()
        guard isStroking, primaryTouch != nil, isErasing == false, isSelecting == false else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.fireHoldLock()
        }
        holdWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + holdLockDuration, execute: item)
    }

    private func fireHoldLock() {
        holdWorkItem = nil
        guard isStroking, primaryTouch != nil, shapeLock == nil,
              !isErasing, !isSelecting, !isTransformingImage,
              samples.count >= 3 else { return }
        guard let fit = QuickShapeFitter.fit(samples) else { return }
        // Baseline for hold-and-adjust: a line anchors at its first point and
        // drags its end; closed shapes rotate/resize around the fit center
        // following the pencil's angle/distance from its lock-time position.
        shapeLock = fit
        shapeLockedSamples = fit.samples
        shapePerfectSamples = nil
        lockedRawEndPoint = samples.last
        shapeLockedKind = fit.kind
        shapeLockedCenter = fit.kind == .line ? fit.samples.first?.point : fit.center
        shapeLockedBaseSamples = fit.samples
        shapeLockedRefPoint = samples.last?.point ?? fit.center
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        requestDisplay()
    }

    private func confirmQuickShape() {
        guard let fit = shapeLock else { return }
        let perfect = QuickShapeFitter.perfectSamples(for: fit)
        shapePerfectSamples = perfect
        shapeLockedSamples = perfect
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        requestDisplay()
    }

    private func commitQuickShape() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        let points = shapePerfectSamples ?? shapeLockedSamples ?? samples
        if points.count > 1 {
            var completedStroke = AnimatedStroke(id: activeStrokeID, samples: points, brush: brush)
            completedStroke.isPreview = true
            committedStrokePreview = completedStroke
            onStroke?(completedStroke)
        }
        samples.removeAll(keepingCapacity: true)
        isStroking = false
        primaryTouch = nil
        shapeLock = nil
        shapeLockedSamples = nil
        shapePerfectSamples = nil
        lockedRawEndPoint = nil
        shapeLockedKind = nil
        shapeLockedCenter = nil
        shapeLockedBaseSamples = nil
        shapeLockedRefPoint = nil
        requestDisplay()
    }

    private func manipulateLockedShape(to penPoint: CGPoint) {
        // Once confirmed with a second finger the shape is frozen; the pencil
        // just keeps it locked until lift commits.
        if shapePerfectSamples != nil { return }
        guard let kind = shapeLockedKind, let base = shapeLockedBaseSamples,
              let prototype = base.last, let anchor = shapeLockedCenter,
              let refPoint = shapeLockedRefPoint else { return }

        let locked: [StrokeSample]
        switch kind {
        case .line:
            // Anchor at the point the pen was first put down (the stroke's
            // start), and drag the far end to the pencil. Using the fit's own
            // min/max endpoint here collapses right-to-left strokes because the
            // pencil rests on that endpoint at lock time.
            guard let start = samples.first?.point else { return }
            locked = QuickShapeFitter.lineSamples(
                from: start, to: penPoint, prototype: prototype
            )
        default:
            // Rotate + scale the closed shape around its center so the pencil
            // position matches its angle/distance from the lock-time reference.
            let v0 = CGPoint(x: refPoint.x - anchor.x, y: refPoint.y - anchor.y)
            let v1 = CGPoint(x: penPoint.x - anchor.x, y: penPoint.y - anchor.y)
            let angle = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
            let cosA = cos(angle), sinA = sin(angle)
            let len0 = max(1e-4, hypot(v0.x, v0.y))
            let scale = hypot(v1.x, v1.y) / len0
            let points = base.map { sample -> CGPoint in
                let dx = sample.point.x - anchor.x
                let dy = sample.point.y - anchor.y
                return CGPoint(
                    x: anchor.x + (dx * cosA - dy * sinA) * scale,
                    y: anchor.y + (dx * sinA + dy * cosA) * scale
                )
            }
            locked = QuickShapeFitter.samples(fromPoints: points, prototype: prototype)
        }
        shapeLockedSamples = locked
        requestDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard canSubmitGPUWork else {
            isPaused = true
            return
        }
        let frameSignpost = OSSignpostID(log: performanceLog)
        os_signpost(.begin, log: performanceLog, name: "Canvas Frame CPU", signpostID: frameSignpost)
        defer { os_signpost(.end, log: performanceLog, name: "Canvas Frame CPU", signpostID: frameSignpost) }
        let currentTime = CACurrentMediaTime()
        let elapsed = currentTime - displayStart
        let phase = isAnimationPlaying
            ? AnimationTiming.phase(at: elapsed * animationPlaybackSpeed)
            : 0
        let rect = fittedRect
        let nativeScale = contentScaleFactor
        let longestSide = max(1, max(rect.width, rect.height))
        // Raster the canvas 1:1 with its on-screen footprint so baked CPU
        // content never looks softened next to the Metal brush layers.
        let renderLimit = max(2_048, drawableSize.width, drawableSize.height)
        let renderScale = min(nativeScale, max(1, renderLimit / longestSide))
        let renderSize = CGSize(
            width: max(1, rect.width * renderScale),
            height: max(1, rect.height * renderScale)
        )
        latestRequestedRenderSize = renderSize
        var activeStroke: AnimatedStroke?
        if let locked = shapeLockedSamples, locked.count > 1 {
            activeStroke = AnimatedStroke(id: activeStrokeID, samples: locked, brush: brush)
        } else {
            activeStroke = samples.count > 1
                ? AnimatedStroke(id: activeStrokeID, samples: samples, brush: brush)
                : committedStrokePreview
        }
        activeStroke?.isPreview = true
        activeStroke = activeStroke?.limitedForLivePreview()
        let activeKind = activeStroke?.brush.kind
        // The live stroke is never part of the baked bitmap. A CPU-brush live
        // stroke is rasterized on top of the committed canvas; a GPU-brush live
        // stroke is drawn by its renderer as the preview stroke.
        // Faded stays on the CPU once committed so canvas playback remains an
        // exact match for export. While the Pencil is down, however, rendering
        // a full-size Core Graphics image for every coalesced touch can miss
        // every visible frame. Its Metal renderer is therefore used only as a
        // responsive under-Pencil preview.
        let activeUsesGPUPreview = activeStroke.map {
            $0.usesGPUAnimatedRenderer || $0.brush.kind == .faded
        } ?? false
        let activeOnCPU = activeStroke != nil && !activeUsesGPUPreview
        if activeStroke != nil {
            if !forceContinuousDisplay {
                forceContinuousDisplay = true
                isPaused = false
            }
            updatePreferredFrameRate()
        }

        // Committed content is rasterized into a cached bitmap and redrawn per
        // frame. GPU-eligible strokes are excluded per-stroke — their renderers
        // draw them, animated, on top. CPU-committed content is re-rasterized
        // at a throttled rate during playback so those brushes keep animating,
        // but is held static while a stroke is being drawn so drawing stays
        // cheap.
        let sizeChanged = abs(bakedCanvasRenderSize.width - renderSize.width) > 1
            || abs(bakedCanvasRenderSize.height - renderSize.height) > 1
        let canAnimateCommitted = isAnimationPlaying && activeStroke == nil
        let committedFrameInterval = 1.0 / 30.0
        // Faded remains the exact Core Graphics brush, but uses the layered
        // cache path so heavy surrounding artwork stays baked while only its
        // isolated layer advances through the already-cached erosion frames.
        let hasCommittedGPU = documentContainsGPUAnimation || documentContainsFadedCPUAnimation
        let hasAnimatedCPUContent = documentContainsAnimatedCPUContent
        func encodeLayerCommitted(_ layerID: UUID, encoder: MTLRenderCommandEncoder) {
            let canvasSize = SIMD2<Float>(Float(document.width), Float(document.height))
            let viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
            let fitted = SIMD2<Float>(Float(rect.width), Float(rect.height))
            let center = SIMD2<Float>(Float(offset.x), Float(offset.y))
            let z = Float(zoom)
            let r = Float(rotation)
            let p = Float(phase)
            let wave: Float = 1
            dashedRenderer?.encode(encoder: encoder, transform: MetalDashedRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
            dryOutlineRenderer?.encode(encoder: encoder, transform: MetalDryOutlineRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p), layerID: layerID)
            starRenderer?.encode(encoder: encoder, transform: MetalStarRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
            particleRenderer?.encode(encoder: encoder, transform: MetalParticleRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
            particleCloudRenderer?.encode(encoder: encoder, transform: MetalParticleCloudRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
            scribblesRenderer?.encode(encoder: encoder, transform: MetalScribblesRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
            proceduralBrushRenderer?.encode(encoder: encoder, transform: MetalProceduralBrushRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
            checkerRenderer?.encode(encoder: encoder, transform: MetalCheckerRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
            outlineFillRenderer?.encode(encoder: encoder, transform: MetalOutlineFillRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), layerID: layerID)
        }
        func encodePreview(_ stroke: AnimatedStroke, into target: MTLTexture, commandBuffer: MTLCommandBuffer) {
            let kind = stroke.brush.kind
            guard stroke.usesGPUAnimatedRenderer || stroke.brush.kind == .faded else { return }
            let canvasSize = SIMD2<Float>(Float(document.width), Float(document.height))
            let viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))
            let fitted = SIMD2<Float>(Float(rect.width), Float(rect.height))
            let center = SIMD2<Float>(Float(offset.x), Float(offset.y))
            let z = Float(zoom)
            let r = Float(rotation)
            let p = Float(phase)
            let wave: Float = 1
            switch kind {
            case .dashed:
                dashedRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalDashedRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .dryOutline:
                dryOutlineRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalDryOutlineRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p), previewStroke: stroke)
            case .star:
                starRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalStarRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .particle:
                particleRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalParticleRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .particleCloud:
                particleCloudRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalParticleCloudRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .scribbles:
                scribblesRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalScribblesRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .goo:
                proceduralBrushRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalProceduralBrushRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .solidColor, .glitter, .gradient, .faded, .retro:
                proceduralBrushRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalProceduralBrushRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .checker:
                checkerRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalCheckerRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            case .outlineFill:
                outlineFillRenderer?.encodePreview(commandBuffer: commandBuffer, target: target, transform: MetalOutlineFillRenderer.ViewTransform(canvasSize: canvasSize, viewSize: viewSize, fittedSize: fitted, centerOffset: center, zoom: z, rotation: r, phase: p, waveAmount: wave), previewStroke: stroke)
            default:
                break
            }
        }
        if hasCommittedGPU {
            // When a document mixes CPU and GPU strokes, CPU content cannot be
            // baked as a single bitmap with every GPU stroke drawn on top of it:
            // a GPU stroke on a lower layer must stay underneath the CPU content
            // of higher layers. Instead each layer's CPU raster and GPU strokes
            // are composed in document order so z-order is always correct.
            // GPU layers are composed per layer (CPU raster under their GPU
            // strokes for z-order). Contiguous CPU-only layers are merged into
            // runs, each rasterized as one bitmap, so CPU-heavy documents cost
            // one texture + composite per run instead of one per layer.
            let gpuLayerIDs = Set(visibleLayerRenderStates.filter(\.hasGPUStroke).map(\.id))
            let visibleGPULayers = document.layers.filter { gpuLayerIDs.contains($0.id) }
            let animationTick = canAnimateCommitted
                && hasAnimatedCPUContent
                && currentTime - lastCommittedFrameTime >= committedFrameInterval
            let hasMissingGPUFrame = visibleGPULayers.contains { bakedLayerFrames[$0.id] == nil }
            let hasMissingRun = cpuRuns.contains { cpuRunFrames[$0] == nil }
            let needsSynchronousRaster = bakedGridFrame == nil || sizeChanged
                || hasMissingGPUFrame || hasMissingRun
            if needsSynchronousRaster {
                let rasterSignpost = OSSignpostID(log: performanceLog)
                os_signpost(
                    .begin,
                    log: performanceLog,
                    name: "Core Graphics Raster",
                    signpostID: rasterSignpost,
                    "samples=%{public}d",
                    sourceSampleCount
                )
                autoreleasepool {
                    if bakedGridFrame == nil || sizeChanged {
                        var gridDocument = document
                        // The base is only the document background/transparency
                        // grid. Images and fills belong to their actual layers;
                        // putting them here both duplicated them and broke z-order.
                        gridDocument.layers.removeAll(keepingCapacity: true)
                        bakedGridFrame = AnimatedDrawingRenderer.image(
                            document: gridDocument,
                            phase: phase,
                            outputSize: renderSize,
                            transparent: false,
                            showTransparencyGrid: true,
                            randomizeStrokePhase: isStrokeAnimationRandomized
                        )
                    }

                    var frames = sizeChanged ? [:] : bakedLayerFrames
                    frames = frames.filter { gpuLayerIDs.contains($0.key) }
                    for layer in visibleGPULayers {
                        let cpuStrokes = layer.strokes.filter { !$0.usesGPUAnimatedRenderer }
                        let layerIsAnimated = !cpuStrokes.isEmpty
                            || (layer.fills ?? []).contains(where: {
                                !($0.animatedMaskFrames?.isEmpty ?? true)
                                    || !($0.animatedContours?.isEmpty ?? true)
                            })
                        guard sizeChanged || frames[layer.id] == nil
                            || (animationTick && layerIsAnimated) else { continue }
                        var single = layer
                        single.strokes = cpuStrokes
                        var layerDocument = document
                        layerDocument.layers = [single]
                        frames[layer.id] = AnimatedDrawingRenderer.image(
                            document: layerDocument,
                            phase: phase,
                            outputSize: renderSize,
                            transparent: true,
                            showTransparencyGrid: false,
                            randomizeStrokePhase: isStrokeAnimationRandomized
                        )
                    }
                    bakedLayerFrames = frames

                    var runFrames = sizeChanged ? [:] : cpuRunFrames
                    let validRuns = Set(cpuRuns)
                    runFrames = runFrames.filter { validRuns.contains($0.key) }
                    for run in cpuRuns {
                        let runIsAnimated = run.contains { animatedCPULayerIDs.contains($0) }
                        guard sizeChanged || runFrames[run] == nil
                            || (animationTick && runIsAnimated) else { continue }
                        var runDocument = document
                        runDocument.layers = run.compactMap { id in document.layers.first { $0.id == id } }
                        runFrames[run] = AnimatedDrawingRenderer.image(
                            document: runDocument,
                            phase: phase,
                            outputSize: renderSize,
                            transparent: true,
                            showTransparencyGrid: false,
                            randomizeStrokePhase: isStrokeAnimationRandomized
                        )
                    }
                    cpuRunFrames = runFrames
                }
                os_signpost(.end, log: performanceLog, name: "Core Graphics Raster", signpostID: rasterSignpost)
                bakedCanvasRenderSize = renderSize
                needsLayerRebakes.removeAll(keepingCapacity: true)
                needsRunRebakes.removeAll(keepingCapacity: true)
                lastCommittedFrameTime = currentTime
            } else if !needsLayerRebakes.isEmpty || !needsRunRebakes.isEmpty {
                // A committed CPU edit invalidated GPU-layer frames and/or CPU
                // runs. Keep the stale content visible and re-raster off the
                // main thread instead of blocking the draw loop. If a raster is
                // already in flight the flags are kept so the next frame retries.
                let pendingLayers = visibleGPULayers.filter { needsLayerRebakes.contains($0.id) }
                let pendingRuns = cpuRuns.filter { needsRunRebakes.contains($0) }
                needsLayerRebakes.removeAll(keepingCapacity: true)
                needsRunRebakes.removeAll(keepingCapacity: true)
                if !pendingLayers.isEmpty,
                   !scheduleMixedCPUAnimationRaster(
                       document: document,
                       layers: pendingLayers,
                       validLayerIDs: gpuLayerIDs,
                       phase: phase,
                       renderSize: renderSize,
                       randomizeStrokePhase: isStrokeAnimationRandomized,
                       version: documentVersion
                   ) {
                    needsLayerRebakes.formUnion(pendingLayers.map(\.id))
                }
                if !pendingRuns.isEmpty,
                   !scheduleRunCPUAnimationRaster(
                       document: document,
                       runs: pendingRuns,
                       validRuns: Set(cpuRuns),
                       phase: phase,
                       renderSize: renderSize,
                       randomizeStrokePhase: isStrokeAnimationRandomized,
                       version: documentVersion
                   ) {
                    needsRunRebakes.formUnion(pendingRuns)
                }
            } else if animationTick {
                let animatedLayers = visibleGPULayers.filter { animatedCPULayerIDs.contains($0.id) }
                _ = scheduleMixedCPUAnimationRaster(
                    document: document,
                    layers: animatedLayers,
                    validLayerIDs: gpuLayerIDs,
                    phase: phase,
                    renderSize: renderSize,
                    randomizeStrokePhase: isStrokeAnimationRandomized,
                    version: documentVersion
                )
                let animatedRuns = cpuRuns.filter { run in run.contains { animatedCPULayerIDs.contains($0) } }
                _ = scheduleRunCPUAnimationRaster(
                    document: document,
                    runs: animatedRuns,
                    validRuns: Set(cpuRuns),
                    phase: phase,
                    renderSize: renderSize,
                    randomizeStrokePhase: isStrokeAnimationRandomized,
                    version: documentVersion
                )
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let drawable = view.currentDrawable,
                  let textureCompositor else { return }

            var liveCPUPreviewFrame: CGImage?
            let activeLayerOpacity = previewLayerOpacity(for: activeStroke)
            if activeOnCPU, let activeStroke {
                var previewDocument = document
                previewDocument.layers.removeAll(keepingCapacity: true)
                liveCPUPreviewFrame = autoreleasepool(invoking: {
                    AnimatedDrawingRenderer.image(
                        document: previewDocument,
                        phase: phase,
                        outputSize: renderSize,
                        transparent: true,
                        randomizeStrokePhase: isStrokeAnimationRandomized,
                        previewStroke: activeStroke,
                        previewLayerOpacity: activeLayerOpacity
                    )
                })
            }

            var units: [CompositeUnit] = []
            var emittedRuns: Set<[UUID]> = []
            for state in visibleLayerRenderStates {
                if state.hasGPUStroke {
                    units.append(CompositeUnit(
                        runID: nil,
                        layerID: state.id,
                        runImage: nil,
                        layerImage: bakedLayerFrames[state.id]
                    ))
                } else if state.hasCPUContent {
                    guard let run = cpuRuns.first(where: { $0.contains(state.id) }) else { continue }
                    if emittedRuns.insert(run).inserted {
                        units.append(CompositeUnit(
                            runID: run,
                            layerID: nil,
                            runImage: cpuRunFrames[run],
                            layerImage: nil
                        ))
                    }
                }
            }

            var baseImages: [CGImage] = []
            if let bakedGridFrame { baseImages.append(bakedGridFrame) }
            for unit in units {
                if let runImage = unit.runImage { baseImages.append(runImage) }
                if let layerImage = unit.layerImage { baseImages.append(layerImage) }
            }
            textureCompositor.prepare(images: baseImages)

            // The committed scene is encoded into a cached offscreen texture.
            // Rendering the GPU layers is the expensive part (their fragment
            // shaders cover more pixels as zoom grows), so while drawing — when
            // content, viewport, and phase are all static — each frame only
            // blits the cached base and draws the live stroke. Playback is
            // excluded: the scene animates, so caching would not help.
            let textureWidth = Int(drawableSize.width)
            let textureHeight = Int(drawableSize.height)
            var contentHash = 0
            for image in baseImages { contentHash ^= ObjectIdentifier(image).hashValue }
            let cacheEnabled = !isAnimationPlaying
            let cacheKey = MixedCacheKey(
                contentHash: contentHash,
                contentVersion: documentVersion,
                drawableWidth: textureWidth,
                drawableHeight: textureHeight,
                zoom: zoom,
                rotation: rotation,
                offset: offset,
                surroundingRed: CGFloat(surroundingColor.red),
                surroundingGreen: CGFloat(surroundingColor.green),
                surroundingBlue: CGFloat(surroundingColor.blue),
                surroundingAlpha: CGFloat(surroundingColor.alpha)
            )
            var needsBaseRender = mixedBaseTexture == nil
                || mixedBaseTexture!.width != textureWidth
                || mixedBaseTexture!.height != textureHeight
                || mixedBaseKey != cacheKey
            if !cacheEnabled { needsBaseRender = true }
            if needsBaseRender, textureWidth > 0, textureHeight > 0 {
                if mixedBaseTexture == nil
                    || mixedBaseTexture!.width != textureWidth
                    || mixedBaseTexture!.height != textureHeight {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: drawable.texture.pixelFormat,
                        width: textureWidth,
                        height: textureHeight,
                        mipmapped: false
                    )
                    descriptor.usage = [.shaderRead, .renderTarget]
                    descriptor.storageMode = .private
                    mixedBaseTexture = commandQueue.device.makeTexture(descriptor: descriptor)
                }
                let basePass = MTLRenderPassDescriptor()
                basePass.colorAttachments[0].texture = mixedBaseTexture
                basePass.colorAttachments[0].loadAction = .clear
                basePass.colorAttachments[0].storeAction = .store
                basePass.colorAttachments[0].clearColor = MTLClearColor(
                    red: Double(surroundingColor.red),
                    green: Double(surroundingColor.green),
                    blue: Double(surroundingColor.blue),
                    alpha: Double(surroundingColor.alpha)
                )
                if let baseEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: basePass) {
                    baseEncoder.label = "Cached Mixed Canvas Base"
                    let compositorTransform = MetalTextureCompositor.ViewTransform(
                        canvasSize: SIMD2(Float(document.width), Float(document.height)),
                        viewSize: SIMD2(Float(bounds.width), Float(bounds.height)),
                        fittedSize: SIMD2(Float(rect.width), Float(rect.height)),
                        centerOffset: SIMD2(Float(offset.x), Float(offset.y)),
                        zoom: Float(zoom),
                        rotation: Float(rotation)
                    )
                    if let grid = bakedGridFrame {
                        textureCompositor.encode(image: grid, encoder: baseEncoder, transform: compositorTransform)
                    }
                    for unit in units {
                        if let runImage = unit.runImage {
                            textureCompositor.encode(image: runImage, encoder: baseEncoder, transform: compositorTransform)
                        }
                        if let layerImage = unit.layerImage {
                            textureCompositor.encode(image: layerImage, encoder: baseEncoder, transform: compositorTransform)
                        }
                        if let layerID = unit.layerID {
                            encodeLayerCommitted(layerID, encoder: baseEncoder)
                        }
                    }
                    baseEncoder.endEncoding()
                    // Publish the key only once the base was rendered, so a frame
                    // that skipped encoding (0-sized drawable, unavailable encoder)
                    // retries next frame instead of blitting a stale-zoom base.
                    mixedBaseKey = cacheKey
                }
            }
            if let base = mixedBaseTexture,
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(
                    from: base,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: base.width, height: base.height, depth: 1),
                    to: drawable.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                blit.endEncoding()
            }

            // Overlay the live CPU stroke on top of the cached base. It changes
            // every frame while drawing, so it is never part of the cached base.
            if let liveCPUPreviewFrame {
                let overlayPass = MTLRenderPassDescriptor()
                overlayPass.colorAttachments[0].texture = drawable.texture
                overlayPass.colorAttachments[0].loadAction = .load
                overlayPass.colorAttachments[0].storeAction = .store
                if let overlayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: overlayPass) {
                    overlayEncoder.label = "Live CPU Preview Overlay"
                    let compositorTransform = MetalTextureCompositor.ViewTransform(
                        canvasSize: SIMD2(Float(document.width), Float(document.height)),
                        viewSize: SIMD2(Float(bounds.width), Float(bounds.height)),
                        fittedSize: SIMD2(Float(rect.width), Float(rect.height)),
                        centerOffset: SIMD2(Float(offset.x), Float(offset.y)),
                        zoom: Float(zoom),
                        rotation: Float(rotation)
                    )
                    textureCompositor.encode(
                        image: liveCPUPreviewFrame,
                        encoder: overlayEncoder,
                        transform: compositorTransform
                    )
                    overlayEncoder.endEncoding()
                }
            }

            if !activeOnCPU, let activeStroke {
                encodePreview(activeStroke, into: drawable.texture, commandBuffer: commandBuffer)
            }
            guard canSubmitGPUWork else { return }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            updateTransformOverlay()
        } else {
        let cpuAnimationTick = canAnimateCommitted
            && hasAnimatedCPUContent
            && currentTime - lastCommittedFrameTime >= committedFrameInterval
        if bakedCanvasFrame == nil || sizeChanged {
            var baseDocument = document
            for index in baseDocument.layers.indices {
                baseDocument.layers[index].strokes.removeAll { $0.usesGPUAnimatedRenderer }
            }
            let rasterSignpost = OSSignpostID(log: performanceLog)
            os_signpost(
                .begin,
                log: performanceLog,
                name: "Core Graphics Raster",
                signpostID: rasterSignpost,
                "samples=%{public}d",
                sourceSampleCount
            )
            bakedCanvasFrame = autoreleasepool(invoking: {
                AnimatedDrawingRenderer.image(
                    document: baseDocument,
                    phase: phase,
                    outputSize: renderSize,
                    showTransparencyGrid: true,
                    randomizeStrokePhase: isStrokeAnimationRandomized
                )
            })
            os_signpost(.end, log: performanceLog, name: "Core Graphics Raster", signpostID: rasterSignpost)
            bakedCanvasRenderSize = renderSize
            needsCommittedRebake = false
            lastCommittedFrameTime = currentTime
        } else if needsCommittedRebake {
            // A committed CPU edit invalidated the full-canvas bake. Keep the
            // previous frame visible and re-raster off the main thread so the
            // commit never blocks the draw loop. If a raster is already in
            // flight the flag is kept so the next frame retries.
            needsCommittedRebake = false
            if !scheduleCanvasCPUAnimationRaster(
                document: document,
                phase: phase,
                renderSize: renderSize,
                randomizeStrokePhase: isStrokeAnimationRandomized,
                version: documentVersion
            ) {
                needsCommittedRebake = true
            }
        } else if cpuAnimationTick {
            _ = scheduleCanvasCPUAnimationRaster(
                document: document,
                phase: phase,
                renderSize: renderSize,
                randomizeStrokePhase: isStrokeAnimationRandomized,
                version: documentVersion
            )
        }
        guard let documentFrame = bakedCanvasFrame else { return }

        // Only the live CPU stroke is re-rasterized per frame; the committed
        // content stays baked in documentFrame. Both are composited with Metal.
        var liveCPUPreviewFrame: CGImage?
        if activeOnCPU, let activeStroke {
            var previewDocument = document
            previewDocument.layers.removeAll(keepingCapacity: true)
            liveCPUPreviewFrame = autoreleasepool(invoking: {
                AnimatedDrawingRenderer.image(
                    document: previewDocument,
                    phase: phase,
                    outputSize: renderSize,
                    transparent: true,
                    randomizeStrokePhase: isStrokeAnimationRandomized,
                    previewStroke: activeStroke,
                    previewLayerOpacity: previewLayerOpacity(for: activeStroke)
                )
            })
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = view.currentDrawable,
              let textureCompositor else { return }

        var baseImages: [CGImage] = [documentFrame]
        if let liveCPUPreviewFrame { baseImages.append(liveCPUPreviewFrame) }
        textureCompositor.prepare(images: baseImages)

        // The committed frame + viewport transform is encoded once into a cached
        // offscreen texture. While drawing (viewport/content static) each frame
        // is a blit plus the live stroke, instead of a full-screen Core Image
        // composite every frame — the CPU-path analogue of the mixed path.
        let textureWidth = Int(drawableSize.width)
        let textureHeight = Int(drawableSize.height)
        let cpuKey = CPUBaseKey(
            contentHash: ObjectIdentifier(documentFrame).hashValue,
            contentVersion: documentVersion,
            drawableWidth: textureWidth,
            drawableHeight: textureHeight,
            zoom: zoom,
            rotation: rotation,
            offset: offset,
            surroundingRed: CGFloat(surroundingColor.red),
            surroundingGreen: CGFloat(surroundingColor.green),
            surroundingBlue: CGFloat(surroundingColor.blue),
            surroundingAlpha: CGFloat(surroundingColor.alpha)
        )
        let compositorTransform = MetalTextureCompositor.ViewTransform(
            canvasSize: SIMD2(Float(document.width), Float(document.height)),
            viewSize: SIMD2(Float(bounds.width), Float(bounds.height)),
            fittedSize: SIMD2(Float(rect.width), Float(rect.height)),
            centerOffset: SIMD2(Float(offset.x), Float(offset.y)),
            zoom: Float(zoom),
            rotation: Float(rotation)
        )
        if cpuBaseTexture == nil
            || cpuBaseTexture!.width != textureWidth
            || cpuBaseTexture!.height != textureHeight
            || cpuBaseKey != cpuKey,
            textureWidth > 0, textureHeight > 0 {
            if cpuBaseTexture == nil
                || cpuBaseTexture!.width != textureWidth
                || cpuBaseTexture!.height != textureHeight {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: drawable.texture.pixelFormat,
                    width: textureWidth,
                    height: textureHeight,
                    mipmapped: false
                )
                descriptor.usage = [.shaderRead, .renderTarget]
                descriptor.storageMode = .private
                cpuBaseTexture = commandQueue.device.makeTexture(descriptor: descriptor)
            }
            let basePass = MTLRenderPassDescriptor()
            basePass.colorAttachments[0].texture = cpuBaseTexture
            basePass.colorAttachments[0].loadAction = .clear
            basePass.colorAttachments[0].storeAction = .store
            basePass.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(surroundingColor.red),
                green: Double(surroundingColor.green),
                blue: Double(surroundingColor.blue),
                alpha: Double(surroundingColor.alpha)
            )
            if let baseEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: basePass) {
                baseEncoder.label = "Cached CPU Canvas Base"
                textureCompositor.encode(image: documentFrame, encoder: baseEncoder, transform: compositorTransform)
                baseEncoder.endEncoding()
                // Only publish the key once the base was actually rendered. If
                // the encoder was unavailable (or the drawable was 0-sized) the
                // key stays stale so the next frame retries instead of blitting
                // a base baked for a different zoom/position — which made strokes
                // vanish while zooming.
                cpuBaseKey = cpuKey
            }
        }
        if let base = cpuBaseTexture,
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(
                from: base,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: base.width, height: base.height, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blit.endEncoding()
        }

        if let liveCPUPreviewFrame {
            let overlayPass = MTLRenderPassDescriptor()
            overlayPass.colorAttachments[0].texture = drawable.texture
            overlayPass.colorAttachments[0].loadAction = .load
            overlayPass.colorAttachments[0].storeAction = .store
            if let overlayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: overlayPass) {
                overlayEncoder.label = "Live CPU Preview Overlay"
                textureCompositor.encode(
                    image: liveCPUPreviewFrame,
                    encoder: overlayEncoder,
                    transform: compositorTransform
                )
                overlayEncoder.endEncoding()
            }
        }

        // No committed GPU strokes exist on this branch, so only the live GPU
        // stroke (when one is active) is drawn, on top of the baked CPU base.
        if let activeStroke, !activeOnCPU, let activeKind,
           activeKind.isGPUAnimated || activeKind == .faded {
            encodePreview(activeStroke, into: drawable.texture, commandBuffer: commandBuffer)
        }
        guard canSubmitGPUWork else { return }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        updateTransformOverlay()
        }
    }

    private func previewLayerOpacity(for stroke: AnimatedStroke?) -> Double {
        guard stroke != nil else { return 1 }
        let index = document.selectedLayerIndex
        guard document.layers.indices.contains(index) else { return 1 }
        return document.layers[index].opacity
    }
}

/// StreamLine-style windowed stroke smoother. Keeps a rolling window of the
/// most recent raw input points and emits their weighted average, which
/// averages out high-frequency pencil jitter while weights that favor the
/// newest point keep lag low. Position, pressure, tilt, and azimuth are all
/// smoothed together so the stroke stays coherent.
private struct StrokePointSmoother {
    private var buffer: [StrokeSample] = []
    private var window = 1

    mutating func reset(amount: Double) {
        buffer.removeAll(keepingCapacity: true)
        // 0 → no smoothing (window 1); 1 → window 10.
        window = max(1, Int((1 + amount * 9).rounded()))
    }

    mutating func push(_ sample: StrokeSample) -> StrokeSample {
        buffer.append(sample)
        if buffer.count > window { buffer.removeFirst() }
        let count = buffer.count
        guard count > 1 else { return sample }
        // Quadratic weights heavily favor the newest point, so the smoothed
        // stroke stays close to the pencil (low lag) while the larger window
        // still averages out high-frequency jitter.
        var weightSum = 0.0
        var x = 0.0, y = 0.0, pressure = 0.0, tilt = 0.0, azimuth = 0.0, timestamp = 0.0
        for (offset, point) in buffer.enumerated() {
            let rank = Double(offset + 1)
            let weight = rank * rank
            weightSum += weight
            x += point.x * weight
            y += point.y * weight
            pressure += point.pressure * weight
            tilt += point.tilt * weight
            azimuth += point.azimuth * weight
            timestamp += point.timestamp * weight
        }
        return StrokeSample(
            x: x / weightSum,
            y: y / weightSum,
            pressure: pressure / weightSum,
            tilt: tilt / weightSum,
            azimuth: azimuth / weightSum,
            timestamp: timestamp / weightSum
        )
    }
}

struct MetalCanvas: UIViewRepresentable {
    @ObservedObject var editor: EditorModel
    var playbackSpeed: Double = 1
    @AppStorage("wigglyGlobalSmoothness") private var globalSmoothness: Double = 0
    var onCanvasInteraction: () -> Void = {}
    var onDrawBlocked: () -> Void = {}
    var onColorPickCommitted: () -> Void = {}

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
        view.globalSmoothing = globalSmoothness
        view.inputPolicy = editor.inputPolicy
        view.isErasing = editor.eraserMode
        view.isSelecting = editor.selectionMode
        view.isDrawingBlocked = editor.selectedLayerGroupID != nil
        view.onDrawBlocked = onDrawBlocked
        view.isAnimationPlaying = editor.isAnimationPlaying
        view.animationPlaybackSpeed = playbackSpeed
        view.isStrokeAnimationRandomized = editor.isStrokeAnimationRandomized
        view.isTransformingImage = editor.imageTransformMode && editor.canTransformSelection
        view.transformTargetLayerIDs = editor.transformTargetLayerIDs
        view.selectedStrokeID = editor.selectedStrokeID
        view.onStroke = { [weak editor] in editor?.addStroke($0) }
        view.onErase = { [weak editor] in
            editor?.erase(at: $0, radius: max(20, editor?.selectedBrush.size ?? 20))
        }
        view.onSelect = { [weak editor] in editor?.select(at: $0) }
        view.onColorPickBegan = { [weak editor] in editor?.beginCanvasColorPick() }
        view.onPickColor = { [weak editor] in editor?.previewCanvasColor($0) }
        view.onColorPickEnded = { [weak editor] commit in
            guard editor?.finishCanvasColorPick(commit: commit) == true else { return }
            onColorPickCommitted()
        }
        view.onCanvasInteraction = onCanvasInteraction
        view.onUndo = { [weak editor] in editor?.undo() }
        view.onRedo = { [weak editor] in editor?.redo() }
        view.onImageTransformBegan = { [weak editor] in editor?.beginImageTransformGesture() }
        view.onImageTransformChanged = { [weak editor] scale, translation in
            editor?.updateSelectedImageTransform(scaleDelta: scale, translation: translation)
        }
        view.onImageTransformEnded = { [weak editor] in editor?.endImageTransformGesture() }
    }
}
