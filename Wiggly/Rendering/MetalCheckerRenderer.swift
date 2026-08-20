import MetalKit
import simd

/// Live GPU renderer for the Checker brush. Stroke ribbons are cached as
/// geometry; the fragment shader paints a four-color, two-row checkerboard over
/// the band and moves it from each stroke's start toward its end.
final class MetalCheckerRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var backgroundColor: SIMD4<Float>
        var tertiaryColor: SIMD4<Float>
        var quaternaryColor: SIMD4<Float>
        var halfWidth: Float
        var totalLength: Float
        var phaseOffset: Float
        var speed: Float
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
    private var layerRanges: [UUID: [Range]] = [:]
    private var previewBuffer: MTLBuffer?
    private lazy var previewRing = MetalLiveBufferRing(device: device, label: "Checker Live Stroke")
    private var previewVertexCount = 0
    private var previewKey: PreviewKey?
    private var strokePhaseRandomized = false

    func setStrokePhaseRandomized(_ value: Bool) {
        guard value != strokePhaseRandomized else { return }
        strokePhaseRandomized = value
        chunks.removeAll(keepingCapacity: true)
        strokeKeys.removeAll(keepingCapacity: true)
        layerRanges.removeAll(keepingCapacity: true)
        previewBuffer = nil
        previewVertexCount = 0
        previewKey = nil
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let vertex = library.makeFunction(name: "checkerVertex"),
                  let fragment = library.makeFunction(name: "checkerFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Checker Brush"
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
            assertionFailure("Unable to create Checker Metal pipeline: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .checker && stroke.usesGPUAnimatedRenderer {
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
        previewBuffer = nil
        previewVertexCount = 0
        previewKey = nil
    }

    func encode(
        encoder: MTLRenderCommandEncoder,
        transform: ViewTransform,
        layerID: UUID
    ) {
        let ranges = layerRanges[layerID] ?? []
        guard !ranges.isEmpty else { return }
        encoder.pushDebugGroup("Checker Brush")
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
        encoder.label = "Checker Brush Preview"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .checker, let last = stroke.samples.last else {
            previewBuffer = nil
            previewVertexCount = 0
            previewKey = nil
            return
        }
        let key = PreviewKey(sampleCount: stroke.samples.count, lastX: last.x, lastY: last.y, brush: stroke.brush)
        guard key != previewKey else { return }
        previewKey = key
        var vertices: [Vertex] = []
        append(stroke: stroke, opacity: 1, scale: 1, transform: { $0 }, to: &vertices)
        previewVertexCount = vertices.count
        previewBuffer = previewRing.write(vertices)
    }

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
        let waveStrength = CGFloat(brush.resolvedWaveAmount / 100)
        func waveNormal(_ normal: CGPoint) -> CGPoint {
            CGPoint(x: normal.x * waveStrength, y: normal.y * waveStrength)
        }
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
        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let checkerBackground = brush.resolvedDashBackgroundColor
        let backgroundColor = SIMD4<Float>(
            Float(checkerBackground.red), Float(checkerBackground.green), Float(checkerBackground.blue),
            Float(checkerBackground.alpha * brush.opacity * opacity)
        )
        let tertiary = brush.resolvedTertiaryColor
        let tertiaryColor = SIMD4<Float>(
            Float(tertiary.red), Float(tertiary.green), Float(tertiary.blue),
            Float(tertiary.alpha * brush.opacity * opacity)
        )
        let quaternary = brush.resolvedQuaternaryColor
        let quaternaryColor = SIMD4<Float>(
            Float(quaternary.red), Float(quaternary.green), Float(quaternary.blue),
            Float(quaternary.alpha * brush.opacity * opacity)
        )
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        let cycles = Float(brush.resolvedCheckerCyclesPerLoop)

        vertices.reserveCapacity(vertices.count + (samples.count + 1) * 6)
        for index in 1..<samples.count {
            let start = points[index - 1]
            let end = points[index]
            let startNormal = normals[index - 1]
            let endNormal = normals[index]
            let startHalf = widths[index - 1] / 2
            let endHalf = widths[index] / 2
            let sl = CGPoint(x: start.x + startNormal.x * startHalf, y: start.y + startNormal.y * startHalf)
            let sr = CGPoint(x: start.x - startNormal.x * startHalf, y: start.y - startNormal.y * startHalf)
            let el = CGPoint(x: end.x + endNormal.x * endHalf, y: end.y + endNormal.y * endHalf)
            let er = CGPoint(x: end.x - endNormal.x * endHalf, y: end.y - endNormal.y * endHalf)
            let a = vertex(sl, normal: waveNormal(startNormal), distance: distances[index - 1], across: -1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
            let b = vertex(sr, normal: waveNormal(startNormal), distance: distances[index - 1], across: 1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
            let c = vertex(el, normal: waveNormal(endNormal), distance: distances[index], across: -1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
            let d = vertex(er, normal: waveNormal(endNormal), distance: distances[index], across: 1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
            vertices.append(contentsOf: [a, b, c, c, b, d])
        }

        if brush.resolvedEndStyle == .rounded {
        // Give the checker ribbon real geometry beyond both recorded endpoints;
        // the fragment capsule below trims these quads into round caps.
        let first = points[0]
        let second = points[1]
        let startLength = max(0.001, hypot(second.x - first.x, second.y - first.y))
        let startDirection = CGPoint(x: (second.x - first.x) / startLength, y: (second.y - first.y) / startLength)
        let startNormal = normals[0]
        let startHalf = widths[0] / 2
        let capStart = CGPoint(x: first.x - startDirection.x * startHalf, y: first.y - startDirection.y * startHalf)
        let startOuterLeft = CGPoint(x: capStart.x + startNormal.x * startHalf, y: capStart.y + startNormal.y * startHalf)
        let startOuterRight = CGPoint(x: capStart.x - startNormal.x * startHalf, y: capStart.y - startNormal.y * startHalf)
        let startInnerLeft = CGPoint(x: first.x + startNormal.x * startHalf, y: first.y + startNormal.y * startHalf)
        let startInnerRight = CGPoint(x: first.x - startNormal.x * startHalf, y: first.y - startNormal.y * startHalf)
        let sa = vertex(startOuterLeft, normal: waveNormal(startNormal), distance: -startHalf, across: -1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        let sb = vertex(startOuterRight, normal: waveNormal(startNormal), distance: -startHalf, across: 1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        let sc = vertex(startInnerLeft, normal: waveNormal(startNormal), distance: 0, across: -1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        let sd = vertex(startInnerRight, normal: waveNormal(startNormal), distance: 0, across: 1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        vertices.append(contentsOf: [sa, sb, sc, sc, sb, sd])

        let last = points[points.count - 1]
        let previous = points[points.count - 2]
        let endLength = max(0.001, hypot(last.x - previous.x, last.y - previous.y))
        let endDirection = CGPoint(x: (last.x - previous.x) / endLength, y: (last.y - previous.y) / endLength)
        let endNormal = normals[normals.count - 1]
        let endHalf = widths[widths.count - 1] / 2
        let capEnd = CGPoint(x: last.x + endDirection.x * endHalf, y: last.y + endDirection.y * endHalf)
        let endInnerLeft = CGPoint(x: last.x + endNormal.x * endHalf, y: last.y + endNormal.y * endHalf)
        let endInnerRight = CGPoint(x: last.x - endNormal.x * endHalf, y: last.y - endNormal.y * endHalf)
        let endOuterLeft = CGPoint(x: capEnd.x + endNormal.x * endHalf, y: capEnd.y + endNormal.y * endHalf)
        let endOuterRight = CGPoint(x: capEnd.x - endNormal.x * endHalf, y: capEnd.y - endNormal.y * endHalf)
        let ea = vertex(endInnerLeft, normal: waveNormal(endNormal), distance: CGFloat(totalLength), across: -1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        let eb = vertex(endInnerRight, normal: waveNormal(endNormal), distance: CGFloat(totalLength), across: 1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        let ec = vertex(endOuterLeft, normal: waveNormal(endNormal), distance: CGFloat(totalLength) + endHalf, across: -1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        let ed = vertex(endOuterRight, normal: waveNormal(endNormal), distance: CGFloat(totalLength) + endHalf, across: 1, color: color, backgroundColor: backgroundColor, tertiaryColor: tertiaryColor, quaternaryColor: quaternaryColor, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset, speed: cycles)
        vertices.append(contentsOf: [ea, eb, ec, ec, eb, ed])
        }
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: Float,
        color: SIMD4<Float>,
        backgroundColor: SIMD4<Float>,
        tertiaryColor: SIMD4<Float>,
        quaternaryColor: SIMD4<Float>,
        halfWidth: CGFloat,
        totalLength: Float,
        phaseOffset: Float,
        speed: Float
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), across),
            color: color,
            backgroundColor: backgroundColor,
            tertiaryColor: tertiaryColor,
            quaternaryColor: quaternaryColor,
            halfWidth: Float(halfWidth),
            totalLength: totalLength,
            phaseOffset: phaseOffset,
            speed: speed
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
            buffer.label = "Checker Geometry \(chunks.count)"
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

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 normal;
        float2 uv;
        float4 color;
        float4 backgroundColor;
        float4 tertiaryColor;
        float4 quaternaryColor;
        float halfWidth;
        float totalLength;
        float phaseOffset;
        float speed;
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
        float4 backgroundColor;
        float4 tertiaryColor;
        float4 quaternaryColor;
        float halfWidth;
        float totalLength;
        float phaseOffset;
        float speed;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    vertex VertexOut checkerVertex(
        uint id [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]) {
        VertexIn input = vertices[id];
        VertexOut out;
        float2 point = input.position;
        if (dot(input.normal, input.normal) > 0.000001 && u.waveAmount > 0.0001 && input.totalLength > 0.001) {
            float progress = clamp(input.uv.x / input.totalLength, 0.0, 1.0);
            float envelope = pow(max(0.0, sin(3.14159265 * progress)), 0.35);
            float amplitude = u.waveAmount * max(8.0, input.halfWidth * 1.1);
            float wavelength = max(72.0, input.halfWidth * 10.0);
            float angle = input.uv.x / wavelength * 6.2831853 - u.phase * 6.2831853;
            point += input.normal * (sin(angle) * amplitude * envelope);
        }
        out.position = float4(canvasToClip(point, u), 0, 1);
        out.canvasPosition = point;
        out.uv = input.uv;
        out.color = input.color;
        out.backgroundColor = input.backgroundColor;
        out.tertiaryColor = input.tertiaryColor;
        out.quaternaryColor = input.quaternaryColor;
        out.halfWidth = input.halfWidth;
        out.totalLength = input.totalLength;
        out.phaseOffset = input.phaseOffset;
        out.speed = input.speed;
        return out;
    }

    // Two rows of square checkers across the ribbon width. UV.x is accumulated
    // path distance, so decreasing the sampled coordinate moves cells from the
    // recorded start of the stroke toward its recorded end, even on curves.
    fragment float4 checkerFragment(VertexOut input [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        if (input.canvasPosition.x < 0.0 || input.canvasPosition.y < 0.0
            || input.canvasPosition.x > u.canvasSize.x || input.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }
        float cell = max(0.1, input.halfWidth);
        float motionPhase = fract(u.phase + input.phaseOffset);
        float travelled = input.uv.x - motionPhase * cell * 2.0 * input.speed;
        int col = int(floor(travelled / cell));
        int parity = ((col % 2) + 2) % 2;
        int row = input.uv.y >= 0.0 ? 1 : 0;
        int paletteIndex = parity + row * 2;
        float4 fill = paletteIndex == 0 ? input.color
            : (paletteIndex == 1 ? input.backgroundColor
            : (paletteIndex == 2 ? input.tertiaryColor : input.quaternaryColor));
        // Capsule distance gives the checker a true rounded start and end while
        // keeping its long sides solid and sharply antialiased.
        float axial = input.uv.x < 0.0 ? -input.uv.x / cell
            : (input.uv.x > input.totalLength
                ? (input.uv.x - input.totalLength) / cell : 0.0);
        float bandDistance = axial > 0.0
            ? length(float2(axial, input.uv.y)) - 1.0
            : abs(input.uv.y) - 1.0;
        float edgeAntialias = max(0.001, fwidth(bandDistance));
        float bandAlpha = 1.0 - smoothstep(-edgeAntialias, edgeAntialias, bandDistance);
        fill.a *= bandAlpha;
        fill.a = fill.a < 0.02 ? 0.0 : fill.a;
        return fill;
    }
    """#
}
