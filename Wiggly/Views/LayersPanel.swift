import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LayersSidebar: View {
    @ObservedObject var editor: EditorModel
    @Binding var isPresented: Bool
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showsBackgroundColorPicker = false
    @State private var importsFile = false
    @State private var showsRename = false
    @State private var renamingLayerID: UUID?
    @State private var showsGroupRename = false
    @State private var renamingGroupID: UUID?
    @State private var renameText = ""
    @State private var optionsLayerID: UUID?
    @State private var draggedLayerID: UUID?
    @State private var draggedGroupID: UUID?
    @State private var dropTargetLayerID: UUID?
    @State private var dropTargetAfter = false
    @State private var dropTargetGroupID: UUID?
    @State private var dropBoundaryGroupID: UUID?
    @State private var dropBoundaryAfter = false
    @State private var dropTargetUngroup = false
    @State private var itemFrames: [String: CGRect] = [:]
    @State private var isSelectingLayers = false
    @State private var selectedLayerIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))
            footer
            Divider().overlay(.white.opacity(0.12))
            opacityControl
            Divider().overlay(.white.opacity(0.12))

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 3) {
                    ForEach(layerListItems) { item in
                        switch item {
                        case .group(let group, let depth):
                            groupRow(group, depth: depth)
                        case .layer(let layer, let depth):
                            if let index = editor.document.layers.firstIndex(where: { $0.id == layer.id }) {
                                layerListEntry(layer: layer, index: index, depth: depth)
                            }
                        }
                    }
                    if (draggedLayerID != nil
                        && editor.document.layers.first(where: { $0.id == draggedLayerID })?.groupID != nil)
                        || draggedGroupID != nil {
                        ungroupDropZone
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            .coordinateSpace(name: "layersPanel")
            .onPreferenceChange(LayerItemFramesKey.self) { itemFrames = $0 }

            Divider().overlay(.white.opacity(0.12))
            backgroundRow
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color(red: 0.15, green: 0.15, blue: 0.17))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 26, y: 12)
        .overlay {
            layerSettingsOverlay
        }
        .animation(.snappy(duration: 0.18), value: optionsLayerID)
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
        .alert("Rename Group", isPresented: $showsGroupRename) {
            TextField("Group name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { applyGroupRename() }
        }
        .onDisappear {
            cancelNativeDrag()
            editor.endBackgroundColorChange()
        }
        .onChange(of: showsBackgroundColorPicker) { _, isPresented in
            if !isPresented { editor.endBackgroundColorChange() }
        }
    }

    private var layerListItems: [LayerListItem] {
        let document = editor.document
        let displayed = Array(document.layers.reversed())
        let groups = document.layerGroups ?? []
        let groupsByID = Dictionary(
            uniqueKeysWithValues: groups.map { ($0.id, $0) }
        )

        func layerPosition(_ id: UUID) -> Int? {
            displayed.firstIndex(where: { $0.id == id })
        }
        // A folder's slot is where its visually-topmost descendant layer sits;
        // folders with no layers are placed first (nil => -1).
        func groupPosition(_ groupID: UUID, visiting: Set<UUID> = []) -> Int? {
            guard !visiting.contains(groupID) else { return nil }
            let nextVisiting = visiting.union([groupID])
            for layer in displayed where layer.groupID == groupID {
                if let position = layerPosition(layer.id) { return position }
            }
            for group in groups where group.parentGroupID == groupID {
                if let position = groupPosition(group.id, visiting: nextVisiting) { return position }
            }
            return nil
        }

        var items: [LayerListItem] = []
        var emitted: Set<UUID> = []

        func emitGroup(_ group: LayerGroup, depth: Int) {
            guard emitted.insert(group.id).inserted else { return }
            items.append(.group(group, depth: depth))
            guard !group.isCollapsed else { return }
            var children: [(position: Int?, ordinal: Int, group: LayerGroup?, layer: DrawingLayer?)] = []
            for (ordinal, childGroup) in groups.enumerated() where childGroup.parentGroupID == group.id {
                children.append((groupPosition(childGroup.id), ordinal, childGroup, nil))
            }
            for (ordinal, layer) in displayed.enumerated() where layer.groupID == group.id {
                children.append((layerPosition(layer.id), ordinal, nil, layer))
            }
            for child in children.sorted(by: {
                ($0.position ?? -1, $0.ordinal) < ($1.position ?? -1, $1.ordinal)
            }) {
                if let childGroup = child.group {
                    emitGroup(childGroup, depth: depth + 1)
                } else if let layer = child.layer {
                    items.append(.layer(layer, depth: depth + 1))
                }
            }
        }

        let rootGroups = groups.filter { $0.parentGroupID == nil }
        var roots: [(position: Int?, ordinal: Int, group: LayerGroup?, layer: DrawingLayer?)] = []
        for (ordinal, group) in rootGroups.enumerated() {
            roots.append((groupPosition(group.id), ordinal, group, nil))
        }
        for (ordinal, layer) in displayed.enumerated()
        where layer.groupID == nil || groupsByID[layer.groupID!] == nil {
            roots.append((layerPosition(layer.id), ordinal, nil, layer))
        }
        for root in roots.sorted(by: {
            ($0.position ?? -1, $0.ordinal) < ($1.position ?? -1, $1.ordinal)
        }) {
            if let group = root.group {
                emitGroup(group, depth: 0)
            } else if let layer = root.layer {
                items.append(.layer(layer, depth: 0))
            }
        }
        return items
    }

    @ViewBuilder
    private var layerSettingsOverlay: some View {
        if let layerID = optionsLayerID,
           let index = editor.document.layers.firstIndex(where: { $0.id == layerID }) {
            let layer = editor.document.layers[index]
            ZStack {
                Color.black.opacity(0.38)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.18)) {
                            optionsLayerID = nil
                        }
                    }

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        LayerMiniMap(
                            layer: layer,
                            canvasSize: CGSize(
                                width: CGFloat(editor.document.width),
                                height: CGFloat(editor.document.height)
                            )
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Layer Settings")
                                .font(.headline)
                            Text(layer.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                optionsLayerID = nil
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close Layer Settings")
                    }
                    .padding(12)

                    Divider().overlay(.white.opacity(0.12))

                    ScrollView(showsIndicators: false) {
                        layerActions(index: index, layer: layer)
                    }
                }
                .frame(width: 260)
                .frame(maxHeight: 430)
                .background(Color(red: 0.11, green: 0.11, blue: 0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                .padding(12)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private var header: some View {
        HStack {
            Text("Layers").font(.headline)
            Spacer()
            Button(isSelectingLayers ? "Done" : "Select") {
                withAnimation(.snappy(duration: 0.18)) {
                    isSelectingLayers.toggle()
                    if !isSelectingLayers { selectedLayerIDs.removeAll() }
                    optionsLayerID = nil
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            Text("\(editor.document.layers.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
        return HStack(spacing: 4) {
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
            NumericValueButton(
                title: "Layer Opacity",
                value: Binding(
                    get: { editor.document.layers[index].opacity },
                    set: { editor.updateSelectedLayerOpacity($0) }
                ),
                range: 0...1,
                fractionDigits: 0,
                suffix: "%",
                valueScale: 100,
                width: 48,
                arrowEdge: .trailing
            ) { newValue in
                editor.beginLayerOpacityChange()
                editor.updateSelectedLayerOpacity(newValue)
                editor.endLayerOpacityChange()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func layerRow(index: Int) -> some View {
        let layer = editor.document.layers[index]
        let selected = layer.id == editor.document.selectedLayerID
            && editor.selectedLayerGroupID == nil
        let selectedForGrouping = selectedLayerIDs.contains(layer.id)

        return HStack(spacing: 10) {
            panelIconButton(
                systemName: layer.isVisible ? "eye" : "eye.slash",
                tint: layer.isVisible ? .white : .secondary,
                accessibilityLabel: layer.isVisible ? "Hide layer" : "Show layer"
            ) {
                editor.commit { $0.layers[index].isVisible.toggle() }
            }

            HStack(spacing: 10) {
                LayerMiniMap(
                    layer: layer,
                    canvasSize: CGSize(
                        width: CGFloat(editor.document.width),
                        height: CGFloat(editor.document.height)
                    ),
                    thumbnailSize: 30
                )
                Text(layer.name)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if isSelectingLayers {
                    Image(systemName: selectedForGrouping ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedForGrouping ? .orange : .secondary)
                } else if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.orange)
                }
                if !isSelectingLayers {
                    dragHandle
                        .simultaneousGesture(layerDragGesture(layer.id))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSelectingLayers {
                    if selectedForGrouping {
                        selectedLayerIDs.remove(layer.id)
                    } else {
                        selectedLayerIDs.insert(layer.id)
                    }
                    return
                }
                let wasSelected = editor.document.selectedLayerID == layer.id
                    && editor.selectedLayerGroupID == nil
                if wasSelected {
                    withAnimation(.snappy(duration: 0.18)) {
                        optionsLayerID = layer.id
                    }
                } else {
                    if editor.imageTransformMode { editor.commitTransformSelection() }
                    editor.imageTransformMode = false
                    editor.selectedLayerGroupID = nil
                    editor.document.selectedLayerID = layer.id
                    optionsLayerID = nil
                }
            }
        }
        .padding(.horizontal, 4)
        .background(
            selected ? Color.orange.opacity(0.18) : Color.white.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func layerListEntry(layer: DrawingLayer, index: Int, depth: Int) -> some View {
        let row = layerRow(index: index)
            .padding(.leading, CGFloat(depth) * 14)
            .reportLayerItemFrame(id: "layer-\(layer.id.uuidString)")
            .overlay { layerDropIndicator(for: layer.id) }
            .scaleEffect(draggedLayerID == layer.id ? 1.04 : 1)
            .opacity(draggedLayerID == layer.id ? 0.94 : 1)
            .shadow(
                color: draggedLayerID == layer.id ? .orange.opacity(0.38) : .clear,
                radius: 12,
                y: 6
            )
            .zIndex(draggedLayerID == layer.id ? 2 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.72), value: draggedLayerID)

        if isSelectingLayers {
            row
        } else {
            row
                .accessibilityHint("Touch and hold, then drag to reorder")
        }
    }

    @ViewBuilder
    private func groupRow(_ group: LayerGroup, depth: Int) -> some View {
        let members = editor.document.groupLayerIDs(group.id)
        let allSelected = !members.isEmpty && members.allSatisfy { selectedLayerIDs.contains($0) }
        let selectedForTransform = editor.selectedLayerGroupID == group.id

        let row = HStack(spacing: 4) {
            panelIconButton(
                systemName: group.isVisible ? "eye" : "eye.slash",
                tint: group.isVisible ? .white : .secondary,
                accessibilityLabel: group.isVisible ? "Hide group" : "Show group"
            ) {
                toggleGroupVisibility(group.id)
            }

            HStack(spacing: 6) {
                Image(systemName: group.isCollapsed ? "folder.fill" : "folder.fill.badge.minus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 30, height: 30)

                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(members.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.18)) {
                    if isSelectingLayers {
                        if allSelected {
                            members.forEach { selectedLayerIDs.remove($0) }
                        } else {
                            members.forEach { selectedLayerIDs.insert($0) }
                        }
                    } else {
                        if editor.imageTransformMode { editor.commitTransformSelection() }
                        editor.imageTransformMode = false
                        editor.selectedLayerGroupID = group.id
                        optionsLayerID = nil
                        editor.setGroupCollapsed(group.id, isCollapsed: !group.isCollapsed)
                    }
                }
            }

            if isSelectingLayers {
                Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(allSelected ? .orange : .secondary)
                    .frame(width: 44, height: 44)
            } else {
                dragHandle
                    .simultaneousGesture(groupDragGesture(group.id))

                Menu {
                    Button("Rename", systemImage: "pencil") {
                        beginGroupRename(group)
                    }
                    Button("Ungroup", systemImage: "folder.badge.minus") {
                        ungroup(group.id)
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        deleteGroup(group.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Group actions")

            }
        }
        .padding(.horizontal, 4)
        .reportLayerItemFrame(id: "group-\(group.id.uuidString)")
        .background(
            Color.orange.opacity(dropTargetGroupID == group.id ? 0.34 : (selectedForTransform ? 0.24 : 0.1)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            if dropBoundaryGroupID == group.id {
                VStack(spacing: 0) {
                    if !dropBoundaryAfter { groupBoundaryIndicator.offset(y: -5) }
                    Spacer(minLength: 0)
                    if dropBoundaryAfter { groupBoundaryIndicator.offset(y: 5) }
                }
                .padding(.horizontal, 4)
                .allowsHitTesting(false)
            } else if selectedForTransform {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.orange.opacity(0.8), lineWidth: 1)
            } else if dropTargetGroupID == group.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.orange.opacity(0.7), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(draggedGroupID == group.id ? 1.04 : 1)
        .opacity(draggedGroupID == group.id ? 0.94 : 1)
        .shadow(
            color: draggedGroupID == group.id ? .orange.opacity(0.38) : .clear,
            radius: 12,
            y: 6
        )
        .zIndex(draggedGroupID == group.id ? 2 : 0)
        .animation(.spring(response: 0.24, dampingFraction: 0.72), value: draggedGroupID)

        if isSelectingLayers {
            row
                .padding(.leading, CGFloat(depth) * 14)
        } else {
            row
                .padding(.leading, CGFloat(depth) * 14)
        }
    }

    private var ungroupDropZone: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.badge.minus")
            Text("Drop here to remove from folder")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            dropTargetUngroup ? Color.orange.opacity(0.24) : Color.black.opacity(0.13),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(dropTargetUngroup ? Color.orange : Color.white.opacity(0.1), lineWidth: dropTargetUngroup ? 1.5 : 1)
        }
        .reportLayerItemFrame(id: "ungroup")
    }

    private func layerActions(index: Int, layer: DrawingLayer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if layer.imageData != nil {
                layerAction("Transform Image", icon: "arrow.up.left.and.arrow.down.right") {
                    optionsLayerID = nil
                    editor.selectedLayerGroupID = nil
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

    /// Icon button whose tappable hit area (44x44) is larger than the thin
    /// icon glyph itself, so it is easy to hit without a background box.
    private func panelIconButton(
        systemName: String,
        tint: Color = .white,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Reorder")
    }

    private var backgroundRow: some View {
        HStack(spacing: 10) {
            panelIconButton(
                systemName: editor.document.resolvedBackgroundVisible ? "eye" : "eye.slash",
                tint: editor.document.resolvedBackgroundVisible ? .white : .secondary,
                accessibilityLabel: editor.document.resolvedBackgroundVisible ? "Hide Background" : "Show Background"
            ) {
                editor.commit { document in
                    document.backgroundVisible = !document.resolvedBackgroundVisible
                }
            }

            Button {
                editor.beginBackgroundColorChange()
                showsBackgroundColorPicker = true
            } label: {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(editor.document.background.swiftUIColor)
                        .frame(width: 38, height: 38)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(.white.opacity(0.3), lineWidth: 1)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background Color")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Text(editor.document.resolvedBackgroundVisible ? "Visible" : "Transparent")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change Background Color")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.1))
        .popover(isPresented: $showsBackgroundColorPicker, arrowEdge: .trailing) {
            DirectColorPicker(color: Binding(
                get: { editor.document.background },
                set: { editor.updateBackgroundColor($0) }
            ))
            .frame(width: 340, height: 390)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var footer: some View {
        Group {
            if isSelectingLayers {
                HStack(spacing: 10) {
                    Button("Cancel") {
                        withAnimation(.snappy(duration: 0.18)) {
                            isSelectingLayers = false
                            selectedLayerIDs.removeAll()
                        }
                    }
                    .buttonStyle(.borderless)

                    Spacer()
                    Text("\(selectedLayerIDs.count) selected")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        groupSelectedLayers()
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(selectedLayerIDs.count < 2)
                    .accessibilityLabel("Group selected layers")
                }
            } else {
                HStack(spacing: 0) {
                    sidebarButton("New Layer", icon: "square.stack.3d.up") {
                        addLayer()
                    }
                    sidebarButton("New Folder", icon: "folder.badge.plus") {
                        addFolder()
                    }

                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Import from Photos")

                    sidebarButton("Import File", icon: "folder") { importsFile = true }
                    sidebarButton("Duplicate", icon: "plus.square.on.square") {
                        duplicateSelected(index: editor.document.selectedLayerIndex)
                    }
                    .disabled(editor.selectedLayerGroupID != nil)
                    sidebarButton("Delete", icon: "trash", role: .destructive) {
                        if let groupID = editor.selectedLayerGroupID {
                            deleteGroup(groupID)
                        } else {
                            deleteSelected(index: editor.document.selectedLayerIndex)
                        }
                    }
                    .disabled(editor.selectedLayerGroupID == nil && editor.document.layers.count <= 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func sidebarButton(
        _ title: String,
        icon: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
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

    private func beginGroupRename(_ group: LayerGroup) {
        renamingGroupID = group.id
        renameText = group.name
        showsGroupRename = true
    }

    private func applyGroupRename() {
        guard let renamingGroupID else { return }
        let cleanName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        editor.commit { document in
            guard let index = document.layerGroups?.firstIndex(where: { $0.id == renamingGroupID }) else { return }
            document.layerGroups?[index].name = cleanName.isEmpty ? "Group" : cleanName
        }
    }

    private func addLayer() {
        editor.commit { document in
            let selectedGroupID = editor.selectedLayerGroupID
                ?? document.layers[document.selectedLayerIndex].groupID
            var layer = DrawingLayer(name: "Layer \(document.layers.count + 1)")
            layer.groupID = selectedGroupID
            let insertionIndex = min(document.layers.count, document.selectedLayerIndex + 1)
            document.layers.insert(layer, at: insertionIndex)
            document.selectedLayerID = layer.id
        }
        editor.selectedLayerGroupID = nil
    }

    private func addFolder() {
        var newGroupID: UUID?
        let parentID = editor.selectedLayerGroupID
        editor.commit { document in
            let group = LayerGroup(name: "Group \((document.layerGroups?.count ?? 0) + 1)")
            var newGroup = group
            newGroup.parentGroupID = parentID
            var groups = document.layerGroups ?? []
            groups.append(newGroup)
            document.layerGroups = groups
            newGroupID = newGroup.id
        }
        editor.selectedLayerGroupID = newGroupID
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
            document.layers[index].contentScale = nil
            document.layers[index].contentOffsetX = nil
            document.layers[index].contentOffsetY = nil
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

    private func groupSelectedLayers() {
        let selectedIDs = selectedLayerIDs
        guard selectedIDs.count >= 2 else { return }
        var createdGroupID: UUID?

        editor.commit { document in
            let selectedEntries = document.layers.enumerated().filter { selectedIDs.contains($0.element.id) }
            guard selectedEntries.count >= 2, let insertionIndex = selectedEntries.map(\.offset).min() else { return }

            let group = LayerGroup(name: "Group \((document.layerGroups?.count ?? 0) + 1)")
            var groupedLayers = selectedEntries.map(\.element)
            for index in groupedLayers.indices { groupedLayers[index].groupID = group.id }

            document.layers.removeAll { selectedIDs.contains($0.id) }
            document.layers.insert(contentsOf: groupedLayers, at: min(insertionIndex, document.layers.count))
            var groups = document.layerGroups ?? []
            groups.append(group)
            document.layerGroups = groups
            createdGroupID = group.id
        }
        editor.selectedLayerGroupID = createdGroupID

        withAnimation(.snappy(duration: 0.2)) {
            isSelectingLayers = false
            selectedLayerIDs.removeAll()
        }
    }

    private func toggleGroupVisibility(_ groupID: UUID) {
        editor.commit { document in
            guard let index = document.layerGroups?.firstIndex(where: { $0.id == groupID }) else { return }
            document.layerGroups?[index].isVisible.toggle()
        }
    }

    private func ungroup(_ groupID: UUID) {
        if editor.imageTransformMode, editor.selectedLayerGroupID == groupID {
            editor.commitTransformSelection()
            editor.imageTransformMode = false
        }
        editor.ungroupGroup(groupID)
        if editor.selectedLayerGroupID == groupID { editor.selectedLayerGroupID = nil }
    }

    private func deleteGroup(_ groupID: UUID) {
        if editor.imageTransformMode, editor.selectedLayerGroupID == groupID {
            editor.commitTransformSelection()
            editor.imageTransformMode = false
        }
        editor.deleteGroup(groupID)
        if let selectedGroupID = editor.selectedLayerGroupID,
           editor.document.layerGroups?.contains(where: { $0.id == selectedGroupID }) != true {
            editor.selectedLayerGroupID = nil
        }
    }

    private func beginLayerDrag(_ layerID: UUID) {
        guard draggedLayerID == nil, draggedGroupID == nil else { return }
        editor.beginLayerReorder()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
            draggedLayerID = layerID
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func beginGroupDrag(_ groupID: UUID) {
        guard draggedLayerID == nil, draggedGroupID == nil else { return }
        editor.beginLayerReorder()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.7)) {
            draggedGroupID = groupID
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func layerDragGesture(_ layerID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.18, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("layersPanel")))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginLayerDrag(layerID)
                case .second(true, let drag?):
                    beginLayerDrag(layerID)
                    updateDragTarget(at: drag.location)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    updateDragTarget(at: drag.location)
                    finishDrag()
                } else {
                    cancelNativeDrag()
                }
            }
    }

    private func groupDragGesture(_ groupID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.18, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("layersPanel")))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginGroupDrag(groupID)
                case .second(true, let drag?):
                    beginGroupDrag(groupID)
                    updateDragTarget(at: drag.location)
                default:
                    break
                }
            }
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    updateDragTarget(at: drag.location)
                    finishDrag()
                } else {
                    cancelNativeDrag()
                }
            }
    }

    private func updateDragTarget(at location: CGPoint) {
        if itemFrames["ungroup"]?.contains(location) == true {
            setDropTarget(layerID: nil, after: false, groupID: nil, boundaryGroupID: nil, boundaryAfter: false, ungroup: true)
            return
        }

        let excludedGroupIDs: Set<UUID> = draggedGroupID.map {
            editor.document.descendantGroupIDs(of: $0).union([$0])
        } ?? []
        let candidates = layerListItems.compactMap { item -> (LayerListItem, CGRect)? in
            switch item {
            case .layer(let layer, _):
                guard layer.id != draggedLayerID,
                      draggedGroupID.map({ !editor.document.groupLayerIDs($0).contains(layer.id) }) ?? true,
                      let frame = itemFrames[item.id] else { return nil }
                return (item, frame)
            case .group(let group, _):
                guard !excludedGroupIDs.contains(group.id),
                      let frame = itemFrames[item.id] else { return nil }
                return (item, frame)
            }
        }
        let visibleFrames = candidates.map(\.1)
        if let minY = visibleFrames.map(\.minY).min(),
           let maxY = visibleFrames.map(\.maxY).max(),
           (location.y < minY - 20 || location.y > maxY + 20 || location.x < -20 || location.x > 320) {
            clearDropTargets()
            return
        }
        guard let target = candidates.min(by: {
            abs($0.1.midY - location.y) < abs($1.1.midY - location.y)
        }) else {
            clearDropTargets()
            return
        }

        switch target.0 {
        case .layer(let layer, _):
            setDropTarget(
                layerID: layer.id,
                after: location.y > target.1.midY,
                groupID: nil,
                boundaryGroupID: nil,
                boundaryAfter: false,
                ungroup: false
            )
        case .group(let group, _):
            let edgeBand = min(14, target.1.height * 0.25)
            if location.y < target.1.minY + edgeBand || location.y > target.1.maxY - edgeBand {
                setDropTarget(
                    layerID: nil,
                    after: false,
                    groupID: nil,
                    boundaryGroupID: group.id,
                    boundaryAfter: location.y > target.1.midY,
                    ungroup: false
                )
            } else {
                setDropTarget(layerID: nil, after: false, groupID: group.id, boundaryGroupID: nil, boundaryAfter: false, ungroup: false)
            }
        }
    }

    private func setDropTarget(
        layerID: UUID?,
        after: Bool,
        groupID: UUID?,
        boundaryGroupID: UUID?,
        boundaryAfter: Bool,
        ungroup: Bool
    ) {
        let changed = dropTargetLayerID != layerID
            || dropTargetAfter != after
            || dropTargetGroupID != groupID
            || dropBoundaryGroupID != boundaryGroupID
            || dropBoundaryAfter != boundaryAfter
            || dropTargetUngroup != ungroup
        guard changed else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            dropTargetLayerID = layerID
            dropTargetAfter = after
            dropTargetGroupID = groupID
            dropBoundaryGroupID = boundaryGroupID
            dropBoundaryAfter = boundaryAfter
            dropTargetUngroup = ungroup
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func clearDropTargets() {
        dropTargetLayerID = nil
        dropTargetGroupID = nil
        dropBoundaryGroupID = nil
        dropTargetUngroup = false
        dropTargetAfter = false
        dropBoundaryAfter = false
    }

    private func finishDrag() {
        guard let sourceID = draggedLayerID ?? draggedGroupID else { return }
        if dropTargetUngroup {
            completeUngroupDrop(sourceID)
        } else if let groupID = dropTargetGroupID {
            if draggedGroupID != nil {
                completeGroupNestGroupDrop(sourceID, groupID)
            } else {
                completeGroupDrop(sourceID, groupID)
            }
        } else if let groupID = dropBoundaryGroupID {
            if draggedGroupID != nil {
                completeGroupBoundaryDrop(sourceID, groupID, dropBoundaryAfter)
            } else {
                completeLayerBoundaryDrop(sourceID, groupID, dropBoundaryAfter)
            }
        } else if let layerID = dropTargetLayerID {
            if draggedGroupID != nil {
                completeGroupLayerDrop(sourceID, layerID, dropTargetAfter)
            } else {
                completeNativeLayerDrop(sourceID, layerID, dropTargetAfter)
            }
        } else {
            cancelNativeDrag()
        }
    }

    private func resetDragState() {
        draggedLayerID = nil
        draggedGroupID = nil
        dropTargetLayerID = nil
        dropTargetGroupID = nil
        dropBoundaryGroupID = nil
        dropTargetUngroup = false
        dropTargetAfter = false
        dropBoundaryAfter = false
    }

    private func cancelNativeDrag() {
        guard draggedLayerID != nil || draggedGroupID != nil else { return }
        editor.cancelLayerReorder()
        resetDragState()
    }

    private func completeNativeLayerDrop(_ layerID: UUID, _ targetLayerID: UUID, _ placeAfter: Bool) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            editor.moveLayer(layerID, relativeTo: targetLayerID, placeAfter: placeAfter)
            editor.endLayerReorder()
            resetDragState()
        }
    }

    private func completeGroupLayerDrop(_ groupID: UUID, _ targetLayerID: UUID, _ placeAfter: Bool) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            editor.moveGroup(groupID, relativeTo: targetLayerID, placeAfter: placeAfter)
            editor.endLayerReorder()
            resetDragState()
        }
    }

    private func completeLayerBoundaryDrop(_ layerID: UUID, _ groupID: UUID, _ placeAfter: Bool) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            editor.moveLayer(layerID, relativeToGroup: groupID, placeAfter: placeAfter)
            editor.endLayerReorder()
            resetDragState()
        }
    }

    private func completeGroupBoundaryDrop(_ groupID: UUID, _ targetGroupID: UUID, _ placeAfter: Bool) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            editor.moveGroup(groupID, relativeToGroup: targetGroupID, placeAfter: placeAfter)
            editor.endLayerReorder()
            resetDragState()
        }
    }

    private func completeGroupDrop(_ layerID: UUID, _ groupID: UUID) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            editor.moveLayer(layerID, toGroup: groupID)
            editor.endLayerReorder()
            resetDragState()
        }
    }

    private func completeGroupNestGroupDrop(_ groupID: UUID, _ targetGroupID: UUID) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            // Dropping a group onto another folder's badge nests it inside.
            editor.moveGroup(groupID, intoGroup: targetGroupID)
            editor.endLayerReorder()
            resetDragState()
        }
    }

    private func completeUngroupDrop(_ id: UUID) {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
            if draggedGroupID == id {
                editor.moveGroup(id, intoGroup: nil)
            } else {
                editor.moveLayer(id, toGroup: nil)
            }
            editor.endLayerReorder()
            resetDragState()
        }
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

    private var groupBoundaryIndicator: some View {
        Capsule()
            .fill(.orange)
            .frame(height: 3)
            .shadow(color: .orange.opacity(0.65), radius: 4)
    }
}

private enum LayerListItem: Identifiable {
    case group(LayerGroup, depth: Int)
    case layer(DrawingLayer, depth: Int)

    var id: String {
        switch self {
        case .group(let group, _): "group-\(group.id.uuidString)"
        case .layer(let layer, _): "layer-\(layer.id.uuidString)"
        }
    }
}

private struct LayerItemFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func reportLayerItemFrame(id: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LayerItemFramesKey.self,
                    value: [id: proxy.frame(in: .named("layersPanel"))]
                )
            }
        }
    }
}

private struct LayerMiniMap: View {
    let layer: DrawingLayer
    let canvasSize: CGSize
    var thumbnailSize: CGFloat = 46
    @State private var importedImage: UIImage?

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
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
            let previewCenter = CGPoint(x: origin.x + drawingSize.width / 2, y: origin.y + drawingSize.height / 2)
            let previewOffset = layer.resolvedContentOffset
            var contentTransform = CGAffineTransform.identity
            contentTransform = contentTransform.translatedBy(
                x: previewCenter.x + previewOffset.x * scale,
                y: previewCenter.y + previewOffset.y * scale
            )
            contentTransform = contentTransform.scaledBy(
                x: layer.resolvedContentScale,
                y: layer.resolvedContentScale
            )
            contentTransform = contentTransform.translatedBy(x: -previewCenter.x, y: -previewCenter.y)
            context.concatenate(contentTransform)

            if let image = importedImage {
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
        .frame(width: thumbnailSize, height: thumbnailSize)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .onAppear {
            importedImage = Self.decodeMiniMapImage(layer.imageData)
        }
        .onChange(of: layer.imageData) { _, data in
            importedImage = Self.decodeMiniMapImage(data)
        }
    }

    private static func decodeMiniMapImage(_ data: Data?) -> UIImage? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
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
