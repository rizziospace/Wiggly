import Combine
import Foundation
import os
import SwiftUI
import UIKit

enum BrushColorSlot: String, CaseIterable, Hashable {
    case primary
    case secondary
    case tertiary
    case quaternary
    case quinary
}

@MainActor
final class EditorModel: ObservableObject {
    private enum HistoryEntry {
        case snapshot(WiggleDocument)
        case addedStroke(layerID: UUID, stroke: AnimatedStroke)
        case removedStroke(layerID: UUID, stroke: AnimatedStroke, index: Int)
    }

    @Published var document: WiggleDocument
    @Published var selectedBrush: BrushSettings {
        didSet { reconcileActiveColorSlot() }
    }
    @Published private(set) var activeColorSlot: BrushColorSlot = .primary
    @Published var inputPolicy: CanvasInputPolicy = .pencilOnly
    @Published var selectionMode = false
    @Published var eraserMode = false
    @Published var imageTransformMode = false
    @Published var isAnimationPlaying = true
    @Published var isStrokeAnimationRandomized = false
    @Published var selectedStrokeID: UUID?
    @Published var selectedLayerGroupID: UUID?

    private var undoStack: [HistoryEntry] = []
    private var activeImageTransformGestures = 0
    private var isChangingBackgroundColor = false
    private var isChangingLayerOpacity = false
    private var isReorderingLayers = false
    private var layerReorderSnapshot: WiggleDocument?
    private var redoStack: [HistoryEntry] = []
    private var strokeBounds: [UUID: CGRect] = [:]
    private var rememberedColorSlotByBrushID: [UUID: BrushColorSlot] = [:]
    private var activeColorPick: ColorPickSession?
    private let performanceLog = OSLog(subsystem: "com.wiggly.canvas", category: "DocumentPerformance")
    var onAutosave: ((WiggleDocument) -> Void)?

    private struct ColorPickSession {
        var brushID: UUID
        var slot: BrushColorSlot
        var originalColor: CodableColor
        var didPreviewColor = false
    }

    init(document: WiggleDocument, selectedBrush: BrushSettings? = nil) {
        var cleanedDocument = document
        for layerIndex in cleanedDocument.layers.indices {
            cleanedDocument.layers[layerIndex].fills?.removeAll { fill in
                fill.maskData != nil || fill.animatedMaskFrames != nil || fill.animatedContours != nil
            }
        }
        self.document = cleanedDocument
        let requestedBrush = selectedBrush ?? .preset(.dashed)
        self.selectedBrush = requestedBrush.kind.isAvailableInCatalog
            ? requestedBrush
            : .preset(.dashed)
        rememberedColorSlotByBrushID[self.selectedBrush.id] = .primary
        rebuildStrokeBounds()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var availableColorSlots: [BrushColorSlot] {
        switch selectedBrush.kind {
        case .star:
            return [.primary, .tertiary, .secondary]
        case .checker:
            return [.primary, .secondary, .tertiary, .quaternary]
        case .retro:
            let all: [BrushColorSlot] = [.primary, .secondary, .tertiary, .quaternary, .quinary]
            return Array(all.prefix(selectedBrush.resolvedTrippyColorCount))
        case .faded:
            return [.primary, .secondary]
        case .solidColor:
            return selectedBrush.resolvedColoringUsesGradient ? [.primary, .secondary] : [.primary]
        case .scribbles, .particleCloud, .dryOutline, .goo:
            return [.primary]
        default:
            return [.primary, .secondary]
        }
    }

    func selectColorSlot(_ slot: BrushColorSlot) {
        let safeSlot = availableColorSlots.contains(slot)
            ? slot
            : (availableColorSlots.first ?? .primary)
        activeColorSlot = safeSlot
        rememberedColorSlotByBrushID[selectedBrush.id] = safeSlot
    }

    func selectedBrushColor(for slot: BrushColorSlot) -> CodableColor {
        switch slot {
        case .primary:
            return selectedBrush.color
        case .secondary:
            return selectedBrush.kind == .faded
                ? selectedBrush.resolvedFadedBaseColor
                : selectedBrush.resolvedDashBackgroundColor
        case .tertiary:
            return selectedBrush.resolvedTertiaryColor
        case .quaternary:
            return selectedBrush.resolvedQuaternaryColor
        case .quinary:
            return selectedBrush.resolvedQuinaryColor
        }
    }

    func setSelectedBrushColor(_ color: CodableColor, for slot: BrushColorSlot) {
        guard availableColorSlots.contains(slot) else { return }
        switch slot {
        case .primary:
            selectedBrush.color = color
        case .secondary:
            selectedBrush.secondaryColor = color
            if selectedBrush.kind == .faded, selectedBrush.fadedBaseOpacity == nil {
                selectedBrush.fadedBaseOpacity = 1
            }
        case .tertiary:
            selectedBrush.tertiaryColor = color
        case .quaternary:
            selectedBrush.quaternaryColor = color
        case .quinary:
            selectedBrush.quinaryColor = color
        }
    }

    func beginCanvasColorPick() {
        reconcileActiveColorSlot()
        let slot = activeColorSlot
        activeColorPick = ColorPickSession(
            brushID: selectedBrush.id,
            slot: slot,
            originalColor: selectedBrushColor(for: slot)
        )
    }

    func previewCanvasColor(_ color: CodableColor) {
        guard var session = activeColorPick,
              session.brushID == selectedBrush.id,
              availableColorSlots.contains(session.slot) else { return }
        setSelectedBrushColor(color, for: session.slot)
        session.didPreviewColor = true
        activeColorPick = session
    }

    @discardableResult
    func finishCanvasColorPick(commit: Bool) -> Bool {
        guard let session = activeColorPick else { return false }
        activeColorPick = nil
        guard session.brushID == selectedBrush.id,
              availableColorSlots.contains(session.slot) else { return false }
        if !commit {
            setSelectedBrushColor(session.originalColor, for: session.slot)
            return false
        }
        return session.didPreviewColor
    }

    private func reconcileActiveColorSlot() {
        let slots = availableColorSlots
        let remembered = rememberedColorSlotByBrushID[selectedBrush.id]
        let safeSlot = remembered.flatMap { slots.contains($0) ? $0 : nil }
            ?? slots.first
            ?? .primary
        if activeColorSlot != safeSlot {
            activeColorSlot = safeSlot
        }
        rememberedColorSlotByBrushID[selectedBrush.id] = safeSlot
    }

    func checkpoint() {
        undoStack.append(.snapshot(document))
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func commit(_ edit: (inout WiggleDocument) -> Void) {
        let signpost = OSSignpostID(log: performanceLog)
        let strokeCount = document.layers.reduce(0) { $0 + $1.strokes.count }
        os_signpost(
            .begin,
            log: performanceLog,
            name: "Document Commit",
            signpostID: signpost,
            "strokes=%{public}d",
            strokeCount
        )
        defer { os_signpost(.end, log: performanceLog, name: "Document Commit", signpostID: signpost) }
        checkpoint()
        edit(&document)
        document.modifiedAt = Date()
        onAutosave?(document)
    }

    func beginLayerOpacityChange() {
        guard !isChangingLayerOpacity else { return }
        checkpoint()
        isChangingLayerOpacity = true
    }

    func beginBackgroundColorChange() {
        guard !isChangingBackgroundColor else { return }
        checkpoint()
        isChangingBackgroundColor = true
    }

    func updateBackgroundColor(_ color: CodableColor) {
        guard isChangingBackgroundColor else { return }
        document.background = color
        document.modifiedAt = Date()
    }

    func endBackgroundColorChange() {
        guard isChangingBackgroundColor else { return }
        isChangingBackgroundColor = false
        document.modifiedAt = Date()
        onAutosave?(document)
    }

    func updateSelectedLayerOpacity(_ opacity: Double) {
        let index = document.selectedLayerIndex
        guard document.layers.indices.contains(index) else { return }
        var updated = document
        updated.layers[index].opacity = min(1, max(0, opacity))
        updated.modifiedAt = Date()
        document = updated
    }

    func endLayerOpacityChange() {
        guard isChangingLayerOpacity else { return }
        isChangingLayerOpacity = false
        document.modifiedAt = Date()
        onAutosave?(document)
    }

    func beginLayerReorder() {
        guard !isReorderingLayers else { return }
        layerReorderSnapshot = document
        isReorderingLayers = true
    }

    func moveLayer(_ draggedID: UUID, relativeTo targetID: UUID, placeAfter: Bool) {
        guard isReorderingLayers, draggedID != targetID else { return }
        var displayed = Array(document.layers.reversed())
        guard let sourceIndex = displayed.firstIndex(where: { $0.id == draggedID }) else { return }
        var moved = displayed.remove(at: sourceIndex)
        guard let targetIndex = displayed.firstIndex(where: { $0.id == targetID }) else { return }
        moved.groupID = displayed[targetIndex].groupID
        displayed.insert(moved, at: targetIndex + (placeAfter ? 1 : 0))
        let reorderedLayers = Array(displayed.reversed())
        guard reorderedLayers.map(\.id) != document.layers.map(\.id) else { return }
        var updated = document
        updated.layers = reorderedLayers
        updated.modifiedAt = Date()
        document = updated
    }

    func moveLayer(_ draggedID: UUID, toGroup groupID: UUID?) {
        guard isReorderingLayers else { return }
        var layers = document.layers
        guard let sourceIndex = layers.firstIndex(where: { $0.id == draggedID }) else { return }
        var moved = layers.remove(at: sourceIndex)
        guard moved.groupID != groupID else { return }
        moved.groupID = groupID
        if let groupID {
            let lastMemberIndex = layers.lastIndex(where: { $0.groupID == groupID })
            layers.insert(moved, at: min(layers.count, (lastMemberIndex ?? layers.count - 1) + 1))
        } else {
            layers.insert(moved, at: 0)
        }
        var updated = document
        updated.layers = layers
        updated.modifiedAt = Date()
        document = updated
    }

    func moveLayer(_ draggedID: UUID, relativeToGroup targetGroupID: UUID, placeAfter: Bool) {
        guard isReorderingLayers,
              let targetGroup = document.layerGroups?.first(where: { $0.id == targetGroupID }) else { return }
        var displayed = Array(document.layers.reversed())
        guard let sourceIndex = displayed.firstIndex(where: { $0.id == draggedID }) else { return }
        var moved = displayed.remove(at: sourceIndex)
        let targetMemberIDs = Set(document.groupLayerIDs(targetGroupID)).subtracting([draggedID])
        let targetIndices = displayed.indices.filter { targetMemberIDs.contains(displayed[$0].id) }
        let insertionIndex: Int
        if let first = targetIndices.first, let last = targetIndices.last {
            insertionIndex = placeAfter ? last + 1 : first
        } else {
            insertionIndex = 0
        }
        moved.groupID = targetGroup.parentGroupID
        displayed.insert(moved, at: min(insertionIndex, displayed.count))
        let reorderedLayers = Array(displayed.reversed())
        guard reorderedLayers != document.layers else { return }
        var updated = document
        updated.layers = reorderedLayers
        updated.modifiedAt = Date()
        document = updated
    }

    func moveGroup(_ groupID: UUID, relativeTo targetID: UUID, placeAfter: Bool) {
        guard isReorderingLayers, groupID != targetID else { return }
        guard let targetLayer = document.layers.first(where: { $0.id == targetID }) else { return }
        // A folder cannot be moved beside a layer in one of its own descendants.
        if let targetGroupID = targetLayer.groupID,
           document.group(groupID, contains: targetGroupID) { return }
        var displayed = Array(document.layers.reversed())
        // A folder move carries its entire nested subtree as one block.
        let memberIDs = Set(document.groupLayerIDs(groupID))
        guard !memberIDs.isEmpty else { return }
        let members = displayed.filter { memberIDs.contains($0.id) }
        displayed.removeAll { memberIDs.contains($0.id) }
        guard let targetIndex = displayed.firstIndex(where: { $0.id == targetID }) else { return }
        displayed.insert(contentsOf: members, at: min(targetIndex + (placeAfter ? 1 : 0), displayed.count))
        let reorderedLayers = Array(displayed.reversed())
        let currentParentID = document.layerGroups?.first(where: { $0.id == groupID })?.parentGroupID
        guard reorderedLayers.map(\.id) != document.layers.map(\.id)
                || currentParentID != targetLayer.groupID else { return }
        var updated = document
        updated.layers = reorderedLayers
        if let groupIndex = updated.layerGroups?.firstIndex(where: { $0.id == groupID }) {
            updated.layerGroups?[groupIndex].parentGroupID = targetLayer.groupID
        }
        updated.modifiedAt = Date()
        document = updated
    }

    /// Nests a folder inside another folder (or moves it back to the root when
    /// `targetGroupID` is nil). Refuses cycles: a folder can never be nested
    /// inside itself or its own subtree.
    func moveGroup(_ groupID: UUID, intoGroup targetGroupID: UUID?) {
        guard isReorderingLayers, groupID != targetGroupID else { return }
        if let targetGroupID, document.group(groupID, contains: targetGroupID) { return }
        guard var groups = document.layerGroups else { return }
        guard let sourceIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[sourceIndex].parentGroupID = targetGroupID
        var updated = document
        updated.layerGroups = groups
        updated.modifiedAt = Date()
        document = updated
    }

    func moveGroup(_ groupID: UUID, relativeToGroup targetGroupID: UUID, placeAfter: Bool) {
        guard isReorderingLayers,
              groupID != targetGroupID,
              !document.group(groupID, contains: targetGroupID),
              var groups = document.layerGroups,
              let sourceGroupIndex = groups.firstIndex(where: { $0.id == groupID }),
              let targetGroup = groups.first(where: { $0.id == targetGroupID }) else { return }

        groups[sourceGroupIndex].parentGroupID = targetGroup.parentGroupID
        if let movedGroupIndex = groups.firstIndex(where: { $0.id == groupID }) {
            let movedGroup = groups.remove(at: movedGroupIndex)
            if let targetIndex = groups.firstIndex(where: { $0.id == targetGroupID }) {
                groups.insert(movedGroup, at: min(targetIndex + (placeAfter ? 1 : 0), groups.count))
            }
        }

        var displayed = Array(document.layers.reversed())
        let sourceMemberIDs = Set(document.groupLayerIDs(groupID))
        let movedLayers = displayed.filter { sourceMemberIDs.contains($0.id) }
        displayed.removeAll { sourceMemberIDs.contains($0.id) }
        let targetMemberIDs = Set(document.groupLayerIDs(targetGroupID))
        let targetIndices = displayed.indices.filter { targetMemberIDs.contains(displayed[$0].id) }
        if !movedLayers.isEmpty {
            if let first = targetIndices.first, let last = targetIndices.last {
                let insertionIndex = placeAfter ? last + 1 : first
                displayed.insert(contentsOf: movedLayers, at: min(insertionIndex, displayed.count))
            } else {
                displayed.insert(contentsOf: movedLayers, at: 0)
            }
        }

        var updated = document
        updated.layers = Array(displayed.reversed())
        updated.layerGroups = groups
        guard updated.layers != document.layers || updated.layerGroups != document.layerGroups else { return }
        updated.modifiedAt = Date()
        document = updated
    }

    /// Removes a folder, promoting its direct child layers and sub-folders up to
    /// the folder's own parent (or the root when the folder was top-level).
    func ungroupGroup(_ groupID: UUID) {
        commit { document in
            guard var groups = document.layerGroups else { return }
            let parentID = groups.first(where: { $0.id == groupID })?.parentGroupID
            for index in document.layers.indices where document.layers[index].groupID == groupID {
                document.layers[index].groupID = parentID
            }
            for index in groups.indices where groups[index].parentGroupID == groupID {
                groups[index].parentGroupID = parentID
            }
            groups.removeAll { $0.id == groupID }
            document.layerGroups = groups
        }
    }

    func moveEmptyGroup(_ groupID: UUID, relativeTo targetGroupID: UUID, placeAfter: Bool) {
        guard isReorderingLayers, var groups = document.layerGroups else { return }
        guard let sourceIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let moved = groups.remove(at: sourceIndex)
        guard let targetIndex = groups.firstIndex(where: { $0.id == targetGroupID }) else { return }
        groups.insert(moved, at: min(placeAfter ? targetIndex : targetIndex + 1, groups.count))
        var updated = document
        updated.layerGroups = groups
        updated.modifiedAt = Date()
        document = updated
    }

    func setGroupCollapsed(_ groupID: UUID, isCollapsed: Bool) {
        commit { document in
            guard let index = document.layerGroups?.firstIndex(where: { $0.id == groupID }) else { return }
            document.layerGroups?[index].isCollapsed = isCollapsed
        }
    }

    /// Deletes a folder, its nested folders, and every layer inside it.
    func deleteGroup(_ groupID: UUID) {
        commit { document in
            guard var groups = document.layerGroups else { return }
            let doomedGroups = document.descendantGroupIDs(of: groupID).union([groupID])
            let doomedLayerIDs = Set(document.groupLayerIDs(groupID))
            groups.removeAll { doomedGroups.contains($0.id) }
            document.layerGroups = groups
            document.layers.removeAll { doomedLayerIDs.contains($0.id) }
            if document.layers.isEmpty {
                let replacement = DrawingLayer(name: "Layer 1")
                document.layers = [replacement]
                document.selectedLayerID = replacement.id
            }
            if !document.layers.contains(where: { $0.id == document.selectedLayerID }) {
                document.selectedLayerID = document.layers.first?.id ?? document.selectedLayerID
            }
        }
    }

    func endLayerReorder() {
        guard isReorderingLayers else { return }
        isReorderingLayers = false
        if let snapshot = layerReorderSnapshot, snapshot != document {
            undoStack.append(.snapshot(snapshot))
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
            document.modifiedAt = Date()
            onAutosave?(document)
        }
        layerReorderSnapshot = nil
    }

    func cancelLayerReorder() {
        guard isReorderingLayers else { return }
        isReorderingLayers = false
        layerReorderSnapshot = nil
    }

    func addStroke(_ stroke: AnimatedStroke) {
        let signpost = OSSignpostID(log: performanceLog)
        let existingStrokeCount = document.layers.reduce(0) { $0 + $1.strokes.count }
        os_signpost(
            .begin,
            log: performanceLog,
            name: "Stroke Commit",
            signpostID: signpost,
            "existing=%{public}d samples=%{public}d",
            existingStrokeCount,
            stroke.samples.count
        )
        defer { os_signpost(.end, log: performanceLog, name: "Stroke Commit", signpostID: signpost) }

        let index = document.selectedLayerIndex
        guard document.layers.indices.contains(index) else { return }
        let layer = document.layers[index]
        var transformedStroke = stroke
        transformedStroke.isPreview = false
        transformedStroke.samples = stroke.samples.map {
            inverseTransformedSample($0, for: layer, document: document)
        }
        undoStack.append(.addedStroke(layerID: layer.id, stroke: transformedStroke))
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        document.layers[index].strokes.append(transformedStroke)
        strokeBounds[transformedStroke.id] = Self.bounds(of: transformedStroke)
        document.modifiedAt = Date()
        onAutosave?(document)
    }

    var selectedImageScale: Double {
        guard document.layers.indices.contains(document.selectedLayerIndex) else { return 1 }
        return document.layers[document.selectedLayerIndex].resolvedImageScale
    }

    var canTransformSelectedImage: Bool {
        document.layers.indices.contains(document.selectedLayerIndex)
            && document.layers[document.selectedLayerIndex].imageData != nil
    }

    var transformTargetLayerIDs: Set<UUID> {
        if let selectedLayerGroupID {
            return Set(document.groupLayerIDs(selectedLayerGroupID))
        }
        return [document.selectedLayerID]
    }

    var canTransformSelection: Bool {
        !transformTargetLayerIDs.isEmpty
    }

    var transformTargetTitle: String {
        if let selectedLayerGroupID,
           let group = document.layerGroups?.first(where: { $0.id == selectedLayerGroupID }) {
            return group.name
        }
        return document.layers[document.selectedLayerIndex].name
    }

    func beginImageTransformGesture() {
        guard canTransformSelection else { return }
        if activeImageTransformGestures == 0 { checkpoint() }
        activeImageTransformGestures += 1
    }

    func updateSelectedImageTransform(scaleDelta: Double = 1, translation: CGPoint = .zero) {
        guard canTransformSelection else { return }
        let targetIDs = transformTargetLayerIDs
        var updated = document
        for index in updated.layers.indices where targetIDs.contains(updated.layers[index].id) {
            let layer = updated.layers[index]
            let appliedScale = min(16, max(0.05, layer.resolvedContentScale * scaleDelta))
            let effectiveDelta = appliedScale / layer.resolvedContentScale
            updated.layers[index].contentScale = appliedScale
            updated.layers[index].contentOffsetX = Double(layer.resolvedContentOffset.x) * effectiveDelta + translation.x
            updated.layers[index].contentOffsetY = Double(layer.resolvedContentOffset.y) * effectiveDelta + translation.y
        }
        updated.modifiedAt = Date()
        document = updated
    }

    func endImageTransformGesture() {
        guard activeImageTransformGestures > 0 else { return }
        activeImageTransformGestures -= 1
        guard activeImageTransformGestures == 0 else { return }
        document.modifiedAt = Date()
        onAutosave?(document)
    }

    func changeSelectedImageScale(by multiplier: Double) {
        guard canTransformSelectedImage else { return }
        commit { document in
            let index = document.selectedLayerIndex
            document.layers[index].imageScale = min(
                8,
                max(0.1, document.layers[index].resolvedImageScale * multiplier)
            )
        }
    }

    func changeTransformScale(by multiplier: Double) {
        guard canTransformSelection else { return }
        beginImageTransformGesture()
        updateSelectedImageTransform(scaleDelta: multiplier)
        endImageTransformGesture()
    }

    func resetTransformSelection() {
        let targetIDs = transformTargetLayerIDs
        guard !targetIDs.isEmpty else { return }
        commit { document in
            for index in document.layers.indices where targetIDs.contains(document.layers[index].id) {
                document.layers[index].contentScale = nil
                document.layers[index].contentOffsetX = nil
                document.layers[index].contentOffsetY = nil
            }
        }
    }

    func commitTransformSelection() {
        let targetIDs = transformTargetLayerIDs
        guard !targetIDs.isEmpty else { return }
        var updated = document
        var changed = false

        for layerIndex in updated.layers.indices where targetIDs.contains(updated.layers[layerIndex].id) {
            let layer = updated.layers[layerIndex]
            let scale = layer.resolvedContentScale
            let offset = layer.resolvedContentOffset
            guard scale != 1 || offset != .zero else { continue }
            changed = true

            for strokeIndex in updated.layers[layerIndex].strokes.indices {
                updated.layers[layerIndex].strokes[strokeIndex].samples = updated.layers[layerIndex]
                    .strokes[strokeIndex].samples.map {
                        transformedSample($0, scale: scale, offset: offset, document: updated)
                    }
                updated.layers[layerIndex].strokes[strokeIndex].brush.size *= scale
            }

            if updated.layers[layerIndex].fills != nil {
                for fillIndex in updated.layers[layerIndex].fills!.indices {
                    updated.layers[layerIndex].fills![fillIndex].samples = updated.layers[layerIndex]
                        .fills![fillIndex].samples.map {
                            transformedSample($0, scale: scale, offset: offset, document: updated)
                        }
                    if let contours = updated.layers[layerIndex].fills![fillIndex].animatedContours {
                        updated.layers[layerIndex].fills![fillIndex].animatedContours = contours.map { contour in
                            contour.map { transformedSample($0, scale: scale, offset: offset, document: updated) }
                        }
                    }
                }
            }

            if layer.imageData != nil {
                updated.layers[layerIndex].imageScale = layer.resolvedImageScale * scale
                updated.layers[layerIndex].imageOffsetX = Double(layer.resolvedImageOffset.x) * scale + offset.x
                updated.layers[layerIndex].imageOffsetY = Double(layer.resolvedImageOffset.y) * scale + offset.y
            }

            updated.layers[layerIndex].contentScale = nil
            updated.layers[layerIndex].contentOffsetX = nil
            updated.layers[layerIndex].contentOffsetY = nil
        }

        guard changed else { return }
        updated.modifiedAt = Date()
        document = updated
        rebuildStrokeBounds()
        onAutosave?(document)
    }

    func resetSelectedImageTransform() {
        guard canTransformSelectedImage else { return }
        commit { document in
            let index = document.selectedLayerIndex
            document.layers[index].imageScale = nil
            document.layers[index].imageOffsetX = nil
            document.layers[index].imageOffsetY = nil
        }
    }

    func erase(at point: CGPoint, radius: CGFloat) {
        let layerIndex = document.selectedLayerIndex
        guard document.layers.indices.contains(layerIndex) else { return }
        let layer = document.layers[layerIndex]
        guard document.isLayerEffectivelyVisible(layer) else { return }
        let transformedPoint = inverseTransformedPoint(point, for: layer, document: document)
        let transformedRadius = radius / CGFloat(layer.resolvedContentScale)
        guard let strokeIndex = layer.strokes.indices.reversed().first(where: {
            let stroke = layer.strokes[$0]
            let visibleRadius = transformedRadius + CGFloat(stroke.brush.size) / 2
            guard cachedBounds(of: stroke)?.insetBy(dx: -visibleRadius, dy: -visibleRadius)
                .contains(transformedPoint) ?? true else { return false }
            return hitsWholeStroke(stroke, at: transformedPoint, radius: transformedRadius)
        }) else { return }

        let removedStroke = document.layers[layerIndex].strokes.remove(at: strokeIndex)
        strokeBounds[removedStroke.id] = nil
        undoStack.append(.removedStroke(layerID: layer.id, stroke: removedStroke, index: strokeIndex))
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        if selectedStrokeID == removedStroke.id { selectedStrokeID = nil }
        document.modifiedAt = Date()
        onAutosave?(document)
    }

    func select(at point: CGPoint, radius: CGFloat = 60) {
        for layer in document.layers.reversed() where document.isLayerEffectivelyVisible(layer) {
            let transformedPoint = inverseTransformedPoint(point, for: layer, document: document)
            let transformedRadius = radius / CGFloat(layer.resolvedContentScale)
            if let stroke = layer.strokes.reversed().first(where: { stroke in
                guard cachedBounds(of: stroke)?.insetBy(dx: -transformedRadius, dy: -transformedRadius)
                    .contains(transformedPoint) ?? true else { return false }
                return stroke.samples.contains {
                    hypot($0.x - transformedPoint.x, $0.y - transformedPoint.y) <= transformedRadius
                }
            }) {
                selectedStrokeID = stroke.id
                return
            }
        }
        selectedStrokeID = nil
    }

    func deleteSelection() {
        guard let selectedStrokeID else { return }
        commit { document in
            for index in document.layers.indices {
                document.layers[index].strokes.removeAll { $0.id == selectedStrokeID }
            }
        }
        strokeBounds[selectedStrokeID] = nil
        self.selectedStrokeID = nil
    }

    func moveSelection(x: Double, y: Double) {
        guard let selectedStrokeID else { return }
        commit { document in
            for layerIndex in document.layers.indices {
                guard let strokeIndex = document.layers[layerIndex].strokes.firstIndex(where: { $0.id == selectedStrokeID }) else { continue }
                let scale = document.layers[layerIndex].resolvedContentScale
                for sampleIndex in document.layers[layerIndex].strokes[strokeIndex].samples.indices {
                    document.layers[layerIndex].strokes[strokeIndex].samples[sampleIndex].x += x / scale
                    document.layers[layerIndex].strokes[strokeIndex].samples[sampleIndex].y += y / scale
                }
            }
        }
        rebuildStrokeBounds()
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        switch entry {
        case .snapshot(let previous):
            redoStack.append(.snapshot(document))
            document = previous
        case .addedStroke(let layerID, let stroke):
            guard let layerIndex = document.layers.firstIndex(where: { $0.id == layerID }),
                  let strokeIndex = document.layers[layerIndex].strokes.lastIndex(where: { $0.id == stroke.id }) else {
                undoStack.append(entry)
                return
            }
            document.layers[layerIndex].strokes.remove(at: strokeIndex)
            document.modifiedAt = Date()
            redoStack.append(entry)
        case .removedStroke(let layerID, let stroke, let index):
            guard let layerIndex = document.layers.firstIndex(where: { $0.id == layerID }) else {
                undoStack.append(entry)
                return
            }
            let insertionIndex = min(index, document.layers[layerIndex].strokes.count)
            document.layers[layerIndex].strokes.insert(stroke, at: insertionIndex)
            document.modifiedAt = Date()
            redoStack.append(entry)
        }
        rebuildStrokeBounds()
        onAutosave?(document)
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        switch entry {
        case .snapshot(let next):
            undoStack.append(.snapshot(document))
            document = next
        case .addedStroke(let layerID, let stroke):
            guard let layerIndex = document.layers.firstIndex(where: { $0.id == layerID }) else {
                redoStack.append(entry)
                return
            }
            document.layers[layerIndex].strokes.append(stroke)
            document.modifiedAt = Date()
            undoStack.append(entry)
        case .removedStroke(let layerID, let stroke, _):
            guard let layerIndex = document.layers.firstIndex(where: { $0.id == layerID }),
                  let strokeIndex = document.layers[layerIndex].strokes.firstIndex(where: { $0.id == stroke.id }) else {
                redoStack.append(entry)
                return
            }
            document.layers[layerIndex].strokes.remove(at: strokeIndex)
            document.modifiedAt = Date()
            undoStack.append(entry)
        }
        rebuildStrokeBounds()
        onAutosave?(document)
    }

    private func rebuildStrokeBounds() {
        var rebuilt: [UUID: CGRect] = [:]
        rebuilt.reserveCapacity(document.layers.reduce(0) { $0 + $1.strokes.count })
        for layer in document.layers {
            for stroke in layer.strokes {
                rebuilt[stroke.id] = Self.bounds(of: stroke)
            }
        }
        strokeBounds = rebuilt
    }

    private func cachedBounds(of stroke: AnimatedStroke) -> CGRect? {
        if let cached = strokeBounds[stroke.id] { return cached }
        let calculated = Self.bounds(of: stroke)
        strokeBounds[stroke.id] = calculated
        return calculated
    }

    private static func bounds(of stroke: AnimatedStroke) -> CGRect? {
        guard let first = stroke.samples.first else { return nil }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for sample in stroke.samples.dropFirst() {
            minX = min(minX, sample.x)
            maxX = max(maxX, sample.x)
            minY = min(minY, sample.y)
            maxY = max(maxY, sample.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func inverseTransformedPoint(
        _ point: CGPoint,
        for layer: DrawingLayer,
        document: WiggleDocument
    ) -> CGPoint {
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        let offset = layer.resolvedContentOffset
        let scale = CGFloat(layer.resolvedContentScale)
        return CGPoint(
            x: center.x + (point.x - center.x - offset.x) / scale,
            y: center.y + (point.y - center.y - offset.y) / scale
        )
    }

    private func inverseTransformedSample(
        _ sample: StrokeSample,
        for layer: DrawingLayer,
        document: WiggleDocument
    ) -> StrokeSample {
        let point = inverseTransformedPoint(
            CGPoint(x: sample.x, y: sample.y),
            for: layer,
            document: document
        )
        var transformed = sample
        transformed.x = point.x
        transformed.y = point.y
        return transformed
    }

    private func transformedSample(
        _ sample: StrokeSample,
        scale: Double,
        offset: CGPoint,
        document: WiggleDocument
    ) -> StrokeSample {
        let centerX = Double(document.width) / 2
        let centerY = Double(document.height) / 2
        var transformed = sample
        transformed.x = centerX + (sample.x - centerX) * scale + offset.x
        transformed.y = centerY + (sample.y - centerY) * scale + offset.y
        return transformed
    }

    private func hitsWholeStroke(_ stroke: AnimatedStroke, at point: CGPoint, radius: CGFloat) -> Bool {
        guard let first = stroke.samples.first else { return false }
        let visibleRadius = radius + CGFloat(stroke.brush.size) / 2
        if stroke.samples.count == 1 {
            return hypot(first.x - point.x, first.y - point.y) <= visibleRadius
        }
        let squaredRadius = Double(visibleRadius * visibleRadius)
        for index in 1..<stroke.samples.count {
            let start = stroke.samples[index - 1]
            let end = stroke.samples[index]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let projection: Double
            if lengthSquared <= 0.000_001 {
                projection = 0
            } else {
                projection = min(1, max(0,
                    ((Double(point.x) - start.x) * dx + (Double(point.y) - start.y) * dy) / lengthSquared
                ))
            }
            let nearestX = start.x + dx * projection
            let nearestY = start.y + dy * projection
            let pointDX = Double(point.x) - nearestX
            let pointDY = Double(point.y) - nearestY
            if pointDX * pointDX + pointDY * pointDY <= squaredRadius { return true }
        }
        return false
    }
}
