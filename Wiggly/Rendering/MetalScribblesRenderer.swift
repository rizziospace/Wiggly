import MetalKit
import simd

/// GPU renderer for Scribbles. Each strand is cached as a narrow ribbon and
/// animated in the vertex stage. That keeps the expensive random/glitch work
/// out of the fragment shader and avoids shading the empty space between
/// strands, which is important for large canvases and thick custom presets.
final class MetalScribblesRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var sampleIndex: Float
        var phaseOffset: Float
        var color: SIMD4<Float>
        var parameters: SIMD4<Float>
        var totalLength: Float
        var baseOffset: Float
        var strandIndex: UInt32
        var seed: UInt32
    }

    struct ViewTransform {
        var canvasSize: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var fittedSize: SIMD2<Float>
        var centerOffset: SIMD2<Float>
        var zoom: Float
        var rotation: Float
        var phase: Float
        var waveAmount: Float = 0
    }

    private struct StrokeKey: Equatable {
        var id: UUID
        var sampleCount: Int
        var lastX: Double
        var lastY: Double
        var brush: BrushSettings
        var opacity: Double
        var scale: Double
        var offset: CGPoint
    }

    private struct Descriptor {
        var stroke: AnimatedStroke
        var layerID: UUID
        var opacity: Double
        var scale: CGFloat
        var offset: CGPoint
        var key: StrokeKey
    }

    /// A contiguous run of committed vertices inside one chunk buffer.
    private struct Range {
        var chunkIndex: Int
        var byteOffset: Int
        var vertexCount: Int
    }

    private struct Chunk {
        var buffer: MTLBuffer
        var usedBytes: Int
        var vertexCount: Int
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let chunkSize = 4 * 1024 * 1024
    private var chunks: [Chunk] = []
    private var strokeKeys: [StrokeKey] = []
    private var layerRanges: [UUID: [Range]] = [:]
    // Incremental live-stroke preview. The in-progress stroke's ribbon is
    // extended by only the newly-arrived samples each frame instead of the
    // whole stroke being re-baked every frame, so drawing cost stays
    // O(new samples) and no longer grows with stroke length. The shader
    // animates purely from the phase uniform, so previously-built geometry
    // never needs to change.
    private var previewBuffer: MTLBuffer?
    private var previewVertexCount = 0
    private var previewPoints: [CGPoint] = []
    private var previewNormals: [CGPoint] = []
    private var previewDistances: [CGFloat] = []
    private var previewStrokeID: UUID?
    private var previewBrush: BrushSettings?
    private var previewLineWidth: CGFloat = 0
    private var previewSeparation: CGFloat = 0
    private var previewLineCount = 0
    private var previewHalfWidth: CGFloat = 0
    private var previewStepCount = 0
    private var previewParameters = SIMD4<Float>.zero
    private var previewColor = SIMD4<Float>.zero
    private var previewPhaseOffset: Float = 0
    private var previewSeed: UInt32 = 0
    private var strokePhaseRandomized = false

    func setStrokePhaseRandomized(_ value: Bool) {
        guard value != strokePhaseRandomized else { return }
        strokePhaseRandomized = value
        chunks.removeAll(keepingCapacity: true)
        strokeKeys.removeAll(keepingCapacity: true)
        layerRanges.removeAll(keepingCapacity: true)
        resetPreview()
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let vertex = library.makeFunction(name: "scribblesVertex"),
                  let fragment = library.makeFunction(name: "scribblesFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Scribbles"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Unable to create Scribbles Metal pipeline: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .scribbles && stroke.usesGPUAnimatedRenderer {
                guard let last = stroke.samples.last else { continue }
                descriptors.append(Descriptor(
                    stroke: stroke,
                    layerID: layer.id,
                    opacity: layer.opacity,
                    scale: CGFloat(layer.resolvedContentScale),
                    offset: layer.resolvedContentOffset,
                    key: StrokeKey(
                        id: stroke.id,
                        sampleCount: stroke.samples.count,
                        lastX: last.x,
                        lastY: last.y,
                        brush: stroke.brush,
                        opacity: layer.opacity,
                        scale: layer.resolvedContentScale,
                        offset: layer.resolvedContentOffset
                    )
                ))
            }
        }

        let newKeys = descriptors.map(\.key)
        let prefixMatches = strokeKeys.count <= newKeys.count
            && zip(strokeKeys, newKeys).allSatisfy(==)
        let start: Int
        if prefixMatches {
            start = strokeKeys.count
        } else {
            chunks.removeAll(keepingCapacity: true)
            strokeKeys.removeAll(keepingCapacity: true)
            layerRanges.removeAll(keepingCapacity: true)
            start = 0
        }

        for descriptor in descriptors.dropFirst(start) {
            var vertices: [Vertex] = []
            let scale = descriptor.scale
            let offset = descriptor.offset
            append(
                stroke: descriptor.stroke,
                opacity: descriptor.opacity,
                scale: scale,
                transform: { point in
                    CGPoint(
                        x: center.x + offset.x + (point.x - center.x) * scale,
                        y: center.y + offset.y + (point.y - center.y) * scale
                    )
                },
                to: &vertices
            )
            let range = appendToChunks(vertices)
            if range.vertexCount > 0 {
                append(range, to: descriptor.layerID)
            }
        }
        strokeKeys = newKeys
        resetPreview()
    }

    /// Encodes committed strokes for a single layer so the canvas can
    /// interleave CPU and GPU content in layer order.
    func encode(
        encoder: MTLRenderCommandEncoder,
        transform: ViewTransform,
        layerID: UUID
    ) {
        let ranges = layerRanges[layerID] ?? []
        guard !ranges.isEmpty else { return }
        encoder.pushDebugGroup("Scribbles Brush")
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        for range in ranges {
            let chunk = chunks[range.chunkIndex]
            encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
            let vertexStart = range.byteOffset / MemoryLayout<Vertex>.stride
            encoder.drawPrimitives(type: .triangle, vertexStart: vertexStart, vertexCount: range.vertexCount)
        }
        encoder.popDebugGroup()
    }

    /// Encodes only the live preview stroke (drawn above the committed base).
    func encodePreview(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        transform: ViewTransform,
        previewStroke: AnimatedStroke?
    ) {
        updatePreview(previewStroke)
        guard let previewBuffer, previewVertexCount > 0 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Scribbles Preview"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .scribbles, stroke.samples.count > 1 else {
            resetPreview()
            return
        }
        let brush = stroke.brush
        if previewStrokeID != stroke.id || previewBrush != brush {
            resetPreview()
            previewStrokeID = stroke.id
            previewBrush = brush
            buildPreviewConstants(for: stroke)
        }
        let newCount = stroke.samples.count
        let builtCount = previewPoints.count
        guard newCount > builtCount else { return }
        for index in builtCount..<newCount {
            previewPoints.append(stroke.samples[index].point)
        }
        extendPreviewNormalsAndDistances(from: builtCount)
        buildPreviewSegments(oldCount: builtCount)
    }

    private func resetPreview() {
        previewStrokeID = nil
        previewBrush = nil
        previewPoints.removeAll(keepingCapacity: true)
        previewNormals.removeAll(keepingCapacity: true)
        previewDistances.removeAll(keepingCapacity: true)
        previewVertexCount = 0
    }

    private func buildPreviewConstants(for stroke: AnimatedStroke) {
        let brush = stroke.brush
        let thickness = brush.resolvedScribbleThickness
        previewLineWidth = max(0.45, brush.size * (0.08 + thickness * 0.24))
        previewSeparation = brush.size * (0.42 + thickness * 0.26)
        previewLineCount = brush.resolvedScribbleLineCount
        // Only one strand's actual width is rasterized. The animated lateral
        // offset is applied by the vertex shader and does not need a wide
        // fragment-stage envelope.
        previewHalfWidth = previewLineWidth / 2 + 0.75
        let speed = brush.resolvedScribbleSpeed
        previewStepCount = speed < 0.01
            ? 1
            : max(2, Int((2 + speed * 7).rounded()))
        previewParameters = SIMD4<Float>(
            Float(brush.resolvedWaveAmount / 100),
            Float(brush.size),
            Float(previewLineWidth / 2),
            Float(previewStepCount)
        )
        previewColor = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity)
        )
        previewPhaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        previewSeed = UInt32(truncatingIfNeeded: stableStrokeSeed(stroke.id, base: brush.seed))
    }

    private func extendPreviewNormalsAndDistances(from start: Int) {
        let m = previewPoints.count
        guard m >= 2, start < m, previewNormals.count == start else { return }
        if start > 0 {
            previewNormals[start - 1] = previewNormal(at: start - 1)
        }
        for r in start..<m {
            previewNormals.append(previewNormal(at: r))
            previewDistances.append(previewDistance(at: r))
        }
    }

    private func previewNormal(at r: Int) -> CGPoint {
        let points = previewPoints
        let m = points.count
        let previous: CGPoint
        let next: CGPoint
        if r == 0 {
            let direction = direction(from: points[0], to: points[1])
            previous = CGPoint(
                x: points[0].x - direction.x * previewHalfWidth,
                y: points[0].y - direction.y * previewHalfWidth
            )
            next = points[1]
        } else if r == m - 1 {
            previous = points[r - 1]
            let direction = direction(from: points[r - 1], to: points[r])
            next = CGPoint(
                x: points[r].x + direction.x * previewHalfWidth,
                y: points[r].y + direction.y * previewHalfWidth
            )
        } else {
            previous = points[r - 1]
            next = points[r + 1]
        }
        let dx = next.x - previous.x
        let dy = next.y - previous.y
        let length = max(0.001, Foundation.hypot(dx, dy))
        return CGPoint(x: -dy / length, y: dx / length)
    }

    private func previewDistance(at r: Int) -> CGFloat {
        if r == 0 { return 0 }
        let a = previewPoints[r - 1]
        let b = previewPoints[r]
        return previewDistances[r - 1] + Foundation.hypot(b.x - a.x, b.y - a.y)
    }

    private func direction(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.001, Foundation.hypot(dx, dy))
        return CGPoint(x: dx / length, y: dy / length)
    }

    /// Regenerates the trailing ribbon segments affected by newly-arrived
    /// samples and writes them into the persistent preview buffer. Only the
    /// last two segments are ever stale (the previous end point gained a real
    /// neighbor), so per-frame work is bounded by the number of new samples.
    private func buildPreviewSegments(oldCount: Int) {
        let points = previewPoints
        let m = points.count
        guard m >= 2, previewNormals.count == m, previewDistances.count == m else { return }
        let startDirection = direction(from: points[0], to: points[1])
        let extStart = CGPoint(
            x: points[0].x - startDirection.x * previewHalfWidth,
            y: points[0].y - startDirection.y * previewHalfWidth
        )
        let endDirection = direction(from: points[m - 2], to: points[m - 1])
        let extEnd = CGPoint(
            x: points[m - 1].x + endDirection.x * previewHalfWidth,
            y: points[m - 1].y + endDirection.y * previewHalfWidth
        )

        func extendedPoint(_ i: Int) -> CGPoint {
            if i == 0 { return extStart }
            if i == m + 1 { return extEnd }
            return points[i - 1]
        }
        func extendedNormal(_ i: Int) -> CGPoint {
            if i == 0 {
                let dx = points[0].x - extStart.x
                let dy = points[0].y - extStart.y
                let length = max(0.001, Foundation.hypot(dx, dy))
                return CGPoint(x: -dy / length, y: dx / length)
            }
            if i == m + 1 {
                let dx = extEnd.x - points[m - 1].x
                let dy = extEnd.y - points[m - 1].y
                let length = max(0.001, Foundation.hypot(dx, dy))
                return CGPoint(x: -dy / length, y: dx / length)
            }
            return previewNormals[i - 1]
        }
        func extendedUVX(_ i: Int) -> CGFloat {
            if i == 0 { return -previewHalfWidth }
            if i == m + 1 { return previewDistances[m - 1] + previewHalfWidth }
            return previewDistances[i - 1]
        }

        let startSegment = max(1, oldCount)
        let verticesPerSegment = previewLineCount * 6
        let keepVertexCount = max(0, oldCount - 1) * verticesPerSegment
        var newVertices: [Vertex] = []
        newVertices.reserveCapacity((m - oldCount + 2) * verticesPerSegment)
        for si in startSegment...(m + 1) {
            let start = extendedPoint(si - 1)
            let end = extendedPoint(si)
            let startNormal = extendedNormal(si - 1)
            let endNormal = extendedNormal(si)
            let startSampleIndex = Float(min(m - 1, max(0, si - 2)))
            let endSampleIndex = Float(min(m - 1, max(0, si - 1)))
            for lineIndex in 0..<previewLineCount {
                let strand = CGFloat(lineIndex) - CGFloat(previewLineCount - 1) / 2
                let baseOffset = strand * previewSeparation
                let a = previewVertex(start, normal: startNormal, distance: extendedUVX(si - 1), across: -previewHalfWidth, sampleIndex: startSampleIndex, baseOffset: baseOffset, lineIndex: lineIndex)
                let b = previewVertex(start, normal: startNormal, distance: extendedUVX(si - 1), across: previewHalfWidth, sampleIndex: startSampleIndex, baseOffset: baseOffset, lineIndex: lineIndex)
                let c = previewVertex(end, normal: endNormal, distance: extendedUVX(si), across: -previewHalfWidth, sampleIndex: endSampleIndex, baseOffset: baseOffset, lineIndex: lineIndex)
                let d = previewVertex(end, normal: endNormal, distance: extendedUVX(si), across: previewHalfWidth, sampleIndex: endSampleIndex, baseOffset: baseOffset, lineIndex: lineIndex)
                newVertices.append(contentsOf: [a, b, c, c, b, d])
            }
        }
        writePreviewVertices(newVertices, atVertexOffset: keepVertexCount)
        previewVertexCount = keepVertexCount + newVertices.count
    }

    private func previewVertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: CGFloat,
        sampleIndex: Float,
        baseOffset: CGFloat,
        lineIndex: Int
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), Float(across)),
            sampleIndex: sampleIndex,
            phaseOffset: previewPhaseOffset,
            color: previewColor,
            parameters: previewParameters,
            totalLength: Float(previewDistances[previewDistances.count - 1]),
            baseOffset: Float(baseOffset),
            strandIndex: UInt32(lineIndex),
            seed: previewSeed
        )
    }

    private func writePreviewVertices(_ vertices: [Vertex], atVertexOffset offset: Int) {
        guard !vertices.isEmpty else { return }
        let stride = MemoryLayout<Vertex>.stride
        let byteOffset = offset * stride
        let needed = byteOffset + vertices.count * stride
        if previewBuffer == nil || previewBuffer!.length < needed {
            let capacity = max(chunkSize, needed)
            previewBuffer = device.makeBuffer(length: capacity, options: .storageModeShared)
            previewBuffer?.label = "Scribbles Preview"
        }
        guard let base = previewBuffer?.contents() else { return }
        vertices.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                base.advanced(by: byteOffset).copyMemory(from: source, byteCount: bytes.count)
            }
        }
    }

    /// Builds one cached ribbon along the stroke centerline. uv.x is the arc
    /// distance, uv.y spans the ribbon width in halfWidth units, and
    /// sampleIndex tracks the CPU kernel's per-sample index so the shader can
    /// derive the glitch cells exactly.
    private func append(
        stroke: AnimatedStroke,
        opacity: Double,
        scale: CGFloat,
        transform: (CGPoint) -> CGPoint,
        to vertices: inout [Vertex]
    ) {
        let samples = stroke.bakedSamples()
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let points = samples.map { transform($0.point) }
        let effectiveSize = brush.size * Double(scale)

        let thickness = brush.resolvedScribbleThickness
        let lineWidth = max(0.45, effectiveSize * (0.08 + thickness * 0.24))
        let separation = effectiveSize * (0.42 + thickness * 0.26)
        let lineCount = brush.resolvedScribbleLineCount
        let halfWidth = lineWidth / 2 + 0.75
        let capExtension = brush.resolvedEndStyle == .rounded ? halfWidth : 0

        let first = points[0]
        let second = points[1]
        let startLength = max(0.001, Foundation.hypot(second.x - first.x, second.y - first.y))
        let startDir = CGPoint(x: (second.x - first.x) / startLength, y: (second.y - first.y) / startLength)
        let extStart = CGPoint(x: first.x - startDir.x * capExtension, y: first.y - startDir.y * capExtension)
        let last = points[points.count - 1]
        let previous = points[points.count - 2]
        let endLength = max(0.001, Foundation.hypot(last.x - previous.x, last.y - previous.y))
        let endDir = CGPoint(x: (last.x - previous.x) / endLength, y: (last.y - previous.y) / endLength)
        let extEnd = CGPoint(x: last.x + endDir.x * capExtension, y: last.y + endDir.y * capExtension)
        let extended = [extStart] + points + [extEnd]

        var normals: [CGPoint] = []
        var distances = [CGFloat](repeating: 0, count: extended.count)
        normals.reserveCapacity(extended.count)
        for index in extended.indices {
            let previousPoint = extended[max(0, index - 1)]
            let nextPoint = extended[min(extended.count - 1, index + 1)]
            let dx = nextPoint.x - previousPoint.x
            let dy = nextPoint.y - previousPoint.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            normals.append(CGPoint(x: -dy / length, y: dx / length))
            if index > 0 {
                distances[index] = distances[index - 1]
                    + Foundation.hypot(extended[index].x - extended[index - 1].x, extended[index].y - extended[index - 1].y)
            }
        }

        let totalLength = Float(distances[extended.count - 2] - capExtension)
        let speed = brush.resolvedScribbleSpeed
        let stepCount = speed < 0.01
            ? 1
            : max(2, Int((2 + speed * 7).rounded()))
        let parameters = SIMD4<Float>(
            Float(brush.resolvedWaveAmount / 100),
            Float(effectiveSize),
            Float(lineWidth / 2),
            Float(stepCount)
        )
        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        let seed = UInt32(truncatingIfNeeded: stableStrokeSeed(stroke.id, base: brush.seed))

        vertices.reserveCapacity(vertices.count + (extended.count - 1) * lineCount * 6)
        for index in 1..<extended.count {
            let start = extended[index - 1]
            let end = extended[index]
            let startNormal = normals[index - 1]
            let endNormal = normals[index]
            let startSampleIndex = Float(min(samples.count - 1, max(0, index - 2)))
            let endSampleIndex = Float(min(samples.count - 1, max(0, index - 1)))
            for lineIndex in 0..<lineCount {
                let strand = CGFloat(lineIndex) - CGFloat(lineCount - 1) / 2
                let baseOffset = strand * separation
                let a = vertex(start, normal: startNormal, distance: distances[index - 1] - capExtension, across: -halfWidth, sampleIndex: startSampleIndex, color: color, parameters: parameters, totalLength: totalLength, baseOffset: baseOffset, lineIndex: lineIndex, phaseOffset: phaseOffset, seed: seed)
                let b = vertex(start, normal: startNormal, distance: distances[index - 1] - capExtension, across: halfWidth, sampleIndex: startSampleIndex, color: color, parameters: parameters, totalLength: totalLength, baseOffset: baseOffset, lineIndex: lineIndex, phaseOffset: phaseOffset, seed: seed)
                let c = vertex(end, normal: endNormal, distance: distances[index] - capExtension, across: -halfWidth, sampleIndex: endSampleIndex, color: color, parameters: parameters, totalLength: totalLength, baseOffset: baseOffset, lineIndex: lineIndex, phaseOffset: phaseOffset, seed: seed)
                let d = vertex(end, normal: endNormal, distance: distances[index] - capExtension, across: halfWidth, sampleIndex: endSampleIndex, color: color, parameters: parameters, totalLength: totalLength, baseOffset: baseOffset, lineIndex: lineIndex, phaseOffset: phaseOffset, seed: seed)
                vertices.append(contentsOf: [a, b, c, c, b, d])
            }
        }
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: CGFloat,
        sampleIndex: Float,
        color: SIMD4<Float>,
        parameters: SIMD4<Float>,
        totalLength: Float,
        baseOffset: CGFloat,
        lineIndex: Int,
        phaseOffset: Float,
        seed: UInt32
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), Float(across)),
            sampleIndex: sampleIndex,
            phaseOffset: phaseOffset,
            color: color,
            parameters: parameters,
            totalLength: totalLength,
            baseOffset: Float(baseOffset),
            strandIndex: UInt32(lineIndex),
            seed: seed
        )
    }

    @discardableResult
    private func appendToChunks(_ vertices: [Vertex]) -> Range {
        guard !vertices.isEmpty else { return Range(chunkIndex: 0, byteOffset: 0, vertexCount: 0) }
        let byteCount = vertices.count * MemoryLayout<Vertex>.stride
        if chunks.isEmpty || chunks[chunks.count - 1].usedBytes + byteCount > chunks[chunks.count - 1].buffer.length {
            guard let buffer = device.makeBuffer(length: max(chunkSize, byteCount), options: .storageModeShared) else {
                return Range(chunkIndex: 0, byteOffset: 0, vertexCount: 0)
            }
            buffer.label = "Scribbles Geometry \(chunks.count)"
            chunks.append(Chunk(buffer: buffer, usedBytes: 0, vertexCount: 0))
        }
        let index = chunks.count - 1
        let byteOffset = chunks[index].usedBytes
        let destination = chunks[index].buffer.contents().advanced(by: chunks[index].usedBytes)
        vertices.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { destination.copyMemory(from: source, byteCount: bytes.count) }
        }
        chunks[index].usedBytes += byteCount
        chunks[index].vertexCount += vertices.count
        return Range(chunkIndex: index, byteOffset: byteOffset, vertexCount: vertices.count)
    }

    private func append(_ range: Range, to layerID: UUID) {
        var ranges = layerRanges[layerID, default: []]
        if let last = ranges.last,
           last.chunkIndex == range.chunkIndex,
           last.byteOffset + last.vertexCount * MemoryLayout<Vertex>.stride == range.byteOffset {
            ranges[ranges.count - 1].vertexCount += range.vertexCount
        } else {
            ranges.append(range)
        }
        layerRanges[layerID] = ranges
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }

    private func seeded(_ seed: UInt64, _ index: Int) -> Double {
        var value = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value % 10_000) / 10_000
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 canvasSize;
        float2 viewSize;
        float2 fittedSize;
        float2 centerOffset;
        float zoom;
        float rotation;
        float phase;
        float waveAmount;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    uint hash32(uint value) {
        value ^= value >> 16;
        value *= 0x7FEB352Du;
        value ^= value >> 15;
        value *= 0x846CA68Bu;
        value ^= value >> 16;
        return value;
    }

    float seededRandom(uint seed, int index) {
        uint key = seed + uint(max(index, 0)) * 0x9E3779B9u;
        return float(hash32(key)) * (1.0 / 4294967295.0);
    }

    struct VertexIn {
        float2 position;
        float2 normal;
        float2 uv;
        float sampleIndex;
        float phaseOffset;
        float4 color;
        float4 parameters;
        float totalLength;
        float baseOffset;
        uint strandIndex;
        uint seed;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 canvasPosition;
        float2 uv;
        float4 color;
        float lineHalf;
        float totalLength;
    };

    // Hash of the glitch offset for one (strand, cell, time-step) triplet.
    float glitchValue(uint seed, int line, int cell, int step) {
        int key = max(0, line * 100003 + cell * 997 + step * 7919);
        float broad = seededRandom(seed + 1009u, key) * 2.0 - 1.0;
        float fine = seededRandom(seed + 6157u, key + 37) * 2.0 - 1.0;
        return broad * 0.78 + fine * 0.22;
    }

    vertex VertexOut scribblesVertex(
        uint id [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]) {
        VertexIn input = vertices[id];

        // The old renderer evaluated these hashes for every covered pixel of
        // one wide envelope. Evaluating them once per vertex is dramatically
        // cheaper and the interpolated narrow ribbon has the same motion.
        float cellF = clamp(input.sampleIndex, 0.0, 1.0e6) / 18.0;
        int cell = int(floor(cellF));
        float progress = fract(cellF);
        float spatialBlend = progress * progress * (3.0 - 2.0 * progress);

        float stepCountF = input.parameters.w;
        float timePosition = fract(u.phase + input.phaseOffset) * stepCountF;
        int stepCountI = max(1, int(stepCountF));
        int currentStep = min(stepCountI - 1, int(floor(timePosition)));
        int nextStep = (currentStep + 1) % stepCountI;
        float localTime = fract(timePosition);
        float rawTransition = clamp((localTime - 0.70) / 0.30, 0.0, 1.0);
        float transition = rawTransition * rawTransition * (3.0 - 2.0 * rawTransition);

        int strand = int(input.strandIndex);
        float held = mix(
            glitchValue(input.seed, strand, cell, currentStep),
            glitchValue(input.seed, strand, cell + 1, currentStep),
            spatialBlend);
        float next = mix(
            glitchValue(input.seed, strand, cell, nextStep),
            glitchValue(input.seed, strand, cell + 1, nextStep),
            spatialBlend);
        float amplitude = input.parameters.y
            * (0.10 + seededRandom(input.seed + 719u, strand) * 0.18);
        float animatedOffset = input.baseOffset + mix(held, next, transition) * amplitude;
        float waveOffset = 0.0;
        if (input.parameters.x > 0.0001 && u.waveAmount > 0.0001 && input.totalLength > 0.001) {
            float progress = clamp(input.uv.x / input.totalLength, 0.0, 1.0);
            float envelope = pow(max(0.0, sin(3.14159265 * progress)), 0.35);
            float amplitude = input.parameters.x * u.waveAmount * max(8.0, input.parameters.y * 0.55);
            float wavelength = max(72.0, input.parameters.y * 5.0);
            float angle = input.uv.x / wavelength * 6.2831853 - u.phase * 6.2831853;
            waveOffset = sin(angle) * amplitude * envelope;
        }
        float2 point = input.position + input.normal * (animatedOffset + input.uv.y + waveOffset);

        VertexOut out;
        out.position = float4(canvasToClip(point, u), 0, 1);
        out.canvasPosition = point;
        out.uv = input.uv;
        out.color = input.color;
        out.lineHalf = input.parameters.z;
        out.totalLength = input.totalLength;
        return out;
    }

    fragment float4 scribblesFragment(
        VertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(1)]]) {
        if (in.canvasPosition.x < 0.0 || in.canvasPosition.y < 0.0
            || in.canvasPosition.x > u.canvasSize.x || in.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }

        float2 q = in.uv;
        float aa = max(0.6, fwidth(q.y));
        float2 strandPoint = float2(clamp(q.x, 0.0, in.totalLength), 0.0);
        float distance = length(q - strandPoint) - in.lineHalf;
        float alpha = (1.0 - smoothstep(-aa, aa, distance)) * in.color.a;
        if (alpha <= 0.001) discard_fragment();
        return float4(in.color.rgb, alpha);
    }
    """#
}
