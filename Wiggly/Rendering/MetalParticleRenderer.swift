import MetalKit
import simd

/// Live GPU renderer for the particle brush. Stroke strips are cached as
/// ribbon geometry; the fragment shader draws a faint trail along the arc
/// length and a stream of glowing particles (core + halo + comet tail) that
/// travel down the path from the animation phase, so no per-particle geometry
/// or CPU re-raster is needed per frame.
final class MetalParticleRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var trailColor: SIMD4<Float>
        var parameters: SIMD4<Float>
        var halfWidth: Float
        var totalLength: Float
        var phaseOffset: Float
        var cornerRadius: Float
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
    private lazy var previewRing = MetalLiveBufferRing(device: device, label: "Particle Live Stroke")
    private var previewVertexCount = 0
    private var previewKey: PreviewKey?
    private var strokePhaseRandomized = false

    /// When randomized each stroke bakes a fixed phase offset (from its id)
    /// into its vertices so it animates independently instead of in lockstep.
    /// Toggling the mode rebuilds the cached geometry.
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
            guard let vertex = library.makeFunction(name: "particleVertex"),
                  let fragment = library.makeFunction(name: "particleFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Particle Brush"
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
            assertionFailure("Unable to create Particle Metal pipeline: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .particle && stroke.usesGPUAnimatedRenderer {
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

    /// Encodes committed strokes for a single layer so the canvas can
    /// interleave CPU and GPU content in layer order.
    func encode(
        encoder: MTLRenderCommandEncoder,
        transform: ViewTransform,
        layerID: UUID
    ) {
        let ranges = layerRanges[layerID] ?? []
        guard !ranges.isEmpty else { return }
        encoder.pushDebugGroup("Particle Brush")
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
        encoder.label = "Particle Brush Preview"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .particle, let last = stroke.samples.last else {
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
        let points = samples.map { transform($0.point) }

        let averageSize = CGFloat(max(1, brush.size * Double(scale)))
        // The comet is a constant-width stroke, so the ribbon half-width is the
        // stroke radius. Both ends are extended along the tangent so the round
        // caps (and the segment sliding past the ends) have geometry to cover
        // those regions.
        let halfWidth = averageSize * 0.5
        let capExtension = brush.resolvedEndStyle == .rounded ? halfWidth : 0

        // Extend both ends along the tangent so round caps and the particles
        // sliding past the ends have ribbon geometry to cover those regions.
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

        // uv.x spans [-halfWidth, totalLength + halfWidth]; the real stroke is [0, totalLength].
        let totalLength = Float(distances[extended.count - 2] - capExtension)
        // Reproduce the CPU comet: the whole stroke is drawn as a constant-width
        // trail (dash background color) with a solid segment of the main color
        // sliding down the path.
        let particleLength = min(
            Double(totalLength) * 0.45,
            max(Double(brush.size * 0.35), Double(brush.size * (0.35 + brush.resolvedParticleLength * 4)))
        )
        let activeDuration = max(0.05, 1 - brush.resolvedParticleDelay)
        let particleCycles = max(1, (brush.resolvedParticleSpeed * 2.5).rounded())
        let parameters = SIMD4<Float>(
            Float(particleLength),
            Float(activeDuration),
            Float(particleCycles),
            Float(max(1, brush.loopCycles))
        )
        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let trail = brush.resolvedDashBackgroundColor
        let trailColor = SIMD4<Float>(
            Float(trail.red), Float(trail.green), Float(trail.blue),
            Float(trail.alpha * brush.opacity * opacity)
        )
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        let cornerRadius = Float(brush.resolvedDashCornerRadius)

        vertices.reserveCapacity(vertices.count + (extended.count - 1) * 6)
        for index in 1..<extended.count {
            let start = extended[index - 1]
            let end = extended[index]
            let startNormal = normals[index - 1]
            let endNormal = normals[index]
            let startWaveNormal = CGPoint(x: startNormal.x * waveStrength, y: startNormal.y * waveStrength)
            let endWaveNormal = CGPoint(x: endNormal.x * waveStrength, y: endNormal.y * waveStrength)
            let sl = CGPoint(x: start.x + startNormal.x * halfWidth, y: start.y + startNormal.y * halfWidth)
            let sr = CGPoint(x: start.x - startNormal.x * halfWidth, y: start.y - startNormal.y * halfWidth)
            let el = CGPoint(x: end.x + endNormal.x * halfWidth, y: end.y + endNormal.y * halfWidth)
            let er = CGPoint(x: end.x - endNormal.x * halfWidth, y: end.y - endNormal.y * halfWidth)
            let a = vertex(sl, normal: startWaveNormal, distance: distances[index - 1] - capExtension, across: -1, color: color, trailColor: trailColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, cornerRadius: cornerRadius)
            let b = vertex(sr, normal: startWaveNormal, distance: distances[index - 1] - capExtension, across: 1, color: color, trailColor: trailColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, cornerRadius: cornerRadius)
            let c = vertex(el, normal: endWaveNormal, distance: distances[index] - capExtension, across: -1, color: color, trailColor: trailColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, cornerRadius: cornerRadius)
            let d = vertex(er, normal: endWaveNormal, distance: distances[index] - capExtension, across: 1, color: color, trailColor: trailColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, cornerRadius: cornerRadius)
            vertices.append(contentsOf: [a, b, c, c, b, d])
        }
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: Float,
        color: SIMD4<Float>,
        trailColor: SIMD4<Float>,
        parameters: SIMD4<Float>,
        halfWidth: CGFloat,
        totalLength: Float,
        phaseOffset: Float,
        cornerRadius: Float
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), across),
            color: color,
            trailColor: trailColor,
            parameters: parameters,
            halfWidth: Float(halfWidth),
            totalLength: totalLength,
            phaseOffset: phaseOffset,
            cornerRadius: cornerRadius
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
            buffer.label = "Particle Geometry \(chunks.count)"
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

    private func makeBuffer(_ vertices: [Vertex]) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        return vertices.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 normal;
        float2 uv;
        float4 color;
        float4 trailColor;
        float4 parameters;
        float halfWidth;
        float totalLength;
        float phaseOffset;
        float cornerRadius;
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
        float4 trailColor;
        float4 parameters;
        float halfWidth;
        float totalLength;
        float phaseOffset;
        float cornerRadius;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    vertex VertexOut particleVertex(
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
        out.trailColor = input.trailColor;
        out.parameters = input.parameters;
        out.halfWidth = input.halfWidth;
        out.totalLength = input.totalLength;
        out.phaseOffset = input.phaseOffset;
        out.cornerRadius = input.cornerRadius;
        return out;
    }

    // Port of the CPU ParticleKernel: a constant-width trail (dash background
    // color) over the whole stroke, with a solid segment of the main color
    // sliding down the path, including the delay/overshoot traversal math.
    fragment float4 particleFragment(
        VertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(1)]]) {
        if (in.canvasPosition.x < 0.0 || in.canvasPosition.y < 0.0
            || in.canvasPosition.x > u.canvasSize.x || in.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }

        float halfWidth = in.halfWidth;
        float total = in.totalLength;
        float qx = in.uv.x;
        float across = in.uv.y;
        float aa = max(0.75, fwidth(in.uv.x));

        // The base is a constant-width trail strip (dash background color)
        // covering the whole stroke, matching the CPU ParticleKernel. The
        // moving solid segment of the main color slides down the path on top.
        // `across` is normalized to -1...1, so a 0.75 minimum softened most
        // of the ribbon. Restrict antialiasing to the final edge pixel.
        float baseAxial = qx < 0.0 ? -qx
            : (qx > total ? qx - total : 0.0);
        float baseDistance = baseAxial > 0.0
            ? length(float2(baseAxial, across * halfWidth)) - halfWidth
            : abs(across * halfWidth) - halfWidth;
        float stripAlpha = in.trailColor.a
            * (1.0 - smoothstep(-aa, aa, baseDistance));

        float particleLength = in.parameters.x;
        float activeDuration = in.parameters.y;
        float cycles = max(1.0, in.parameters.z);
        float loopCycles = max(1.0, in.parameters.w);

        float unit = fract((u.phase + in.phaseOffset) * loopCycles * cycles);
        float overshoot = particleLength / max(0.001, total);
        float travel;
        if (unit < activeDuration) {
            travel = unit / activeDuration;
        } else {
            travel = 1.0 + (unit - activeDuration) / max(0.05, 1.0 - activeDuration) * overshoot;
        }
        float centerDistance = travel * total;
        float start = max(0.0, centerDistance - particleLength * 0.5);
        float end = min(total, centerDistance + particleLength * 0.5);
        float segmentHalfLength = max(0.0, (end - start) * 0.5);
        float segmentRadius = min(segmentHalfLength, halfWidth) * in.cornerRadius;
        float2 segmentPoint = float2(qx - (start + end) * 0.5, across * halfWidth);
        float2 segmentBox = float2(segmentHalfLength, halfWidth);
        float2 segmentQ = abs(segmentPoint) - segmentBox + segmentRadius;
        float segmentDistance = length(max(segmentQ, 0.0))
            + min(max(segmentQ.x, segmentQ.y), 0.0) - segmentRadius;
        float segment = 1.0 - smoothstep(-aa, aa, segmentDistance);
        float beadAlpha = in.color.a * segment;

        // The moving comet wins where it overlaps the trailing strip.
        float alpha = max(beadAlpha, stripAlpha);
        if (alpha <= 0.001) discard_fragment();
        float beadWeight = clamp(beadAlpha / max(0.001, in.color.a), 0.0, 1.0);
        float3 rgb = mix(in.trailColor.rgb, in.color.rgb, beadWeight);
        return float4(rgb * alpha, alpha);
    }
    """#
}
