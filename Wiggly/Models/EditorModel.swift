import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class EditorModel: ObservableObject {
    @Published var document: WiggleDocument
    @Published var selectedBrush: BrushSettings
    @Published var inputPolicy: CanvasInputPolicy = .pencilOnly
    @Published var selectionMode = false
    @Published var eraserMode = false
    @Published var imageTransformMode = false
    @Published var selectedStrokeID: UUID?

    private var undoStack: [WiggleDocument] = []
    private var activeImageTransformGestures = 0
    private var isChangingLayerOpacity = false
    private var redoStack: [WiggleDocument] = []
    var onAutosave: ((WiggleDocument) -> Void)?

    init(document: WiggleDocument) {
        self.document = document
        selectedBrush = .preset(.wiggle)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func checkpoint() {
        undoStack.append(document)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func commit(_ edit: (inout WiggleDocument) -> Void) {
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

    func addStroke(_ stroke: AnimatedStroke) {
        commit { document in
            let index = document.selectedLayerIndex
            document.layers[index].strokes.append(stroke)
        }
    }

    var selectedImageScale: Double {
        guard document.layers.indices.contains(document.selectedLayerIndex) else { return 1 }
        return document.layers[document.selectedLayerIndex].resolvedImageScale
    }

    var canTransformSelectedImage: Bool {
        document.layers.indices.contains(document.selectedLayerIndex)
            && document.layers[document.selectedLayerIndex].imageData != nil
    }

    func beginImageTransformGesture() {
        guard canTransformSelectedImage else { return }
        if activeImageTransformGestures == 0 { checkpoint() }
        activeImageTransformGestures += 1
    }

    func updateSelectedImageTransform(scaleDelta: Double = 1, translation: CGPoint = .zero) {
        guard canTransformSelectedImage else { return }
        let index = document.selectedLayerIndex
        var updated = document
        let layer = updated.layers[index]
        updated.layers[index].imageScale = min(8, max(0.1, layer.resolvedImageScale * scaleDelta))
        updated.layers[index].imageOffsetX = Double(layer.resolvedImageOffset.x + translation.x)
        updated.layers[index].imageOffsetY = Double(layer.resolvedImageOffset.y + translation.y)
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
        var didErase = false
        var replacement: [AnimatedStroke] = []

        for stroke in document.layers[layerIndex].strokes {
            let result = clipped(stroke: stroke, outside: point, radius: Double(radius))
            didErase = didErase || result.changed
            replacement.append(contentsOf: result.strokes)
        }

        guard didErase else { return }
        commit { $0.layers[layerIndex].strokes = replacement }
    }

    func select(at point: CGPoint, radius: CGFloat = 60) {
        for layer in document.layers.reversed() where layer.isVisible {
            if let stroke = layer.strokes.reversed().first(where: { stroke in
                stroke.samples.contains { hypot($0.x - point.x, $0.y - point.y) <= radius }
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
        self.selectedStrokeID = nil
    }

    func moveSelection(x: Double, y: Double) {
        guard let selectedStrokeID else { return }
        commit { document in
            for layerIndex in document.layers.indices {
                guard let strokeIndex = document.layers[layerIndex].strokes.firstIndex(where: { $0.id == selectedStrokeID }) else { continue }
                for sampleIndex in document.layers[layerIndex].strokes[strokeIndex].samples.indices {
                    document.layers[layerIndex].strokes[strokeIndex].samples[sampleIndex].x += x
                    document.layers[layerIndex].strokes[strokeIndex].samples[sampleIndex].y += y
                }
            }
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        onAutosave?(document)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        onAutosave?(document)
    }

    private func clipped(
        stroke: AnimatedStroke,
        outside center: CGPoint,
        radius: Double
    ) -> (changed: Bool, strokes: [AnimatedStroke]) {
        guard stroke.samples.count > 1 else { return (false, [stroke]) }
        var changed = false
        var pieces: [[StrokeSample]] = []
        var current: [StrokeSample] = []

        for index in 1..<stroke.samples.count {
            let start = stroke.samples[index - 1]
            let end = stroke.samples[index]
            var boundaries = [0.0]
            boundaries.append(contentsOf: circleIntersections(from: start, to: end, center: center, radius: radius))
            boundaries.append(1.0)
            boundaries.sort()

            for boundaryIndex in 1..<boundaries.count {
                let lower = boundaries[boundaryIndex - 1]
                let upper = boundaries[boundaryIndex]
                guard upper - lower > 0.000_001 else { continue }
                let midpoint = interpolated(start, end, t: (lower + upper) / 2)
                let isOutside = hypot(midpoint.x - center.x, midpoint.y - center.y) > radius

                if isOutside {
                    appendUnique(interpolated(start, end, t: lower), to: &current)
                    appendUnique(interpolated(start, end, t: upper), to: &current)
                } else {
                    changed = true
                    finish(&current, into: &pieces)
                }
            }
        }
        finish(&current, into: &pieces)

        guard changed else { return (false, [stroke]) }
        return (true, pieces.map { AnimatedStroke(samples: $0, brush: stroke.brush) })
    }

    private func circleIntersections(
        from start: StrokeSample,
        to end: StrokeSample,
        center: CGPoint,
        radius: Double
    ) -> [Double] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let fx = start.x - center.x
        let fy = start.y - center.y
        let a = dx * dx + dy * dy
        guard a > 0.000_001 else { return [] }
        let b = 2 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant > 0 else { return [] }
        let root = sqrt(discriminant)
        return [(-b - root) / (2 * a), (-b + root) / (2 * a)]
            .filter { $0 > 0 && $0 < 1 }
            .sorted()
    }

    private func interpolated(_ start: StrokeSample, _ end: StrokeSample, t: Double) -> StrokeSample {
        StrokeSample(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t,
            pressure: start.pressure + (end.pressure - start.pressure) * t,
            tilt: start.tilt + (end.tilt - start.tilt) * t,
            azimuth: start.azimuth + (end.azimuth - start.azimuth) * t,
            timestamp: start.timestamp + (end.timestamp - start.timestamp) * t
        )
    }
    private func appendUnique(_ sample: StrokeSample, to samples: inout [StrokeSample]) {
        guard let last = samples.last else {
            samples.append(sample)
            return
        }
        if hypot(last.x - sample.x, last.y - sample.y) > 0.001 {
            samples.append(sample)
        }
    }

    private func finish(_ current: inout [StrokeSample], into pieces: inout [[StrokeSample]]) {
        if current.count > 1 { pieces.append(current) }
        current.removeAll(keepingCapacity: true)
    }
}
