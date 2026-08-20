import CoreImage
import Foundation
import MetalKit
import SwiftUI

struct BrushStudioView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: BrushPresetStore
    let onDismiss: () -> Void

    @State private var draft: BrushSettings
    @State private var editingBuiltInName: String?
    @State private var searchText = ""
    @State private var libraryFilter: BrushLibraryFilter = .all
    @State private var scratchCommand = BrushScratchCommand.idle
    @State private var isPreviewPlaying = true
    @State private var previewBackground: BrushPreviewBackground = .paper

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
            let studioWidth = min(max(700, proxy.size.width - 18), 1500)
            let studioHeight = min(max(620, proxy.size.height - 18), 980)

            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .ignoresSafeArea()

                studioContent(width: studioWidth)
                .frame(width: studioWidth, height: studioHeight)
                .background {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
                }
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.48), radius: 38, y: 20)
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

    private func studioContent(width: CGFloat) -> some View {
        let libraryWidth: CGFloat = width < 1_050 ? 210 : 238
        let inspectorWidth: CGFloat = width < 1_050 ? 320 : 370

        return HStack(spacing: 0) {
            brushLibrary
                .frame(width: libraryWidth)
                .background(Color(red: 0.13, green: 0.13, blue: 0.15))

            Divider()

            settingsInspector
                .frame(width: inspectorWidth)
                .background(Color(red: 0.13, green: 0.13, blue: 0.15))

            Divider()

            previewPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview")
                        .font(.title2.bold())
                    Text("Draw anywhere in the area below")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isPreviewPlaying {
                    Label("Live", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.12), in: Capsule())
                } else {
                    Label("Paused", systemImage: "pause.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.07), in: Capsule())
                }
            }

            previewToolbar

            BrushScratchPad(
                brush: draft,
                command: scratchCommand,
                isPlaying: isPreviewPlaying,
                background: previewBackground
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(previewBackground.swiftUIColor)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)

            HStack(spacing: 10) {
                Text("Apple Pencil or one finger")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)

                Button {
                    useDraft()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.headline.bold())
                        .frame(width: 46, height: 46)
                        .foregroundStyle(.white)
                        .background(.blue, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use Brush")
            }
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 8) {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                scratchCommand = BrushScratchCommand(action: .undo)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .help("Undo test stroke")

            Button("Clear", systemImage: "trash") {
                scratchCommand = BrushScratchCommand(action: .clear)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .help("Clear test canvas")

            Spacer()

            Menu {
                ForEach(BrushPreviewBackground.allCases) { background in
                    Button {
                        previewBackground = background
                    } label: {
                        Label(background.rawValue, systemImage: background.symbol)
                    }
                }
            } label: {
                Label(previewBackground.rawValue, systemImage: previewBackground.symbol)
            }
            .buttonStyle(.bordered)

            Button {
                isPreviewPlaying.toggle()
            } label: {
                Label(
                    isPreviewPlaying ? "Pause" : "Play",
                    systemImage: isPreviewPlaying ? "pause.fill" : "play.fill"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.regular)
    }

    private var settingsInspector: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .font(.title3.bold())
                    HStack(spacing: 6) {
                        Circle()
                            .fill(draft.color.swiftUIColor)
                            .frame(width: 7, height: 7)
                        Text(draft.name)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Reset", systemImage: "arrow.counterclockwise") {
                    resetDraft()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .frame(height: 66)

            Divider()

            ScrollView {
                LazyVStack(spacing: 12) {
                    brushSettingsCard
                    dynamicsSettingsCard
                    if draft.kind != .solidColor {
                        animationSettingsCard
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.visible)

            Divider()
            studioFooter
                .padding(12)
        }
    }

    private var studioFooter: some View {
        HStack(spacing: 8) {
            Button("Copy", systemImage: "plus.square.on.square") { createCopy() }
                .buttonStyle(.bordered)

            Spacer()

            Button("Save", systemImage: "square.and.arrow.down") { persistDraft() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var brushSettingsCard: some View {
        settingsCard("Brush", systemImage: "paintbrush.fill", tint: .blue) {
            TextField("Brush name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .disabled(editingBuiltInName != nil)

            if editingBuiltInName != nil {
                Text("Built-in names stay fixed. Choose Copy to create your own version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Brush engine", selection: $draft.kind) {
                ForEach(BrushKind.catalogCases) { Text($0.title).tag($0) }
            }

            ColorPicker(draft.kind == .faded ? "Faded color" : "Color", selection: colorBinding, supportsOpacity: true)

            if draft.kind == .gradient || (draft.kind == .solidColor && draft.resolvedColoringUsesGradient) {
                ColorPicker("Second color", selection: secondaryColorBinding, supportsOpacity: true)
            } else if draft.kind == .retro {
                if draft.resolvedTrippyColorCount >= 2 {
                    ColorPicker("Color 2", selection: secondaryColorBinding, supportsOpacity: true)
                }
                if draft.resolvedTrippyColorCount >= 3 {
                    ColorPicker("Color 3", selection: tertiaryColorBinding, supportsOpacity: true)
                }
                if draft.resolvedTrippyColorCount >= 4 {
                    ColorPicker("Color 4", selection: quaternaryColorBinding, supportsOpacity: true)
                }
                if draft.resolvedTrippyColorCount >= 5 {
                    ColorPicker("Color 5", selection: quinaryColorBinding, supportsOpacity: true)
                }
            } else if draft.kind == .glitter {
                ColorPicker("Sparkle color", selection: secondaryColorBinding, supportsOpacity: true)
            } else if draft.kind == .colorNoise {
                ColorPicker("Noise color", selection: secondaryColorBinding, supportsOpacity: true)
            } else if draft.kind == .particle {
                ColorPicker("Particle color", selection: secondaryColorBinding, supportsOpacity: true)
            } else if draft.kind == .faded {
                ColorPicker("Base color", selection: secondaryColorBinding, supportsOpacity: true)
            } else if draft.kind == .checker {
                ColorPicker("Checker color 2", selection: secondaryColorBinding, supportsOpacity: true)
                ColorPicker("Checker color 3", selection: tertiaryColorBinding, supportsOpacity: true)
                ColorPicker("Checker color 4", selection: quaternaryColorBinding, supportsOpacity: true)
            } else if draft.kind == .outlineFill {
                SettingSlider(title: "Outline width", value: Binding(get: { draft.outlineWidth ?? 6 }, set: { draft.outlineWidth = $0 }), range: 0.5...20)
                SettingSlider(title: "Wiggly", value: Binding(get: { draft.wobbleAmount ?? 0.35 }, set: { draft.wobbleAmount = $0 }), range: 0...1)
                SettingSlider(title: "Wiggle speed", value: Binding(get: { draft.wobbleSpeed ?? 1 }, set: { draft.wobbleSpeed = $0 }), range: 0...4)
            }

            SettingSlider(title: "Size", value: $draft.size, range: 1...200)
            SettingSlider(title: "Opacity", value: $draft.opacity, range: 0.05...1)
            SettingSlider(title: "Smoothing", value: $draft.smoothing, range: 0...1)
            if draft.kind.supportsGlobalWave {
                SettingSlider(title: "Wave", value: brushWaveAmountBinding, range: 0...100)
            }
            if draft.kind == .dashed {
                SettingSlider(title: "Dash length", value: $draft.spacing, range: 2...100)
                SettingSlider(title: "Dash gap", value: dashGapBinding, range: 0...200)
            } else if draft.kind == .dotted {
                SettingSlider(title: "Dot gap", value: dotGapBinding, range: 0...200)
            } else if draft.kind == .particle {
                SettingSlider(title: "Corner radius", value: dashCornerBinding, range: 0...1)
                SettingSlider(title: "Particle length", value: particleLengthBinding, range: 0...1)
                SettingSlider(title: "Particle speed", value: particleSpeedBinding, range: 0...4)
                SettingSlider(title: "Particle delay", value: particleDelayBinding, range: 0...0.9)
            } else if draft.kind == .checker {
                SettingSlider(title: "Checker speed", value: checkerSpeedBinding, range: 0...4)
            } else {
                SettingSlider(title: "Spacing", value: $draft.spacing, range: 2...100)
            }
        }
    }

    private var dynamicsSettingsCard: some View {
        settingsCard("Pencil Dynamics", systemImage: "pencil.tip.crop.circle", tint: .orange) {
            WidthDynamicsPreview(brush: draft)
                .frame(height: 68)

            Text("Start and end width affect the outer 15% of each stroke.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Start / End", selection: endStyleBinding) {
                ForEach(BrushEndStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            SettingSlider(title: "Start width", value: startWidthBinding, range: 0.05...2)
            SettingSlider(title: "End width", value: endWidthBinding, range: 0.05...2)
            SettingSlider(title: "Pressure → size", value: $draft.pressureSize, range: 0...1)
            SettingSlider(title: "Pressure → opacity", value: $draft.pressureOpacity, range: 0...1)
            SettingSlider(title: "Tilt response", value: $draft.tiltResponse, range: 0...1)
        }
    }

    private var animationSettingsCard: some View {
        settingsCard("Animation", systemImage: "waveform.path.ecg", tint: .purple) {
            SettingSlider(title: "Motion amount", value: $draft.motionAmount, range: 0...100)
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
                Text("Motion amount controls dot pulse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if draft.kind == .glitter {
                SettingSlider(title: "Grain density", value: glitterDensityBinding, range: 0.05...1)
                SettingSlider(title: "Sparkle amount", value: sparkleAmountBinding, range: 0...1)
            }

            if draft.kind == .goo {
                SettingSlider(title: "Goo speed", value: gooSpeedBinding, range: 0...2)
                SettingSlider(title: "Thickness", value: gooThicknessBinding, range: 0...1)
                SettingSlider(title: "Waviness", value: gooWavinessBinding, range: 0...1)
                SettingSlider(title: "Wave length", value: gooWaveLengthBinding, range: 0...1)
                Toggle("Droplets", isOn: gooDropletsBinding)
                Text("Lower wave length packs tighter fluid ripples along the stroke.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if draft.kind == .solidColor {
                Toggle("Two-color gradient", isOn: coloringUsesGradientBinding)
            }

            if draft.kind == .gradient || (draft.kind == .solidColor && draft.resolvedColoringUsesGradient) {
                Toggle("Merge strokes together", isOn: gradientMergeBinding)
                Text("On: every stroke shares one canvas-wide gradient. Off: each stroke gets its own gradient but self-overlaps still merge.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if draft.kind == .faded {
                SettingSlider(title: "Faded speed", value: fadedSpeedBinding, range: 0...4)
                SettingSlider(title: "Fade amount", value: fadedAmountBinding, range: 0...1)
                SettingSlider(title: "Base opacity", value: fadedBaseOpacityBinding, range: 0...1)
                SettingSlider(title: "Faded opacity", value: fadedTextureOpacityBinding, range: 0...1)
            }

            if draft.kind == .retro {
                SettingSlider(title: "Color cycle speed", value: gradientSpeedBinding, range: 0...4)
                Picker("Colors", selection: trippyColorCountBinding) {
                    ForEach(2...5, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .pickerStyle(.segmented)
                Text("The selected colors sweep along the stroke in order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if draft.kind == .star {
                SettingSlider(title: "Rotation speed", value: starRotationSpeedBinding, range: 0...4)
                Picker("Star rotation", selection: starRotationModeBinding) {
                    ForEach(StarRotationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Gradient across layer", isOn: starGradientAcrossStrokeBinding)
                Text("Layer gradient flows color along the whole stroke instead of per star.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if [.cutMarker, .gouache, .faded, .charcoal, .colorNoise, .dryOutline].contains(draft.kind) {
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
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 130)
                Button("Randomize", systemImage: "dice") {
                    draft.seed = UInt64.random(in: 1...UInt64.max)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }
        }
    }

    private func settingsCard<Content: View>(
        _ title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding(15)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private var brushLibrary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Brush Studio", systemImage: "paintbrush.fill")
                    .font(.headline)
                Spacer()
                Text("\(builtInBrushes.count + store.presets.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(height: 40)

            libraryHeader
            libraryFilters

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !filteredBuiltInBrushes.isEmpty {
                        librarySectionLabel("BUILT-IN", count: filteredBuiltInBrushes.count)

                        ForEach(filteredBuiltInBrushes, id: \.name) { brush in
                            BrushRow(
                                brush: brush,
                                isSelected: brush.name == draft.name && editingBuiltInName != nil
                            ) {
                                selectBrush(brush, builtInName: brush.name)
                            }
                        }
                    }

                    if !filteredCustomBrushes.isEmpty {
                        Divider().padding(.vertical, 5)
                        librarySectionLabel("MY BRUSHES", count: filteredCustomBrushes.count)

                        ForEach(filteredCustomBrushes) { brush in
                            BrushRow(
                                brush: brush,
                                isSelected: brush.id == draft.id && editingBuiltInName == nil
                            ) {
                                selectBrush(brush, builtInName: nil)
                            }
                            .contextMenu {
                                Button("Duplicate") {
                                    afterContextMenuDismisses { store.duplicate(brush) }
                                }
                                Button("Delete", role: .destructive) {
                                    afterContextMenuDismisses { store.delete(brush) }
                                }
                            }
                        }
                    }

                    if filteredBuiltInBrushes.isEmpty && filteredCustomBrushes.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.title2)
                            Text("No brushes found")
                                .font(.subheadline.weight(.medium))
                            Text("Try another search or category.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
            }
        }
        .padding(13)
    }

    private var compactBrushLibrary: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                libraryHeader
                libraryFilters
            }

            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(filteredBuiltInBrushes, id: \.name) { brush in
                        BrushTile(
                            brush: brush,
                            isSelected: brush.name == draft.name && editingBuiltInName != nil
                        ) {
                            selectBrush(brush, builtInName: brush.name)
                        }
                    }

                    ForEach(filteredCustomBrushes) { brush in
                        BrushTile(
                            brush: brush,
                            isSelected: brush.id == draft.id && editingBuiltInName == nil
                        ) {
                            selectBrush(brush, builtInName: nil)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search brushes", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var libraryFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(BrushLibraryFilter.allCases) { filter in
                    Button {
                        libraryFilter = filter
                    } label: {
                        Label(filter.rawValue, systemImage: filter.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                libraryFilter == filter ? Color.blue.opacity(0.22) : Color.white.opacity(0.06),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func librarySectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func selectBrush(_ brush: BrushSettings, builtInName: String?) {
        editingBuiltInName = builtInName
        draft = brush
        scratchCommand = BrushScratchCommand(action: .clear)
    }

    private func afterContextMenuDismisses(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            action()
        }
    }

    private var filteredBuiltInBrushes: [BrushSettings] {
        builtInBrushes.filter(matchesLibrarySelection)
    }

    private var filteredCustomBrushes: [BrushSettings] {
        store.presets.filter { $0.kind.isAvailableInCatalog && matchesLibrarySelection($0) }
    }

    private func matchesLibrarySelection(_ brush: BrushSettings) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesSearch = query.isEmpty
            || brush.name.localizedCaseInsensitiveContains(query)
            || brush.kind.title.localizedCaseInsensitiveContains(query)
        return matchesSearch && libraryFilter.matches(brush.kind)
    }

    private func persistDraft() {
        if let editingBuiltInName {
            store.saveBuiltIn(draft, defaultName: editingBuiltInName)
        } else {
            store.save(draft)
        }
        editor.selectedBrush = draft
        store.rememberSelection(draft)
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
    }

    private func createCopy() {
        let copy = store.duplicate(draft)
        editingBuiltInName = nil
        draft = copy
    }

    private func useDraft() {
        persistDraft()
        editor.eraserMode = false
        editor.selectionMode = false
        onDismiss()
    }

    private var factoryBrushes: [BrushSettings] {
        return BrushKind.catalogCases.map(BrushSettings.preset)
    }

    private var builtInBrushes: [BrushSettings] {
        factoryBrushes.map { store.builtInBrush(default: $0) }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { draft.color.swiftUIColor },
            set: { draft.color = CodableColor($0) }
        )
    }

    private var secondaryColorBinding: Binding<Color> {
        Binding(
            get: {
                (draft.kind == .faded
                    ? draft.resolvedFadedBaseColor
                    : draft.resolvedSecondaryColor).swiftUIColor
            },
            set: {
                draft.secondaryColor = CodableColor($0)
                if draft.kind == .faded, draft.fadedBaseOpacity == nil {
                    draft.fadedBaseOpacity = 1
                }
            }
        )
    }

    private var tertiaryColorBinding: Binding<Color> {
        Binding(
            get: { draft.resolvedTertiaryColor.swiftUIColor },
            set: { draft.tertiaryColor = CodableColor($0) }
        )
    }

    private var quaternaryColorBinding: Binding<Color> {
        Binding(
            get: { draft.resolvedQuaternaryColor.swiftUIColor },
            set: { draft.quaternaryColor = CodableColor($0) }
        )
    }

    private var quinaryColorBinding: Binding<Color> {
        Binding(
            get: { draft.resolvedQuinaryColor.swiftUIColor },
            set: { draft.quinaryColor = CodableColor($0) }
        )
    }

    private var gradientSpeedBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedGradientSpeed },
            set: { draft.gradientSpeed = $0 }
        )
    }

    private var coloringUsesGradientBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedColoringUsesGradient },
            set: { draft.coloringUsesGradient = $0 }
        )
    }

    private var brushWaveAmountBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedWaveAmount },
            set: { draft.waveAmount = $0 }
        )
    }

    private var gradientMergeBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedGradientMergesAcrossStrokes },
            set: { draft.gradientMergesAcrossStrokes = $0 }
        )
    }

    private var trippyColorCountBinding: Binding<Int> {
        Binding(
            get: { draft.resolvedTrippyColorCount },
            set: { draft.trippyColorCount = max(2, min(5, $0)) }
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

    private var fadedSpeedBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedFadedSpeed },
            set: { draft.fadedSpeed = $0 }
        )
    }

    private var fadedAmountBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedFadedAmount },
            set: { draft.fadedAmount = $0 }
        )
    }

    private var fadedBaseOpacityBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedFadedBaseOpacity },
            set: { draft.fadedBaseOpacity = $0 }
        )
    }

    private var fadedTextureOpacityBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedFadedTextureOpacity },
            set: { draft.fadedTextureOpacity = $0 }
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

    private var dashGapBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedDashGap },
            set: { draft.dashGap = $0 }
        )
    }

    private var dashCornerBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedDashCornerRadius },
            set: { draft.dashCornerRadius = $0 }
        )
    }

    private var dotGapBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedDotGap },
            set: { draft.dotGap = $0 }
        )
    }

    private var particleSpeedBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedParticleSpeed },
            set: { draft.particleSpeed = $0 }
        )
    }

    private var particleLengthBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedParticleLength },
            set: { draft.particleLength = $0 }
        )
    }

    private var particleDelayBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedParticleDelay },
            set: { draft.particleDelay = $0 }
        )
    }

    private var checkerSpeedBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedCheckerSpeed },
            set: { draft.checkerSpeed = $0 }
        )
    }

    private var gooSpeedBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedGooSpeed },
            set: { draft.gooSpeed = $0 }
        )
    }

    private var gooThicknessBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedGooThickness },
            set: { draft.gooThickness = $0 }
        )
    }

    private var gooWavinessBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedGooWaviness },
            set: { draft.gooWaviness = $0 }
        )
    }

    private var gooWaveLengthBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedGooWaveLength },
            set: { draft.gooWaveLength = $0 }
        )
    }

    private var gooDropletsBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedGooDroplets > 0.01 },
            set: { draft.gooDroplets = $0 ? 1 : 0 }
        )
    }

    private var starRotationSpeedBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedStarRotationSpeed },
            set: { draft.starRotationSpeed = $0 }
        )
    }

    private var starRotationModeBinding: Binding<StarRotationMode> {
        Binding(
            get: { draft.resolvedStarRotationMode },
            set: { draft.starRotationMode = $0 }
        )
    }

    private var starGradientAcrossStrokeBinding: Binding<Bool> {
        Binding(
            get: { draft.resolvedStarGradientAcrossStroke },
            set: { draft.starGradientAcrossStroke = $0 }
        )
    }

    private var startWidthBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedStartWidthScale },
            set: { draft.startWidthScale = $0 }
        )
    }

    private var endStyleBinding: Binding<BrushEndStyle> {
        Binding(
            get: { draft.resolvedEndStyle },
            set: { draft.endStyle = $0 }
        )
    }

    private var endWidthBinding: Binding<Double> {
        Binding(
            get: { draft.resolvedEndWidthScale },
            set: { draft.endWidthScale = $0 }
        )
    }
}

private enum BrushLibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case coloring = "Color"
    case texture = "Texture"
    case motion = "Motion"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .coloring: "paintpalette"
        case .texture: "aqi.medium"
        case .motion: "waveform.path"
        }
    }

    func matches(_ kind: BrushKind) -> Bool {
        switch self {
        case .all:
            true
        case .coloring:
            [.cutMarker, .solidColor, .softAirbrush, .gouache, .flatChisel, .gradient].contains(kind)
        case .texture:
            [.jitter, .cutMarker, .gouache, .glitter, .faded, .dryOutline].contains(kind)
        case .motion:
            ![.solidColor, .softAirbrush, .gouache, .flatChisel].contains(kind)
        }
    }
}

private enum BrushPreviewBackground: String, CaseIterable, Identifiable {
    case paper = "Paper"
    case charcoal = "Dark"
    case warm = "Warm"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .paper: "square.fill"
        case .charcoal: "moon.fill"
        case .warm: "sun.max.fill"
        }
    }

    var color: CodableColor {
        switch self {
        case .paper:
            CodableColor(red: 0.98, green: 0.98, blue: 0.97)
        case .charcoal:
            CodableColor(red: 0.08, green: 0.075, blue: 0.10)
        case .warm:
            CodableColor(red: 0.95, green: 0.87, blue: 0.73)
        }
    }

    var swiftUIColor: Color { color.swiftUIColor }

    var ciColor: CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

private struct BrushScratchCommand: Equatable {
    enum Action {
        case none
        case undo
        case clear
    }

    let id: UUID
    let action: Action

    static let idle = BrushScratchCommand(id: UUID(), action: .none)

    init(id: UUID = UUID(), action: Action) {
        self.id = id
        self.action = action
    }
}

private struct BrushScratchPad: UIViewRepresentable {
    let brush: BrushSettings
    let command: BrushScratchCommand
    let isPlaying: Bool
    let background: BrushPreviewBackground

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> AnimatedMetalView {
        let view = AnimatedMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        let document = makePreviewDocument(brush: brush, background: background)

        view.document = document
        view.surroundingColor = background.ciColor
        view.canvasInsetFactor = 1
        view.canvasFillsView = true
        view.brush = brush
        view.inputPolicy = .pencilAndFinger
        view.isAnimationPlaying = isPlaying

        context.coordinator.view = view
        context.coordinator.appliedBrush = brush
        context.coordinator.appliedBackground = background
        context.coordinator.lastCommandID = command.id

        view.onStroke = { [weak view] stroke in
            guard let view else { return }
            var committed = stroke
            committed.isPreview = false
            var updated = view.document
            updated.layers[0].strokes.append(committed)
            updated.modifiedAt = Date()
            view.document = updated
        }

        return view
    }

    func updateUIView(_ view: AnimatedMetalView, context: Context) {
        view.brush = brush
        view.isAnimationPlaying = isPlaying

        if context.coordinator.appliedBackground != background {
            context.coordinator.appliedBackground = background
            view.surroundingColor = background.ciColor
            var updated = view.document
            updated.background = background.color
            updated.backgroundVisible = true
            updated.modifiedAt = Date()
            view.document = updated
        }

        if context.coordinator.lastCommandID != command.id {
            context.coordinator.lastCommandID = command.id
            context.coordinator.apply(command.action)
        }

        if context.coordinator.appliedBrush != brush {
            context.coordinator.scheduleBrushUpdate(brush)
        }
    }

    static func dismantleUIView(_ view: AnimatedMetalView, coordinator: Coordinator) {
        coordinator.cancelPendingUpdate()
        view.onStroke = nil
    }

    private func makePreviewDocument(
        brush: BrushSettings,
        background: BrushPreviewBackground
    ) -> WiggleDocument {
        var document = WiggleDocument.blank(
            name: "Brush Preview",
            size: CGSize(width: 1000, height: 1000)
        )
        document.background = background.color
        document.backgroundVisible = true
        document.layers[0].strokes = [sampleStroke(brush: brush)]
        document.modifiedAt = Date()
        return document
    }

    private func sampleStroke(brush: BrushSettings) -> AnimatedStroke {
        let samples = (0..<92).map { index -> StrokeSample in
            let progress = Double(index) / 91
            let x = 80 + progress * 840
            let wave = sin(progress * .pi * 2.2) * 110
            let lift = sin(progress * .pi) * 52
            let pressure = 0.45 + sin(progress * .pi) * 0.45
            return StrokeSample(
                x: x,
                y: 510 + wave - lift,
                pressure: pressure,
                tilt: 0.18,
                azimuth: progress * 0.3,
                timestamp: progress * 1.2
            )
        }
        return AnimatedStroke(samples: samples, brush: brush)
    }

    final class Coordinator: NSObject {
        weak var view: AnimatedMetalView?
        var appliedBrush: BrushSettings?
        var appliedBackground: BrushPreviewBackground?
        var lastCommandID: UUID?
        private var pendingBrush: BrushSettings?

        func scheduleBrushUpdate(_ brush: BrushSettings) {
            pendingBrush = brush
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(applyPendingBrush),
                object: nil
            )
            perform(#selector(applyPendingBrush), with: nil, afterDelay: 0.09)
        }

        func cancelPendingUpdate() {
            NSObject.cancelPreviousPerformRequests(
                withTarget: self,
                selector: #selector(applyPendingBrush),
                object: nil
            )
        }

        func apply(_ action: BrushScratchCommand.Action) {
            guard let view else { return }
            var updated = view.document

            switch action {
            case .none:
                return
            case .undo:
                guard !updated.layers[0].strokes.isEmpty else { return }
                updated.layers[0].strokes.removeLast()
            case .clear:
                updated.layers[0].strokes.removeAll()
            }

            updated.modifiedAt = Date()
            view.document = updated
        }

        @objc private func applyPendingBrush() {
            guard let view, let brush = pendingBrush else { return }
            pendingBrush = nil
            appliedBrush = brush

            var updated = view.document
            for layerIndex in updated.layers.indices {
                for strokeIndex in updated.layers[layerIndex].strokes.indices {
                    updated.layers[layerIndex].strokes[strokeIndex].brush = brush
                }
            }
            updated.modifiedAt = Date()
            view.document = updated
        }
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
        .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
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
                brushIcon

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
                isSelected ? Color.blue.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var brushIcon: some View {
        Image(systemName: brush.kind.symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(brush.color.swiftUIColor)
            .frame(width: 36, height: 36)
            .background(Color(red: 0.11, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }
    }
}

private struct BrushTile: View {
    let brush: BrushSettings
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: brush.kind.symbol)
                    .foregroundStyle(brush.color.swiftUIColor)
                    .frame(width: 30, height: 30)
                    .background(Color(red: 0.11, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 1) {
                    Text(brush.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(brush.kind.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 154, height: 48, alignment: .leading)
            .background(
                isSelected ? Color.blue.opacity(0.18) : Color.white.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.blue.opacity(0.7) : .white.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                NumericValueButton(
                    title: title,
                    value: $value,
                    range: range,
                    fractionDigits: value >= 10 ? 1 : 2
                )
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
