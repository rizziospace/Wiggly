import MetalKit
import simd

/// Live GPU renderer for the Outline Fill brush. Each stroke becomes two
/// concentric ribbons: a wider outline ribbon in the primary color underneath
/// a narrower fill ribbon in the secondary color. An animated organic wobble
/// and the global wave displace both ribbons by the same amount (keyed by arc
/// distance and the fill half width), so the outline always hugs the fill.
final class MetalOutlineFillRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var parameters: SIMD4<Float>
        var halfWidth: Float
        var totalLength: Float
        var phaseOffset: Float
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

    private struct PreviewKey: Equatable {
        var sampleCount: Int
        var lastX: Double
        var lastY: Double
        var brush: BrushSettings
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let chunkSize = 4 * 1024 * 1024
    private var chunks: [Chunk] = []
    private var strokeKeys: [StrokeKey] = []
    private var outlineRanges: [UUID: [Range]] = [:]
    private var fillRanges: [UUID: [Range]] = [:]
    private var previewBuffer: MTLBuffer?
    private lazy var previewRing = MetalLiveBufferRing(device: device, label: "Outline Fill Live Stroke")
    private var previewVertexCount = 0
    private var previewKey: PreviewKey?
    private var strokePhaseRandomized = false

    func setStrokePhaseRandomized(_ value: Bool) {
        guard value != strokePhaseRandomized else { return }
        strokePhaseRandomized = value
        chunks.removeAll(keepingCapacity: true)
        strokeKeys.removeAll(keepingCapacity: true)
        outlineRanges.removeAll(keepingCapacity: true)
        fillRanges.removeAll(keepingCapacity: true)
        previewBuffer = nil
        previewVertexCount = 0
        previewKey = nil
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let vertex = library.makeFunction(name: "outlineFillVertex"),
                  let fragment = library.makeFunction(name: "outlineFillFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Outline Fill Brush"
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
            assertionFailure("Unable to create Outline Fill Metal pipeline: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .outlineFill && stroke.usesGPUAnimatedRenderer {
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
            outlineRanges.removeAll(keepingCapacity: true)
            fillRanges.removeAll(keepingCapacity: true)
            start = 0
        }

        for descriptor in descriptors.dropFirst(start) {
            var outlineVertices: [Vertex] = []
            var fillVertices: [Vertex] = []
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
                outlineVertices: &outlineVertices,
                fillVertices: &fillVertices
            )
            let outlineRange = appendToChunks(outlineVertices)
            if outlineRange.vertexCount > 0 {
                append(outlineRange, to: &outlineRanges, layerID: descriptor.layerID)
            }
            let fillRange = appendToChunks(fillVertices)
            if fillRange.vertexCount > 0 {
                append(fillRange, to: &fillRanges, layerID: descriptor.layerID)
            }
        }
        strokeKeys = newKeys
        previewBuffer = nil
        previewVertexCount = 0
        previewKey = nil
    }

    func encode(
        encoder: MTLRenderCommandEncoder,
        transform: ViewTransform,
        layerID: UUID
    ) {
        let outlines = outlineRanges[layerID] ?? []
        let fills = fillRanges[layerID] ?? []
        guard !outlines.isEmpty || !fills.isEmpty else { return }
        encoder.pushDebugGroup("Outline Fill Brush")
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        for range in outlines {
            let chunk = chunks[range.chunkIndex]
            encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
            let vertexStart = range.byteOffset / MemoryLayout<Vertex>.stride
            encoder.drawPrimitives(type: .triangle, vertexStart: vertexStart, vertexCount: range.vertexCount)
        }
        for range in fills {
            let chunk = chunks[range.chunkIndex]
            encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
            let vertexStart = range.byteOffset / MemoryLayout<Vertex>.stride
            encoder.drawPrimitives(type: .triangle, vertexStart: vertexStart, vertexCount: range.vertexCount)
        }
        encoder.popDebugGroup()
    }

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
        encoder.label = "Outline Fill Brush Preview"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .outlineFill, let last = stroke.samples.last else {
            previewBuffer = nil
            previewVertexCount = 0
            previewKey = nil
            return
        }
        let key = PreviewKey(sampleCount: stroke.samples.count, lastX: last.x, lastY: last.y, brush: stroke.brush)
        guard key != previewKey else { return }
        previewKey = key
        var outlineVertices: [Vertex] = []
        var fillVertices: [Vertex] = []
        append(stroke: stroke, opacity: 1, scale: 1, transform: { $0 }, outlineVertices: &outlineVertices, fillVertices: &fillVertices)
        var combined = outlineVertices
        combined.append(contentsOf: fillVertices)
        previewVertexCount = combined.count
        previewBuffer = previewRing.write(combined)
    }

    private func append(
        stroke: AnimatedStroke,
        opacity: Double,
        scale: CGFloat,
        transform: (CGPoint) -> CGPoint,
        outlineVertices: inout [Vertex],
        fillVertices: inout [Vertex]
    ) {
        let samples = stroke.bakedSamples()
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let points = samples.map { transform($0.point) }
        var normals: [CGPoint] = []
        var widths: [CGFloat] = []
        var distances = Array(repeating: CGFloat.zero, count: samples.count)
        normals.reserveCapacity(samples.count)
        widths.reserveCapacity(samples.count)
        for index in samples.indices {
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, hypot(dx, dy))
            normals.append(CGPoint(x: -dy / length, y: dx / length))
            widths.append(localWidth(samples[index], index: index, count: samples.count, brush: brush) * scale)
            if index > 0 {
                distances[index] = distances[index - 1]
                    + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
            }
        }

        let totalLength = Float(distances.last ?? 0)
        let outlineColor = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let secondary = brush.resolvedSecondaryColor
        let fillColor = SIMD4<Float>(
            Float(secondary.red), Float(secondary.green), Float(secondary.blue),
            Float(secondary.alpha * brush.opacity * opacity)
        )
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        let parameters = SIMD4<Float>(
            Float(brush.resolvedWaveAmount / 100),
            Float(brush.size / 2 * scale),
            Float(brush.resolvedWobbleAmount),
            Float(brush.resolvedWobbleSpeed)
        )
        let seed = UInt32(truncatingIfNeeded: brush.seed)
        let outlineThickness = CGFloat(brush.resolvedOutlineWidth) / 2 * scale

        outlineVertices.reserveCapacity(outlineVertices.count + (samples.count + 1) * 6)
        fillVertices.reserveCapacity(fillVertices.count + (samples.count + 1) * 6)
        for index in 1..<samples.count {
            let start = points[index - 1]
            let end = points[index]
            let startNormal = normals[index - 1]
            let endNormal = normals[index]
            let fillStartHalf = widths[index - 1] / 2
            let fillEndHalf = widths[index] / 2
            let outlineStartHalf = fillStartHalf + outlineThickness
            let outlineEndHalf = fillEndHalf + outlineThickness
            let startDistance = distances[index - 1]
            let endDistance = distances[index]
            appendQuad(
                to: &outlineVertices,
                start: start, end: end,
                startNormal: startNormal, endNormal: endNormal,
                startHalf: outlineStartHalf, endHalf: outlineEndHalf,
                startDistance: startDistance, endDistance: endDistance,
                color: outlineColor,
                fillHalfWidth: fillStartHalf,
                parameters: parameters,
                totalLength: totalLength,
                phaseOffset: phaseOffset,
                seed: seed
            )
            appendQuad(
                to: &fillVertices,
                start: start, end: end,
                startNormal: startNormal, endNormal: endNormal,
                startHalf: fillStartHalf, endHalf: fillEndHalf,
                startDistance: startDistance, endDistance: endDistance,
                color: fillColor,
                fillHalfWidth: fillStartHalf,
                parameters: parameters,
                totalLength: totalLength,
                phaseOffset: phaseOffset,
                seed: seed
            )
        }

        if brush.resolvedEndStyle == .rounded {
            let first = points[0]
            let second = points[1]
            let startLength = max(0.001, hypot(second.x - first.x, second.y - first.y))
            let startDirection = CGPoint(x: (second.x - first.x) / startLength, y: (second.y - first.y) / startLength)
            let startNormal = normals[0]
            let fillStartHalf = widths[0] / 2
            let outlineStartHalf = fillStartHalf + outlineThickness
            let capStart = CGPoint(x: first.x - startDirection.x * outlineStartHalf, y: first.y - startDirection.y * outlineStartHalf)
            let startOuterLeft = CGPoint(x: capStart.x + startNormal.x * outlineStartHalf, y: capStart.y + startNormal.y * outlineStartHalf)
            let startOuterRight = CGPoint(x: capStart.x - startNormal.x * outlineStartHalf, y: capStart.y - startNormal.y * outlineStartHalf)
            let startInnerLeft = CGPoint(x: first.x + startNormal.x * outlineStartHalf, y: first.y + startNormal.y * outlineStartHalf)
            let startInnerRight = CGPoint(x: first.x - startNormal.x * outlineStartHalf, y: first.y - startNormal.y * outlineStartHalf)
            appendCap(
                to: &outlineVertices,
                outerLeft: startOuterLeft, outerRight: startOuterRight,
                innerLeft: startInnerLeft, innerRight: startInnerRight,
                normal: startNormal,
                outerDistance: -outlineStartHalf, innerDistance: 0,
                halfWidth: outlineStartHalf,
                color: outlineColor,
                fillHalfWidth: fillStartHalf,
                parameters: parameters,
                totalLength: totalLength,
                phaseOffset: phaseOffset,
                seed: seed
            )
            let capFillStart = CGPoint(x: first.x - startDirection.x * fillStartHalf, y: first.y - startDirection.y * fillStartHalf)
            let fillOuterLeft = CGPoint(x: capFillStart.x + startNormal.x * fillStartHalf, y: capFillStart.y + startNormal.y * fillStartHalf)
            let fillOuterRight = CGPoint(x: capFillStart.x - startNormal.x * fillStartHalf, y: capFillStart.y - startNormal.y * fillStartHalf)
            let fillInnerLeft = CGPoint(x: first.x + startNormal.x * fillStartHalf, y: first.y + startNormal.y * fillStartHalf)
            let fillInnerRight = CGPoint(x: first.x - startNormal.x * fillStartHalf, y: first.y - startNormal.y * fillStartHalf)
            appendCap(
                to: &fillVertices,
                outerLeft: fillOuterLeft, outerRight: fillOuterRight,
                innerLeft: fillInnerLeft, innerRight: fillInnerRight,
                normal: startNormal,
                outerDistance: -fillStartHalf, innerDistance: 0,
                halfWidth: fillStartHalf,
                color: fillColor,
                fillHalfWidth: fillStartHalf,
                parameters: parameters,
                totalLength: totalLength,
                phaseOffset: phaseOffset,
                seed: seed
            )

            let last = points[points.count - 1]
            let previous = points[points.count - 2]
            let endLength = max(0.001, hypot(last.x - previous.x, last.y - previous.y))
            let endDirection = CGPoint(x: (last.x - previous.x) / endLength, y: (last.y - previous.y) / endLength)
            let endNormal = normals[normals.count - 1]
            let fillEndHalf = widths[widths.count - 1] / 2
            let outlineEndHalf = fillEndHalf + outlineThickness
            let capEnd = CGPoint(x: last.x + endDirection.x * outlineEndHalf, y: last.y + endDirection.y * outlineEndHalf)
            let endInnerLeft = CGPoint(x: last.x + endNormal.x * outlineEndHalf, y: last.y + endNormal.y * outlineEndHalf)
            let endInnerRight = CGPoint(x: last.x - endNormal.x * outlineEndHalf, y: last.y - endNormal.y * outlineEndHalf)
            let endOuterLeft = CGPoint(x: capEnd.x + endNormal.x * outlineEndHalf, y: capEnd.y + endNormal.y * outlineEndHalf)
            let endOuterRight = CGPoint(x: capEnd.x - endNormal.x * outlineEndHalf, y: capEnd.y - endNormal.y * outlineEndHalf)
            appendCap(
                to: &outlineVertices,
                outerLeft: endOuterLeft, outerRight: endOuterRight,
                innerLeft: endInnerLeft, innerRight: endInnerRight,
                normal: endNormal,
                outerDistance: CGFloat(totalLength) + outlineEndHalf, innerDistance: CGFloat(totalLength),
                halfWidth: outlineEndHalf,
                color: outlineColor,
                fillHalfWidth: fillEndHalf,
                parameters: parameters,
                totalLength: totalLength,
                phaseOffset: phaseOffset,
                seed: seed
            )
            let capFillEnd = CGPoint(x: last.x + endDirection.x * fillEndHalf, y: last.y + endDirection.y * fillEndHalf)
            let endFillInnerLeft = CGPoint(x: last.x + endNormal.x * fillEndHalf, y: last.y + endNormal.y * fillEndHalf)
            let endFillInnerRight = CGPoint(x: last.x - endNormal.x * fillEndHalf, y: last.y - endNormal.y * fillEndHalf)
            let endFillOuterLeft = CGPoint(x: capFillEnd.x + endNormal.x * fillEndHalf, y: capFillEnd.y + endNormal.y * fillEndHalf)
            let endFillOuterRight = CGPoint(x: capFillEnd.x - endNormal.x * fillEndHalf, y: capFillEnd.y - endNormal.y * fillEndHalf)
            appendCap(
                to: &fillVertices,
                outerLeft: endFillOuterLeft, outerRight: endFillOuterRight,
                innerLeft: endFillInnerLeft, innerRight: endFillInnerRight,
                normal: endNormal,
                outerDistance: CGFloat(totalLength) + fillEndHalf, innerDistance: CGFloat(totalLength),
                halfWidth: fillEndHalf,
                color: fillColor,
                fillHalfWidth: fillEndHalf,
                parameters: parameters,
                totalLength: totalLength,
                phaseOffset: phaseOffset,
                seed: seed
            )
        }
    }

    private func appendQuad(
        to vertices: inout [Vertex],
        start: CGPoint, end: CGPoint,
        startNormal: CGPoint, endNormal: CGPoint,
        startHalf: CGFloat, endHalf: CGFloat,
        startDistance: CGFloat, endDistance: CGFloat,
        color: SIMD4<Float>,
        fillHalfWidth: CGFloat,
        parameters: SIMD4<Float>,
        totalLength: Float,
        phaseOffset: Float,
        seed: UInt32
    ) {
        let sl = CGPoint(x: start.x + startNormal.x * startHalf, y: start.y + startNormal.y * startHalf)
        let sr = CGPoint(x: start.x - startNormal.x * startHalf, y: start.y - startNormal.y * startHalf)
        let el = CGPoint(x: end.x + endNormal.x * endHalf, y: end.y + endNormal.y * endHalf)
        let er = CGPoint(x: end.x - endNormal.x * endHalf, y: end.y - endNormal.y * endHalf)
        let a = vertex(sl, normal: startNormal, distance: startDistance, across: -1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        let b = vertex(sr, normal: startNormal, distance: startDistance, across: 1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        let c = vertex(el, normal: endNormal, distance: endDistance, across: -1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        let d = vertex(er, normal: endNormal, distance: endDistance, across: 1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        vertices.append(contentsOf: [a, b, c, c, b, d])
    }

    private func appendCap(
        to vertices: inout [Vertex],
        outerLeft: CGPoint, outerRight: CGPoint,
        innerLeft: CGPoint, innerRight: CGPoint,
        normal: CGPoint,
        outerDistance: CGFloat, innerDistance: CGFloat,
        halfWidth: CGFloat,
        color: SIMD4<Float>,
        fillHalfWidth: CGFloat,
        parameters: SIMD4<Float>,
        totalLength: Float,
        phaseOffset: Float,
        seed: UInt32
    ) {
        let a = vertex(outerLeft, normal: normal, distance: outerDistance, across: -1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        let b = vertex(outerRight, normal: normal, distance: outerDistance, across: 1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        let c = vertex(innerLeft, normal: normal, distance: innerDistance, across: -1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        let d = vertex(innerRight, normal: normal, distance: innerDistance, across: 1, color: color, fillHalfWidth: fillHalfWidth, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, seed: seed)
        vertices.append(contentsOf: [a, b, c, c, b, d])
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: Float,
        color: SIMD4<Float>,
        fillHalfWidth: CGFloat,
        parameters: SIMD4<Float>,
        halfWidth: CGFloat,
        totalLength: Float,
        phaseOffset: Float,
        seed: UInt32
    ) -> Vertex {
        var params = parameters
        params.y = Float(fillHalfWidth)
        return Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), across),
            color: color,
            parameters: params,
            halfWidth: Float(halfWidth),
            totalLength: totalLength,
            phaseOffset: phaseOffset,
            seed: seed
        )
    }

    private func localWidth(_ sample: StrokeSample, index: Int, count: Int, brush: BrushSettings) -> CGFloat {
        let pressure = 1 + (sample.pressure - 0.5) * brush.pressureSize
        let tilt = 1 + sample.tilt * brush.tiltResponse * 0.5
        let progress = count > 1 ? Double(index) / Double(count - 1) : 0.5
        let taperZone = 0.15
        let taper: Double
        if progress < taperZone {
            taper = brush.resolvedStartWidthScale + (1 - brush.resolvedStartWidthScale) * progress / taperZone
        } else if progress > 1 - taperZone {
            taper = 1 + (brush.resolvedEndWidthScale - 1) * (progress - (1 - taperZone)) / taperZone
        } else {
            taper = 1
        }
        return max(0.35, brush.size * pressure * tilt * taper)
    }

    @discardableResult
    private func appendToChunks(_ vertices: [Vertex]) -> Range {
        guard !vertices.isEmpty else { return Range(chunkIndex: 0, byteOffset: 0, vertexCount: 0) }
        let byteCount = vertices.count * MemoryLayout<Vertex>.stride
        if chunks.isEmpty || chunks[chunks.count - 1].usedBytes + byteCount > chunks[chunks.count - 1].buffer.length {
            guard let buffer = device.makeBuffer(length: max(chunkSize, byteCount), options: .storageModeShared) else {
                return Range(chunkIndex: 0, byteOffset: 0, vertexCount: 0)
            }
            buffer.label = "Outline Fill Geometry \(chunks.count)"
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

    private func append(_ range: Range, to ranges: inout [UUID: [Range]], layerID: UUID) {
        var layerRanges = ranges[layerID, default: []]
        if let last = layerRanges.last,
           last.chunkIndex == range.chunkIndex,
           last.byteOffset + last.vertexCount * MemoryLayout<Vertex>.stride == range.byteOffset {
            layerRanges[layerRanges.count - 1].vertexCount += range.vertexCount
        } else {
            layerRanges.append(range)
        }
        ranges[layerID] = layerRanges
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 normal;
        float2 uv;
        float4 color;
        float4 parameters;
        float halfWidth;
        float totalLength;
        float phaseOffset;
        uint seed;
    };

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

    struct VertexOut {
        float4 position [[position]];
        float2 canvasPosition;
        float2 uv;
        float4 color;
        float halfWidth;
        float totalLength;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    vertex VertexOut outlineFillVertex(
        uint id [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]) {
        VertexIn input = vertices[id];
        float2 point = input.position;
        float fillHalf = max(1.0, input.parameters.y);
        float progress = clamp(input.uv.x / max(0.001, input.totalLength), 0.0, 1.0);
        float envelope = pow(max(0.0, sin(3.14159265 * progress)), 0.25);

        // Animated organic wobble, coherent for outline and fill ribbons.
        float seedHash = fract(sin(input.seed * 0.618034 + 1.0) * 43758.5453);
        float spatial = input.uv.x / max(24.0, fillHalf * 2.0) * 6.2831853;
        float wobbleAmplitude = input.parameters.z * max(4.0, fillHalf * 0.9);
        float wobbleOffset = sin(spatial + (u.phase + input.phaseOffset) * 6.2831853 * max(0.001, input.parameters.w) + seedHash) * wobbleAmplitude * envelope;
        point += input.normal * wobbleOffset;

        // Global wave, gated by wave strength and scaled by the fill half width.
        if (dot(input.normal, input.normal) > 0.000001 && u.waveAmount > 0.0001 && input.parameters.x > 0.0001 && input.totalLength > 0.001) {
            float amplitude = input.parameters.x * u.waveAmount * max(8.0, fillHalf * 1.1);
            float wavelength = max(72.0, fillHalf * 10.0);
            float angle = input.uv.x / wavelength * 6.2831853 - u.phase * 6.2831853;
            point += input.normal * (sin(angle) * amplitude * envelope);
        }

        VertexOut out;
        out.position = float4(canvasToClip(point, u), 0, 1);
        out.canvasPosition = point;
        out.uv = input.uv;
        out.color = input.color;
        out.halfWidth = input.halfWidth;
        out.totalLength = input.totalLength;
        return out;
    }

    fragment float4 outlineFillFragment(VertexOut input [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        if (input.canvasPosition.x < 0.0 || input.canvasPosition.y < 0.0
            || input.canvasPosition.x > u.canvasSize.x || input.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }
        float hw = max(0.001, input.halfWidth);
        float axial = input.uv.x < 0.0 ? -input.uv.x / hw
            : (input.uv.x > input.totalLength
                ? (input.uv.x - input.totalLength) / hw : 0.0);
        float bandDistance = axial > 0.0
            ? length(float2(axial, input.uv.y)) - 1.0
            : abs(input.uv.y) - 1.0;
        float edgeAntialias = max(0.001, fwidth(bandDistance));
        float bandAlpha = 1.0 - smoothstep(-edgeAntialias, edgeAntialias, bandDistance);
        float alpha = bandAlpha * input.color.a;
        if (alpha <= 0.002) {
            discard_fragment();
        }
        return float4(input.color.rgb, alpha);
    }
    """#
}