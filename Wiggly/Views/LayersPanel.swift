import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LayersSidebar: View {
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importsFile = false
    @State private var showsRename = false
    @State private var renamingLayerID: UUID?
    @State private var renameText = ""
    @State private var optionsLayerID: UUID?
    @State private var draggedLayerID: UUID?
    @State private var dragTranslation: CGSize = .zero
    @State private var dropTargetLayerID: UUID?
    @State private var dropTargetAfter = false
    @State private var layerRowFrames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            opacityControl
            Divider().overlay(.white.opacity(0.12))

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(editor.document.layers.reversed())) { layer in
                        if let index = editor.document.layers.firstIndex(where: { $0.id == layer.id }) {
                            layerRow(index: index)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(
                                            key: LayerRowFramePreferenceKey.self,
                                            value: [layer.id: proxy.frame(in: .named("layerList"))]
                                        )
                                    }
                                }
                                .overlay { layerDropIndicator(for: layer.id) }
                                .offset(y: draggedLayerID == layer.id ? dragTranslation.height : 0)
                                .scaleEffect(draggedLayerID == layer.id ? 1.04 : 1)
                                .opacity(draggedLayerID == layer.id ? 0.94 : 1)
                                .shadow(
                                    color: draggedLayerID == layer.id ? .orange.opacity(0.38) : .clear,
                                    radius: 12,
                                    y: 6
                                )
                                .zIndex(draggedLayerID == layer.id ? 2 : 0)
                                .animation(.spring(response: 0.24, dampingFraction: 0.72), value: draggedLayerID)
                                .highPriorityGesture(layerReorderGesture(for: layer.id))
                                .accessibilityHint("Touch and hold, then drag to reorder")
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .coordinateSpace(name: "layerList")
            .onPreferenceChange(LayerRowFramePreferenceKey.self) { layerRowFrames = $0 }

            Divider().overlay(.white.opacity(0.12))
            backgroundRow
            Divider().overlay(.white.opacity(0.12))
            footer
        }
        .frame(width: 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 10)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.image]) { result in
            importFile(result)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    importImage(data: data, name: "Photo")
                }
                selectedPhoto = nil
            }
        }
        .alert("Rename Layer", isPresented: $showsRename) {
            TextField("Layer name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { applyRename() }
        }
    }

    private var header: some View {
        HStack {
            Text("Layers").font(.headline)
            Spacer()
            Text("\(editor.document.layers.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Layers")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var opacityControl: some View {
        let index = editor.document.selectedLayerIndex
        return HStack(spacing: 10) {
            Text("Opacity")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { editor.document.layers[index].opacity },
                    set: { editor.updateSelectedLayerOpacity($0) }
                ),
                in: 0...1,
                onEditingChanged: { isEditing in
                    if isEditing {
                        editor.beginLayerOpacityChange()
                    } else {
                        editor.endLayerOpacityChange()
                    }
                }
            )
            .transaction { $0.animation = nil }
            Text("\(Int(editor.document.layers[index].opacity * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func layerRow(index: Int) -> some View {
        let layer = editor.document.layers[index]
        let selected = layer.id == editor.document.selectedLayerID

        return HStack(spacing: 10) {
            Button {
                editor.commit { $0.layers[index].isVisible.toggle() }
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .foregroundStyle(layer.isVisible ? .white : .secondary)
                    .frame(width: 28, height: 42)
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                LayerMiniMap(
                    layer: layer,
                    canvasSize: CGSize(
                        width: CGFloat(editor.document.width),
                        height: CGFloat(editor.document.height)
                    )
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(layer.name)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(layer.imageData == nil
                         ? "\(layer.strokes.count) stroke\(layer.strokes.count == 1 ? "" : "s")"
                         : "Imported image")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if editor.document.selectedLayerID != layer.id {
                    editor.imageTransformMode = false
                }
                editor.document.selectedLayerID = layer.id
                optionsLayerID = layer.id
            }
        }
        .padding(8)
        .background(
            selected ? Color.orange.opacity(0.14) : Color.black.opacity(0.13),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(Rectangle())
        .popover(isPresented: Binding(
            get: { optionsLayerID == layer.id },
            set: { if !$0 { optionsLayerID = nil } }
        ), arrowEdge: .trailing) {
            layerActions(index: index, layer: layer)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func layerActions(index: Int, layer: DrawingLayer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if layer.imageData != nil {
                layerAction("Transform Image", icon: "arrow.up.left.and.arrow.down.right") {
                    optionsLayerID = nil
                    editor.document.selectedLayerID = layer.id
                    editor.selectionMode = false
                    editor.eraserMode = false
                    editor.imageTransformMode = true
                    isPresented = false
                }
                layerAction("Reset Image Transform", icon: "arrow.counterclockwise") {
                    optionsLayerID = nil
                    editor.document.selectedLayerID = layer.id
                    editor.resetSelectedImageTransform()
                }
                Divider().padding(.vertical, 3)
            }
            layerAction("Rename", icon: "pencil") {
                optionsLayerID = nil
                DispatchQueue.main.async { beginRename(layer) }
            }
            layerAction("Select Contents", icon: "lasso") {
                optionsLayerID = nil
                editor.document.selectedLayerID = layer.id
                editor.selectedStrokeID = layer.strokes.last?.id
                editor.selectionMode = true
                editor.eraserMode = false
                editor.imageTransformMode = false
            }
            layerAction("Copy Layer", icon: "plus.square.on.square") {
                optionsLayerID = nil
                duplicateSelected(index: index)
            }
            layerAction("Fill Layer", icon: "paintbrush.fill") {
                optionsLayerID = nil
                fillLayer(index: index)
            }
            Divider().padding(.vertical, 3)
            layerAction("Move to Top", icon: "arrow.up.to.line") {
                optionsLayerID = nil
                moveLayerToTop(layer.id)
            }
            layerAction("Move to Bottom", icon: "arrow.down.to.line") {
                optionsLayerID = nil
                moveLayerToBottom(layer.id)
            }
            layerAction("Clear", icon: "eraser", role: .destructive) {
                optionsLayerID = nil
                clearLayer(index: index)
            }
            if editor.document.layers.count > 1 {
                layerAction("Delete", icon: "trash", role: .destructive) {
                    optionsLayerID = nil
                    deleteSelected(index: index)
                }
            }
        }
        .padding(8)
        .frame(width: 230)
    }

    private func layerAction(
        _ title: String,
        icon: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var backgroundRow: some View {
        HStack(spacing: 10) {
            Button {
                editor.commit { document in
                    document.backgroundVisible = !document.resolvedBackgroundVisible
                }
            } label: {
                Image(systemName: editor.document.resolvedBackgroundVisible ? "eye" : "eye.slash")
                    .foregroundStyle(editor.document.resolvedBackgroundVisible ? .white : .secondary)
                    .frame(width: 28, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(editor.document.resolvedBackgroundVisible ? "Hide Background" : "Show Background")

            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(editor.document.background.swiftUIColor)
                .frame(width: 46, height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Background Color")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Text(editor.document.resolvedBackgroundVisible ? "Visible" : "Transparent")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.1))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            sidebarButton("Add", icon: "plus", action: addLayer)

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Image(systemName: "photo").frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Import from Photos")

            sidebarButton("Import File", icon: "folder") { importsFile = true }
            sidebarButton("Duplicate", icon: "plus.square.on.square") {
                duplicateSelected(index: editor.document.selectedLayerIndex)
            }
            sidebarButton("Delete", icon: "trash", role: .destructive) {
                deleteSelected(index: editor.document.selectedLayerIndex)
            }
            .disabled(editor.document.layers.count <= 1)
        }
        .padding(10)
    }

    private func sidebarButton(
        _ title: String,
        icon: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: icon).frame(width: 26, height: 26)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }

    private func beginRename(_ layer: DrawingLayer) {
        renamingLayerID = layer.id
        renameText = layer.name
        showsRename = true
    }

    private func applyRename() {
        guard let renamingLayerID,
              let index = editor.document.layers.firstIndex(where: { $0.id == renamingLayerID }) else { return }
        let cleanName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.commit { $0.layers[index].name = cleanName.isEmpty ? "Layer" : cleanName }
    }

    private func addLayer() {
        editor.commit { document in
            let layer = DrawingLayer(name: "Layer \(document.layers.count + 1)")
            let insertionIndex = min(document.layers.count, document.selectedLayerIndex + 1)
            document.layers.insert(layer, at: insertionIndex)
            document.selectedLayerID = layer.id
        }
    }

    private func importImage(data: Data, name: String) {
        guard UIImage(data: data) != nil else { return }
        editor.commit { document in
            var layer = DrawingLayer(name: name)
            layer.imageData = data
            layer.imageName = name
            document.layers.append(layer)
            document.selectedLayerID = layer.id
        }
        editor.selectionMode = false
        editor.eraserMode = false
        editor.imageTransformMode = true
        isPresented = false
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        importImage(data: data, name: url.deletingPathExtension().lastPathComponent)
    }

    private func duplicateSelected(index: Int) {
        editor.commit { document in
            var copy = document.layers[index]
            copy.id = UUID()
            copy.name += " Copy"
            copy.strokes = copy.strokes.map {
                var stroke = $0
                stroke.id = UUID()
                return stroke
            }
            document.layers.insert(copy, at: index + 1)
            document.selectedLayerID = copy.id
        }
    }

    private func fillLayer(index: Int) {
        let width = Double(editor.document.width)
        let height = Double(editor.document.height)
        let color = editor.selectedBrush.color
        let rectangle = [
            StrokeSample(x: 0, y: 0, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokeSample(x: width, y: 0, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokeSample(x: width, y: height, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0),
            StrokeSample(x: 0, y: height, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ]
        editor.commit { document in
            var fills = document.layers[index].fills ?? []
            fills.append(CanvasFill(samples: rectangle, color: color))
            document.layers[index].fills = fills
        }
    }

    private func clearLayer(index: Int) {
        editor.commit { document in
            document.layers[index].strokes.removeAll()
            document.layers[index].fills = nil
            document.layers[index].imageData = nil
            document.layers[index].imageName = nil
            document.layers[index].imageScale = nil
            document.layers[index].imageOffsetX = nil
            document.layers[index].imageOffsetY = nil
        }
        editor.selectedStrokeID = nil
        editor.imageTransformMode = false
    }

    private func moveLayerToTop(_ layerID: UUID) {
        editor.commit { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { return }
            document.layers.append(document.layers.remove(at: index))
        }
    }

    private func moveLayerToBottom(_ layerID: UUID) {
        editor.commit { document in
            guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { return }
            document.layers.insert(document.layers.remove(at: index), at: 0)
        }
    }

    private func deleteSelected(index: Int) {
        guard editor.document.layers.count > 1 else { return }
        if editor.document.layers[index].id == editor.document.selectedLayerID {
            editor.imageTransformMode = false
        }
        editor.commit { document in
            document.layers.remove(at: index)
            document.selectedLayerID = document.layers[min(index, document.layers.count - 1)].id
        }
    }

    private func layerReorderGesture(for layerID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.22, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("layerList")))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if draggedLayerID == nil {
                    editor.beginLayerReorder()
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
                        draggedLayerID = layerID
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                dragTranslation = drag.translation
                if abs(drag.translation.height) > 6 {
                    updateDropTarget(for: layerID, at: drag.location.y)
                }
            }
            .onEnded { _ in
                guard draggedLayerID == layerID else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                    if let dropTargetLayerID {
                        editor.moveLayer(
                            layerID,
                            relativeTo: dropTargetLayerID,
                            placeAfter: dropTargetAfter
                        )
                    }
                    editor.endLayerReorder()
                    dragTranslation = .zero
                    draggedLayerID = nil
                    dropTargetLayerID = nil
                    dropTargetAfter = false
                }
            }
    }

    private func updateDropTarget(for layerID: UUID, at verticalLocation: CGFloat) {
        guard draggedLayerID == layerID,
              let target = layerRowFrames
                .filter({ $0.key != layerID })
                .min(by: {
                    abs($0.value.midY - verticalLocation) < abs($1.value.midY - verticalLocation)
                }) else { return }
        let placeAfter = verticalLocation > target.value.midY
        guard dropTargetLayerID != target.key || dropTargetAfter != placeAfter else { return }
        withAnimation(.easeOut(duration: 0.14)) {
            dropTargetLayerID = target.key
            dropTargetAfter = placeAfter
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @ViewBuilder
    private func layerDropIndicator(for layerID: UUID) -> some View {
        if dropTargetLayerID == layerID {
            VStack(spacing: 0) {
                if !dropTargetAfter {
                    Capsule()
                        .fill(.orange)
                        .frame(height: 3)
                        .shadow(color: .orange.opacity(0.65), radius: 4)
                        .offset(y: -5)
                }
                Spacer(minLength: 0)
                if dropTargetAfter {
                    Capsule()
                        .fill(.orange)
                        .frame(height: 3)
                        .shadow(color: .orange.opacity(0.65), radius: 4)
                        .offset(y: 5)
                }
            }
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
        }
    }
}

private struct LayerRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LayerMiniMap: View {
    let layer: DrawingLayer
    let canvasSize: CGSize

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            drawCheckerboard(in: &context, size: size)
            guard canvasSize.width > 0, canvasSize.height > 0 else { return }

            let scale = min(size.width / canvasSize.width, size.height / canvasSize.height)
            let drawingSize = CGSize(
                width: canvasSize.width * scale,
                height: canvasSize.height * scale
            )
            let origin = CGPoint(
                x: (size.width - drawingSize.width) / 2,
                y: (size.height - drawingSize.height) / 2
            )

            context.clip(to: Path(CGRect(origin: origin, size: drawingSize)))
            context.opacity = layer.opacity

            if let data = layer.imageData, let image = UIImage(data: data) {
                let fittedScale = min(
                    canvasSize.width / max(1, image.size.width),
                    canvasSize.height / max(1, image.size.height)
                ) * layer.resolvedImageScale
                let imageSize = CGSize(
                    width: image.size.width * fittedScale * scale,
                    height: image.size.height * fittedScale * scale
                )
                let offset = layer.resolvedImageOffset
                let imageRect = CGRect(
                    x: origin.x + (drawingSize.width - imageSize.width) / 2 + offset.x * scale,
                    y: origin.y + (drawingSize.height - imageSize.height) / 2 + offset.y * scale,
                    width: imageSize.width,
                    height: imageSize.height
                )
                context.draw(Image(uiImage: image), in: imageRect)
            }

            for fill in layer.fills ?? [] where fill.samples.count > 2 {
                var path = Path()
                let first = miniPoint(fill.samples[0].point, origin: origin, scale: scale)
                path.move(to: first)
                for sample in fill.samples.dropFirst() {
                    path.addLine(to: miniPoint(sample.point, origin: origin, scale: scale))
                }
                path.closeSubpath()
                context.fill(path, with: .color(fill.color.swiftUIColor))
            }

            for stroke in layer.strokes where stroke.samples.count > 1 {
                var path = Path()
                path.move(to: miniPoint(stroke.samples[0].point, origin: origin, scale: scale))
                for sample in stroke.samples.dropFirst() {
                    path.addLine(to: miniPoint(sample.point, origin: origin, scale: scale))
                }
                context.stroke(
                    path,
                    with: .color(stroke.brush.color.swiftUIColor.opacity(stroke.brush.opacity)),
                    style: StrokeStyle(
                        lineWidth: max(0.7, stroke.brush.size * scale),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .frame(width: 46, height: 46)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func miniPoint(_ point: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    private func drawCheckerboard(in context: inout GraphicsContext, size: CGSize) {
        let tile: CGFloat = 6
        let rows = Int(ceil(size.height / tile))
        let columns = Int(ceil(size.width / tile))
        for row in 0..<rows {
            for column in 0..<columns {
                let shade = (row + column).isMultiple(of: 2) ? 0.94 : 0.82
                context.fill(
                    Path(CGRect(
                        x: CGFloat(column) * tile,
                        y: CGFloat(row) * tile,
                        width: tile,
                        height: tile
                    )),
                    with: .color(Color(white: shade))
                )
            }
        }
    }
}
