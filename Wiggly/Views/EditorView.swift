import SwiftUI
import UIKit

struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: ProjectLibrary
    @StateObject private var editor: EditorModel
    @StateObject private var brushStore: BrushPresetStore
    @State private var presentedPanel: Panel?
    @State private var showsLayers: Bool
    @State private var showsBrushStudio = false
    @State private var showsColorPicker = false
    @State private var showsFolderDrawNotice = false
    @AppStorage("wigglyGlobalSmoothness") private var globalSmoothness: Double = 0
    @AppStorage("wigglyAnimationPlaybackSpeed") private var animationPlaybackSpeed: Double = 1

    enum Panel: String, Identifiable {
        case export
        case guide
        var id: String { rawValue }
    }

    init(document: WiggleDocument, library: ProjectLibrary, showLayersInitially: Bool = false) {
        self.library = library
        let brushStore = BrushPresetStore()
        _brushStore = StateObject(wrappedValue: brushStore)
        _editor = StateObject(wrappedValue: EditorModel(
            document: document,
            selectedBrush: brushStore.lastSelectedBrush
        ))
        _showsLayers = State(initialValue: showLayersInitially)
    }

    var body: some View {
        ZStack {
            Color(red: 0.075, green: 0.072, blue: 0.085)
                .ignoresSafeArea()

            MetalCanvas(
                editor: editor,
                playbackSpeed: animationPlaybackSpeed,
                onCanvasInteraction: {
                    if showsLayers { showsLayers = false }
                },
                onDrawBlocked: { showsFolderDrawNotice = true },
                onColorPickCommitted: { persistSelectedBrush() }
            )
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

            HStack {
                Spacer()
                brushColorRail
            }
            .padding(.trailing, 14)
            .padding(.top, 76)
            .padding(.bottom, 18)

            if editor.imageTransformMode && editor.canTransformSelection {
                VStack {
                    Spacer()
                    imageTransformBar
                }
                .padding(.bottom, 22)
                .zIndex(4)
            }

            if showsLayers {
                GeometryReader { proxy in
                    HStack {
                        Spacer()
                        LayersSidebar(editor: editor, isPresented: $showsLayers)
                            .frame(height: proxy.size.height)
                    }
                }
                .padding(.trailing, 14)
                .padding(.top, 96)
                .padding(.bottom, 0)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
            }

            if showsBrushStudio {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showsBrushStudio = false
                    }
                    .zIndex(10)

                BrushPanelPopup(editor: editor, store: brushStore) {
                    showsBrushStudio = false
                }
                .zIndex(11)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }

            if presentedPanel == .export {
                ExportView(
                    document: editor.document,
                    randomizeStrokePhase: editor.isStrokeAnimationRandomized
                ) {
                    presentedPanel = nil
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(20)
            }

        }
        .coordinateSpace(name: "canvasSpace")
        .animation(.snappy(duration: 0.22), value: showsLayers)
        .interactiveDismissDisabled(true)
        .statusBarHidden(true)
        .onAppear {
            editor.onAutosave = { [weak library] in library?.scheduleAutosave($0) }
        }
        .onDisappear {
            editor.commitTransformSelection()
            library.saveImmediately(editor.document)
        }
        .onChange(of: showsColorPicker) { _, isPresented in
            guard !isPresented else { return }
            persistSelectedBrush()
        }
        .sheet(isPresented: Binding(
            get: { presentedPanel == .guide },
            set: { isPresented in
                if !isPresented { presentedPanel = nil }
            }
        )) {
            BrushGuideView()
        }
        .alert("Select a Layer", isPresented: $showsFolderDrawNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You can't draw on a folder. Select a layer first.")
        }
    }

    private var isBrushActive: Bool {
        !editor.eraserMode && !editor.selectionMode && !editor.imageTransformMode
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
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
                finishTransform()
                editor.selectionMode.toggle()
                editor.eraserMode = false
            } label: {
                Image(systemName: "lasso")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: editor.selectionMode))
            .accessibilityLabel("Selection")

            Button {
                if editor.imageTransformMode {
                    finishTransform()
                } else if editor.canTransformSelection {
                    editor.imageTransformMode = true
                }
                editor.selectionMode = false
                editor.eraserMode = false
                if editor.imageTransformMode { showsLayers = false }
            } label: {
                Image(systemName: "cursorarrow.rays")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: editor.imageTransformMode))
            .accessibilityLabel("Transform selected layer or group")

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
                presentedPanel = .export
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: presentedPanel == .export))
            .accessibilityLabel("Export animation")

            Button {
                showsLayers.toggle()
            } label: {
                Image(systemName: "square.3.layers.3d")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(CanvasToolButtonStyle(active: showsLayers))
            .accessibilityLabel("Layers")
        }
        .padding(6)
        .background(Color(red: 0.15, green: 0.15, blue: 0.17), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var brushColorRail: some View {
        VStack(spacing: 10) {
            ForEach(editor.availableColorSlots, id: \.self) { slot in
                brushColorButton(
                    color: editor.selectedBrushColor(for: slot),
                    slot: slot,
                    label: colorSlotLabel(slot)
                )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(Color(red: 0.15, green: 0.15, blue: 0.17), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
        .popover(isPresented: $showsColorPicker, arrowEdge: .trailing) {
            DirectColorPicker(color: selectedColorBinding)
                .frame(width: 340, height: 390)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func colorSlotLabel(_ slot: BrushColorSlot) -> String {
        if editor.selectedBrush.kind == .retro || editor.selectedBrush.kind == .checker {
            switch slot {
            case .primary: return "Color 1"
            case .secondary: return "Color 2"
            case .tertiary: return "Color 3"
            case .quaternary: return "Color 4"
            case .quinary: return "Color 5"
            }
        }
        switch slot {
        case .primary:
            switch editor.selectedBrush.kind {
            case .particle: return "Particle"
            case .goo: return "Goo"
            case .scribbles: return "Scribble"
            case .particleCloud: return "Drizzle"
            case .glitter: return "Glitter"
            case .solidColor, .gradient: return "Color 1"
            case .faded: return "Faded"
            case .dryOutline: return "Ink"
            case .star: return "Star"
            default: return "Dash"
            }
        case .secondary:
            switch editor.selectedBrush.kind {
            case .faded: return "Base"
            case .glitter: return "Background"
            case .solidColor, .gradient: return "Color 2"
            case .star: return "Base"
            default: return "Base"
            }
        case .tertiary:
            return editor.selectedBrush.kind == .checker ? "Color 3" : "Glow"
        case .quaternary:
            return "Color 4"
        case .quinary:
            return "Color 5"
        }
    }

    private func brushColorButton(
        color: CodableColor,
        slot: BrushColorSlot,
        label: String
    ) -> some View {
        Button {
            editor.selectColorSlot(slot)
            showsColorPicker = true
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.swiftUIColor)
                    .frame(width: 42, height: 42)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(
                                editor.activeColorSlot == slot ? Color.blue : Color.white.opacity(0.72),
                                lineWidth: editor.activeColorSlot == slot ? 3 : 1.5
                            )
                    }
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) color")
        .accessibilityHint("Tap to edit this brush color")
    }

    private var selectedColorBinding: Binding<CodableColor> {
        Binding(
            get: { editor.selectedBrushColor(for: editor.activeColorSlot) },
            set: { editor.setSelectedBrushColor($0, for: editor.activeColorSlot) }
        )
    }

    private func persistSelectedBrush() {
        brushStore.saveBuiltIn(editor.selectedBrush, defaultName: editor.selectedBrush.kind.title)
        brushStore.rememberSelection(editor.selectedBrush)
    }

    private var imageTransformBar: some View {
        HStack(spacing: 10) {
            Label("Transform", systemImage: "cursorarrow.rays")
                .font(.subheadline.weight(.semibold))

            Text(editor.transformTargetTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Text("Drag to move • Drag corners or pinch to scale")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))

            Divider()
                .frame(height: 24)
                .overlay(.white.opacity(0.16))

            Button {
                editor.changeTransformScale(by: 0.9)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle())
            .accessibilityLabel("Zoom Image Out")

            Button {
                editor.changeTransformScale(by: 1.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle())
            .accessibilityLabel("Zoom Image In")

            Button("Reset") {
                editor.resetTransformSelection()
            }
            .buttonStyle(.bordered)

            Button("Done") {
                finishTransform()
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.15, green: 0.15, blue: 0.17), in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private func finishTransform() {
        guard editor.imageTransformMode else { return }
        editor.commitTransformSelection()
        editor.imageTransformMode = false
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
                fractionDigits: 0
            )

            VerticalBrushControl(
                title: "Opacity",
                systemImage: "circle.lefthalf.filled",
                value: Binding(
                    get: { editor.selectedBrush.opacity },
                    set: { editor.selectedBrush.opacity = $0 }
                ),
                range: 0.05...1,
                fractionDigits: 0,
                suffix: "%",
                valueScale: 100
            )

            VerticalBrushControl(
                title: "Smooth",
                systemImage: "water.waves",
                value: $globalSmoothness,
                range: 0...1,
                fractionDigits: 0,
                suffix: "%",
                valueScale: 100
            )
            .accessibilityLabel("Global smoothness")
            .accessibilityHint("Smooths every brush's strokes")

            Button {
                if isBrushActive {
                    showsBrushStudio = true
                } else {
                    finishTransform()
                    editor.eraserMode = false
                    editor.selectionMode = false
                }
            } label: {
                Image(systemName: "pencil.tip")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle(active: isBrushActive))
            .accessibilityLabel("Select brush and edit settings")

            Button {
                finishTransform()
                editor.eraserMode.toggle()
                editor.selectionMode = false
            } label: {
                Image(systemName: "eraser")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle(active: editor.eraserMode))
            .accessibilityLabel("Eraser")

            Divider()
                .frame(width: 38)
                .overlay(.white.opacity(0.18))

            Button {
                editor.isAnimationPlaying.toggle()
            } label: {
                Image(systemName: editor.isAnimationPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle())
            .accessibilityLabel(editor.isAnimationPlaying ? "Pause animation" : "Play animation")
            .accessibilityHint("Pause animation while drawing to improve performance on complex canvases")

            Menu {
                Button("¼×  Slowest") { animationPlaybackSpeed = 0.25 }
                Button("⅓×  Original 3s speed") { animationPlaybackSpeed = 1.0 / 3.0 }
                Button("½×  Slow") { animationPlaybackSpeed = 0.5 }
                Button("1×  Normal") { animationPlaybackSpeed = 1 }
                Button("2×  Fast") { animationPlaybackSpeed = 2 }
            } label: {
                Text(animationPlaybackSpeedLabel)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(RailButtonStyle(active: animationPlaybackSpeed != 1))
            .accessibilityLabel("Global animation speed \(animationPlaybackSpeedLabel)")
            .accessibilityHint("Choose quarter, half, normal, or double speed")

            Button {
                editor.isStrokeAnimationRandomized.toggle()
            } label: {
                Image(systemName: "shuffle")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(RailButtonStyle(active: editor.isStrokeAnimationRandomized))
            .accessibilityLabel(editor.isStrokeAnimationRandomized ? "Random stroke animation" : "Synced stroke animation")
            .accessibilityHint("Random gives each stroke its own animation timing; synced animates every stroke together")

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
        .background(Color(red: 0.15, green: 0.15, blue: 0.17), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var animationPlaybackSpeedLabel: String {
        if abs(animationPlaybackSpeed - 0.25) < 0.001 { return "¼×" }
        if abs(animationPlaybackSpeed - (1.0 / 3.0)) < 0.001 { return "⅓×" }
        if abs(animationPlaybackSpeed - 0.5) < 0.001 { return "½×" }
        if abs(animationPlaybackSpeed - 2) < 0.001 { return "2×" }
        return "1×"
    }

}

private struct VerticalBrushControl: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var fractionDigits = 1
    var suffix = ""
    var valueScale = 1.0

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

            NumericValueButton(
                title: title,
                value: $value,
                range: range,
                fractionDigits: fractionDigits,
                suffix: suffix,
                valueScale: valueScale,
                width: 48
            )
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
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.orange : .white.opacity(isEnabled ? 0.88 : 0.25))
            .padding(5)
            .background(
                active ? Color.orange.opacity(0.16) : .black.opacity(configuration.isPressed ? 0.32 : 0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

struct DirectColorPicker: View {
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
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Color")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(selectedColor)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    .shadow(color: .black.opacity(0.35), radius: 3)
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hue: hue, saturation: 1, brightness: 1))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [.white, .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [.clear, .black],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                        }

                    Circle()
                        .fill(selectedColor)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.55), radius: 2)
                        .position(
                            x: min(proxy.size.width - 12, max(12, saturation * proxy.size.width)),
                            y: min(proxy.size.height - 12, max(12, (1 - brightness) * proxy.size.height))
                        )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { updateSaturationBrightness($0.location, size: proxy.size) }
                )
            }
            .frame(height: 190)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                    Circle()
                        .fill(Color(hue: hue, saturation: 1, brightness: 1))
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.45), radius: 2)
                        .position(
                            x: min(proxy.size.width - 11, max(11, hue * proxy.size.width)),
                            y: proxy.size.height / 2
                        )
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { updateHue($0.location.x, width: proxy.size.width) }
                )
            }
            .frame(height: 26)

            HStack(spacing: 6) {
                ForEach(Array(swatches.enumerated()), id: \.offset) { _, swatch in
                    Button {
                        color = CodableColor(swatch)
                        load(color)
                    } label: {
                        Circle()
                            .fill(swatch)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white.opacity(0.42), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
                Slider(value: $alpha, in: 0...1)
                    .onChange(of: alpha) { _, _ in updateColor() }
                NumericValueButton(
                    title: "Color Opacity",
                    value: $alpha,
                    range: 0...1,
                    fractionDigits: 0,
                    suffix: "%",
                    valueScale: 100,
                    width: 48,
                    arrowEdge: .trailing
                )
            }
        }
        .padding(14)
        .foregroundStyle(.white)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .preferredColorScheme(.dark)
    }

    private var selectedColor: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness, opacity: alpha)
    }

    private func updateSaturationBrightness(_ location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        saturation = min(1, max(0, location.x / size.width))
        brightness = min(1, max(0, 1 - location.y / size.height))
        updateColor()
    }

    private func updateHue(_ locationX: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        hue = min(1, max(0, locationX / width))
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
