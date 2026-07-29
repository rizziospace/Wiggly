import CoreImage
import Foundation
import MetalKit
import SwiftUI

struct BrushStudioView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: BrushPresetStore
    let onDismiss: () -> Void
    @State private var draft: BrushSettings
    @State private var scratchID = UUID()
    @State private var section: BrushSection = .stroke
    @State private var editingBuiltInName: String?

    private enum BrushSection: String, CaseIterable, Identifiable {
        case stroke = "Stroke"
        case dynamics = "Dynamics"
        case animation = "Animation"
        var id: String { rawValue }
    }

    init(
        editor: EditorModel,
        store: BrushPresetStore,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.editor = editor
        self.store = store
        self.onDismiss = onDismiss
        _draft = State(initialValue: editor.selectedBrush)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.28))
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    studioHeader
                    Divider()

                    HStack(spacing: 0) {
                        brushLibrary
                            .frame(width: 250)
                            .background(.thinMaterial)

                        Divider()

                        VStack(spacing: 14) {
                            preview

                            Picker("Brush settings", selection: $section) {
                                ForEach(BrushSection.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)

                            ScrollView {
                                settingsContent
                                    .padding(.bottom, 12)
                            }
                            .scrollIndicators(.visible)

                            studioFooter
                        }
                        .padding(20)
                    }
                }
                .frame(
                    width: min(proxy.size.width * 0.88, 1180),
                    height: min(proxy.size.height * 0.88, 900)
                )
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.13), .clear, .black.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.46), radius: 38, y: 20)
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            guard editingBuiltInName == nil,
                  let factory = factoryBrushes.first(where: { $0.name == draft.name }) else { return }
            editingBuiltInName = factory.name
            draft = store.builtInBrush(default: factory)
        }
    }

    private var studioHeader: some View {
        HStack(spacing: 14) {
            Button("Cancel", systemImage: "xmark") { onDismiss() }
                .buttonStyle(.bordered)

            Spacer()

            VStack(spacing: 2) {
                Text("Brush Studio")
                    .font(.title2.bold())
                Text(draft.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Use Brush", systemImage: "checkmark") { useDraft() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
    }

    private var studioFooter: some View {
        HStack {
            Button("Reset", systemImage: "arrow.counterclockwise") { resetDraft() }
                .buttonStyle(.bordered)

            Spacer()

            Button("Create Copy", systemImage: "plus.square.on.square") { createCopy() }
                .buttonStyle(.bordered)

            Button("Save", systemImage: "square.and.arrow.down") { persistDraft() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func persistDraft() {
        if let editingBuiltInName {
            store.saveBuiltIn(draft, defaultName: editingBuiltInName)
        } else {
            store.save(draft)
        }
        editor.selectedBrush = draft
    }

    private func resetDraft() {
        if let editingBuiltInName,
           let factory = factoryBrushes.first(where: { $0.name == editingBuiltInName }) {
            store.resetBuiltIn(named: editingBuiltInName)
            draft = factory
        } else {
            var reset = BrushSettings.preset(draft.kind)
            reset.id = draft.id
            reset.name = draft.name
            draft = reset
            store.save(reset)
        }
        scratchID = UUID()
    }

    private func createCopy() {
        let copy = store.duplicate(draft)
        editingBuiltInName = nil
        draft = copy
        scratchID = UUID()
    }

    private func useDraft() {
        persistDraft()
        editor.eraserMode = false
        editor.selectionMode = false
        onDismiss()
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Test your brush", systemImage: "applepencil")
                    .font(.headline)
                Spacer()
                Button("Clear", systemImage: "trash") { scratchID = UUID() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
            }

            BrushScratchPad(brush: draft)
                .id(scratchID)
                .frame(minHeight: 360, idealHeight: 420, maxHeight: 460)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.secondary.opacity(0.3), lineWidth: 1)
                }

            Text("Draw in this canvas with Apple Pencil or one finger.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch section {
        case .stroke:
            settingsCard("Brush") {
                TextField("Brush name", text: $draft.name)
                    .disabled(editingBuiltInName != nil)
                if editingBuiltInName != nil {
                    Text("Built-in brushes keep their name. Use Create Copy to make a new brush.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Brush engine", selection: $draft.kind) {
                    ForEach(BrushKind.allCases) { Text($0.title).tag($0) }
                }
                ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
                if draft.kind == .gradient {
                    ColorPicker("Second color", selection: secondaryColorBinding, supportsOpacity: true)
                    ColorPicker("Third color", selection: tertiaryColorBinding, supportsOpacity: true)
                } else if draft.kind == .glitter {
                    ColorPicker("Sparkle color", selection: secondaryColorBinding, supportsOpacity: true)
                } else if draft.kind == .colorNoise {
                    ColorPicker("Noise color", selection: secondaryColorBinding, supportsOpacity: true)
                }
                SettingSlider(title: "Size", value: $draft.size, range: 1...200)
                SettingSlider(title: "Opacity", value: $draft.opacity, range: 0.05...1)
                SettingSlider(title: "Smoothing", value: $draft.smoothing, range: 0...1)
                SettingSlider(title: "Spacing", value: $draft.spacing, range: 2...100)
            }

        case .dynamics:
            settingsCard("Width and Pencil") {
                WidthDynamicsPreview(brush: draft)
                    .frame(height: 72)
                Text("Start and end only taper the outer 15% of the stroke.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingSlider(title: "Start width", value: startWidthBinding, range: 0.05...2)
                SettingSlider(title: "End width", value: endWidthBinding, range: 0.05...2)
                SettingSlider(title: "Pressure → size", value: $draft.pressureSize, range: 0...1)
                SettingSlider(title: "Pressure → opacity", value: $draft.pressureOpacity, range: 0...1)
                SettingSlider(title: "Tilt response", value: $draft.tiltResponse, range: 0...1)
            }

        case .animation:
            settingsCard("Loop Motion") {
                SettingSlider(title: "Amount", value: $draft.motionAmount, range: 0...100)
                SettingSlider(title: "Frequency", value: $draft.frequency, range: 0.25...8)
                Stepper("Loop cycles: \(draft.loopCycles)", value: $draft.loopCycles, in: 1...12)
                if draft.kind == .scribbles {
                    Stepper(
                        "Lines: \(draft.resolvedScribbleLineCount)",
                        value: Binding(
                            get: { draft.resolvedScribbleLineCount },
                            set: { draft.scribbleLineCount = $0 }
                        ),
                        in: 2...12
                    )
                    Picker(
                        "Line animation",
                        selection: Binding(
                            get: { draft.resolvedScribbleMotionMode },
                            set: { draft.scribbleMotionMode = $0 }
                        )
                    ) {
                        ForEach(ScribbleMotionMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if draft.kind == .polkaDots {
                    Stepper(
                        "Rows: \(draft.resolvedPolkaRowCount)",
                        value: Binding(
                            get: { draft.resolvedPolkaRowCount },
                            set: { draft.polkaRowCount = $0 }
                        ),
                        in: 1...8
                    )
                    Text("Amount controls dot pulse.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if draft.kind == .glitter {
                    SettingSlider(title: "Grain density", value: glitterDensityBinding, range: 0.05...1)
                    SettingSlider(title: "Sparkle amount", value: sparkleAmountBinding, range: 0...1)
                }
                if draft.kind == .gradient {
                    Text("Frequency controls color repeats; loop cycles controls travel speed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if [.faded, .charcoal, .colorNoise].contains(draft.kind) {
                    SettingSlider(title: "Texture density", value: textureDensityBinding, range: 0.05...1)
                    SettingSlider(title: "Roughness", value: textureRoughnessBinding, range: 0...1)
                }
                if draft.kind == .charcoal {
                    Stepper(
                        "Strands: \(draft.resolvedCharcoalLineCount)",
                        value: Binding(
                            get: { draft.resolvedCharcoalLineCount },
                            set: { draft.charcoalLineCount = $0 }
                        ),
                        in: 2...8
                    )
                }
                HStack {
                    Text("Seed")
                    Spacer()
                    TextField("Seed", value: $draft.seed, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 150)
                    Button("Randomize", systemImage: "dice") {
                        draft.seed = UInt64.random(in: 1...UInt64.max)
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
    }

    private func settingsCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var factoryBrushes: [BrushSettings] {
        var softWiggle = BrushSettings.preset(.wiggle)
        softWiggle.name = "Soft Wiggle"
        softWiggle.size = 28
        softWiggle.opacity = 0.38
        softWiggle.motionAmount = 10
        softWiggle.frequency = 1.4

        var charcoal = BrushSettings.preset(.jitter)
        charcoal.name = "Charcoal Jitter"
        charcoal.color = CodableColor(red: 0.12, green: 0.11, blue: 0.14)
        charcoal.size = 14
        charcoal.opacity = 0.52
        charcoal.spacing = 4
        charcoal.motionAmount = 5
        charcoal.pressureSize = 1

        var neon = BrushSettings.preset(.pulse)
        neon.name = "Neon Pulse"
        neon.color = CodableColor(red: 0.05, green: 0.78, blue: 1)
        neon.size = 42
        neon.opacity = 0.88
        neon.motionAmount = 0.22

        var confetti = BrushSettings.preset(.scatter)
        confetti.name = "Confetti Dots"
        confetti.color = CodableColor(red: 1, green: 0.12, blue: 0.55)
        confetti.size = 18
        confetti.spacing = 8
        confetti.motionAmount = 32
        confetti.loopCycles = 2

        var flow = BrushSettings.preset(.pulse)
        flow.name = "Flow Ribbon"
        flow.color = CodableColor(red: 1, green: 0.68, blue: 0.05)
        flow.size = 52
        flow.opacity = 0.92
        flow.motionAmount = 0.16
        flow.startWidthScale = 0.18
        flow.endWidthScale = 0.45

        return BrushKind.allCases.map(BrushSettings.preset)
            + [softWiggle, charcoal, neon, confetti, flow]
    }

    private var builtInBrushes: [BrushSettings] {
        factoryBrushes.map { store.builtInBrush(default: $0) }
    }

    private var brushLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Brushes", systemImage: "paintbrush")
                    .font(.headline)
                Spacer()
                Text("\(builtInBrushes.count + store.presets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    Text("BUILT-IN")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                    ForEach(builtInBrushes, id: \.name) { brush in
                        BrushRow(brush: brush, isSelected: brush.name == draft.name && editingBuiltInName != nil) {
                            editingBuiltInName = brush.name
                            draft = brush
                            scratchID = UUID()
                        }
                    }

                    if !store.presets.isEmpty {
                        Divider().padding(.vertical, 6)
                        Text("MY BRUSHES")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)

                        ForEach(store.presets) { brush in
                            BrushRow(brush: brush, isSelected: brush.id == draft.id && editingBuiltInName == nil) {
                                editingBuiltInName = nil
                                draft = brush
                                scratchID = UUID()
                            }
                            .contextMenu {
                                Button("Duplicate") { store.duplicate(brush) }
                                Button("Delete", role: .destructive) { store.delete(brush) }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { draft.color.swiftUIColor },
            set: { draft.color = CodableColor($0) }
        )
    }

    private var secondaryColorBinding: Binding<Color> {
        Binding(
            get: { draft.resolvedSecondaryColor.swiftUIColor },
            set: { draft.secondaryColor = CodableColor($0) }
        )
    }

    private var tertiaryColorBinding: Binding<Color> {
        Binding(
            get: { draft.resolvedTertiaryColor.swiftUIColor },
            set: { draft.tertiaryColor = CodableColor($0) }
        )
    }

    private var glitterDensityBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedGlitterDensity },
            set: { draft.glitterDensity = $0 }
        )
    }

    private var sparkleAmountBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedSparkleAmount },
            set: { draft.sparkleAmount = $0 }
        )
    }

    private var textureDensityBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedTextureDensity },
            set: { draft.textureDensity = $0 }
        )
    }

    private var textureRoughnessBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedTextureRoughness },
            set: { draft.textureRoughness = $0 }
        )
    }

    private var startWidthBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedStartWidthScale },
            set: { draft.startWidthScale = $0 }
        )
    }

    private var endWidthBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedEndWidthScale },
            set: { draft.endWidthScale = $0 }
        )
    }
}

private struct BrushScratchPad: UIViewRepresentable {
    let brush: BrushSettings

    func makeUIView(context: Context) -> AnimatedMetalView {
        let view = AnimatedMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        var document = WiggleDocument.blank(
            name: "Brush Preview",
            size: CGSize(width: 1200, height: 420)
        )
        document.background = .white
        view.document = document
        view.surroundingColor = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        view.brush = brush
        view.inputPolicy = .pencilAndFinger
        view.onStroke = { [weak view] stroke in
            guard let view else { return }
            var updated = view.document
            updated.layers[0].strokes.append(stroke)
            view.document = updated
        }
        return view
    }

    func updateUIView(_ view: AnimatedMetalView, context: Context) {
        view.brush = brush
        var updated = view.document
        for layerIndex in updated.layers.indices {
            for strokeIndex in updated.layers[layerIndex].strokes.indices {
                updated.layers[layerIndex].strokes[strokeIndex].brush = brush
            }
        }
        view.document = updated
    }
}

private struct WidthDynamicsPreview: View {
    let brush: BrushSettings

    var body: some View {
        Canvas { context, size in
            let steps = 48
            for index in 1...steps {
                let previousProgress = Double(index - 1) / Double(steps)
                let progress = Double(index) / Double(steps)
                let previousWidth = brush.size * taper(at: previousProgress)
                let currentWidth = brush.size * taper(at: progress)
                var path = Path()
                path.move(to: CGPoint(x: size.width * previousProgress, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width * progress, y: size.height / 2))
                context.stroke(
                    path,
                    with: .color(brush.color.swiftUIColor.opacity(brush.opacity)),
                    style: StrokeStyle(
                        lineWidth: min(size.height * 0.8, (previousWidth + currentWidth) * 0.25),
                        lineCap: .round
                    )
                )
            }
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func taper(at progress: Double) -> Double {
        let taperZone = 0.15
        if progress < taperZone {
            return brush.resolvedStartWidthScale
                + (1 - brush.resolvedStartWidthScale) * (progress / taperZone)
        }
        if progress > 1 - taperZone {
            return 1 + (brush.resolvedEndWidthScale - 1)
                * ((progress - (1 - taperZone)) / taperZone)
        }
        return 1
    }
}

private struct BrushRow: View {
    let brush: BrushSettings
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: brush.kind.symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(brush.color.swiftUIColor)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(.white.opacity(0.09), lineWidth: 1)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(brush.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(brush.kind.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                isSelected ? Color.blue.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range)
                .transaction { $0.animation = nil }
        }
    }
}

#Preview("Brush Studio") {
    ZStack {
        LinearGradient(
            colors: [Color(red: 0.07, green: 0.06, blue: 0.10), .indigo.opacity(0.75)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
        Circle()
            .fill(.orange)
            .frame(width: 340)
            .offset(x: -330, y: 250)
        Circle()
            .fill(.cyan)
            .frame(width: 280)
            .offset(x: 370, y: -250)

        BrushStudioView(
            editor: EditorModel(document: .blank()),
            store: BrushPresetStore()
        )
    }
}
