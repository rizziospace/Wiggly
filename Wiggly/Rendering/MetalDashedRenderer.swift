import MetalKit
import simd

/// Production live renderer for the unified dot/dash brush. Stroke ribbons are
/// cached; the fragment shader creates the moving rounded marks from arc length.
final class MetalDashedRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var backgroundColor: SIMD4<Float>
        var parameters: SIMD4<Float>
        var halfWidth: Float
        var totalLength: Float
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
    private lazy var previewRing = MetalLiveBufferRing(device: device, label: "Dashed Live Stroke")
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
            guard let vertex = library.makeFunction(name: "dashVertex"),
                  let fragment = library.makeFunction(name: "dashFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Unified Dashed Brush"
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
            assertionFailure("Unable to create Dashed Metal pipeline: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .dashed && stroke.usesGPUAnimatedRenderer {
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
        encoder.pushDebugGroup("Unified Dashed Brush")
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
        encoder.label = "Unified Dashed Brush Preview"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .dashed, let last = stroke.samples.last else {
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

        let averageSize = Float(max(1, brush.size * Double(scale)))
        let dashLength = averageSize * Float(1 + brush.resolvedDashLength * 4)
        let gap = Float(brush.resolvedDashGap * Double(scale))
        let cycles = Float(brush.resolvedDashCyclesPerLoop * Double(max(1, brush.loopCycles)))
        let dashCorner = Float(brush.resolvedDashCornerRadius)
        let encodedCorner = brush.resolvedEndStyle == .cut ? -dashCorner - 1 : dashCorner
        let parameters = SIMD4<Float>(dashLength, gap, encodedCorner, cycles)
        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let dashBackground = brush.resolvedDashBackgroundColor
        let backgroundColor = SIMD4<Float>(
            Float(dashBackground.red), Float(dashBackground.green), Float(dashBackground.blue),
            Float(dashBackground.alpha * brush.opacity * opacity)
        )
        let totalLength = Float(distances.last ?? 0)
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0

        vertices.reserveCapacity(vertices.count + (samples.count - 1) * 6)
        for index in 1..<samples.count {
            let start = points[index - 1]
            let end = points[index]
            let startNormal = normals[index - 1]
            let endNormal = normals[index]
            let startWaveNormal = CGPoint(x: startNormal.x * waveStrength, y: startNormal.y * waveStrength)
            let endWaveNormal = CGPoint(x: endNormal.x * waveStrength, y: endNormal.y * waveStrength)
            let startHalf = widths[index - 1] / 2
            let endHalf = widths[index] / 2
            let sl = CGPoint(x: start.x + startNormal.x * startHalf, y: start.y + startNormal.y * startHalf)
            let sr = CGPoint(x: start.x - startNormal.x * startHalf, y: start.y - startNormal.y * startHalf)
            let el = CGPoint(x: end.x + endNormal.x * endHalf, y: end.y + endNormal.y * endHalf)
            let er = CGPoint(x: end.x - endNormal.x * endHalf, y: end.y - endNormal.y * endHalf)
            let a = vertex(sl, normal: startWaveNormal, distance: distances[index - 1], across: -1, color: color, backgroundColor: backgroundColor, parameters: parameters, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset)
            let b = vertex(sr, normal: startWaveNormal, distance: distances[index - 1], across: 1, color: color, backgroundColor: backgroundColor, parameters: parameters, halfWidth: startHalf, totalLength: totalLength, phaseOffset: phaseOffset)
            let c = vertex(el, normal: endWaveNormal, distance: distances[index], across: -1, color: color, backgroundColor: backgroundColor, parameters: parameters, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset)
            let d = vertex(er, normal: endWaveNormal, distance: distances[index], across: 1, color: color, backgroundColor: backgroundColor, parameters: parameters, halfWidth: endHalf, totalLength: totalLength, phaseOffset: phaseOffset)
            vertices.append(contentsOf: [a, b, c, c, b, d])
        }
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: Float,
        color: SIMD4<Float>,
        backgroundColor: SIMD4<Float>,
        parameters: SIMD4<Float>,
        halfWidth: CGFloat,
        totalLength: Float,
        phaseOffset: Float
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), across),
            color: color,
            backgroundColor: backgroundColor,
            parameters: parameters,
            halfWidth: Float(halfWidth),
            totalLength: totalLength,
            phaseOffset: phaseOffset
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
            buffer.label = "Dashed Geometry \(chunks.count)"
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
        float4 backgroundColor;
        float4 parameters;
        float halfWidth;
        float totalLength;
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
        float waveAmount;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 canvasPosition;
        float2 uv;
        float4 color;
        float4 backgroundColor;
        float4 parameters;
        float halfWidth;
        float totalLength;
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

    vertex VertexOut dashVertex(
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
        out.parameters = input.parameters;
        out.halfWidth = input.halfWidth;
        out.totalLength = input.totalLength;
        out.phaseOffset = input.phaseOffset;
        return out;
    }

    fragment float4 dashFragment(VertexOut input [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        if (input.canvasPosition.x < 0.0 || input.canvasPosition.y < 0.0
            || input.canvasPosition.x > u.canvasSize.x || input.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }
        float dashLength = max(0.5, input.parameters.x);
        float pattern = dashLength + max(0.0, input.parameters.y);
        float strokePhase = u.phase + input.phaseOffset;
        float travelled = input.uv.x + strokePhase * pattern * input.parameters.w;
        float local = fmod(fmod(travelled, pattern) + pattern, pattern);
        // The dash's extent along the stroke. The ribbon has no geometry beyond
        // 0..totalLength, so a dash that spills past either end used to be sliced
        // off square. Clamp the mark to the base domain and re-round the visible
        // portion so dashes entering and exiting the base keep the same rounded
        // caps as interior dashes.
        float dashStart = input.uv.x - local;
        float dashEnd = dashStart + dashLength;
        float left = max(0.0, dashStart);
        float right = min(input.totalLength, dashEnd);
        float visibleLength = max(0.0, right - left);
        float2 point = float2(input.uv.x - 0.5 * (left + right), input.uv.y * input.halfWidth);
        float2 box = float2(0.5 * visibleLength, input.halfWidth);
        bool cutEnds = input.parameters.z < 0.0;
        float dashCorner = cutEnds ? -input.parameters.z - 1.0 : input.parameters.z;
        float radius = min(box.x, box.y) * dashCorner;
        float2 q = abs(point) - box + radius;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        // Size the SDF edge ramp from the smooth arc-length coordinate rather
        // than fwidth(distance): where the signed-distance gradient changes
        // inside a pixel (the diagonal corners of a rounded cap) fwidth
        // overestimates the ramp and leaves a faint hairline from the cap.
        float antialias = max(0.75, fwidth(input.uv.x));
        float dashAlpha = 1.0 - smoothstep(-antialias, antialias, distance);
        // A dash clipped down to only a sub-pixel fragment at either end of
        // the stroke looks like a long, faint hairline after antialiasing.
        // Hide only those incomplete end fragments; full marks are unchanged.
        float minimumVisibleMark = min(dashLength, max(1.0, input.halfWidth * 0.35));
        bool clippedAtStrokeEnd = dashStart < 0.0 || dashEnd > input.totalLength;
        if (clippedAtStrokeEnd && visibleLength < minimumVisibleMark) {
            dashAlpha = 0.0;
        }
        float edgeAntialias = max(0.01, fwidth(input.uv.y));
        float edgeAlpha = 1.0 - smoothstep(1.0 - edgeAntialias, 1.0, abs(input.uv.y));
        // Give the base strip the same corner treatment as its dashes. A zero
        // radius remains a true flat-ended rectangle.
        float baseRadius = cutEnds
            ? 0.0
            : min(input.totalLength * 0.5, input.halfWidth);
        float2 basePoint = float2(input.uv.x - input.totalLength * 0.5,
                                  input.uv.y * input.halfWidth);
        float2 baseBox = float2(input.totalLength * 0.5, input.halfWidth);
        float2 baseQ = abs(basePoint) - baseBox + baseRadius;
        float baseDistance = length(max(baseQ, 0.0))
            + min(max(baseQ.x, baseQ.y), 0.0) - baseRadius;
        float baseAlpha = 1.0 - smoothstep(-antialias, antialias, baseDistance);
        float foregroundAlpha = input.color.a * dashAlpha * edgeAlpha;
        float backgroundAlpha = input.backgroundColor.a * baseAlpha;
        // At a stroke end a dash that spills past the base used to poke out with
        // a square edge. Mask the foreground to the base's own rounded silhouette
        // so dashes exiting the base keep a rounded cap.
        foregroundAlpha *= baseAlpha;
        // Do not preserve extremely low-alpha SDF residue. On large dark
        // dashes it appears as a thin diagonal hair extending from the cap.
        foregroundAlpha = foregroundAlpha < 0.02 ? 0.0 : foregroundAlpha;
        backgroundAlpha = backgroundAlpha < 0.02 ? 0.0 : backgroundAlpha;
        float finalAlpha = foregroundAlpha + backgroundAlpha * (1.0 - foregroundAlpha);
        float3 premultiplied = input.color.rgb * foregroundAlpha
            + input.backgroundColor.rgb * backgroundAlpha * (1.0 - foregroundAlpha);
        float3 finalColor = finalAlpha > 0.0001 ? premultiplied / finalAlpha : float3(0.0);
        return float4(finalColor, finalAlpha);
    }
    """#
}
