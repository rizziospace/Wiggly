import MetalKit
import simd

/// Live GPU renderer for the particleCloud ("Drizzle") brush, mirroring the
/// CPU ParticleCloudKernel so nothing re-rasterizes per frame:
///  - The static core (thin skeleton line + two dense rows of attached blobs)
///    is baked into cached ribbon geometry. The fragment shader redraws it each
///    frame from arc length + across offset with a small per-station window, so
///    the look is identical but the geometry never changes.
///  - The animated band of shed droplets is stored as instanced quad data. Each
///    droplet's cycle count, life offset, travel distance, and radius are baked
///    at update time; the vertex shader derives the current emission slot (and
///    its seeded location + side) from the animation phase and looks the droplet
///    position up on the stroke path, so per-frame work is bounded regardless of
///    droplet count.
final class MetalParticleCloudRenderer {
    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var color: SIMD4<Float>
        var parameters: SIMD4<Float>
        var halfWidth: Float
        var totalLength: Float
        var stationCount: Float
        var seed: UInt32
    }

    private struct Droplet {
        var color: SIMD4<Float>
        var pathStart: UInt32
        var pathCount: UInt32
        var totalLength: Float
        var lineHalf: Float
        var nominalBlobDiameter: Float
        var lifeOffset: Float
        var cycleCount: Float
        var maxTravel: Float
        var radius: Float
        var seed: UInt32
        var reserved: Float
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

    private struct Chunk {
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

    /// A single layer's instanced droplet data. Droplet `pathStart`/`pathCount`
    /// offsets index into this batch's own combined path buffer.
    private struct DropletBatch {
        var pathBuffer: MTLBuffer?
        var dropletBuffer: MTLBuffer?
        var count: Int
    }

    private struct PreviewKey: Equatable {
        var sampleCount: Int
        var lastX: Double
        var lastY: Double
        var brush: BrushSettings
    }

    private let device: MTLDevice
    private let corePipeline: MTLRenderPipelineState
    private let dropletPipeline: MTLRenderPipelineState
    private let chunkSize = 4 * 1024 * 1024
    private var chunks: [Chunk] = []
    private var strokeKeys: [StrokeKey] = []
    private var layerRanges: [UUID: [Range]] = [:]
    private var layerDroplets: [UUID: DropletBatch] = [:]
    private var previewBuffer: MTLBuffer?
    private lazy var previewCoreRing = MetalLiveBufferRing(device: device, label: "Drizzle Core Live Stroke")
    private var previewVertexCount = 0
    private var previewPathBuffer: MTLBuffer?
    private lazy var previewPathRing = MetalLiveBufferRing(device: device, label: "Drizzle Path Live Stroke")
    private var previewDropletBuffer: MTLBuffer?
    private lazy var previewDropletRing = MetalLiveBufferRing(device: device, label: "Drizzle Droplet Live Stroke")
    private var previewDropletCount = 0
    private var previewKey: PreviewKey?
    private var strokePhaseRandomized = false

    /// When randomized each stroke bakes a fixed phase offset (from its id) into
    /// its droplet life offsets so it animates independently instead of in lockstep.
    func setStrokePhaseRandomized(_ value: Bool) {
        guard value != strokePhaseRandomized else { return }
        strokePhaseRandomized = value
        chunks.removeAll(keepingCapacity: true)
        strokeKeys.removeAll(keepingCapacity: true)
        layerRanges.removeAll(keepingCapacity: true)
        layerDroplets.removeAll(keepingCapacity: true)
        previewBuffer = nil
        previewVertexCount = 0
        previewPathBuffer = nil
        previewDropletBuffer = nil
        previewDropletCount = 0
        previewKey = nil
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let coreVertex = library.makeFunction(name: "particleCloudCoreVertex"),
                  let coreFragment = library.makeFunction(name: "particleCloudCoreFragment"),
                  let dropletVertex = library.makeFunction(name: "particleCloudDropletVertex"),
                  let dropletFragment = library.makeFunction(name: "particleCloudDropletFragment") else { return nil }

            let coreDescriptor = MTLRenderPipelineDescriptor()
            coreDescriptor.label = "Drizzle Core"
            coreDescriptor.vertexFunction = coreVertex
            coreDescriptor.fragmentFunction = coreFragment
            coreDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            let coreAttachment = coreDescriptor.colorAttachments[0]!
            coreAttachment.isBlendingEnabled = true
            coreAttachment.sourceRGBBlendFactor = .sourceAlpha
            coreAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            coreAttachment.sourceAlphaBlendFactor = .one
            coreAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            corePipeline = try device.makeRenderPipelineState(descriptor: coreDescriptor)

            let dropletDescriptor = MTLRenderPipelineDescriptor()
            dropletDescriptor.label = "Drizzle Droplets"
            dropletDescriptor.vertexFunction = dropletVertex
            dropletDescriptor.fragmentFunction = dropletFragment
            dropletDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            let dropletAttachment = dropletDescriptor.colorAttachments[0]!
            dropletAttachment.isBlendingEnabled = true
            dropletAttachment.sourceRGBBlendFactor = .sourceAlpha
            dropletAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            dropletAttachment.sourceAlphaBlendFactor = .one
            dropletAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            dropletPipeline = try device.makeRenderPipelineState(descriptor: dropletDescriptor)
        } catch {
            assertionFailure("Unable to create Drizzle Metal pipelines: \(error)")
            return nil
        }
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where stroke.brush.kind == .particleCloud && stroke.usesGPUAnimatedRenderer {
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
        // Unrelated document edits do not affect cached drizzle geometry or its
        // combined droplet/path buffers. Avoid rebuilding all of them.
        guard newKeys != strokeKeys else { return }
        let prefixMatches = strokeKeys.count <= newKeys.count
            && zip(strokeKeys, newKeys).allSatisfy(==)
        if !prefixMatches {
            chunks.removeAll(keepingCapacity: true)
            strokeKeys.removeAll(keepingCapacity: true)
            layerRanges.removeAll(keepingCapacity: true)
        }

        // Core ribbon geometry is appended incrementally on prefix match.
        for descriptor in descriptors.dropFirst(strokeKeys.count) {
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

        // Droplet + path data references absolute offsets in one combined path
        // buffer, so rebuild per-layer combined buffers every update. Layers are
        // visited in document order, so per-layer batches are contiguous here.
        layerDroplets.removeAll(keepingCapacity: true)
        var combinedPaths: [SIMD4<Float>] = []
        var combinedDroplets: [Droplet] = []
        var lastLayer: UUID?
        for descriptor in descriptors {
            if lastLayer != descriptor.layerID {
                if let lastLayer, !combinedDroplets.isEmpty {
                    layerDroplets[lastLayer] = DropletBatch(
                        pathBuffer: makeBuffer(combinedPaths),
                        dropletBuffer: makeBuffer(combinedDroplets),
                        count: combinedDroplets.count
                    )
                }
                lastLayer = descriptor.layerID
                combinedPaths.removeAll(keepingCapacity: true)
                combinedDroplets.removeAll(keepingCapacity: true)
            }
            let (paths, droplets) = buildDropletData(
                stroke: descriptor.stroke,
                opacity: descriptor.opacity,
                scale: descriptor.scale,
                pathBase: combinedPaths.count,
                transform: { point in
                    CGPoint(
                        x: center.x + descriptor.offset.x + (point.x - center.x) * descriptor.scale,
                        y: center.y + descriptor.offset.y + (point.y - center.y) * descriptor.scale
                    )
                }
            )
            combinedPaths.append(contentsOf: paths)
            combinedDroplets.append(contentsOf: droplets)
        }
        if let lastLayer, !combinedDroplets.isEmpty {
            layerDroplets[lastLayer] = DropletBatch(
                pathBuffer: makeBuffer(combinedPaths),
                dropletBuffer: makeBuffer(combinedDroplets),
                count: combinedDroplets.count
            )
        }

        strokeKeys = newKeys
        previewBuffer = nil
        previewVertexCount = 0
        previewPathBuffer = nil
        previewDropletBuffer = nil
        previewDropletCount = 0
        previewKey = nil
    }

    /// Encodes a single layer's committed core + droplets so the canvas can
    /// interleave CPU and GPU content in layer order.
    func encode(
        encoder: MTLRenderCommandEncoder,
        transform: ViewTransform,
        layerID: UUID
    ) {
        let ranges = layerRanges[layerID] ?? []
        let droplets = layerDroplets[layerID]
        guard !ranges.isEmpty || droplets?.count ?? 0 > 0 else { return }
        var uniforms = transform
        encoder.pushDebugGroup("Drizzle Brush")

        if !ranges.isEmpty {
            encoder.setRenderPipelineState(corePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
            for range in ranges {
                let chunk = chunks[range.chunkIndex]
                encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
                let vertexStart = range.byteOffset / MemoryLayout<Vertex>.stride
                encoder.drawPrimitives(type: .triangle, vertexStart: vertexStart, vertexCount: range.vertexCount)
            }
        }

        if let droplets, droplets.count > 0 {
            encoder.setRenderPipelineState(dropletPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 2)
            if let dropletBuffer = droplets.dropletBuffer, let pathBuffer = droplets.pathBuffer {
                encoder.setVertexBuffer(dropletBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(pathBuffer, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: droplets.count)
            }
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
        let hasCore = previewVertexCount > 0
        let hasDrops = previewDropletCount > 0
        guard hasCore || hasDrops else { return }
        var uniforms = transform

        if hasCore {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "Drizzle Core Preview"
                encoder.setRenderPipelineState(corePipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
                if let previewBuffer, previewVertexCount > 0 {
                    encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
                }
                encoder.endEncoding()
            }
        }

        if hasDrops {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.label = "Drizzle Droplet Preview"
                encoder.setRenderPipelineState(dropletPipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 2)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 2)
                if let previewDropletBuffer, previewDropletCount > 0 {
                    encoder.setVertexBuffer(previewDropletBuffer, offset: 0, index: 0)
                    encoder.setVertexBuffer(previewPathBuffer, offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: previewDropletCount)
                }
                encoder.endEncoding()
            }
        }
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke, stroke.brush.kind == .particleCloud, let last = stroke.samples.last else {
            previewBuffer = nil
            previewVertexCount = 0
            previewPathBuffer = nil
            previewDropletBuffer = nil
            previewDropletCount = 0
            previewKey = nil
            return
        }
        let key = PreviewKey(sampleCount: stroke.samples.count, lastX: last.x, lastY: last.y, brush: stroke.brush)
        guard key != previewKey else { return }
        previewKey = key
        var vertices: [Vertex] = []
        append(stroke: stroke, opacity: 1, scale: 1, transform: { $0 }, to: &vertices)
        previewVertexCount = vertices.count
        previewBuffer = previewCoreRing.write(vertices)
        let (paths, droplets) = buildDropletData(
            stroke: stroke,
            opacity: 1,
            scale: 1,
            pathBase: 0,
            transform: { $0 }
        )
        previewPathBuffer = previewPathRing.write(paths)
        previewDropletBuffer = previewDropletRing.write(droplets)
        previewDropletCount = droplets.count
    }

    /// Builds the static core ribbon: a thin skeleton line plus two dense rows
    /// of attached blobs, all baked into one cached strip. uv.x is the arc
    /// distance from the start (negative in the cap extensions), uv.y spans the
    /// ribbon width in halfWidth units.
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

        let lineWidth = max(0.35, brush.size * (0.05 + brush.resolvedParticleCloudThickness * 0.55))
        let nominalBlobDiameter = brush.size * (0.11 + (1 - brush.resolvedParticleCloudScale) * 0.25)
        // Blob edge offset maxes out at lineWidth*0.38 + diameter*0.28, and a
        // blob radius maxes at diameter/2 (diameter up to nominal*1.22). The
        // ribbon must cover that whole band, with a little margin.
        let halfWidth = (lineWidth * 0.38 + nominalBlobDiameter * 0.952) * 1.1
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
        let fallOff = brush.resolvedParticleCloudFallOff
        let blobSpacing = max(
            0.35,
            nominalBlobDiameter * (0.88 - 0.44 * Foundation.sqrt(fallOff))
        )
        let naturalStationCount = max(2, Int(Foundation.floor(Double(totalLength) / blobSpacing)) + 1)
        let centerStationCount = min(560, naturalStationCount)
        let actualSpacing = naturalStationCount > 560
            ? Double(totalLength) / Double(max(1, centerStationCount - 1))
            : blobSpacing
        let parameters = SIMD4<Float>(
            Float(nominalBlobDiameter),
            Float(actualSpacing),
            Float(lineWidth / 2),
            Float(lineWidth * 0.15)
        )
        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let seed = UInt32(truncatingIfNeeded: stableStrokeSeed(stroke.id, base: brush.seed))

        vertices.reserveCapacity(vertices.count + (extended.count - 1) * 6)
        for index in 1..<extended.count {
            let start = extended[index - 1]
            let end = extended[index]
            let startNormal = normals[index - 1]
            let endNormal = normals[index]
            let sl = CGPoint(x: start.x + startNormal.x * halfWidth, y: start.y + startNormal.y * halfWidth)
            let sr = CGPoint(x: start.x - startNormal.x * halfWidth, y: start.y - startNormal.y * halfWidth)
            let el = CGPoint(x: end.x + endNormal.x * halfWidth, y: end.y + endNormal.y * halfWidth)
            let er = CGPoint(x: end.x - endNormal.x * halfWidth, y: end.y - endNormal.y * halfWidth)
            let a = vertex(sl, normal: waveNormal(startNormal), distance: distances[index - 1] - capExtension, across: -1, color: color, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, stationCount: Float(centerStationCount), seed: seed)
            let b = vertex(sr, normal: waveNormal(startNormal), distance: distances[index - 1] - capExtension, across: 1, color: color, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, stationCount: Float(centerStationCount), seed: seed)
            let c = vertex(el, normal: waveNormal(endNormal), distance: distances[index] - capExtension, across: -1, color: color, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, stationCount: Float(centerStationCount), seed: seed)
            let d = vertex(er, normal: waveNormal(endNormal), distance: distances[index] - capExtension, across: 1, color: color, parameters: parameters, halfWidth: halfWidth, totalLength: totalLength, stationCount: Float(centerStationCount), seed: seed)
            vertices.append(contentsOf: [a, b, c, c, b, d])
        }
    }

    /// Builds the combined path-point buffer and instanced droplet data for one
    /// stroke, exactly mirroring the CPU kernel's droplet emission math. The
    /// per-frame parts (life, emission slot, arc fraction, side) are derived in
    /// the shader from the baked cycleCount/lifeOffset/seed.
    private func buildDropletData(
        stroke: AnimatedStroke,
        opacity: Double,
        scale: CGFloat,
        pathBase: Int,
        transform: (CGPoint) -> CGPoint
    ) -> (paths: [SIMD4<Float>], droplets: [Droplet]) {
        let samples = stroke.bakedSamples()
        guard samples.count > 2 else { return ([], []) }
        let brush = stroke.brush
        let fallOff = brush.resolvedParticleCloudFallOff
        guard fallOff > 0.001 else { return ([], []) }
        let points = samples.map { transform($0.point) }
        var distances = [Double](repeating: 0, count: points.count)
        for index in 1..<points.count {
            distances[index] = distances[index - 1] + Foundation.hypot(
                points[index].x - points[index - 1].x,
                points[index].y - points[index - 1].y
            )
        }
        let total = distances.last ?? 0
        guard total > 0.001 else { return ([], []) }

        let lineWidth = max(0.35, brush.size * (0.05 + brush.resolvedParticleCloudThickness * 0.55))
        let nominalBlobDiameter = brush.size * (0.11 + (1 - brush.resolvedParticleCloudScale) * 0.25)
        let speed = brush.resolvedParticleCloudSpeed
        let strokeSeed = stableStrokeSeed(stroke.id, base: brush.seed)
        let seed32 = UInt32(truncatingIfNeeded: strokeSeed)
        let particlesPerHundred = fallOff * (34 + brush.resolvedParticleCloudScale * 34)
        let particleCount = min(
            480,
            max(1, Int((total / 100 * particlesPerHundred).rounded()))
        )

        var paths: [SIMD4<Float>] = []
        paths.reserveCapacity(points.count)
        for (index, point) in points.enumerated() {
            paths.append(SIMD4(Float(point.x), Float(point.y), Float(distances[index]), 0))
        }

        let color = SIMD4<Float>(
            Float(brush.color.red), Float(brush.color.green), Float(brush.color.blue),
            Float(brush.color.alpha * brush.opacity * opacity)
        )
        let phaseOffset = strokePhaseRandomized
            ? Double(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        var droplets: [Droplet] = []
        droplets.reserveCapacity(particleCount)
        for particleIndex in 0..<particleCount {
            let randomA = seeded(strokeSeed &+ 101, particleIndex)
            let randomB = seeded(strokeSeed &+ 313, particleIndex)
            let randomC = seeded(strokeSeed &+ 719, particleIndex)
            let cycleCount = speed < 0.01
                ? 0
                : max(1, Int((speed * (1.15 + randomA * 1.85)).rounded()))
            let lifeOffset = seeded(strokeSeed &+ 1_237, particleIndex) + phaseOffset
            let maxTravel = brush.size * (0.22 + randomB * 0.62)
            let diameter = max(0.45, nominalBlobDiameter * (0.28 + randomC * 0.42))
            droplets.append(Droplet(
                color: color,
                pathStart: UInt32(pathBase),
                pathCount: UInt32(points.count),
                totalLength: Float(total),
                lineHalf: Float(lineWidth / 2),
                nominalBlobDiameter: Float(nominalBlobDiameter),
                lifeOffset: Float(lifeOffset),
                cycleCount: Float(cycleCount),
                maxTravel: Float(maxTravel),
                radius: Float(diameter / 2),
                seed: seed32,
                reserved: Float(brush.resolvedWaveAmount / 100)
            ))
        }
        return (paths, droplets)
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint,
        distance: CGFloat,
        across: Float,
        color: SIMD4<Float>,
        parameters: SIMD4<Float>,
        halfWidth: CGFloat,
        totalLength: Float,
        stationCount: Float,
        seed: UInt32
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), across),
            color: color,
            parameters: parameters,
            halfWidth: Float(halfWidth),
            totalLength: totalLength,
            stationCount: stationCount,
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
            buffer.label = "Drizzle Geometry \(chunks.count)"
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

    private func makeBuffer<T>(_ elements: [T]) -> MTLBuffer? {
        guard !elements.isEmpty else { return nil }
        return elements.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
    }

    // Port of the CPU kernel's FNV-style stroke seed so droplet randomness is
    // stable across frames and strokes differ from each other.
    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }

    // Port of AnimatedBrushKernel's global `seeded(seed, index)`.
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

    // Fast 32-bit hash. The renderer stores a 32-bit stroke seed, so doing
    // 64-bit integer arithmetic in every covered fragment only wastes GPU ALU.
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

    // ---- Core pass (skeleton line + two dense rows of attached blobs) ----

    struct CoreVertexIn {
        float2 position;
        float2 normal;
        float2 uv;
        float4 color;
        float4 parameters;
        float halfWidth;
        float totalLength;
        float stationCount;
        uint seed;
    };

    struct CoreVertexOut {
        float4 position [[position]];
        float2 canvasPosition;
        float2 uv;
        float4 color;
        float4 parameters;
        float halfWidth;
        float totalLength;
        float stationCount;
        uint seed;
    };

    vertex CoreVertexOut particleCloudCoreVertex(
        uint id [[vertex_id]],
        const device CoreVertexIn *vertices [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]) {
        CoreVertexIn input = vertices[id];
        CoreVertexOut out;
        float2 point = input.position;
        if (dot(input.normal, input.normal) > 0.000001 && u.waveAmount > 0.0001 && input.totalLength > 0.001) {
            float progress = clamp(input.uv.x / input.totalLength, 0.0, 1.0);
            float envelope = pow(max(0.0, sin(3.14159265 * progress)), 0.35);
            float amplitude = u.waveAmount * max(8.0, input.parameters.x * 1.8);
            float wavelength = max(72.0, input.parameters.x * 16.0);
            float angle = input.uv.x / wavelength * 6.2831853 - u.phase * 6.2831853;
            point += input.normal * (sin(angle) * amplitude * envelope);
        }
        out.position = float4(canvasToClip(point, u), 0, 1);
        out.canvasPosition = point;
        out.uv = input.uv;
        out.color = input.color;
        out.parameters = input.parameters;
        out.halfWidth = input.halfWidth;
        out.totalLength = input.totalLength;
        out.stationCount = input.stationCount;
        out.seed = input.seed;
        return out;
    }

    fragment float4 particleCloudCoreFragment(
        CoreVertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(1)]]) {
        if (in.canvasPosition.x < 0.0 || in.canvasPosition.y < 0.0
            || in.canvasPosition.x > u.canvasSize.x || in.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }

        float halfWidth = in.halfWidth;
        float total = in.totalLength;
        float2 q = float2(in.uv.x, in.uv.y * halfWidth);
        float aa = max(0.75, fwidth(in.uv.x));

        // Thin skeleton core with round caps (capsule distance function).
        float skeletonHalf = in.parameters.w;
        float2 capCenter = float2(clamp(q.x, 0.0, total), 0.0);
        float skeletonDist = length(q - capCenter) - skeletonHalf;
        float skeletonAlpha = 1.0 - smoothstep(-aa, aa, skeletonDist);

        // Two dense rows of attached blobs. Only the handful of stations near
        // this fragment are evaluated, so cost stays bounded.
        float nominal = in.parameters.x;
        float spacing = in.parameters.y;
        float lineHalf = in.parameters.z;
        int stationCount = int(in.stationCount);
        float maxRadius = nominal * 1.22 / 2.0;
        int firstJ = int(floor((in.uv.x - maxRadius) / max(0.0001, spacing)));
        int lastJ = int(floor((in.uv.x + maxRadius) / max(0.0001, spacing)));
        float blobAcc = 0.0;
        for (int j = firstJ; j <= lastJ; j++) {
            if (j < 0 || j >= stationCount) continue;
            for (int sideIndex = 0; sideIndex < 2; sideIndex++) {
                int key = j * 2 + sideIndex;
                float sizeNoise = seededRandom(in.seed + 3019u, key);
                float offsetNoise = seededRandom(in.seed + 2417u, key) * 2.0 - 1.0;
                float diameter = max(0.48, nominal * (0.88 + sizeNoise * 0.34));
                float radius = diameter / 2.0;
                float edgeOffset = lineHalf * 0.76 + diameter * (0.20 + offsetNoise * 0.08);
                float side = sideIndex == 0 ? -1.0 : 1.0;
                float2 center = float2(float(j) * spacing, side * edgeOffset);
                float d = length(q - center);
                blobAcc += 1.0 - smoothstep(radius * 0.8, radius, d);
            }
        }
        float blobAlpha = min(blobAcc, 1.0);

        float finalAlpha = min(1.0, skeletonAlpha + blobAlpha) * in.color.a;
        if (finalAlpha <= 0.001) discard_fragment();
        return float4(in.color.rgb, finalAlpha);
    }

    // ---- Droplet pass (instanced shed droplets) ----

    struct DropletIn {
        float4 color;
        uint pathStart;
        uint pathCount;
        float totalLength;
        float lineHalf;
        float nominalBlobDiameter;
        float lifeOffset;
        float cycleCount;
        float maxTravel;
        float radius;
        uint seed;
        float reserved;
    };

    struct DropletVertexOut {
        float4 position [[position]];
        float2 canvasPosition;
        float2 local;
        float4 color;
        float fade;
        float radius;
    };

    vertex DropletVertexOut particleCloudDropletVertex(
        uint vid [[vertex_id]],
        uint iid [[instance_id]],
        const device DropletIn *droplets [[buffer(0)]],
        const device float4 *paths [[buffer(1)]],
        constant Uniforms &u [[buffer(2)]]) {
        DropletIn d = droplets[iid];

        // Life cycle derived from the animation phase. The emission slot picks a
        // seeded emission point along the path and an edge side that change per
        // cycle, exactly like the CPU kernel.
        float rawLifeFull = u.phase * d.cycleCount + d.lifeOffset;
        float life = fract(rawLifeFull);
        int cycleCountI = int(d.cycleCount);
        int emissionNumber = int(floor(rawLifeFull));
        int cycleSlot = cycleCountI > 0
            ? ((emissionNumber % cycleCountI) + cycleCountI) % cycleCountI
            : 0;
        float location = seededRandom(d.seed + uint(iid + 1) * 2009u, cycleSlot);
        float sideSeed = seededRandom(d.seed + 1919u, int(iid) * 31 + cycleSlot);
        float side = (iid % 2 == 0 ? 1.0 : -1.0) * (sideSeed > 0.82 ? -1.0 : 1.0);

        float outward = d.cycleCount <= 0.0 ? 0.0 : pow(life, 0.72);
        float fadeProgress = clamp((life - 0.68) / 0.22, 0.0, 1.0);
        float fade = d.cycleCount <= 0.0
            ? 1.0
            : 1.0 - fadeProgress * fadeProgress * (3.0 - 2.0 * fadeProgress);

        // Arc distance -> point on the polyline path. A binary search keeps
        // long Pencil strokes logarithmic; the former linear scan made Drizzle
        // progressively more expensive as a stroke accumulated samples.
        float arc = (0.03 + location * 0.94) * d.totalLength;
        uint end = d.pathStart + d.pathCount;
        uint low = d.pathStart + 1;
        uint high = end - 1;
        while (low < high) {
            uint middle = low + (high - low) / 2;
            if (paths[middle].z < arc) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        float4 segEnd = paths[low];
        float4 segStart = paths[max(d.pathStart, low - 1)];
        float segLen = max(1e-4, segEnd.z - segStart.z);
        float t = clamp((arc - segStart.z) / segLen, 0.0, 1.0);
        float2 base = mix(segStart.xy, segEnd.xy, t);
        float2 dir = (segEnd.xy - segStart.xy) / segLen;
        float2 normal = float2(-dir.y, dir.x);

        if (d.reserved > 0.5 && u.waveAmount > 0.0001 && d.totalLength > 0.001) {
            float progress = clamp(arc / d.totalLength, 0.0, 1.0);
            float envelope = pow(max(0.0, sin(3.14159265 * progress)), 0.35);
            float amplitude = d.reserved * u.waveAmount * max(8.0, d.nominalBlobDiameter * 1.8);
            float wavelength = max(72.0, d.nominalBlobDiameter * 16.0);
            float angle = arc / wavelength * 6.2831853 - u.phase * 6.2831853;
            base += normal * (sin(angle) * amplitude * envelope);
        }

        float travel = d.lineHalf + d.nominalBlobDiameter * 0.45 + outward * d.maxTravel;
        float2 center = base + normal * side * travel;

        float2 uv = float2(vid == 0 || vid == 4 || vid == 5 ? 0.0 : 1.0, vid >= 2 && vid <= 4 ? 1.0 : 0.0);
        float2 local = uv * 2.0 - 1.0;
        float2 pos = center + local * d.radius;

        DropletVertexOut out;
        out.position = float4(canvasToClip(pos, u), 0, 1);
        out.canvasPosition = pos;
        out.local = local;
        out.color = d.color;
        out.fade = fade;
        out.radius = d.radius;
        return out;
    }

    fragment float4 particleCloudDropletFragment(
        DropletVertexOut in [[stage_in]],
        constant Uniforms &u [[buffer(2)]]) {
        if (in.canvasPosition.x < 0.0 || in.canvasPosition.y < 0.0
            || in.canvasPosition.x > u.canvasSize.x || in.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }
        if (in.fade <= 0.002) discard_fragment();
        float dist = length(in.local);
        float alpha = (1.0 - smoothstep(0.7, 1.0, dist)) * in.fade * in.color.a;
        if (alpha <= 0.001) discard_fragment();
        return float4(in.color.rgb, alpha);
    }
    """#
}
