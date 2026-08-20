import MetalKit
import simd

/// Live GPU renderer for the star brush. Stroke strips are cached as ribbon
/// geometry; the fragment shader draws the solid strip with rounded caps and
/// paints the animated pentagram stars (radial gradient, rotation) from arc
/// length, so no per-star geometry or CPU re-raster is needed per frame.
final class MetalStarRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var gradientColor: SIMD4<Float>
        var stripColor: SIMD4<Float>
        var parameters: SIMD4<Float>
        var halfWidth: Float
        var totalLength: Float
        var phaseOffset: Float
        var rotationMode: Float
        var gradientMode: Float
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
    private lazy var previewRing = MetalLiveBufferRing(device: device, label: "Star Live Stroke")
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
            guard let vertex = library.makeFunction(name: "starVertex"),
                  let fragment = library.makeFunction(name: "starFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Star Brush"
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
            assertionFailure("Unable to create Star Metal pipeline: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .star && stroke.usesGPUAnimatedRenderer {
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
        encoder.pushDebugGroup("Star Brush")
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
        encoder.label = "Star Brush Preview"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .star, let last = stroke.samples.last else {
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
        let starDiameter = averageSize * CGFloat(1 + brush.resolvedDashLength * 4)
        let halfWidth = starDiameter * 0.65
        let capExtension = brush.resolvedEndStyle == .rounded ? halfWidth : 0

        // Extend both ends along the tangent so the round caps and the stars
        // sliding around them have ribbon geometry to cover those regions.
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
        let gap = Float(max(0.5, brush.resolvedDashGap) * Double(scale))
        let pattern = Float(starDiameter) + gap
        let cycles = Float(brush.resolvedDashCyclesPerLoop * Double(max(1, brush.loopCycles)))
        let parameters = SIMD4<Float>(
            Float(starDiameter),
            pattern,
            Float(brush.resolvedStarRotationCyclesPerLoop),
            cycles
        )
        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let tertiary = brush.resolvedTertiaryColor
        let gradientColor = SIMD4<Float>(
            Float(tertiary.red), Float(tertiary.green), Float(tertiary.blue),
            Float(tertiary.alpha * brush.opacity * opacity)
        )
        let strip = brush.resolvedDashBackgroundColor
        let stripColor = SIMD4<Float>(
            Float(strip.red), Float(strip.green), Float(strip.blue),
            Float(strip.alpha * brush.opacity * opacity)
        )
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        let rotationMode: Float = brush.resolvedStarRotationMode == .random ? 1 : 0
        let gradientMode: Float = brush.resolvedStarGradientAcrossStroke ? 1 : 0
        let seed = UInt32(truncatingIfNeeded: brush.seed)

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
            let a = vertex(sl, normal: startWaveNormal, distance: distances[index - 1] - capExtension, across: -1, color: color, gradientColor: gradientColor, stripColor: stripColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, rotationMode: rotationMode, gradientMode: gradientMode, seed: seed)
            let b = vertex(sr, normal: startWaveNormal, distance: distances[index - 1] - capExtension, across: 1, color: color, gradientColor: gradientColor, stripColor: stripColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, rotationMode: rotationMode, gradientMode: gradientMode, seed: seed)
            let c = vertex(el, normal: endWaveNormal, distance: distances[index] - capExtension, across: -1, color: color, gradientColor: gradientColor, stripColor: stripColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, rotationMode: rotationMode, gradientMode: gradientMode, seed: seed)
            let d = vertex(er, normal: endWaveNormal, distance: distances[index] - capExtension, across: 1, color: color, gradientColor: gradientColor, stripColor: stripColor, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, phaseOffset: phaseOffset, rotationMode: rotationMode, gradientMode: gradientMode, seed: seed)
            vertices.append(contentsOf: [a, b, c, c, b, d])
        }
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: Float,
        color: SIMD4<Float>,
        gradientColor: SIMD4<Float>,
        stripColor: SIMD4<Float>,
        parameters: SIMD4<Float>,
        halfWidth: CGFloat,
        totalLength: Float,
        phaseOffset: Float,
        rotationMode: Float,
        gradientMode: Float,
        seed: UInt32
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), across),
            color: color,
            gradientColor: gradientColor,
            stripColor: stripColor,
            parameters: parameters,
            halfWidth: Float(halfWidth),
            totalLength: totalLength,
            phaseOffset: phaseOffset,
            rotationMode: rotationMode,
            gradientMode: gradientMode,
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
            buffer.label = "Star Geometry \(chunks.count)"
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
        float4 gradientColor;
        float4 stripColor;
        float4 parameters;
        float halfWidth;
        float totalLength;
        float phaseOffset;
        float rotationMode;
        float gradientMode;
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
        float4 gradientColor;
        float4 stripColor;
        float4 parameters;
        float halfWidth;
        float totalLength;
        float phaseOffset;
        float rotationMode;
        float gradientMode;
        uint seed;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    // Signed distance to a 5-pointed star with outer radius r and inner ratio
    // rf; with rotation 0 a vertex points along +y.
    float sdStar5(float2 p, float r, float rf) {
        const float2 k1 = float2(0.809016994375, -0.587785252292);
        const float2 k2 = float2(-k1.x, k1.y);
        p.x = abs(p.x);
        p -= 2.0 * max(dot(k1, p), 0.0) * k1;
        p -= 2.0 * max(dot(k2, p), 0.0) * k2;
        p.x = abs(p.x);
        p.y -= r;
        float2 ba = rf * float2(-k1.y, k1.x) - float2(0.0, 1.0);
        float h = clamp(dot(p, ba) / dot(ba, ba), 0.0, r);
        return length(p - ba * h) * sign(p.y * ba.x - p.x * ba.y);
    }

    uint hash32(uint value) {
        value ^= value >> 16;
        value *= 0x7FEB352Du;
        value ^= value >> 15;
        value *= 0x846CA68Bu;
        value ^= value >> 16;
        return value;
    }

    // A 32-bit seed is baked into every stroke. Keep random star rotation in
    // native 32-bit integer ALU instead of emulating 64-bit math per fragment.
    float seededRandom(uint seed, int index) {
        uint key = seed + uint(max(index, 0)) * 0x9E3779B9u;
        return float(hash32(key)) * (1.0 / 4294967295.0);
    }

    vertex VertexOut starVertex(
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
        out.gradientColor = input.gradientColor;
        out.stripColor = input.stripColor;
        out.parameters = input.parameters;
        out.halfWidth = input.halfWidth;
        out.totalLength = input.totalLength;
        out.phaseOffset = input.phaseOffset;
        out.rotationMode = input.rotationMode;
        out.gradientMode = input.gradientMode;
        out.seed = input.seed;
        return out;
    }

    fragment float4 starFragment(
        VertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(1)]]) {
        if (in.canvasPosition.x < 0.0 || in.canvasPosition.y < 0.0
            || in.canvasPosition.x > u.canvasSize.x || in.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }

        // Solid strip with rounded caps over the real stroke [0, totalLength].
        float halfWidth = in.halfWidth;
        float2 q = float2(in.uv.x, in.uv.y * halfWidth);
        float clamped = clamp(q.x, 0.0, in.totalLength);
        float stripDist = length(q - float2(clamped, 0.0)) - halfWidth;
        float stripAA = max(0.75, fwidth(in.uv.x));
        float stripAlpha = 1.0 - smoothstep(-stripAA, stripAA, stripDist);
        if (stripAlpha <= 0.001) discard_fragment();

        float starDiameter = max(0.5, in.parameters.x);
        float pattern = max(starDiameter, in.parameters.y);
        float cycles = max(1.0, in.parameters.w);
        float phaseFull = (u.phase + in.phaseOffset) * cycles;
        float shift = fract(phaseFull) * pattern;
        // Star centers are measured along the extended path from its start,
        // which is `overhang` (= pattern * 1.5) before the real stroke start
        // (uv.x == 0), matching the CPU kernel's station() convention.
        float overhang = pattern * 1.5;
        float moved = in.uv.x + overhang - shift;
        float local = fmod(moved, pattern);
        if (local < 0.0) local += pattern;
        int starIndex = int(floor(moved / pattern));

        float3 rgb = in.stripColor.rgb;
        float colorAlpha = in.stripColor.a;

        if (local <= starDiameter) {
            float outer = starDiameter * 0.5;
            float px = local - starDiameter * 0.5;
            float py = in.uv.y * halfWidth;
            float spin = (u.phase + in.phaseOffset) * 6.2831853 * in.parameters.z;
            float offset = in.rotationMode > 0.5 ? seededRandom(in.seed + 5999u, starIndex) * 6.2831853 : 0.0;
            float rotation = spin + offset;
            // sdStar5 points +y at 0; rotate so a star vertex follows the path
            // tangent (rotation measured from +x), matching the CPU kernel.
            float angle = 1.5707963 - rotation;
            float c = cos(angle);
            float s = sin(angle);
            float2 rp = float2(px * c - py * s, px * s + py * c);
            float sd = sdStar5(rp, outer, 0.48);
            float starAA = max(0.5, fwidth(in.uv.x));
            float starCover = 1.0 - smoothstep(-starAA, starAA, sd);
            if (starCover > 0.001) {
                float t = in.gradientMode > 0.5
                    ? clamp(in.uv.x / max(in.totalLength, 0.001), 0.0, 1.0)
                    : clamp(length(float2(px, py)) / outer, 0.0, 1.0);
                rgb = mix(in.color.rgb, in.gradientColor.rgb, t);
                colorAlpha = mix(in.color.a, in.gradientColor.a, t);
            }
        }

        float finalAlpha = stripAlpha * colorAlpha;
        if (finalAlpha <= 0.001) discard_fragment();
        return float4(rgb, finalAlpha);
    }
    """#
}
