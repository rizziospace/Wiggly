import Combine
import SwiftUI
import UIKit

struct GalleryView: View {
    @ObservedObject var library: ProjectLibrary
    @State private var activeDocument: WiggleDocument?
    @State private var showingNewProject = false
    @State private var openingProjectID: UUID?
    @State private var renameProject: ProjectSummary?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 20)]

    var body: some View {
        NavigationStack {
            Group {
                if library.projects.isEmpty {
                    ContentUnavailableView {
                        Label("Start something wiggly", systemImage: "scribble.variable")
                    } description: {
                        Text("Create a canvas, pick up Apple Pencil, and draw in motion.")
                    } actions: {
                        Button("New Drawing") {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                showingNewProject = true
                            }
                        }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(library.projects) { project in
                                ProjectCard(project: project, library: library)
                                    .onTapGesture { open(project) }
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") {
                                            afterContextMenuDismisses {
                                                renameText = project.name
                                                renameProject = project
                                            }
                                        }
                                        Button("Duplicate", systemImage: "plus.square.on.square") {
                                            afterContextMenuDismisses {
                                                library.duplicate(project)
                                            }
                                        }
                                        Divider()
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            afterContextMenuDismisses {
                                                library.delete(project)
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("Wiggly")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Drawing", systemImage: "plus") {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            showingNewProject = true
                        }
                    }
                }
            }
        }
        .overlay {
            if showingNewProject {
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(0.42)
                            .ignoresSafeArea()
                            .onTapGesture {
                                dismissActiveKeyboard()
                                withAnimation(.easeOut(duration: 0.16)) {
                                    showingNewProject = false
                                }
                            }

                        NewProjectView(
                            onCancel: {
                                dismissActiveKeyboard()
                                withAnimation(.easeOut(duration: 0.16)) {
                                    showingNewProject = false
                                }
                            },
                            onCreate: { name, size in
                                activeDocument = library.create(name: name, size: size)
                                showingNewProject = false
                            }
                        )
                        .frame(
                            width: min(620, proxy.size.width - 40),
                            height: min(560, proxy.size.height - 60)
                        )
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .zIndex(10)
            }
        }
        .overlay {
            if openingProjectID != nil {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                    ProgressView("Opening drawing…")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(Color(red: 0.15, green: 0.15, blue: 0.17), in: Capsule())
                }
                .allowsHitTesting(true)
                .zIndex(30)
            }
        }
        .fullScreenCover(item: $activeDocument) { document in
            EditorView(document: document, library: library)
        }
        .alert("Rename Drawing", isPresented: Binding(
            get: { renameProject != nil },
            set: { if !$0 { renameProject = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let renameProject { library.rename(renameProject, to: renameText) }
            }
        }
        .alert("Wiggly", isPresented: Binding(
            get: { library.lastError != nil },
            set: { if !$0 { library.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(library.lastError ?? "")
        }
    }

    private func afterContextMenuDismisses(_ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            action()
        }
    }

    private func open(_ project: ProjectSummary) {
        guard openingProjectID == nil else { return }
        openingProjectID = project.id
        Task {
            let document = await library.loadAsync(id: project.id)
            guard openingProjectID == project.id else { return }
            openingProjectID = nil
            activeDocument = document
        }
    }
}

private struct DashboardThumbnail: View {
    let project: ProjectSummary
    @ObservedObject var library: ProjectLibrary
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(.white)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "scribble.variable")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: project.modifiedAt) {
            image = await library.thumbnailImage(for: project)
        }
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    @ObservedObject var library: ProjectLibrary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardThumbnail(project: project, library: library)
            .aspectRatio(CGFloat(project.width) / CGFloat(project.height), contentMode: .fit)
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 5)

            Text(project.name)
                .font(.headline)
                .lineLimit(1)
            Text("\(project.width) × \(project.height) • \(project.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct NewProjectView: View {
    @StateObject private var presetStore = CanvasPresetStore()
    @State private var name = "Untitled"
    @State private var width = 2048
    @State private var height = 2048
    @State private var selectedPresetID: String? = CanvasTemplate.builtIns[0].id
    @State private var showingSavePreset = false
    @State private var presetName = ""
    let onCancel: () -> Void
    let onCreate: (String, CGSize) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Canvas")
                        .font(.title3.bold())
                    Text("Set your canvas size")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("NAME")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)

                    TextField("Canvas name", text: $name)
                        .font(.body.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(
                            Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("DIMENSIONS")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text("\(orientationTitle) • \(megapixelText)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .bottom, spacing: 10) {
                        PixelDimensionField(title: "Width", value: widthBinding)

                        Button {
                            let oldWidth = width
                            width = height
                            height = oldWidth
                            selectedPresetID = matchingPresetID
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.body.weight(.semibold))
                                .frame(width: 56, height: 56)
                                .background(
                                    Color.primary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Swap width and height")

                        PixelDimensionField(title: "Height", value: heightBinding)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("PRESETS")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Save current size", systemImage: "bookmark") {
                            dismissActiveKeyboard()
                            presetName = suggestedPresetName
                            showingSavePreset = true
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                    }

                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)
                            ],
                            spacing: 10
                        ) {
                            ForEach(allPresets) { preset in
                                CanvasPresetCard(
                                    preset: preset,
                                    isSelected: selectedPresetID == preset.id,
                                    compact: false,
                                    onSelect: { select(preset) },
                                    onDelete: preset.isBuiltIn ? nil : {
                                        presetStore.delete(preset)
                                        if selectedPresetID == preset.id {
                                            selectedPresetID = matchingPresetID
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .scrollIndicators(.visible)
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .padding(22)

            Divider()

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 42)

                Spacer()

                Button {
                    createCanvas()
                } label: {
                    Label("Create Canvas", systemImage: "plus")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                        .foregroundStyle(.white)
                        .background(.blue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.46), radius: 34, y: 20)
        .onDisappear {
            dismissActiveKeyboard()
        }
        .alert("Save Canvas Preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let saved = presetStore.save(
                    name: presetName,
                    width: clampedWidth,
                    height: clampedHeight
                )
                selectedPresetID = saved.id
                presetName = ""
            }
            .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("\(clampedWidth) × \(clampedHeight) px")
        }
    }

    private func friendlyPresetSection(
        _ title: String,
        presets: [CanvasTemplate]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 145, maximum: 190), spacing: 10)],
                spacing: 10
            ) {
                ForEach(presets) { preset in
                    CanvasPresetCard(
                        preset: preset,
                        isSelected: selectedPresetID == preset.id,
                        compact: false,
                        onSelect: { select(preset) },
                        onDelete: preset.isBuiltIn ? nil : { presetStore.delete(preset) }
                    )
                }
            }
        }
    }

    private var friendlySetupCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Canvas name")
                    .font(.headline)
                TextField("Untitled", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Dimensions")
                        .font(.headline)
                    Spacer()
                    Text("\(orientationTitle) • \(megapixelText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    PixelDimensionField(title: "Width", value: widthBinding)

                    Button {
                        let oldWidth = width
                        width = height
                        height = oldWidth
                        selectedPresetID = matchingPresetID
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Swap width and height")

                    PixelDimensionField(title: "Height", value: heightBinding)
                }

                Text("Enter a value from 64 to 8192 pixels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPresetName)
                        .font(.subheadline.weight(.semibold))
                    Text("\(clampedWidth) × \(clampedHeight) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Save as Preset", systemImage: "bookmark.badge.plus") {
                    presetName = suggestedPresetName
                    showingSavePreset = true
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(Color(red: 0.15, green: 0.15, blue: 0.17), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var presetBrowser: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Canvas Presets", systemImage: "rectangle.3.group")
                    .font(.title3.bold())
                Text("Choose a starting size or save your own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    presetSection("POPULAR", presets: CanvasTemplate.builtIns)

                    if !presetStore.presets.isEmpty {
                        presetSection("MY PRESETS", presets: presetStore.presets)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(18)
    }

    private var compactPresetBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Canvas Presets", systemImage: "rectangle.3.group")
                .font(.headline)

            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(allPresets) { preset in
                        CanvasPresetCard(
                            preset: preset,
                            isSelected: selectedPresetID == preset.id,
                            compact: true,
                            onSelect: { select(preset) },
                            onDelete: preset.isBuiltIn ? nil : { presetStore.delete(preset) }
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func presetSection(_ title: String, presets: [CanvasTemplate]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ],
                spacing: 8
            ) {
                ForEach(presets) { preset in
                    CanvasPresetCard(
                        preset: preset,
                        isSelected: selectedPresetID == preset.id,
                        compact: false,
                        onSelect: { select(preset) },
                        onDelete: preset.isBuiltIn ? nil : { presetStore.delete(preset) }
                    )
                }
            }
        }
    }

    private var setupPanel: some View {
        ScrollView {
            setupContent
                .frame(maxWidth: 620)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            canvasPreview

            VStack(alignment: .leading, spacing: 8) {
                Text("Canvas name")
                    .font(.headline)
                TextField("Untitled", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Dimensions")
                        .font(.headline)
                    Spacer()
                    Text(megapixelText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    dimensionField("Width", value: widthBinding)

                    Button {
                        let oldWidth = width
                        width = height
                        height = oldWidth
                        selectedPresetID = matchingPresetID
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Swap width and height")

                    dimensionField("Height", value: heightBinding)
                }

                Text("64–8192 pixels per side")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPresetName)
                        .font(.subheadline.weight(.semibold))
                    Text("\(clampedWidth) × \(clampedHeight) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Save Preset", systemImage: "bookmark.badge.plus") {
                    presetName = suggestedPresetName
                    showingSavePreset = true
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var canvasPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Preview", systemImage: "rectangle.on.rectangle")
                    .font(.headline)
                Spacer()
                Text(orientationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.blue.opacity(0.12), in: Capsule())
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.10), Color.black.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white)
                    .aspectRatio(previewAspectRatio, contentMode: .fit)
                    .padding(22)
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 5)

                Text("\(clampedWidth) × \(clampedHeight)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(red: 0.11, green: 0.11, blue: 0.13), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(12)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
        }
    }

    private func dimensionField(_ title: String, value: Binding<Int>) -> some View {
        PixelDimensionField(title: title, value: value)
    }

    private var widthBinding: Binding<Int> {
        Binding(
            get: { width },
            set: {
                width = $0
                selectedPresetID = matchingPresetID
            }
        )
    }

    private var heightBinding: Binding<Int> {
        Binding(
            get: { height },
            set: {
                height = $0
                selectedPresetID = matchingPresetID
            }
        )
    }

    private var allPresets: [CanvasTemplate] {
        CanvasTemplate.builtIns + presetStore.presets
    }

    private var matchingPresetID: String? {
        allPresets.first {
            $0.width == clampedWidth && $0.height == clampedHeight
        }?.id
    }

    private var selectedPresetName: String {
        guard let selectedPresetID,
              let preset = allPresets.first(where: { $0.id == selectedPresetID }) else {
            return "Custom Size"
        }
        return preset.name
    }

    private var suggestedPresetName: String {
        selectedPresetName == "Custom Size"
            ? "\(orientationTitle) \(clampedWidth) × \(clampedHeight)"
            : "\(selectedPresetName) Copy"
    }

    private var orientationTitle: String {
        if clampedWidth == clampedHeight { return "Square" }
        return clampedWidth > clampedHeight ? "Landscape" : "Portrait"
    }

    private var previewAspectRatio: CGFloat {
        CGFloat(clampedWidth) / CGFloat(max(1, clampedHeight))
    }

    private var megapixelText: String {
        let megapixels = Double(clampedWidth * clampedHeight) / 1_000_000
        return "\(megapixels.formatted(.number.precision(.fractionLength(1)))) MP"
    }

    private var clampedWidth: Int {
        min(8192, max(64, width))
    }

    private var clampedHeight: Int {
        min(8192, max(64, height))
    }

    private func select(_ preset: CanvasTemplate) {
        selectedPresetID = preset.id
        width = preset.width
        height = preset.height
    }

    private func createCanvas() {
        dismissActiveKeyboard()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(
            cleanName.isEmpty ? "Untitled" : cleanName,
            CGSize(width: clampedWidth, height: clampedHeight)
        )
        onCancel()
    }
}

@MainActor
private func dismissActiveKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

private struct CanvasTemplate: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    var width: Int
    var height: Int
    var isBuiltIn: Bool

    static let builtIns: [CanvasTemplate] = [
        CanvasTemplate(id: "builtin.square", name: "Square", width: 2048, height: 2048, isBuiltIn: true),
        CanvasTemplate(id: "builtin.portrait", name: "Portrait", width: 2048, height: 2732, isBuiltIn: true),
        CanvasTemplate(id: "builtin.landscape", name: "Landscape", width: 2732, height: 2048, isBuiltIn: true),
        CanvasTemplate(id: "builtin.story", name: "Story", width: 1080, height: 1920, isBuiltIn: true),
        CanvasTemplate(id: "builtin.fullhd", name: "Full HD", width: 1920, height: 1080, isBuiltIn: true),
        CanvasTemplate(id: "builtin.4k", name: "4K", width: 3840, height: 2160, isBuiltIn: true),
        CanvasTemplate(id: "builtin.a4", name: "A4 Print", width: 2480, height: 3508, isBuiltIn: true),
        CanvasTemplate(id: "builtin.icon", name: "App Icon", width: 1024, height: 1024, isBuiltIn: true)
    ]
}

@MainActor
private final class CanvasPresetStore: ObservableObject {
    @Published private(set) var presets: [CanvasTemplate] = []

    private let defaults: UserDefaults
    private let storageKey = "wiggly.saved-canvas-presets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    @discardableResult
    func save(name: String, width: Int, height: Int) -> CanvasTemplate {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "Custom Canvas" : cleanName

        if let index = presets.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(finalName) == .orderedSame
        }) {
            presets[index].width = width
            presets[index].height = height
            persist()
            return presets[index]
        }

        let preset = CanvasTemplate(
            id: "saved.\(UUID().uuidString)",
            name: finalName,
            width: width,
            height: height,
            isBuiltIn: false
        )
        presets.append(preset)
        presets.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persist()
        return preset
    }

    func delete(_ preset: CanvasTemplate) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CanvasTemplate].self, from: data) else {
            presets = []
            return
        }
        presets = decoded.filter { !$0.isBuiltIn }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

private struct PixelDimensionField: View {
    let title: String
    @Binding var value: Int
    @State private var showsKeypad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                showsKeypad = true
            } label: {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    Text(String(value))
                        .font(.title3.monospacedDigit().weight(.semibold))
                    Text("px")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CanvasDimensionButtonStyle())
            .accessibilityLabel("Canvas \(title), \(value) pixels")
            .accessibilityHint("Opens the number keypad and replaces the current value")
            .popover(isPresented: $showsKeypad, arrowEdge: .top) {
                CanvasDimensionKeypad(title: title, initialValue: value) { newValue in
                    value = newValue
                }
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

private struct CanvasDimensionKeypad: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialValue: Int
    let commit: (Int) -> Void

    @State private var input = ""
    @State private var startedTyping = false

    private let digits = [7, 8, 9, 4, 5, 6, 1, 2, 3]

    private var validValue: Int? {
        guard let value = Int(input), (64...8192).contains(value) else { return nil }
        return value
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("64–8192 px")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(input)
                .font(.title2.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                ForEach(digits, id: \.self) { digit in
                    key(String(digit)) { append(digit) }
                }

                Button {
                    if !startedTyping {
                        input = ""
                        startedTyping = true
                    } else if !input.isEmpty {
                        input.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete digit")

                key("0") { append(0) }

                Button {
                    guard let validValue else { return }
                    commit(validValue)
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                .disabled(validValue == nil)
                .opacity(validValue == nil ? 0.35 : 1)
                .accessibilityLabel("Done")
            }

            Button("Cancel") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 320)
        .onAppear {
            input = String(initialValue)
            startedTyping = false
        }
    }

    private func key(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.title2.weight(.semibold).monospacedDigit())
                .frame(maxWidth: .infinity)
                .frame(height: 60)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func append(_ digit: Int) {
        if !startedTyping {
            input = String(digit)
            startedTyping = true
            return
        }
        guard input.count < 4 else { return }
        if input == "0" {
            input = String(digit)
        } else {
            input.append(String(digit))
        }
    }
}

private struct CanvasDimensionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
    }
}

private struct CanvasPresetCard: View {
    let preset: CanvasTemplate
    let isSelected: Bool
    let compact: Bool
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: orientationSymbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(isSelected ? .blue : .secondary)
                .frame(width: 38, height: 38)
                .background(
                    isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(preset.width) × \(preset.height)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.blue)
                }

                if let onDelete {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(width: compact ? 190 : nil, alignment: .leading)
        .frame(minHeight: 64, alignment: .leading)
        .background(
            isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? Color.blue : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(.isButton)
    }

    private var orientationSymbol: String {
        if preset.width == preset.height {
            return "square"
        }
        return preset.width > preset.height ? "rectangle" : "rectangle.portrait"
    }
}
