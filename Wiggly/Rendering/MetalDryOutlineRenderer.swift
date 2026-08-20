import MetalKit
import simd

/// Grainy Ink GPU renderer. The opaque ink body stays stable while only the
/// fine grains around its outside silhouette animate.
final class MetalDryOutlineRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var parameters: SIMD4<Float>
        var normal: SIMD2<Float>
        var seed: Float
        var mode: Float
        var phaseOffset: Float
    }

    struct ViewTransform {
        var canvasSize: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var fittedSize: SIMD2<Float>
        var centerOffset: SIMD2<Float>
        var zoom: Float
        var rotation: Float
        var phase: Float
        var padding: Float = 0
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let chunkByteCount = 4 * 1024 * 1024
    private struct GeometryChunk {
        var buffer: MTLBuffer
        var usedBytes: Int
        var vertexCount: Int
    }
    /// A contiguous run of committed vertices inside one chunk buffer.
    private struct Range {
        var chunkIndex: Int
        var byteOffset: Int
        var vertexCount: Int
    }
    private struct StrokeKey: Equatable {
        var id: UUID
        var sampleCount: Int
        var lastX: Double
        var lastY: Double
        var lastTimestamp: Double
        var brush: BrushSettings
        var layerOpacity: Double
        var layerScale: Double
        var layerOffset: CGPoint
    }
    private struct StrokeDescriptor {
        var stroke: AnimatedStroke
        var layerID: UUID
        var opacity: Double
        var scale: CGFloat
        var offset: CGPoint
        var key: StrokeKey
    }
    private var completedChunks: [GeometryChunk] = []
    private var completedStrokeKeys: [StrokeKey] = []
    private var layerRanges: [UUID: [Range]] = [:]
    private var previewBuffer: MTLBuffer?
    private lazy var previewRing = MetalLiveBufferRing(device: device, label: "Dry Outline Live Stroke")
    private var previewVertexCount = 0
    private var previewSignature: PreviewSignature?
    private var strokePhaseRandomized = false

    /// When randomized each stroke bakes a fixed phase offset (from its id)
    /// into its vertices so it animates independently instead of in lockstep.
    /// Toggling the mode rebuilds the cached geometry.
    func setStrokePhaseRandomized(_ value: Bool) {
        guard value != strokePhaseRandomized else { return }
        strokePhaseRandomized = value
        completedChunks.removeAll(keepingCapacity: true)
        completedStrokeKeys.removeAll(keepingCapacity: true)
        layerRanges.removeAll(keepingCapacity: true)
        previewBuffer = nil
        previewVertexCount = 0
        previewSignature = nil
    }

    private struct PreviewSignature: Equatable {
        var sampleCount: Int
        var lastX: Double
        var lastY: Double
        var brush: BrushSettings
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "dryOutlineVertex"),
                  let fragment = library.makeFunction(name: "dryOutlineFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Dry Outline GPU"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Unable to create Dry Outline Metal pipeline: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [StrokeDescriptor] = []
        let canvasCenter = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            let layerScale = CGFloat(layer.resolvedContentScale)
            let layerOffset = layer.resolvedContentOffset
            for stroke in layer.strokes where stroke.brush.kind == .dryOutline && stroke.usesGPUAnimatedRenderer {
                guard let last = stroke.samples.last else { continue }
                descriptors.append(StrokeDescriptor(
                    stroke: stroke,
                    layerID: layer.id,
                    opacity: layer.opacity,
                    scale: layerScale,
                    offset: layerOffset,
                    key: StrokeKey(
                        id: stroke.id,
                        sampleCount: stroke.samples.count,
                        lastX: last.x,
                        lastY: last.y,
                        lastTimestamp: last.timestamp,
                        brush: stroke.brush,
                        layerOpacity: layer.opacity,
                        layerScale: layer.resolvedContentScale,
                        layerOffset: layerOffset
                    )
                ))
            }
        }

        let newKeys = descriptors.map(\.key)
        let existingGeometryIsPrefix = completedStrokeKeys.count <= newKeys.count
            && zip(completedStrokeKeys, newKeys).allSatisfy(==)
        let startIndex: Int
        if existingGeometryIsPrefix {
            startIndex = completedStrokeKeys.count
        } else {
            completedChunks.removeAll(keepingCapacity: true)
            layerRanges.removeAll(keepingCapacity: true)
                startIndex = 0
        }
        for descriptor in descriptors.dropFirst(startIndex) {
            var vertices: [Vertex] = []
            let scale = descriptor.scale
            let offset = descriptor.offset
            append(
                stroke: descriptor.stroke,
                opacity: descriptor.opacity,
                pointTransform: { point in
                    CGPoint(
                        x: canvasCenter.x + offset.x + (point.x - canvasCenter.x) * scale,
                        y: canvasCenter.y + offset.y + (point.y - canvasCenter.y) * scale
                    )
                },
                widthScale: scale,
                to: &vertices
            )
            let range = appendToGeometryChunks(vertices)
            if range.vertexCount > 0 {
                append(range, to: descriptor.layerID)
            }
        }
        completedStrokeKeys = newKeys
        previewBuffer = nil
        previewVertexCount = 0
        previewSignature = nil
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
        encoder.pushDebugGroup("Dry Outline Brush")
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        for range in ranges {
            let chunk = completedChunks[range.chunkIndex]
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
        updatePreviewIfNeeded(previewStroke)
        guard let previewBuffer, previewVertexCount > 0 else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Dry Outline GPU Pass"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreviewIfNeeded(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .dryOutline, let last = stroke.samples.last else {
            previewBuffer = nil
            previewVertexCount = 0
            previewSignature = nil
            return
        }
        let signature = PreviewSignature(
            sampleCount: stroke.samples.count,
            lastX: last.x,
            lastY: last.y,
            brush: stroke.brush
        )
        guard signature != previewSignature else { return }
        previewSignature = signature
        var vertices: [Vertex] = []
        append(stroke: stroke, opacity: 1, pointTransform: { $0 }, widthScale: 1, to: &vertices)
        previewVertexCount = vertices.count
        previewBuffer = previewRing.write(vertices)
    }

    private func makeBuffer(_ vertices: [Vertex]) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        return vertices.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: bytes.count, options: .storageModeShared)
        }
    }

    @discardableResult
    private func appendToGeometryChunks(_ vertices: [Vertex]) -> Range {
        guard !vertices.isEmpty else { return Range(chunkIndex: 0, byteOffset: 0, vertexCount: 0) }
        let bytesNeeded = vertices.count * MemoryLayout<Vertex>.stride
        if completedChunks.isEmpty || completedChunks[completedChunks.count - 1].usedBytes + bytesNeeded > completedChunks[completedChunks.count - 1].buffer.length {
            let allocationSize = max(chunkByteCount, bytesNeeded)
            guard let buffer = device.makeBuffer(length: allocationSize, options: .storageModeShared) else {
                return Range(chunkIndex: 0, byteOffset: 0, vertexCount: 0)
            }
            buffer.label = "Dry Outline Geometry \(completedChunks.count)"
            completedChunks.append(GeometryChunk(buffer: buffer, usedBytes: 0, vertexCount: 0))
        }
        let chunkIndex = completedChunks.count - 1
        let byteOffset = completedChunks[chunkIndex].usedBytes
        let destination = completedChunks[chunkIndex].buffer.contents().advanced(by: completedChunks[chunkIndex].usedBytes)
        vertices.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress { destination.copyMemory(from: source, byteCount: bytes.count) }
        }
        completedChunks[chunkIndex].usedBytes += bytesNeeded
        completedChunks[chunkIndex].vertexCount += vertices.count
        return Range(chunkIndex: chunkIndex, byteOffset: byteOffset, vertexCount: vertices.count)
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

    private func append(
        stroke: AnimatedStroke,
        opacity: Double,
        pointTransform: (CGPoint) -> CGPoint,
        widthScale: CGFloat,
        to vertices: inout [Vertex]
    ) {
        let samples = stroke.bakedSamples()
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let points = samples.map { pointTransform($0.point) }
        var widths: [CGFloat] = []
        var normals: [CGPoint] = []
        var distances = Array(repeating: CGFloat.zero, count: samples.count)
        widths.reserveCapacity(samples.count)
        normals.reserveCapacity(samples.count)

        for index in samples.indices {
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, hypot(dx, dy))
            normals.append(CGPoint(x: -dy / length, y: dx / length))
            widths.append(localWidth(sample: samples[index], index: index, count: samples.count, brush: brush) * widthScale)
            if index > 0 { distances[index] = distances[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y) }
        }

        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let borderSpeed = brush.resolvedBorderSpeed
        let borderCycles = borderSpeed < 0.01
            ? 0
            : max(1, (borderSpeed * 2).rounded())
        let parameters = SIMD4<Float>(
            Float(brush.resolvedTextureRoughness),
            Float(brush.resolvedTextureDensity),
            Float(borderCycles),
            Float(max(1, brush.loopCycles))
        )
        let strokeSeed = stableStrokeSeed(stroke.id, base: brush.seed)
        let seed = Float(strokeSeed % 65_521) / 65_521
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        let textureScale = CGFloat(max(4, brush.size))

        vertices.reserveCapacity(vertices.count + max(0, samples.count - 1) * 6)
        for index in 1..<samples.count {
            let start = points[index - 1]
            let end = points[index]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let segmentLength = max(0.001, hypot(dx, dy))
            // One normal per segment prevents the outside edge of a turn from
            // stretching into a long miter. Round stamps below fill the joins.
            let segmentNormal = CGPoint(x: -dy / segmentLength, y: dx / segmentLength)
            let startHalfWidth = widths[index - 1] / 2
            let endHalfWidth = widths[index] / 2
            let startDistance = Float(distances[index - 1] / textureScale)
            let endDistance = Float(distances[index] / textureScale)
            let sl = CGPoint(x: start.x + segmentNormal.x * startHalfWidth, y: start.y + segmentNormal.y * startHalfWidth)
            let sr = CGPoint(x: start.x - segmentNormal.x * startHalfWidth, y: start.y - segmentNormal.y * startHalfWidth)
            let el = CGPoint(x: end.x + segmentNormal.x * endHalfWidth, y: end.y + segmentNormal.y * endHalfWidth)
            let er = CGPoint(x: end.x - segmentNormal.x * endHalfWidth, y: end.y - segmentNormal.y * endHalfWidth)
            let a = vertex(sl, uv: SIMD2(startDistance, -1), color: color, parameters: parameters, normal: segmentNormal, seed: seed, mode: 0, phaseOffset: phaseOffset)
            let b = vertex(sr, uv: SIMD2(startDistance, 1), color: color, parameters: parameters, normal: segmentNormal, seed: seed, mode: 0, phaseOffset: phaseOffset)
            let c = vertex(el, uv: SIMD2(endDistance, -1), color: color, parameters: parameters, normal: segmentNormal, seed: seed, mode: 0, phaseOffset: phaseOffset)
            let d = vertex(er, uv: SIMD2(endDistance, 1), color: color, parameters: parameters, normal: segmentNormal, seed: seed, mode: 0, phaseOffset: phaseOffset)
            vertices.append(contentsOf: [a, b, c, c, b, d])
        }

        // Repeated round shape stamps create clean Procreate-style joins and
        // caps without any long wedges on tight turns.
        for index in points.indices {
            if brush.resolvedEndStyle == .cut,
               index == points.startIndex || index == points.index(before: points.endIndex) {
                continue
            }
            appendCap(
                center: points[index],
                normal: normals[index],
                size: widths[index],
                color: color,
                parameters: parameters,
                seed: seed + Float(random(seed: strokeSeed &+ 2_003, index: index)) * 0.93,
                phaseOffset: phaseOffset,
                to: &vertices
            )
        }

        // The granular silhouette is generated in the fragment shader from a
        // soft circular shape source plus fine moving grain. Detached dots are
        // intentionally avoided; Procreate's result is a powdery falloff.
    }

    private func appendCap(
        center: CGPoint,
        normal: CGPoint,
        size: CGFloat,
        color: SIMD4<Float>,
        parameters: SIMD4<Float>,
        seed: Float,
        phaseOffset: Float,
        to vertices: inout [Vertex]
    ) {
        let corners = [SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1), SIMD2<Float>(-1, 1), SIMD2<Float>(1, 1)]
        let made = corners.map { corner in
            Vertex(
                position: SIMD2(Float(center.x), Float(center.y)),
                uv: corner,
                color: color,
                parameters: parameters,
                normal: SIMD2(Float(normal.x), Float(normal.y)),
                seed: seed,
                mode: 2 + Float(size) / 10_000,
                phaseOffset: phaseOffset
            )
        }
        vertices.append(contentsOf: [made[0], made[1], made[2], made[2], made[1], made[3]])
    }

    private func appendParticle(
        center: CGPoint,
        normal: CGPoint,
        size: CGFloat,
        color: SIMD4<Float>,
        parameters: SIMD4<Float>,
        seed: Float,
        phaseOffset: Float,
        to vertices: inout [Vertex]
    ) {
        let corners = [SIMD2<Float>(-1, -1), SIMD2<Float>(1, -1), SIMD2<Float>(-1, 1), SIMD2<Float>(1, 1)]
        let made = corners.map { corner in
            Vertex(
                position: SIMD2(Float(center.x), Float(center.y)),
                uv: corner,
                color: color,
                parameters: parameters,
                normal: SIMD2(Float(normal.x), Float(normal.y)),
                seed: seed,
                mode: 1 + Float(size) / 10_000,
                phaseOffset: phaseOffset
            )
        }
        vertices.append(contentsOf: [made[0], made[1], made[2], made[2], made[1], made[3]])
    }

    private func vertex(
        _ point: CGPoint,
        uv: SIMD2<Float>,
        color: SIMD4<Float>,
        parameters: SIMD4<Float>,
        normal: CGPoint,
        seed: Float,
        mode: Float,
        phaseOffset: Float
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            uv: uv,
            color: color,
            parameters: parameters,
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            seed: seed,
            mode: mode,
            phaseOffset: phaseOffset
        )
    }

    private func localWidth(sample: StrokeSample, index: Int, count: Int, brush: BrushSettings) -> CGFloat {
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
        return max(0.35, brush.size * 0.98 * pressure * tilt * taper)
    }

    private func random(seed: UInt64, index: Int) -> CGFloat {
        var value = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return CGFloat(value % 10_000) / 10_000
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 uv;
        float4 color;
        float4 parameters;
        float2 normal;
        float seed;
        float mode;
        float phaseOffset;
    };

    struct Uniforms {
        float2 canvasSize;
        float2 viewSize;
        float2 fittedSize;
        float2 centerOffset;
        float zoom;
        float rotation;
        float phase;
        float padding;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 canvasPosition;
        float2 uv;
        float4 color;
        float4 parameters;
        float seed;
        float mode;
        float phaseOffset;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    vertex VertexOut dryOutlineVertex(
        uint id [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]) {
        VertexIn input = vertices[id];
        float2 point = input.position;
        if (input.mode >= 2.0) {
            float size = (input.mode - 2.0) * 10000.0;
            point += input.uv * size * 0.5;
        } else if (input.mode >= 1.0) {
            float size = (input.mode - 1.0) * 10000.0;
            float angle = (u.phase + input.phaseOffset) * 6.2831853 * input.parameters.z + input.seed * 6.2831853;
            float travel = input.parameters.z <= 0.001
                ? 0.0
                : size * (0.035 + input.parameters.z * 0.025);
            float2 tangent = float2(-input.normal.y, input.normal.x);
            point += input.normal * sin(angle) * travel + tangent * cos(angle) * travel * 0.45;
            point += input.uv * size * 0.5;
        }
        VertexOut out;
        out.position = float4(canvasToClip(point, u), 0, 1);
        out.canvasPosition = point;
        out.uv = input.uv;
        out.color = input.color;
        out.parameters = input.parameters;
        out.seed = input.seed;
        out.mode = input.mode;
        out.phaseOffset = input.phaseOffset;
        return out;
    }

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float valueNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + 1.0), f.x), f.y);
    }

    float granularInkAlpha(
        float distanceToEdge,
        float2 coordinate,
        float seed,
        float roughness,
        float density,
        float cycles,
        float phase) {
        float fuzzWidth = mix(0.055, 0.32, saturate(roughness));
        float solidEdge = 1.0 - fuzzWidth;
        float angle = phase * 6.2831853 * cycles;
        float2 drift = cycles <= 0.001
            ? float2(0.0)
            : float2(cos(angle), sin(angle)) * 2.6;
        float coarse = valueNoise(coordinate + drift + seed * 41.0);
        float medium = valueNoise(coordinate * 2.7 - drift * 1.35 + seed * 73.0);
        float fine = valueNoise(coordinate * 5.9 + drift * 0.62 + seed * 109.0);
        float blotch = valueNoise(coordinate * 1.3 - drift * 1.7 + seed * 17.0);
        if (distanceToEdge <= solidEdge) {
            // Dry-skip holes inside the body so paper shows through the filled
            // ink and the grain animates across the stroke — not just on its
            // hairline — which makes the brush feel grungy and alive.
            float hole = smoothstep(0.72, 0.94, blotch * 0.7 + medium * 0.3 + fine * 0.1);
            float coverage = mix(1.0, 0.70, hole * (0.35 + roughness * 0.65));
            return coverage;
        }

        float edgeProgress = saturate((distanceToEdge - solidEdge) / fuzzWidth);
        float grain = blotch * 0.10 + coarse * 0.46 + medium * 0.30 + fine * 0.14;
        float threshold = mix(0.13, 0.90, edgeProgress)
            + (1.0 - saturate(density)) * 0.18;
        // Crisp ink/paper flecks keep the grunge pronounced without the grey
        // halo that a wide soft ramp leaves behind.
        float speckle = smoothstep(threshold - 0.035, threshold + 0.035, grain);
        float shapeCoverage = 1.0 - smoothstep(0.975, 1.0, distanceToEdge);
        return speckle * shapeCoverage;
    }

    fragment float4 dryOutlineFragment(VertexOut input [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        if (input.canvasPosition.x < 0.0 || input.canvasPosition.y < 0.0
            || input.canvasPosition.x > u.canvasSize.x || input.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }
        float strokePhase = u.phase + input.phaseOffset;
        if (input.mode >= 2.0) {
            float radius = length(input.uv);
            float alpha = granularInkAlpha(
                radius,
                input.uv * 32.0,
                input.seed,
                input.parameters.x,
                input.parameters.y,
                input.parameters.z,
                strokePhase
            );
            return float4(input.color.rgb, input.color.a * alpha);
        }

        if (input.mode >= 1.0) {
            float radius = length(input.uv);
            float alpha = 1.0 - smoothstep(0.74, 1.0, radius);
            float pulse = input.parameters.z <= 0.001
                ? 0.92
                : 0.84 + 0.16 * sin(strokePhase * 6.2831853 * input.parameters.z + input.seed * 9.0);
            return float4(input.color.rgb, input.color.a * alpha * pulse * 0.82);
        }

        float distanceToEdge = abs(input.uv.y);
        float alpha = granularInkAlpha(
            distanceToEdge,
            float2(input.uv.x * 42.0, input.uv.y * 34.0),
            input.seed,
            input.parameters.x,
            input.parameters.y,
            input.parameters.z,
            strokePhase
        );
        return float4(input.color.rgb, input.color.a * alpha);
    }
    """#
}
