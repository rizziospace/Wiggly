import CoreGraphics
import Metal
import MetalKit
import simd

/// Temporary rollout switch. Keep `.legacy` available until the unified renderer
/// passes canvas and export acceptance checks.
enum GooRendererFeatureFlag {
    enum Mode: Equatable {
        case legacy
        case unified
    }

    static let mode: Mode = .unified
}

/// A procedural Goo renderer. Geometry is represented only as spline samples and
/// variable-radius capsules evaluated into one floating-point mask per paint batch.
/// No segment geometry is ever rasterized into the destination framebuffer.
final class UnifiedGooMaskRenderer {
    struct ViewTransform: Equatable {
        var canvasSize: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var fittedSize: SIMD2<Float>
        var centerOffset: SIMD2<Float>
        var zoom: Float
        var rotation: Float
        var phase: Float = 0
    }

    private struct SourceStroke {
        var stroke: AnimatedStroke
        var opacity: Float
        var contentScale: Float
        var contentOffset: SIMD2<Float>
    }

    private struct PaintBatch {
        var layerID: UUID
        var color: SIMD4<Float>
        var strokes: [SourceStroke]
    }

    /// Layout must match GooSegment in Metal.
    private struct GooSegment {
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var normalA: SIMD2<Float>
        var normalB: SIMD2<Float>
        var radiusA: Float
        var radiusB: Float
        var arcA: Float
        var arcB: Float
        var totalLength: Float
        var seed: Float
        var speed: Float
        var waviness: Float
        var waveLength: Float
        var padding0: Float = 0
        var padding1: Float = 0
        var padding2: Float = 0
    }

    private struct MaskParams {
        var segmentCount: UInt32
        var strokeCount: UInt32
        var width: UInt32
        var height: UInt32
        var antialiasPixels: Float
        var phase: Float
    }

    private struct GooStrokeInfo {
        var segmentStart: UInt32
        var segmentCount: UInt32
        var totalLength: Float
        var seed: Float
        var speed: Float
        var waviness: Float
        var waveLength: Float
        var droplets: Float
    }

    private struct PreparedBatch {
        var layerID: UUID
        var color: SIMD4<Float>
        var mask: MTLTexture
        var segments: MTLBuffer
        var segmentCount: Int
        var strokes: MTLBuffer
        var strokeCount: Int
    }

    private struct GeometrySignature: Equatable {
        var revision: Int
        var drawableWidth: Int
        var drawableHeight: Int
        var transform: ViewTransform
    }

    private struct CurveVertex {
        var point: SIMD2<Float>
        var pressure: Float
        var tilt: Float
        var tangent: SIMD2<Float>
        var normal: SIMD2<Float>
        var arcLength: Float
        var radius: Float
    }

    private let device: MTLDevice
    private let maskPipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var sourceBatches: [PaintBatch] = []
    private var preparedBatches: [PreparedBatch] = []
    private var geometryRevision = 0
    private var preparedSignature: GeometrySignature?
    private var previewMask: MTLTexture?

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let clear = library.makeFunction(name: "unifiedGooClearMask"),
                  let mask = library.makeFunction(name: "unifiedGooBaselineMask"),
                  let vertex = library.makeFunction(name: "unifiedGooCompositeVertex"),
                  let fragment = library.makeFunction(name: "unifiedGooCompositeFragment") else {
                return nil
            }
            clearPipeline = try device.makeComputePipelineState(function: clear)
            maskPipeline = try device.makeComputePipelineState(function: mask)

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Unified Goo Mask Composite"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Unable to create unified Goo renderer: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var batches: [PaintBatch] = []
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .goo {
                let alpha = Float(stroke.brush.color.alpha * stroke.brush.opacity * layer.opacity)
                let color = SIMD4<Float>(
                    Float(stroke.brush.color.red) * alpha,
                    Float(stroke.brush.color.green) * alpha,
                    Float(stroke.brush.color.blue) * alpha,
                    alpha
                )
                let source = SourceStroke(
                    stroke: stroke,
                    opacity: Float(layer.opacity),
                    contentScale: Float(layer.resolvedContentScale),
                    contentOffset: SIMD2(Float(layer.resolvedContentOffset.x), Float(layer.resolvedContentOffset.y))
                )
                if let index = batches.indices.last,
                   batches[index].layerID == layer.id,
                   batches[index].color == color {
                    batches[index].strokes.append(source)
                } else {
                    batches.append(PaintBatch(layerID: layer.id, color: color, strokes: [source]))
                }
            }
        }
        sourceBatches = batches
        geometryRevision &+= 1
        preparedSignature = nil
    }

    func precompute(
        commandBuffer: MTLCommandBuffer,
        drawableSize: SIMD2<Int>,
        transform: ViewTransform
    ) {
        guard drawableSize.x > 0, drawableSize.y > 0 else { return }
        let signature = GeometrySignature(
            revision: geometryRevision,
            drawableWidth: drawableSize.x,
            drawableHeight: drawableSize.y,
            transform: transform
        )
        if signature != preparedSignature {
            preparedBatches = makePreparedBatches(drawableSize: drawableSize, transform: transform)
            preparedSignature = signature
        }
        for batch in preparedBatches {
            encodeMask(
                commandBuffer: commandBuffer,
                mask: batch.mask,
                segmentBuffer: batch.segments,
                segmentCount: batch.segmentCount,
                strokeBuffer: batch.strokes,
                strokeCount: batch.strokeCount,
                phase: transform.phase
            )
        }
    }

    func encode(encoder: MTLRenderCommandEncoder, layerID: UUID) {
        for batch in preparedBatches where batch.layerID == layerID {
            composite(mask: batch.mask, color: batch.color, encoder: encoder)
        }
    }

    func encodePreview(
        commandBuffer: MTLCommandBuffer,
        target: MTLTexture,
        transform: ViewTransform,
        previewStroke: AnimatedStroke?
    ) {
        guard let previewStroke, previewStroke.brush.kind == .goo else { return }
        let source = SourceStroke(
            stroke: previewStroke,
            opacity: 1,
            contentScale: 1,
            contentOffset: .zero
        )
        let segments = makeSegments(for: source, transform: transform, drawableWidth: target.width)
        let strokeInfo = makeStrokeInfo(source: source, segmentStart: 0, segments: segments)
        guard !segments.isEmpty,
              let buffer = device.makeBuffer(
                bytes: segments,
                length: segments.count * MemoryLayout<GooSegment>.stride,
                options: .storageModeShared
              ),
              let strokeBuffer = device.makeBuffer(
                bytes: [strokeInfo],
                length: MemoryLayout<GooStrokeInfo>.stride,
                options: .storageModeShared
              ) else { return }
        let mask = ensurePreviewMask(width: target.width, height: target.height)
        encodeMask(
            commandBuffer: commandBuffer,
            mask: mask,
            segmentBuffer: buffer,
            segmentCount: segments.count,
            strokeBuffer: strokeBuffer,
            strokeCount: 1,
            phase: transform.phase
        )

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let alpha = Float(previewStroke.brush.color.alpha * previewStroke.brush.opacity)
        composite(
            mask: mask,
            color: SIMD4(
                Float(previewStroke.brush.color.red) * alpha,
                Float(previewStroke.brush.color.green) * alpha,
                Float(previewStroke.brush.color.blue) * alpha,
                alpha
            ),
            encoder: encoder
        )
        encoder.endEncoding()
    }

    private func makePreparedBatches(
        drawableSize: SIMD2<Int>,
        transform: ViewTransform
    ) -> [PreparedBatch] {
        var result: [PreparedBatch] = []
        for batch in sourceBatches {
            var segments: [GooSegment] = []
            var strokeInfos: [GooStrokeInfo] = []
            for source in batch.strokes {
                let strokeSegments = makeSegments(for: source, transform: transform, drawableWidth: drawableSize.x)
                guard !strokeSegments.isEmpty else { continue }
                strokeInfos.append(makeStrokeInfo(
                    source: source,
                    segmentStart: segments.count,
                    segments: strokeSegments
                ))
                segments.append(contentsOf: strokeSegments)
            }
            guard !segments.isEmpty, !strokeInfos.isEmpty,
                  let buffer = device.makeBuffer(
                    bytes: segments,
                    length: segments.count * MemoryLayout<GooSegment>.stride,
                    options: .storageModeShared
                  ),
                  let strokeBuffer = device.makeBuffer(
                    bytes: strokeInfos,
                    length: strokeInfos.count * MemoryLayout<GooStrokeInfo>.stride,
                    options: .storageModeShared
                  ),
                  let mask = makeMask(width: drawableSize.x, height: drawableSize.y) else { continue }
            result.append(PreparedBatch(
                layerID: batch.layerID,
                color: batch.color,
                mask: mask,
                segments: buffer,
                segmentCount: segments.count,
                strokes: strokeBuffer,
                strokeCount: strokeInfos.count
            ))
        }
        return result
    }

    private func makeStrokeInfo(
        source: SourceStroke,
        segmentStart: Int,
        segments: [GooSegment]
    ) -> GooStrokeInfo {
        GooStrokeInfo(
            segmentStart: UInt32(segmentStart),
            segmentCount: UInt32(segments.count),
            totalLength: segments.last?.totalLength ?? 0,
            seed: stableSeed(source.stroke),
            speed: Float(source.stroke.brush.resolvedGooSpeed),
            waviness: Float(source.stroke.brush.resolvedGooWaviness),
            waveLength: Float(source.stroke.brush.resolvedGooWaveLength),
            droplets: Float(source.stroke.brush.resolvedGooDroplets)
        )
    }

    private func makeSegments(
        for source: SourceStroke,
        transform: ViewTransform,
        drawableWidth: Int
    ) -> [GooSegment] {
        let pixelScale = Float(drawableWidth) / max(1, transform.viewSize.x)
        let documentToPixel = transform.fittedSize.x / max(1, transform.canvasSize.x)
            * transform.zoom * pixelScale
        let vertices = adaptiveSpline(source: source, pixelsPerDocumentPoint: documentToPixel)
        guard !vertices.isEmpty else { return [] }

        func toPixel(_ point: SIMD2<Float>) -> SIMD2<Float> {
            var p = point / transform.canvasSize - SIMD2<Float>(repeating: 0.5)
            p *= transform.fittedSize * transform.zoom
            let c = cos(transform.rotation)
            let s = sin(transform.rotation)
            p = SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
            p += transform.viewSize * 0.5 + transform.centerOffset
            return p * pixelScale
        }

        if vertices.count == 1 {
            let center = toPixel(vertices[0].point)
            let radius = vertices[0].radius * documentToPixel
            return [GooSegment(
                a: center,
                b: center,
                normalA: SIMD2(0, 1),
                normalB: SIMD2(0, 1),
                radiusA: radius,
                radiusB: radius,
                arcA: 0,
                arcB: 0,
                totalLength: 0,
                seed: stableSeed(source.stroke),
                speed: Float(source.stroke.brush.resolvedGooSpeed),
                waviness: Float(source.stroke.brush.resolvedGooWaviness),
                waveLength: Float(source.stroke.brush.resolvedGooWaveLength)
            )]
        }
        let totalLength = vertices.last!.arcLength * documentToPixel
        let strokeSeed = stableSeed(source.stroke)
        let rotationCos = cos(transform.rotation)
        let rotationSin = sin(transform.rotation)
        func rotatedNormal(_ normal: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(
                normal.x * rotationCos - normal.y * rotationSin,
                normal.x * rotationSin + normal.y * rotationCos
            )
        }
        var result: [GooSegment] = []
        result.reserveCapacity(vertices.count - 1)
        for index in 1..<vertices.count {
            let a = vertices[index - 1]
            let b = vertices[index]
            result.append(GooSegment(
                a: toPixel(a.point),
                b: toPixel(b.point),
                normalA: rotatedNormal(a.normal),
                normalB: rotatedNormal(b.normal),
                radiusA: a.radius * documentToPixel,
                radiusB: b.radius * documentToPixel,
                arcA: a.arcLength * documentToPixel,
                arcB: b.arcLength * documentToPixel,
                totalLength: totalLength,
                seed: strokeSeed,
                speed: Float(source.stroke.brush.resolvedGooSpeed),
                waviness: Float(source.stroke.brush.resolvedGooWaviness),
                waveLength: Float(source.stroke.brush.resolvedGooWaveLength)
            ))
        }
        return result
    }

    private func stableSeed(_ stroke: AnimatedStroke) -> Float {
        var hash = stroke.brush.seed ^ 0xcbf29ce484222325
        for byte in stroke.id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Float(hash & 0x00ff_ffff) / Float(0x0100_0000)
    }

    /// Centripetal Catmull-Rom sampling with recursive screen-space flatness and
    /// tangent-angle tests. It creates no renderable quads.
    private func adaptiveSpline(
        source: SourceStroke,
        pixelsPerDocumentPoint: Float
    ) -> [CurveVertex] {
        let samples = source.stroke.samples
        guard let first = samples.first else { return [] }
        let points = samples.map {
            SIMD2<Float>(Float($0.x), Float($0.y)) * source.contentScale + source.contentOffset
        }
        let baseRadius = Float(source.stroke.brush.size) * source.contentScale * 0.5
        if points.count == 1 {
            return [CurveVertex(
                point: points[0],
                pressure: Float(first.pressure),
                tilt: Float(first.tilt),
                tangent: SIMD2(1, 0),
                normal: SIMD2(0, 1),
                arcLength: 0,
                radius: sampleRadius(sample: first, progress: 0.5, brush: source.stroke.brush, baseRadius: baseRadius)
            )]
        }

        struct RawVertex {
            var point: SIMD2<Float>
            var pressure: Float
            var tilt: Float
            var derivative: SIMD2<Float>
        }
        func evaluate(_ segment: Int, _ t: Float) -> RawVertex {
            let i0 = max(0, segment - 1)
            let i1 = segment
            let i2 = min(points.count - 1, segment + 1)
            let i3 = min(points.count - 1, segment + 2)
            let t2 = t * t
            let t3 = t2 * t
            let p0 = points[i0], p1 = points[i1], p2 = points[i2], p3 = points[i3]
            let c0 = p1 * Float(2)
            let c1 = -p0 + p2
            var c2 = p0 * Float(2)
            c2 -= p1 * Float(5)
            c2 += p2 * Float(4)
            c2 -= p3
            var c3 = -p0
            c3 += p1 * Float(3)
            c3 -= p2 * Float(3)
            c3 += p3
            var point = c0 + c1 * t
            point += c2 * t2
            point += c3 * t3
            point *= Float(0.5)
            var derivative = c1 + c2 * (Float(2) * t)
            derivative += c3 * (Float(3) * t2)
            derivative *= Float(0.5)
            let s1 = samples[i1], s2 = samples[i2]
            return RawVertex(
                point: point,
                pressure: Float(s1.pressure + (s2.pressure - s1.pressure) * Double(t)),
                tilt: Float(s1.tilt + (s2.tilt - s1.tilt) * Double(t)),
                derivative: derivative
            )
        }
        func normalized(_ value: SIMD2<Float>) -> SIMD2<Float> {
            let length = simd_length(value)
            return length > 0.000_01 ? value / length : SIMD2(1, 0)
        }

        let flatnessLimit: Float = 0.20
        let angleLimit = Float(4 * Double.pi / 180)
        let maximumDepth = 12
        var raw: [RawVertex] = []
        raw.reserveCapacity(min(16_384, samples.count * 8))
        raw.append(evaluate(0, 0))

        func subdivide(segment: Int, t0: Float, t1: Float, a: RawVertex, b: RawVertex, depth: Int) {
            let tm = (t0 + t1) * 0.5
            let m = evaluate(segment, tm)
            let chordMidpoint = (a.point + b.point) * 0.5
            let errorPixels = simd_length(m.point - chordMidpoint) * pixelsPerDocumentPoint
            let tangentDot = simd_clamp(simd_dot(normalized(a.derivative), normalized(b.derivative)), -1, 1)
            let tangentAngle = acos(tangentDot)
            if depth < maximumDepth && (errorPixels > flatnessLimit || tangentAngle > angleLimit) {
                subdivide(segment: segment, t0: t0, t1: tm, a: a, b: m, depth: depth + 1)
                subdivide(segment: segment, t0: tm, t1: t1, a: m, b: b, depth: depth + 1)
            } else {
                raw.append(b)
            }
        }

        for segment in 0..<(points.count - 1) {
            let a = evaluate(segment, 0)
            let b = evaluate(segment, 1)
            subdivide(segment: segment, t0: 0, t1: 1, a: a, b: b, depth: 0)
        }

        var cumulative: Float = 0
        var result: [CurveVertex] = []
        result.reserveCapacity(raw.count)
        for index in raw.indices {
            if index > 0 { cumulative += simd_length(raw[index].point - raw[index - 1].point) }
            let tangent = normalized(raw[index].derivative)
            let progress = raw.count > 1 ? Float(index) / Float(raw.count - 1) : 0.5
            let radius = sampleRadius(
                pressure: raw[index].pressure,
                tilt: raw[index].tilt,
                progress: progress,
                brush: source.stroke.brush,
                baseRadius: baseRadius
            )
            result.append(CurveVertex(
                point: raw[index].point,
                pressure: raw[index].pressure,
                tilt: raw[index].tilt,
                tangent: tangent,
                normal: SIMD2(-tangent.y, tangent.x),
                arcLength: cumulative,
                radius: radius
            ))
        }
        return result
    }

    private func sampleRadius(
        sample: StrokeSample,
        progress: Float,
        brush: BrushSettings,
        baseRadius: Float
    ) -> Float {
        sampleRadius(
            pressure: Float(sample.pressure),
            tilt: Float(sample.tilt),
            progress: progress,
            brush: brush,
            baseRadius: baseRadius
        )
    }

    private func sampleRadius(
        pressure: Float,
        tilt: Float,
        progress: Float,
        brush: BrushSettings,
        baseRadius: Float
    ) -> Float {
        let pressureScale = 1 + (pressure - 0.5) * Float(brush.pressureSize)
        let tiltScale = 1 + tilt * Float(brush.tiltResponse) * 0.5
        let taperZone: Float = 0.15
        let taper: Float
        if progress < taperZone {
            let start = Float(brush.resolvedStartWidthScale)
            taper = start + (1 - start) * progress / taperZone
        } else if progress > 1 - taperZone {
            let end = Float(brush.resolvedEndWidthScale)
            taper = 1 + (end - 1) * (progress - (1 - taperZone)) / taperZone
        } else {
            taper = 1
        }
        return max(0.35, baseRadius * pressureScale * tiltScale * taper)
    }

    private func encodeMask(
        commandBuffer: MTLCommandBuffer,
        mask: MTLTexture,
        segmentBuffer: MTLBuffer,
        segmentCount: Int,
        strokeBuffer: MTLBuffer,
        strokeCount: Int,
        phase: Float
    ) {
        let threadsPerGroup = MTLSize(width: 8, height: 8, depth: 1)
        let threads = MTLSize(width: mask.width, height: mask.height, depth: 1)
        if let clear = commandBuffer.makeComputeCommandEncoder() {
            clear.label = "Unified Goo Exact-Zero Clear"
            clear.setComputePipelineState(clearPipeline)
            clear.setTexture(mask, index: 0)
            clear.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
            clear.endEncoding()
        }
        var params = MaskParams(
            segmentCount: UInt32(segmentCount),
            strokeCount: UInt32(strokeCount),
            width: UInt32(mask.width),
            height: UInt32(mask.height),
            antialiasPixels: 1.25,
            phase: phase
        )
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "Unified Goo Baseline SDF"
        encoder.setComputePipelineState(maskPipeline)
        encoder.setBuffer(segmentBuffer, offset: 0, index: 0)
        encoder.setBuffer(strokeBuffer, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<MaskParams>.stride, index: 2)
        encoder.setTexture(mask, index: 0)
        encoder.dispatchThreads(threads, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }

    private func composite(mask: MTLTexture, color: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(compositePipeline)
        var color = color
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(mask, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func makeMask(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func ensurePreviewMask(width: Int, height: Int) -> MTLTexture {
        if let previewMask, previewMask.width == width, previewMask.height == height { return previewMask }
        guard let texture = makeMask(width: width, height: height) else {
            preconditionFailure("Unable to allocate unified Goo preview mask")
        }
        texture.label = "Unified Goo Preview Mask"
        previewMask = texture
        return texture
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct GooSegment {
        float2 a;
        float2 b;
        float2 normalA;
        float2 normalB;
        float radiusA;
        float radiusB;
        float arcA;
        float arcB;
        float totalLength;
        float seed;
        float speed;
        float waviness;
        float waveLength;
        float padding0;
        float padding1;
        float padding2;
    };

    struct MaskParams {
        uint segmentCount;
        uint strokeCount;
        uint width;
        uint height;
        float antialiasPixels;
        float phase;
    };

    struct GooStrokeInfo {
        uint segmentStart;
        uint segmentCount;
        float totalLength;
        float seed;
        float speed;
        float waviness;
        float waveLength;
        float droplets;
    };

    kernel void unifiedGooClearMask(
        texture2d<half, access::write> mask [[texture(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) { return; }
        mask.write(half4(0.0h), gid);
    }

    inline float wrappedArcDistance(float a, float b, float length) {
        float d = abs(a - b);
        return min(d, max(0.0, length - d));
    }

    inline float bodyPulse(float arc, device const GooSegment &segment, float phase) {
        if (segment.totalLength < 1.0 || segment.waviness < 0.001) { return 0.0; }
        float wavelength = mix(0.36, 0.16, segment.waveLength) * segment.totalLength;
        wavelength = max(wavelength, max(segment.radiusA, segment.radiusB) * 3.5);
        float travel = phase * segment.totalLength * mix(0.35, 1.6, clamp(segment.speed * 0.5, 0.0, 1.0));
        float pulse = 0.0;
        for (uint index = 0; index < 3; ++index) {
            float offset = fract(segment.seed * (7.31 + float(index) * 3.17) + float(index) * 0.331);
            float direction = index == 1 ? -0.72 : 1.0;
            float center = fmod(offset * segment.totalLength + travel * direction + segment.totalLength * 4.0, segment.totalLength);
            float x = wrappedArcDistance(arc, center, segment.totalLength) / wavelength;
            float envelope = exp(-x * x * 18.0);
            pulse += envelope * (1.0 - float(index) * 0.16);
        }
        return min(1.35, pulse) * segment.waviness;
    }

    inline float variableCapsuleDistance(float2 p, device const GooSegment &segment, float phase) {
        float2 axis = segment.b - segment.a;
        float axisLengthSquared = dot(axis, axis);
        float t = axisLengthSquared > 1e-8
            ? clamp(dot(p - segment.a, axis) / axisLengthSquared, 0.0, 1.0)
            : 0.0;
        float arc = mix(segment.arcA, segment.arcB, t);
        float pulse = bodyPulse(arc, segment, phase);
        float radius = mix(segment.radiusA, segment.radiusB, t) * (1.0 + pulse * 0.34);
        float2 normal = normalize(mix(segment.normalA, segment.normalB, t));
        float leanSign = fract(segment.seed * 19.19) < 0.5 ? -1.0 : 1.0;
        float2 center = mix(segment.a, segment.b, t) + normal * leanSign * radius * pulse * 0.10;
        return length(p - center) - radius;
    }

    inline float gooSmoothMinimum(float a, float b, float blend) {
        if (blend <= 0.0001) { return min(a, b); }
        float h = clamp(0.5 + 0.5 * (b - a) / blend, 0.0, 1.0);
        return mix(b, a, h) - blend * h * (1.0 - h);
    }

    inline float circleDistance(float2 p, float2 center, float radius) {
        return length(p - center) - radius;
    }

    inline float neckDistance(
        float2 p,
        float2 a,
        float2 b,
        float radiusA,
        float radiusB) {
        float2 axis = b - a;
        float denominator = max(1e-8, dot(axis, axis));
        float t = clamp(dot(p - a, axis) / denominator, 0.0, 1.0);
        return length(p - mix(a, b, t)) - mix(radiusA, radiusB, t);
    }

    struct StrokeFrame {
        float2 position;
        float2 normal;
        float radius;
    };

    inline StrokeFrame strokeFrameAtArc(
        device const GooSegment *segments,
        device const GooStrokeInfo &stroke,
        float arc,
        float phase) {
        StrokeFrame frame;
        frame.position = float2(0.0);
        frame.normal = float2(0.0, 1.0);
        frame.radius = 1.0;
        float target = clamp(arc, 0.0, stroke.totalLength);
        uint lastIndex = stroke.segmentStart + max(1u, stroke.segmentCount) - 1u;
        for (uint local = 0; local < stroke.segmentCount; ++local) {
            uint index = stroke.segmentStart + local;
            device const GooSegment &segment = segments[index];
            if (target <= segment.arcB || index == lastIndex) {
                float denominator = max(1e-6, segment.arcB - segment.arcA);
                float t = clamp((target - segment.arcA) / denominator, 0.0, 1.0);
                float pulse = bodyPulse(target, segment, phase);
                frame.radius = mix(segment.radiusA, segment.radiusB, t) * (1.0 + pulse * 0.34);
                frame.normal = normalize(mix(segment.normalA, segment.normalB, t));
                float leanSign = fract(segment.seed * 19.19) < 0.5 ? -1.0 : 1.0;
                frame.position = mix(segment.a, segment.b, t)
                    + frame.normal * leanSign * frame.radius * pulse * 0.10;
                return frame;
            }
        }
        return frame;
    }

    inline float singleDropletEventDistance(
        float2 p,
        device const GooSegment *segments,
        device const GooStrokeInfo &stroke,
        float phase,
        thread bool &attached) {
        attached = false;
        if (stroke.droplets < 0.01 || stroke.totalLength < 8.0) { return INFINITY; }
        float sourceFraction = mix(0.16, 0.48, fract(stroke.seed * 13.73));
        float destinationFraction = fract(sourceFraction + mix(0.34, 0.62, fract(stroke.seed * 29.17)));
        float sourceArc = sourceFraction * stroke.totalLength;
        float destinationArc = destinationFraction * stroke.totalLength;
        StrokeFrame source = strokeFrameAtArc(segments, stroke, sourceArc, phase);
        StrokeFrame destination = strokeFrameAtArc(segments, stroke, destinationArc, phase);
        float side = fract(stroke.seed * 41.91) < 0.5 ? -1.0 : 1.0;
        float eventTime = fract(phase * mix(0.55, 1.25, clamp(stroke.speed * 0.5, 0.0, 1.0))
            + stroke.seed * 5.37);
        float dropletRadius = source.radius * mix(0.30, 0.48, fract(stroke.seed * 71.11));
        float2 start = source.position + source.normal * side * source.radius * 0.70;
        float2 detached = source.position + source.normal * side * source.radius * 3.3;
        float destinationSide = -side;
        float2 arrival = destination.position + destination.normal * destinationSide * destination.radius * 3.0;
        float2 end = destination.position + destination.normal * destinationSide * destination.radius * 0.72;
        float2 center;
        float radius = dropletRadius;
        float distance;

        if (eventTime < 0.20) {
            float u = smoothstep(0.0, 0.20, eventTime);
            center = mix(start, source.position + source.normal * side * source.radius * 1.35, u);
            radius *= u;
            attached = true;
            float circle = circleDistance(p, center, radius);
            float neck = neckDistance(p, source.position, center, source.radius * 0.42, max(0.1, radius * 0.74));
            distance = gooSmoothMinimum(circle, neck, max(0.5, radius * 0.34));
        } else if (eventTime < 0.42) {
            float u = smoothstep(0.20, 0.42, eventTime);
            center = mix(source.position + source.normal * side * source.radius * 1.35, detached, u);
            attached = true;
            float circle = circleDistance(p, center, radius);
            float neckRadius = radius * mix(0.68, 0.035, u);
            float neck = neckDistance(p, source.position, center, source.radius * 0.34, neckRadius);
            distance = gooSmoothMinimum(circle, neck, max(0.25, radius * mix(0.30, 0.03, u)));
        } else if (eventTime < 0.84) {
            float u = smoothstep(0.42, 0.84, eventTime);
            float2 linear = mix(detached, arrival, u);
            float2 travelNormal = normalize(source.normal + destination.normal * 0.35);
            center = linear + travelNormal * side * sin(u * M_PI_F) * source.radius * 2.2;
            distance = circleDistance(p, center, radius);
        } else {
            float u = smoothstep(0.84, 1.0, eventTime);
            center = mix(arrival, end, u);
            radius *= 1.0 - u * 0.52;
            attached = true;
            float circle = circleDistance(p, center, radius);
            float neck = neckDistance(p, destination.position, center, destination.radius * 0.38, radius * mix(0.08, 0.72, u));
            distance = gooSmoothMinimum(circle, neck, max(0.25, radius * 0.30));
        }
        return distance;
    }

    kernel void unifiedGooBaselineMask(
        device const GooSegment *segments [[buffer(0)]],
        device const GooStrokeInfo *strokes [[buffer(1)]],
        constant MaskParams &params [[buffer(2)]],
        texture2d<half, access::write> mask [[texture(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= params.width || gid.y >= params.height) { return; }
        float2 p = float2(gid) + 0.5;
        float distance = INFINITY;
        for (uint index = 0; index < params.segmentCount; ++index) {
            distance = min(distance, variableCapsuleDistance(p, segments[index], params.phase));
        }
        for (uint index = 0; index < params.strokeCount; ++index) {
            bool attached = false;
            float eventDistance = singleDropletEventDistance(
                p,
                segments,
                strokes[index],
                params.phase,
                attached
            );
            if (attached) {
                float blend = max(0.5, strokeFrameAtArc(
                    segments,
                    strokes[index],
                    strokes[index].totalLength * mix(0.16, 0.48, fract(strokes[index].seed * 13.73)),
                    params.phase
                ).radius * 0.18);
                distance = gooSmoothMinimum(distance, eventDistance, blend);
            } else {
                distance = min(distance, eventDistance);
            }
        }
        float coverage = 0.0;
        if (distance < params.antialiasPixels) {
            coverage = smoothstep(params.antialiasPixels, -params.antialiasPixels, distance);
        }
        // Preserve exact zero outside the final antialiasing band.
        mask.write(half4(half(coverage), 0.0h, 0.0h, 0.0h), gid);
    }

    struct CompositeVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex CompositeVertexOut unifiedGooCompositeVertex(uint vertexID [[vertex_id]]) {
        constexpr float2 positions[6] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0),
            float2(1.0, 1.0), float2(-1.0, 1.0), float2(-1.0, -1.0)
        };
        CompositeVertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = positions[vertexID] * 0.5 + 0.5;
        return out;
    }

    fragment float4 unifiedGooCompositeFragment(
        CompositeVertexOut in [[stage_in]],
        constant float4 &premultipliedColor [[buffer(0)]],
        texture2d<half> mask [[texture(0)]]) {
        constexpr sampler maskSampler(coord::normalized, filter::linear, address::clamp_to_zero);
        float coverage = float(mask.sample(maskSampler, in.uv).r);
        return float4(premultipliedColor.rgb * coverage, premultipliedColor.a * coverage);
    }
    """#
}
