import SwiftUI
import UIKit

struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: ProjectLibrary
    @StateObject private var editor: EditorModel
    @StateObject private var brushStore = BrushPresetStore()
    @State private var presentedPanel: Panel?
    @State private var showsLayers: Bool
    @State private var showsBrushStudio = false
    @State private var showsColorPicker = false

    enum Panel: String, Identifiable {
        case export
        case guide
        var id: String { rawValue }
    }

    init(document: WiggleDocument, library: ProjectLibrary, showLayersInitially: Bool = false) {
        self.library = library
        _editor = StateObject(wrappedValue: EditorModel(document: document))
        _showsLayers = State(initialValue: showLayersInitially)
    }

    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.072, blue: 0.085)
                .ignoresSafeArea()

            MetalCanvas(editor: editor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            HStack {
                controlRail
                Spacer()
            }
            .padding(.leading, 14)
            .padding(.top, 76)
            .padding(.bottom, 18)

            if editor.imageTransformMode && editor.canTransformSelectedImage {
                VStack {
                    Spacer()
                    imageTransformBar
                }
                .padding(.bottom, 22)
                .zIndex(4)
            }

            if showsLayers {
                HStack {
                    Spacer()
                    LayersSidebar(editor: editor, isPresented: $showsLayers)
                }
                .padding(.trailing, 14)
                .padding(.top, 76)
                .padding(.bottom, 18)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
            }

            if showsBrushStudio {
                BrushStudioView(editor: editor, store: brushStore) {
                    showsBrushStudio = false
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(20)
            }
        }
        .coordinateSpace(name: "canvasSpace")
        .animation(.snappy(duration: 0.22), value: showsLayers)
        .animation(.easeInOut(duration: 0.2), value: showsBrushStudio)
        .statusBarHidden(true)
        .onAppear {
            editor.onAutosave = { [weak library] in library?.scheduleAutosave($0) }
        }
        .onDisappear {
            library.saveImmediately(editor.document)
        }
        .sheet(item: $presentedPanel) { panel in
            switch panel {
            case .export:
                ExportView(document: editor.document)
            case .guide:
                BrushGuideView()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                library.saveImmediately(editor.document)
                dismiss()
            } label: {
                Label("Gallery", systemImage: "chevron.backward")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(CanvasToolButtonStyle())

            Menu {
                Picker("Drawing input", selection: $editor.inputPolicy) {
                    ForEach(CanvasInputPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Divider()
                Button("Export Animation", systemImage: "square.and.arrow.up") {
                    presentedPanel = .export
                }
                Button("Brush Guide", systemImage: "questionmark.circle") {
                    presentedPanel = .guide
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle())
            .accessibilityLabel("Actions")

            Button {
                editor.imageTransformMode = false
                editor.selectionMode.toggle()
                editor.eraserMode = false
            } label: {
                Image(systemName: "lasso")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: editor.selectionMode))
            .accessibilityLabel("Selection")

            Spacer()

            Text(editor.document.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.24), in: Capsule())

            Spacer()

            Button {
                editor.imageTransformMode = false
                editor.eraserMode = false
                editor.selectionMode = false
                showsBrushStudio = true
            } label: {
                Image(systemName: editor.selectedBrush.kind.symbol)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: !editor.eraserMode && !editor.selectionMode && !editor.imageTransformMode))
            .accessibilityLabel("Brush Studio")

            Button {
                editor.imageTransformMode = false
                editor.eraserMode.toggle()
                editor.selectionMode = false
            } label: {
                Image(systemName: "eraser")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: editor.eraserMode))
            .accessibilityLabel("Eraser")

            Button {
                showsLayers.toggle()
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: showsLayers))
            .accessibilityLabel("Layers")

            Circle()
                .fill(editor.selectedBrush.color.swiftUIColor)
                .stroke(.white.opacity(0.85), lineWidth: 2)
                .frame(width: 32, height: 32)
                .padding(7)
                .contentShape(Rectangle())
                .onTapGesture { showsColorPicker = true }
                .popover(isPresented: $showsColorPicker, arrowEdge: .top) {
                    DirectColorPicker(color: $editor.selectedBrush.color)
                        .frame(width: 420, height: 590)
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("Brush Color")
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var imageTransformBar: some View {
        HStack(spacing: 10) {
            Label("Transform Image", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))

            Text("Drag to move • Pinch to scale")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))

            Divider()
                .frame(height: 24)
                .overlay(.white.opacity(0.16))

            Button {
                editor.changeSelectedImageScale(by: 0.9)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle())
            .accessibilityLabel("Zoom Image Out")

            Text("\(Int((editor.selectedImageScale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .frame(width: 50)

            Button {
                editor.changeSelectedImageScale(by: 1.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle())
            .accessibilityLabel("Zoom Image In")

            Button("Reset") {
                editor.resetSelectedImageTransform()
            }
            .buttonStyle(.bordered)

            Button("Done") {
                editor.imageTransformMode = false
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private var controlRail: some View {
        VStack(spacing: 12) {
            VerticalBrushControl(
                title: "Size",
                systemImage: "circle.fill",
                value: Binding(
                    get: { editor.selectedBrush.size },
                    set: { editor.selectedBrush.size = $0 }
                ),
                range: 1...200,
                display: { "\(Int($0))" }
            )

            VerticalBrushControl(
                title: "Opacity",
                systemImage: "circle.lefthalf.filled",
                value: Binding(
                    get: { editor.selectedBrush.opacity },
                    set: { editor.selectedBrush.opacity = $0 }
                ),
                range: 0.05...1,
                display: { "\(Int($0 * 100))%" }
            )

            Divider()
                .frame(width: 38)
                .overlay(.white.opacity(0.18))

            Button(action: editor.undo) {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle())
            .disabled(!editor.canUndo)
            .accessibilityLabel("Undo. Two-finger tap")

            Button(action: editor.redo) {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle())
            .disabled(!editor.canRedo)
            .accessibilityLabel("Redo. Three-finger tap")
        }
        .frame(width: 54)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private struct VerticalBrushControl: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let display: (Double) -> String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))

            Slider(value: $value, in: range)
                .transaction { $0.animation = nil }
                .tint(.white)
                .frame(width: 108)
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 108)
                .accessibilityLabel(title)

            Text(display(value))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 42)
        }
    }
}

private struct CanvasToolButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.orange : Color.white.opacity(0.9))
            .padding(9)
            .background(
                active ? Color.orange.opacity(0.16) : Color.black.opacity(configuration.isPressed ? 0.34 : 0.16),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct RailButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(isEnabled ? 0.88 : 0.25))
            .padding(5)
            .background(.black.opacity(configuration.isPressed ? 0.32 : 0.12), in: RoundedRectangle(cornerRadius: 10))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

private struct DirectColorPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var color: CodableColor
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double
    @State private var alpha: Double

    private let swatches: [Color] = [
        .white, .black, .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink
    ]

    init(color: Binding<CodableColor>) {
        _color = color
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        UIColor(
            red: color.wrappedValue.red,
            green: color.wrappedValue.green,
            blue: color.wrappedValue.blue,
            alpha: color.wrappedValue.alpha
        ).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        _hue = State(initialValue: Double(hue))
        _saturation = State(initialValue: Double(saturation))
        _brightness = State(initialValue: Double(brightness))
        _alpha = State(initialValue: Double(alpha))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Colors").font(.title2.bold())
                Spacer()
                Circle()
                    .fill(selectedColor)
                    .frame(width: 38, height: 38)
                    .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 2))
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                let center = CGPoint(x: side / 2, y: side / 2)
                let ringRadius = side * 0.43
                let innerSide = side * 0.64
                let innerRadius = innerSide / 2
                let hueAngle = hue * Double.pi * 2
                let markerPoint = saturationValueMarker(
                    center: center,
                    innerRadius: innerRadius
                )

                ZStack {
                    Circle()
                        .stroke(
                            AngularGradient(
                                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: side * 0.12)
                        )

                    Circle()
                        .fill(Color(hue: hue, saturation: 1, brightness: 1))
                        .overlay {
                            Circle().fill(LinearGradient(
                                colors: [.white, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                        }
                        .overlay {
                            Circle().fill(LinearGradient(
                                colors: [.clear, .black],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                        }
                        .frame(width: innerSide, height: innerSide)
                        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 6))

                    Circle()
                        .fill(Color(hue: hue, saturation: 1, brightness: 1))
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .frame(width: 28, height: 28)
                        .position(
                            x: center.x + Foundation.cos(hueAngle) * ringRadius,
                            y: center.y + Foundation.sin(hueAngle) * ringRadius
                        )
                        .shadow(color: .black.opacity(0.5), radius: 2)

                    Circle()
                        .fill(selectedColor)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .frame(width: 28, height: 28)
                        .position(markerPoint)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .frame(width: side, height: side)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            updateSelection(
                                location: value.location,
                                center: center,
                                innerRadius: innerRadius
                            )
                        }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)

            HStack(spacing: 9) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        color = CodableColor(swatch)
                        load(color)
                    } label: {
                        Circle()
                            .fill(swatch)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            LabeledContent("Opacity") {
                Slider(value: $alpha, in: 0...1)
                    .onChange(of: alpha) { _, _ in updateColor() }
            }
        }
        .padding(20)
        .foregroundStyle(.white)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .preferredColorScheme(.dark)
    }

    private var selectedColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness, opacity: alpha)
    }

    private func saturationValueMarker(
        center: CGPoint,
        innerRadius: CGFloat
    ) -> CGPoint {
        let u = saturation * 2 - 1
        let v = 1 - brightness * 2
        let discX = u * Foundation.sqrt(max(0, 1 - v * v / 2))
        let discY = v * Foundation.sqrt(max(0, 1 - u * u / 2))
        let radius = Double(max(1, innerRadius - 16))
        return CGPoint(
            x: center.x + discX * radius,
            y: center.y + discY * radius
        )
    }

    private func updateSelection(
        location: CGPoint,
        center: CGPoint,
        innerRadius: CGFloat
    ) {
        let dx = location.x - center.x
        let dy = location.y - center.y
        if hypot(dx, dy) > innerRadius {
            var newHue = atan2(dy, dx) / (Double.pi * 2)
            if newHue < 0 { newHue += 1 }
            hue = newHue
        } else {
            let radius = max(1, innerRadius - 16)
            var discX = Double(dx / radius)
            var discY = Double(dy / radius)
            let distance = hypot(discX, discY)
            if distance > 1 {
                discX /= distance
                discY /= distance
            }
            let rootTwo = Foundation.sqrt(2.0)
            let u = 0.5 * (
                Foundation.sqrt(max(0, 2 + discX * discX - discY * discY + 2 * rootTwo * discX))
                - Foundation.sqrt(max(0, 2 + discX * discX - discY * discY - 2 * rootTwo * discX))
            )
            let v = 0.5 * (
                Foundation.sqrt(max(0, 2 - discX * discX + discY * discY + 2 * rootTwo * discY))
                - Foundation.sqrt(max(0, 2 - discX * discX + discY * discY - 2 * rootTwo * discY))
            )
            saturation = min(1, max(0, (u + 1) / 2))
            brightness = min(1, max(0, (1 - v) / 2))
        }
        updateColor()
    }

    private func load(_ newColor: CodableColor) {
        var newHue: CGFloat = 0
        var newSaturation: CGFloat = 0
        var newBrightness: CGFloat = 0
        var newAlpha: CGFloat = 1
        UIColor(
            red: newColor.red,
            green: newColor.green,
            blue: newColor.blue,
            alpha: newColor.alpha
        ).getHue(
            &newHue,
            saturation: &newSaturation,
            brightness: &newBrightness,
            alpha: &newAlpha
        )
        hue = Double(newHue)
        saturation = Double(newSaturation)
        brightness = Double(newBrightness)
        alpha = Double(newAlpha)
    }

    private func updateColor() {
        color = CodableColor(selectedColor)
    }
}

#Preview("Canvas") {
    EditorView(
        document: .blank(name: "Animated Study", size: CGSize(width: 2048, height: 2048)),
        library: ProjectLibrary(),
        showLayersInitially: true
    )
}
