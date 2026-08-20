import MetalKit
import simd

/// Reusable triple buffer for geometry that changes while a Pencil stroke is
/// active. It prevents allocations on every sample and avoids overwriting
/// memory still referenced by an in-flight GPU command buffer.
final class MetalLiveBufferRing {
    private let device: MTLDevice
    private let label: String
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var index = -1

    init(device: MTLDevice, label: String = "Live Stroke") {
        self.device = device
        self.label = label
    }

    func write<Element>(_ elements: [Element]) -> MTLBuffer? {
        guard !elements.isEmpty else { return nil }
        index = (index + 1) % buffers.count
        let byteCount = elements.count * MemoryLayout<Element>.stride
        if buffers[index] == nil || buffers[index]!.length < byteCount {
            var capacity = 64 * 1024
            while capacity < byteCount { capacity *= 2 }
            buffers[index] = device.makeBuffer(length: capacity, options: .storageModeShared)
            buffers[index]?.label = "\(label) \(index)"
        }
        guard let buffer = buffers[index] else { return nil }
        elements.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                buffer.contents().copyMemory(from: source, byteCount: bytes.count)
            }
        }
        return buffer
    }

    func reset() {
        index = -1
    }
}

/// Shared GPU renderer for animated ribbon brushes that previously rebuilt a
/// full-canvas Core Graphics image every frame. Geometry is uploaded when a
/// stroke changes; animation is driven only by the `phase` uniform.
final class MetalProceduralBrushRenderer {
    static let supportedKinds: Set<BrushKind> = [.solidColor, .goo, .glitter, .gradient, .faded, .retro]

    private struct Vertex {
        var position: SIMD2<Float>
        var normal: SIMD2<Float>
        var uv: SIMD2<Float>
        var color1: SIMD4<Float>
        var color2: SIMD4<Float>
        var parameters0: SIMD4<Float>
        var parameters1: SIMD4<Float>
        var dropletData: SIMD4<Float>
        var dropletCurve0: SIMD4<Float>
        var dropletCurve1: SIMD4<Float>
        var dropletCurve2: SIMD4<Float>
        var dropletCurve3: SIMD4<Float>
        var halfWidth: Float
        var baseHalfWidth: Float
        var totalLength: Float
        var seed: Float
        var kind: Float
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
    }

    private struct PreviewKey: Equatable {
        var id: UUID
        var sampleCount: Int
        var lastX: Double
        var lastY: Double
        var brush: BrushSettings
    }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let previewRing: MetalLiveBufferRing
    private let chunkSize = 4 * 1024 * 1024
    private var chunks: [Chunk] = []
    private var strokeKeys: [StrokeKey] = []
    private var layerRanges: [UUID: [Range]] = [:]
    private var previewBuffer: MTLBuffer?
    private var previewVertexCount = 0
    private var previewKey: PreviewKey?
    private var strokePhaseRandomized = false

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        self.device = device
        previewRing = MetalLiveBufferRing(device: device, label: "Procedural Live Stroke")
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            guard let vertex = library.makeFunction(name: "proceduralVertex"),
                  let fragment = library.makeFunction(name: "proceduralFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Shared Procedural Brush Pipeline"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            let attachment = descriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            assertionFailure("Unable to create procedural Metal pipeline: \(error)")
            return nil
        }
    }

    func setStrokePhaseRandomized(_ value: Bool) {
        guard value != strokePhaseRandomized else { return }
        strokePhaseRandomized = value
        resetGeometry()
    }

    func update(document: WiggleDocument) {
        var descriptors: [Descriptor] = []
        let center = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            for stroke in layer.strokes where Self.supportedKinds.contains(stroke.brush.kind) && stroke.usesGPUAnimatedRenderer {
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
            append(
                stroke: descriptor.stroke,
                opacity: descriptor.opacity,
                scale: descriptor.scale,
                transform: { point in
                    CGPoint(
                        x: center.x + descriptor.offset.x + (point.x - center.x) * descriptor.scale,
                        y: center.y + descriptor.offset.y + (point.y - center.y) * descriptor.scale
                    )
                },
                to: &vertices
            )
            let range = appendToChunks(vertices)
            if range.vertexCount > 0 { append(range, to: descriptor.layerID) }
        }
        strokeKeys = newKeys
        clearPreview()
    }

    func encode(
        encoder: MTLRenderCommandEncoder,
        transform: ViewTransform,
        layerID: UUID
    ) {
        let ranges = layerRanges[layerID] ?? []
        guard !ranges.isEmpty else { return }
        encoder.pushDebugGroup("Shared Procedural Brushes")
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        for range in ranges {
            encoder.setVertexBuffer(chunks[range.chunkIndex].buffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: range.byteOffset / MemoryLayout<Vertex>.stride,
                vertexCount: range.vertexCount
            )
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
        encoder.label = "Shared Procedural Brush Preview"
        encoder.setRenderPipelineState(pipeline)
        var uniforms = transform
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewTransform>.stride, index: 1)
        encoder.setVertexBuffer(previewBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: previewVertexCount)
        encoder.endEncoding()
    }

    private func updatePreview(_ stroke: AnimatedStroke?) {
        guard let stroke,
              Self.supportedKinds.contains(stroke.brush.kind),
              let last = stroke.samples.last else {
            clearPreview()
            return
        }
        let key = PreviewKey(
            id: stroke.id,
            sampleCount: stroke.samples.count,
            lastX: last.x,
            lastY: last.y,
            brush: stroke.brush
        )
        guard key != previewKey else { return }
        previewKey = key
        var vertices: [Vertex] = []
        append(stroke: stroke, opacity: 1, scale: 1, transform: { $0 }, to: &vertices)
        previewVertexCount = vertices.count
        previewBuffer = previewRing.write(vertices)
    }

    private func clearPreview() {
        previewBuffer = nil
        previewVertexCount = 0
        previewKey = nil
        previewRing.reset()
    }

    private func resetGeometry() {
        chunks.removeAll(keepingCapacity: true)
        strokeKeys.removeAll(keepingCapacity: true)
        layerRanges.removeAll(keepingCapacity: true)
        clearPreview()
    }

    private func append(
        stroke: AnimatedStroke,
        opacity: Double,
        scale: CGFloat,
        transform: (CGPoint) -> CGPoint,
        to vertices: inout [Vertex]
    ) {
        let source = stroke.samples
        guard !source.isEmpty else { return }
        let brush = stroke.brush
        let samples: [StrokeSample]
        let points: [CGPoint]
        let splineTangents: [CGPoint]?
        let gooStations: [GooSplineStation]?
        if brush.kind == .goo {
            let stations = GooSplineSampler.stations(
                source: source,
                brush: brush,
                scale: scale,
                transform: transform
            )
            samples = stations.map(\.sample)
            points = stations.map(\.point)
            splineTangents = stations.map(\.tangent)
            gooStations = stations
        } else {
            guard source.count > 1 else { return }
            let minimumDistance = max(0.6, min(2.5, brush.size * Double(scale) * 0.035))
            var filteredSamples: [StrokeSample] = []
            var filteredPoints: [CGPoint] = []
            filteredSamples.reserveCapacity(source.count)
            filteredPoints.reserveCapacity(source.count)
            for (index, sample) in source.enumerated() {
                let point = transform(sample.point)
                if index == 0 || index == source.count - 1
                    || hypot(point.x - (filteredPoints.last?.x ?? point.x), point.y - (filteredPoints.last?.y ?? point.y)) >= minimumDistance {
                    filteredSamples.append(sample)
                    filteredPoints.append(point)
                }
            }
            samples = filteredSamples
            points = filteredPoints
            splineTangents = nil
            gooStations = nil
        }
        guard samples.count > 1 else { return }

        var normals: [CGPoint] = []
        var tangents: [CGPoint] = []
        var baseWidths: [CGFloat] = []
        var widths: [CGFloat] = []
        var distances = Array(repeating: CGFloat.zero, count: samples.count)
        normals.reserveCapacity(samples.count)
        tangents.reserveCapacity(samples.count)
        baseWidths.reserveCapacity(samples.count)
        widths.reserveCapacity(samples.count)
        let envelopeScale: CGFloat = brush.kind == .goo
            ? CGFloat(1.18 + brush.resolvedGooWaviness * 0.42)
            : 1
        for index in samples.indices {
            let tangent: CGPoint
            if brush.kind == .goo {
                let incoming = index > 0
                    ? unitDirection(from: points[index - 1], to: points[index])
                    : unitDirection(from: points[index], to: points[index + 1])
                let outgoing = index + 1 < points.count
                    ? unitDirection(from: points[index], to: points[index + 1])
                    : incoming
                var tx = incoming.x + outgoing.x
                var ty = incoming.y + outgoing.y
                var tangentLength = hypot(tx, ty)
                if tangentLength < 0.001 {
                    let fallback = splineTangents?[index] ?? outgoing
                    tx = fallback.x
                    ty = fallback.y
                    tangentLength = max(0.001, hypot(tx, ty))
                }
                tangent = CGPoint(x: tx / tangentLength, y: ty / tangentLength)
            } else {
                let incoming = unitDirection(
                    from: points[max(0, index - 1)],
                    to: points[index]
                )
                let outgoing = unitDirection(
                    from: points[index],
                    to: points[min(points.count - 1, index + 1)]
                )
                var tx = incoming.x + outgoing.x
                var ty = incoming.y + outgoing.y
                var tangentLength = hypot(tx, ty)
                if tangentLength < 0.001 {
                    tx = outgoing.x
                    ty = outgoing.y
                    tangentLength = max(0.001, hypot(tx, ty))
                }
                tangent = CGPoint(x: tx / tangentLength, y: ty / tangentLength)
            }
            tangents.append(tangent)
            normals.append(CGPoint(x: -tangent.y, y: tangent.x))
            let baseWidth = localWidth(samples[index], index: index, count: samples.count, brush: brush)
                * scale
            baseWidths.append(baseWidth)
            widths.append(baseWidth * envelopeScale)
            if index > 0 {
                distances[index] = distances[index - 1]
                    + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y)
            }
        }

        let colors = makeColors(brush: brush, opacity: opacity)
        let parameters = makeParameters(
            brush: brush,
            isPreview: stroke.isPreview,
            contentScale: Double(scale)
        )
        let totalLength = Float(max(0.001, distances.last ?? 0))
        let seed = stableSeed(stroke.id, base: brush.seed)
        let kind = kindValue(brush.kind)
        let phaseOffset = strokePhaseRandomized
            ? Float(AnimatedDrawingRenderer.strokePhaseOffset(stroke.id))
            : 0
        var parameters1 = SIMD4<Float>(
            phaseOffset,
            brush.resolvedEndStyle == .cut ? 1 : 0,
            0,
            0
        )
        if brush.kind == .goo {
            parameters1.z = Float(brush.size * Double(scale))
            parameters1.w = Float(max(1, brush.loopCycles))
        }
        if brush.kind == .gradient || brush.kind == .solidColor {
            parameters1.z = brush.resolvedGradientMergesAcrossStrokes ? 1 : 0
        }
        if brush.kind == .solidColor {
            parameters1.w = Float(10 + brush.resolvedWaveAmount / 100)
        }
        if brush.kind == .glitter {
            parameters1.w = Float(brush.resolvedWaveAmount / 100)
        }
        if brush.kind == .retro {
            parameters1.z = Float(brush.resolvedTrippyColorCount)
        }

        let gooDiameter = brush.size * Double(scale)
        let gooEvents: [GooDropletEvent]
        // Droplet planning is the most expensive part of Goo geometry. It is
        // useless while the stroke is still under the pencil (droplets are a
        // committed-artwork effect and the shader does not gate them on the
        // preview flag), so skip it for preview strokes to keep the live tip
        // response immediate; the full planning runs once on commit.
        if brush.kind == .goo, !stroke.isPreview, let gooStations {
            gooEvents = GooDropletPlanner.events(
                stations: gooStations,
                distances: distances.map(Double.init),
                brush: brush,
                strokeID: stroke.id,
                diameter: gooDiameter
            )
        } else {
            gooEvents = []
        }
        func encodedEvent(_ event: GooDropletEvent) -> SIMD4<Float> {
            SIMD4(
                Float(event.arcDistance),
                Float(-event.side),
                Float(event.startPhase),
                Float(event.detachmentEligible ? event.variation : -1 - event.variation)
            )
        }
        func embeddedEvents(near distance: CGFloat, span: CGFloat) -> (SIMD4<Float>, SIMD4<Float>) {
            let reach = gooDiameter * 1.35 + Double(span) * 0.5
            let nearby = gooEvents
                .filter { abs($0.arcDistance - Double(distance)) <= reach }
                .sorted { abs($0.arcDistance - Double(distance)) < abs($1.arcDistance - Double(distance)) }
            let none = SIMD4<Float>(-1, 0, 0, 0)
            return (
                nearby.first.map(encodedEvent) ?? none,
                nearby.dropFirst().first.map(encodedEvent) ?? none
            )
        }

        // Adjacent GOO segments share their center, tangent, normal, radius,
        // and arc length exactly. One canvas pixel of axial overlap covers the
        // antialiasing band; round joins below cover the curved exterior.
        // Per-stroke gradient anchor: the stroke's own bounding box, projected
        // onto its own diagonal. Baked into every vertex so the shader colors a
        // pixel from that stroke's own field — a looping stroke fuses seamlessly,
        // while a brand-new stroke carries a separate gradient.
        let gradientAnchor: SIMD4<Float>
        if brush.kind == .gradient || brush.kind == .solidColor {
            var minX = CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude
            var maxY = -CGFloat.greatestFiniteMagnitude
            for p in points {
                minX = min(minX, p.x)
                minY = min(minY, p.y)
                maxX = max(maxX, p.x)
                maxY = max(maxY, p.y)
            }
            var dx = maxX - minX
            var dy = maxY - minY
            let diagonal = hypot(dx, dy)
            if diagonal < 0.001 {
                dx = 1
                dy = 0
            } else {
                dx /= diagonal
                dy /= diagonal
            }
            let half = Float(diagonal * 0.5)
            gradientAnchor = SIMD4(
                Float((minX + maxX) * 0.5),
                Float((minY + maxY) * 0.5),
                Float(dx) * half,
                Float(dy) * half
            )
        } else {
            gradientAnchor = .zero
        }

        // Retro carries the third, fourth, and fifth palette colors in the free
        // dropletCurve slots (first two ride in color1/color2). Each vertex of
        // the whole stroke carries the same full palette so the color cycle is
        // uniform along the ribbon.
        func retroValue(_ color: CodableColor) -> SIMD4<Float> {
            SIMD4(
                Float(color.red), Float(color.green), Float(color.blue),
                Float(color.alpha * brush.opacity * opacity)
            )
        }
        let retroColorCurve: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
        if brush.kind == .retro {
            retroColorCurve = (
                retroValue(brush.resolvedTertiaryColor),
                retroValue(brush.resolvedQuaternaryColor),
                retroValue(brush.resolvedQuinaryColor)
            )
        } else {
            retroColorCurve = (.zero, .zero, .zero)
        }

        let gooJoinOverlap: CGFloat = brush.kind == .goo ? 1 : 0
        let gooEventEnvelope = gooEvents.isEmpty ? 0 : CGFloat(gooDiameter * 0.28)

        vertices.reserveCapacity(vertices.count + (samples.count - 1) * 6 + 12)
        for index in 1..<samples.count {
            var start = points[index - 1]
            var end = points[index]
            let startNormal = normals[index - 1]
            let endNormal = normals[index]
            let startHalf = widths[index - 1] / 2 + gooEventEnvelope
            let endHalf = widths[index] / 2 + gooEventEnvelope
            let startBaseHalf = baseWidths[index - 1] / 2
            let endBaseHalf = baseWidths[index] / 2
            var startDistance = distances[index - 1]
            var endDistance = distances[index]
            let segmentStartDistance = startDistance
            let segmentEndDistance = endDistance
            if index == 1 {
                start.x -= tangents[0].x * startHalf
                start.y -= tangents[0].y * startHalf
                startDistance = -startHalf
            }
            if index == samples.count - 1 {
                end.x += tangents[index].x * endHalf
                end.y += tangents[index].y * endHalf
                endDistance += endHalf
            }
            if gooJoinOverlap > 0 {
                if index > 1 {
                    start.x -= tangents[index - 1].x * gooJoinOverlap
                    start.y -= tangents[index - 1].y * gooJoinOverlap
                    startDistance -= gooJoinOverlap
                }
                if index < samples.count - 1 {
                    end.x += tangents[index].x * gooJoinOverlap
                    end.y += tangents[index].y * gooJoinOverlap
                    endDistance += gooJoinOverlap
                }
            }
            let sl = CGPoint(x: start.x + startNormal.x * startHalf, y: start.y + startNormal.y * startHalf)
            let sr = CGPoint(x: start.x - startNormal.x * startHalf, y: start.y - startNormal.y * startHalf)
            let el = CGPoint(x: end.x + endNormal.x * endHalf, y: end.y + endNormal.y * endHalf)
            let er = CGPoint(x: end.x - endNormal.x * endHalf, y: end.y - endNormal.y * endHalf)
            let segmentData = brush.kind == .goo
                ? SIMD4<Float>(Float(segmentStartDistance), Float(segmentEndDistance), 0, 0)
                : .zero
            let segmentPoints = brush.kind == .goo
                ? SIMD4<Float>(
                    Float(points[index - 1].x), Float(points[index - 1].y),
                    Float(points[index].x), Float(points[index].y)
                )
                : .zero
            let segmentNormals = brush.kind == .goo
                ? SIMD4<Float>(
                    Float(startNormal.x), Float(startNormal.y),
                    Float(endNormal.x), Float(endNormal.y)
                )
                : .zero
            let embedded = embeddedEvents(
                near: (segmentStartDistance + segmentEndDistance) * 0.5,
                span: segmentEndDistance - segmentStartDistance
            )
            let gradientPoints = (brush.kind == .gradient || brush.kind == .solidColor) ? gradientAnchor : segmentPoints
            let retroCurve: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = retroColorCurve
            let a = vertex(sl, normal: startNormal, distance: startDistance, across: -1, color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: startHalf, baseHalfWidth: startBaseHalf, totalLength: totalLength, seed: seed, kind: kind, dropletData: segmentData, dropletCurve0: brush.kind == .retro ? retroCurve.0 : gradientPoints, dropletCurve1: brush.kind == .retro ? retroCurve.1 : segmentNormals, dropletCurve2: brush.kind == .retro ? retroCurve.2 : embedded.0, dropletCurve3: embedded.1)
            let b = vertex(sr, normal: startNormal, distance: startDistance, across: 1, color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: startHalf, baseHalfWidth: startBaseHalf, totalLength: totalLength, seed: seed, kind: kind, dropletData: segmentData, dropletCurve0: brush.kind == .retro ? retroCurve.0 : gradientPoints, dropletCurve1: brush.kind == .retro ? retroCurve.1 : segmentNormals, dropletCurve2: brush.kind == .retro ? retroCurve.2 : embedded.0, dropletCurve3: embedded.1)
            let c = vertex(el, normal: endNormal, distance: endDistance, across: -1, color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: endHalf, baseHalfWidth: endBaseHalf, totalLength: totalLength, seed: seed, kind: kind, dropletData: segmentData, dropletCurve0: brush.kind == .retro ? retroCurve.0 : gradientPoints, dropletCurve1: brush.kind == .retro ? retroCurve.1 : segmentNormals, dropletCurve2: brush.kind == .retro ? retroCurve.2 : embedded.0, dropletCurve3: embedded.1)
            let d = vertex(er, normal: endNormal, distance: endDistance, across: 1, color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: endHalf, baseHalfWidth: endBaseHalf, totalLength: totalLength, seed: seed, kind: kind, dropletData: segmentData, dropletCurve0: brush.kind == .retro ? retroCurve.0 : gradientPoints, dropletCurve1: brush.kind == .retro ? retroCurve.1 : segmentNormals, dropletCurve2: brush.kind == .retro ? retroCurve.2 : embedded.0, dropletCurve3: embedded.1)
            vertices.append(contentsOf: [a, b, c, c, b, d])
        }

        if brush.kind == .goo, samples.count > 2 {
            for index in 1..<(samples.count - 1) {
                let center = points[index]
                let tangent = tangents[index]
                let normal = normals[index]
                let extent = widths[index] / 2 + gooEventEnvelope + 1
                func joinPoint(along: CGFloat, across: CGFloat) -> CGPoint {
                    CGPoint(
                        x: center.x + tangent.x * along + normal.x * across,
                        y: center.y + tangent.y * along + normal.y * across
                    )
                }
                let joinData = SIMD4<Float>(Float(distances[index]), 0, 0, 0)
                let embedded = embeddedEvents(near: distances[index], span: 0)
                let topLeft = vertex(joinPoint(along: -extent, across: -extent), distance: -extent, across: Float(-extent), color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: widths[index] / 2, baseHalfWidth: baseWidths[index] / 2, totalLength: totalLength, seed: seed, kind: 5, dropletData: joinData, dropletCurve2: embedded.0, dropletCurve3: embedded.1)
                let bottomLeft = vertex(joinPoint(along: -extent, across: extent), distance: -extent, across: Float(extent), color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: widths[index] / 2, baseHalfWidth: baseWidths[index] / 2, totalLength: totalLength, seed: seed, kind: 5, dropletData: joinData, dropletCurve2: embedded.0, dropletCurve3: embedded.1)
                let topRight = vertex(joinPoint(along: extent, across: -extent), distance: extent, across: Float(-extent), color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: widths[index] / 2, baseHalfWidth: baseWidths[index] / 2, totalLength: totalLength, seed: seed, kind: 5, dropletData: joinData, dropletCurve2: embedded.0, dropletCurve3: embedded.1)
                let bottomRight = vertex(joinPoint(along: extent, across: extent), distance: extent, across: Float(extent), color1: colors.0, color2: colors.1, parameters0: parameters, parameters1: parameters1, halfWidth: widths[index] / 2, baseHalfWidth: baseWidths[index] / 2, totalLength: totalLength, seed: seed, kind: 5, dropletData: joinData, dropletCurve2: embedded.0, dropletCurve3: embedded.1)
                vertices.append(contentsOf: [
                    topLeft, bottomLeft, topRight,
                    topRight, bottomLeft, bottomRight
                ])
            }
        }

        if brush.kind == .goo {
            let diameter = CGFloat(brush.size * Double(scale))
            // Covers the monotonic arc-length travel plus the triplet's short
            // forward separation without allowing its analytical field to clip.
            let alongExtent = diameter * 2.15
            for event in gooEvents {
                let index = event.stationIndex
                let nextIndex = index + 1
                guard points.indices.contains(index), points.indices.contains(nextIndex) else { continue }
                let fraction = CGFloat(event.stationFraction)
                let center = CGPoint(
                    x: points[index].x + (points[nextIndex].x - points[index].x) * fraction,
                    y: points[index].y + (points[nextIndex].y - points[index].y) * fraction
                )
                var tangent = CGPoint(
                    x: tangents[index].x + (tangents[nextIndex].x - tangents[index].x) * fraction,
                    y: tangents[index].y + (tangents[nextIndex].y - tangents[index].y) * fraction
                )
                let tangentLength = max(0.000_001, hypot(tangent.x, tangent.y))
                tangent.x /= tangentLength
                tangent.y /= tangentLength
                let normal = CGPoint(x: -tangent.y, y: tangent.x)
                let localBaseHalfWidth = (
                    baseWidths[index] + (baseWidths[nextIndex] - baseWidths[index]) * fraction
                ) / 2
                let inwardExtent = diameter * 0.55
                let outwardExtent = diameter * 1.95
                let lowerOutward = event.side > 0 ? -inwardExtent : -outwardExtent
                let upperOutward = event.side > 0 ? outwardExtent : inwardExtent
                func point(along: CGFloat, outward: CGFloat) -> CGPoint {
                    CGPoint(
                        x: center.x + tangent.x * along + normal.x * outward,
                        y: center.y + tangent.y * along + normal.y * outward
                    )
                }
                let data = SIMD4<Float>(
                    Float(event.arcDistance), Float(-event.side),
                    Float(event.startPhase),
                    Float(event.detachmentEligible ? event.variation : -1 - event.variation)
                )
                func sampleCurve(at targetDistance: CGFloat) -> (point: CGPoint, halfWidth: CGFloat) {
                    let target = min(totalLength, max(0, Float(targetDistance)))
                    var lower = 0
                    var upper = distances.count - 1
                    while lower + 1 < upper {
                        let middle = (lower + upper) / 2
                        if Float(distances[middle]) <= target {
                            lower = middle
                        } else {
                            upper = middle
                        }
                    }
                    lower = min(distances.count - 2, max(0, lower))
                    let span = max(0.000_001, distances[lower + 1] - distances[lower])
                    let sampleFraction = CGFloat((target - Float(distances[lower])) / Float(span))
                    return (
                        CGPoint(
                            x: points[lower].x + (points[lower + 1].x - points[lower].x) * sampleFraction,
                            y: points[lower].y + (points[lower + 1].y - points[lower].y) * sampleFraction
                        ),
                        (baseWidths[lower] + (baseWidths[lower + 1] - baseWidths[lower]) * sampleFraction) / 2
                    )
                }
                // Five globally-resolved samples cache a +/-1.8-diameter
                // centerline window. The unchanged travel + triplet formulas
                // require at most 1.61 diameters, so every moving component is
                // sampled inside this window; only true stroke endpoints clamp.
                let frameStep = diameter * 0.90
                let curveSamples = (-2...2).map { step -> (point: CGPoint, halfWidth: CGFloat) in
                    let sample = sampleCurve(
                        at: CGFloat(event.arcDistance) + CGFloat(step) * frameStep
                    )
                    let delta = CGPoint(x: sample.point.x - center.x, y: sample.point.y - center.y)
                    return (
                        CGPoint(
                            x: delta.x * tangent.x + delta.y * tangent.y,
                            y: -(delta.x * normal.x + delta.y * normal.y)
                        ),
                        sample.halfWidth
                    )
                }
                let curve0 = SIMD4<Float>(
                    Float(curveSamples[0].point.x), Float(curveSamples[0].point.y),
                    Float(curveSamples[1].point.x), Float(curveSamples[1].point.y)
                )
                let curve1 = SIMD4<Float>(
                    Float(curveSamples[2].point.x), Float(curveSamples[2].point.y),
                    Float(curveSamples[3].point.x), Float(curveSamples[3].point.y)
                )
                let curve2 = SIMD4<Float>(
                    Float(curveSamples[4].point.x), Float(curveSamples[4].point.y),
                    Float(curveSamples[0].halfWidth), Float(curveSamples[1].halfWidth)
                )
                let curve3 = SIMD4<Float>(
                    Float(curveSamples[2].halfWidth), Float(curveSamples[3].halfWidth),
                    Float(curveSamples[4].halfWidth), Float(frameStep)
                )
                let topLeft = vertex(
                    point(along: -alongExtent, outward: lowerOutward),
                    distance: -alongExtent, across: Float(-lowerOutward),
                    color1: colors.0, color2: colors.1,
                    parameters0: parameters, parameters1: parameters1,
                    halfWidth: outwardExtent, baseHalfWidth: localBaseHalfWidth,
                    totalLength: totalLength, seed: seed, kind: 4,
                    dropletData: data, dropletCurve0: curve0, dropletCurve1: curve1,
                    dropletCurve2: curve2, dropletCurve3: curve3
                )
                let bottomLeft = vertex(
                    point(along: -alongExtent, outward: upperOutward),
                    distance: -alongExtent, across: Float(-upperOutward),
                    color1: colors.0, color2: colors.1,
                    parameters0: parameters, parameters1: parameters1,
                    halfWidth: outwardExtent, baseHalfWidth: localBaseHalfWidth,
                    totalLength: totalLength, seed: seed, kind: 4,
                    dropletData: data, dropletCurve0: curve0, dropletCurve1: curve1,
                    dropletCurve2: curve2, dropletCurve3: curve3
                )
                let topRight = vertex(
                    point(along: alongExtent, outward: lowerOutward),
                    distance: alongExtent, across: Float(-lowerOutward),
                    color1: colors.0, color2: colors.1,
                    parameters0: parameters, parameters1: parameters1,
                    halfWidth: outwardExtent, baseHalfWidth: localBaseHalfWidth,
                    totalLength: totalLength, seed: seed, kind: 4,
                    dropletData: data, dropletCurve0: curve0, dropletCurve1: curve1,
                    dropletCurve2: curve2, dropletCurve3: curve3
                )
                let bottomRight = vertex(
                    point(along: alongExtent, outward: upperOutward),
                    distance: alongExtent, across: Float(-upperOutward),
                    color1: colors.0, color2: colors.1,
                    parameters0: parameters, parameters1: parameters1,
                    halfWidth: outwardExtent, baseHalfWidth: localBaseHalfWidth,
                    totalLength: totalLength, seed: seed, kind: 4,
                    dropletData: data, dropletCurve0: curve0, dropletCurve1: curve1,
                    dropletCurve2: curve2, dropletCurve3: curve3
                )
                vertices.append(contentsOf: [
                    topLeft, bottomLeft, topRight,
                    topRight, bottomLeft, bottomRight
                ])
            }
        }
    }

    private func unitDirection(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: dx / length, y: dy / length)
    }

    private func makeColors(brush: BrushSettings, opacity: Double) -> (SIMD4<Float>, SIMD4<Float>) {
        func value(_ color: CodableColor, opacityMultiplier: Double = 1) -> SIMD4<Float> {
            SIMD4(
                Float(color.red), Float(color.green), Float(color.blue),
                Float(color.alpha * brush.opacity * opacity * opacityMultiplier)
            )
        }
        if brush.kind == .faded {
            return (
                value(brush.color, opacityMultiplier: brush.resolvedFadedTextureOpacity),
                value(brush.resolvedFadedBaseColor, opacityMultiplier: brush.resolvedFadedBaseOpacity)
            )
        }
        let secondColor = brush.kind == .solidColor && !brush.resolvedColoringUsesGradient
            ? brush.color
            : brush.resolvedSecondaryColor
        return (value(brush.color), value(secondColor))
    }

    private func makeParameters(
        brush: BrushSettings,
        isPreview: Bool,
        contentScale: Double
    ) -> SIMD4<Float> {
        switch brush.kind {
        case .goo:
            return SIMD4(
                Float(brush.resolvedGooSpeed),
                Float(brush.resolvedGooThickness),
                Float(brush.resolvedGooWaviness),
                Float(brush.resolvedGooWaveLength)
            )
        case .glitter:
            return SIMD4(
                Float(brush.resolvedGlitterSpeed),
                Float(brush.resolvedGlitterDensity),
                Float(brush.resolvedSparkleAmount),
                Float(max(1, brush.spacing))
            )
        case .gradient:
            return SIMD4(Float(brush.resolvedGradientCyclesPerLoop), 0, 0, 0)
        case .solidColor:
            return .zero
        case .retro:
            return SIMD4(Float(brush.resolvedGradientCyclesPerLoop), 0, 0, 0)
        case .faded:
            return SIMD4(
                Float(brush.resolvedFadedSpeed),
                Float(brush.resolvedFadedAmount),
                Float(brush.resolvedTextureDensity),
                Float(brush.resolvedTextureRoughness)
            )
        default:
            return .zero
        }
    }

    private func kindValue(_ kind: BrushKind) -> Float {
        switch kind {
        case .goo: 0
        case .glitter: 1
        case .solidColor, .gradient: 2
        case .faded: 3
        case .retro: 6
        default: -1
        }
    }

    private func stableSeed(_ id: UUID, base: UInt64) -> Float {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return Float(hash & 0x00FF_FFFF) / Float(0x0100_0000)
    }

    private func localWidth(_ sample: StrokeSample, index: Int, count: Int, brush: BrushSettings) -> CGFloat {
        let pressure = 1 + (sample.pressure - 0.5) * brush.pressureSize
        let tilt = 1 + sample.tilt * brush.tiltResponse * 0.5
        let progress = count > 1 ? Double(index) / Double(count - 1) : 0.5
        let taperZone = 0.15
        let taper: Double
        if progress < taperZone {
            taper = brush.resolvedStartWidthScale
                + (1 - brush.resolvedStartWidthScale) * progress / taperZone
        } else if progress > 1 - taperZone {
            taper = 1 + (brush.resolvedEndWidthScale - 1)
                * (progress - (1 - taperZone)) / taperZone
        } else {
            taper = 1
        }
        return max(0.35, brush.size * pressure * tilt * taper)
    }

    private func vertex(
        _ point: CGPoint,
        normal: CGPoint = .zero,
        distance: CGFloat,
        across: Float,
        color1: SIMD4<Float>,
        color2: SIMD4<Float>,
        parameters0: SIMD4<Float>,
        parameters1: SIMD4<Float>,
        halfWidth: CGFloat,
        baseHalfWidth: CGFloat,
        totalLength: Float,
        seed: Float,
        kind: Float,
        dropletData: SIMD4<Float> = .zero,
        dropletCurve0: SIMD4<Float> = .zero,
        dropletCurve1: SIMD4<Float> = .zero,
        dropletCurve2: SIMD4<Float> = .zero,
        dropletCurve3: SIMD4<Float> = .zero
    ) -> Vertex {
        Vertex(
            position: SIMD2(Float(point.x), Float(point.y)),
            normal: SIMD2(Float(normal.x), Float(normal.y)),
            uv: SIMD2(Float(distance), across),
            color1: color1,
            color2: color2,
            parameters0: parameters0,
            parameters1: parameters1,
            dropletData: dropletData,
            dropletCurve0: dropletCurve0,
            dropletCurve1: dropletCurve1,
            dropletCurve2: dropletCurve2,
            dropletCurve3: dropletCurve3,
            halfWidth: Float(halfWidth),
            baseHalfWidth: Float(baseHalfWidth),
            totalLength: totalLength,
            seed: seed,
            kind: kind
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
            buffer.label = "Procedural Geometry \(chunks.count)"
            chunks.append(Chunk(buffer: buffer, usedBytes: 0))
        }
        let index = chunks.count - 1
        let byteOffset = chunks[index].usedBytes
        vertices.withUnsafeBytes { bytes in
            if let source = bytes.baseAddress {
                chunks[index].buffer.contents().advanced(by: byteOffset)
                    .copyMemory(from: source, byteCount: bytes.count)
            }
        }
        chunks[index].usedBytes += byteCount
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

    constant float kPi = 3.14159265358979323846;

    struct VertexIn {
        float2 position;
        float2 normal;
        float2 uv;
        float4 color1;
        float4 color2;
        float4 parameters0;
        float4 parameters1;
        float4 dropletData;
        float4 dropletCurve0;
        float4 dropletCurve1;
        float4 dropletCurve2;
        float4 dropletCurve3;
        float halfWidth;
        float baseHalfWidth;
        float totalLength;
        float seed;
        float kind;
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
        float4 color1;
        float4 color2;
        float4 parameters0;
        float4 parameters1;
        float4 dropletData;
        float4 dropletCurve0;
        float4 dropletCurve1;
        float4 dropletCurve2;
        float4 dropletCurve3;
        float halfWidth;
        float baseHalfWidth;
        float totalLength;
        float seed;
        float kind;
    };

    float2 canvasToClip(float2 point, constant Uniforms &u) {
        float2 p = (point / u.canvasSize - 0.5) * u.fittedSize * u.zoom;
        float c = cos(u.rotation);
        float s = sin(u.rotation);
        p = float2(p.x * c - p.y * s, p.x * s + p.y * c);
        p += u.viewSize * 0.5 + u.centerOffset;
        return float2(p.x / u.viewSize.x * 2.0 - 1.0, 1.0 - p.y / u.viewSize.y * 2.0);
    }

    vertex VertexOut proceduralVertex(
        uint id [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]) {
        VertexIn input = vertices[id];
        VertexOut out;
        float2 point = input.position;
        float waveStrength = input.kind == 1.0
            ? max(0.0, input.parameters1.w)
            : (input.kind == 2.0 && input.parameters1.w >= 10.0
                ? clamp(input.parameters1.w - 10.0, 0.0, 1.0)
                : 0.0);
        if (waveStrength > 0.0001 && u.waveAmount > 0.0001 && input.totalLength > 0.001) {
            float progress = clamp(input.uv.x / input.totalLength, 0.0, 1.0);
            float envelope = pow(max(0.0, sin(kPi * progress)), 0.35);
            float amplitude = waveStrength * u.waveAmount * max(8.0, input.baseHalfWidth * 1.1);
            float wavelength = max(72.0, input.baseHalfWidth * 10.0);
            float angle = input.uv.x / wavelength * 2.0 * kPi - u.phase * 2.0 * kPi;
            point += input.normal * (sin(angle) * amplitude * envelope);
        }
        out.position = float4(canvasToClip(point, u), 0, 1);
        out.canvasPosition = point;
        out.uv = input.uv;
        out.color1 = input.color1;
        out.color2 = input.color2;
        out.parameters0 = input.parameters0;
        out.parameters1 = input.parameters1;
        out.dropletData = input.dropletData;
        out.dropletCurve0 = input.dropletCurve0;
        out.dropletCurve1 = input.dropletCurve1;
        out.dropletCurve2 = input.dropletCurve2;
        out.dropletCurve3 = input.dropletCurve3;
        out.halfWidth = input.halfWidth;
        out.baseHalfWidth = input.baseHalfWidth;
        out.totalLength = input.totalLength;
        out.seed = input.seed;
        out.kind = input.kind;
        return out;
    }

    float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    float organicNoise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
                   mix(hash21(i + float2(0, 1)), hash21(i + 1.0), f.x), f.y);
    }

    float strokeDistance(VertexOut input, float radius) {
        float safeHalfWidth = max(0.001, input.halfWidth);
        if (input.uv.x < 0.0) {
            return length(float2(input.uv.x / safeHalfWidth, input.uv.y)) - radius;
        }
        if (input.uv.x > input.totalLength) {
            return length(float2((input.uv.x - input.totalLength) / safeHalfWidth, input.uv.y)) - radius;
        }
        return abs(input.uv.y) - radius;
    }

    float coverageForDistance(float distance) {
        float antialias = max(0.006, fwidth(distance));
        return 1.0 - smoothstep(-antialias, antialias, distance);
    }

    // Interpolate adjacent whole-cycle sine waves. Both waves meet exactly at
    // phase 0/1, so Goo can have continuous speed control without a visible
    // jump at the animation-loop boundary.
    float loopedSine(float phase, float cycles, float offset, float direction) {
        float safeCycles = max(0.0, cycles);
        float lower = floor(safeCycles);
        float upper = lower + 1.0;
        float blend = safeCycles - lower;
        float lowerValue = sin(direction * phase * 2.0 * kPi * lower + offset);
        float upperValue = sin(direction * phase * 2.0 * kPi * upper + offset);
        return mix(lowerValue, upperValue, blend);
    }

    float loopedCosine(float phase, float cycles, float offset, float direction) {
        float safeCycles = max(0.0, cycles);
        float lower = floor(safeCycles);
        float upper = lower + 1.0;
        float blend = safeCycles - lower;
        float lowerValue = cos(direction * phase * 2.0 * kPi * lower + offset);
        float upperValue = cos(direction * phase * 2.0 * kPi * upper + offset);
        return mix(lowerValue, upperValue, blend);
    }

    // Spatial RMS of loopedSine. The continuous speed interpolation changes
    // amplitude through the loop; accounting for it keeps mean radius^2 steady.
    float loopedSineEnergy(float phase, float cycles) {
        float safeCycles = max(0.0, cycles);
        float blend = safeCycles - floor(safeCycles);
        float phaseDelta = phase * 2.0 * kPi;
        return (1.0 - blend) * (1.0 - blend) + blend * blend
            + 2.0 * blend * (1.0 - blend) * cos(phaseDelta);
    }

    struct GooField {
        float centerOffset;
        float radius;
    };

    GooField evaluateGooField(
        float time,
        float splineDistance,
        float baseHalfWidth,
        float fieldDiameter,
        float4 parameters0,
        float4 parameters1,
        float seed
    ) {
        float speed = parameters0.x;
        float thickness = parameters0.y;
        float waviness = parameters0.z;
        float wavelengthSetting = parameters0.w;
        float speedCycles = speed * 2.0 * max(1.0, parameters1.w);
        float diameter = baseHalfWidth * 2.0;
        float seedPhase = seed * 2.0 * kPi;

        float centerLong = loopedSine(
            time,
            speedCycles * 0.73,
            splineDistance / (fieldDiameter * (8.0 + wavelengthSetting * 6.0)) * 2.0 * kPi
                + seedPhase * 1.31,
            1.0);
        float centerMedium = loopedSine(
            time,
            speedCycles * 1.37,
            splineDistance / (fieldDiameter * (3.2 + wavelengthSetting * 3.8)) * 2.0 * kPi
                + seedPhase * 2.17 + 1.9,
            -1.0);
        float centerDetail = loopedSine(
            time,
            speedCycles * 2.71,
            splineDistance / (fieldDiameter * (0.72 + wavelengthSetting * 0.34)) * 2.0 * kPi
                + seedPhase * 3.43 + 3.2,
            1.0);
        float centerAmplitude = diameter * (0.035 + waviness * 0.085);
        float centerOffset = centerAmplitude * (centerLong * 0.64 + centerMedium * 0.36)
            + diameter * (0.009 + waviness * 0.013) * centerDetail;

        float radiusAmplitude = 0.12 + waviness * 0.10;
        float radiusLongCycles = speedCycles * 0.91;
        float radiusMediumCycles = speedCycles * 1.61;
        float radiusDetailCycles = speedCycles * 2.23;
        float radiusEdgeCycles = speedCycles * 2.83;
        float radiusLong = loopedSine(
            time,
            radiusLongCycles,
            splineDistance / (fieldDiameter * (5.0 + wavelengthSetting * 4.0)) * 2.0 * kPi
                + seedPhase * 2.83 + 0.7,
            -1.0);
        float radiusMedium = loopedSine(
            time,
            radiusMediumCycles,
            splineDistance / (fieldDiameter * (2.2 + wavelengthSetting * 2.8)) * 2.0 * kPi
                + seedPhase * 4.11 + 2.4,
            1.0);
        float radiusDetail = loopedSine(
            time,
            radiusDetailCycles,
            splineDistance / (fieldDiameter * (0.9 + wavelengthSetting * 0.5)) * 2.0 * kPi
                + seedPhase * 5.37 + 4.1,
            -1.0);
        float radiusEdge = loopedSine(
            time,
            radiusEdgeCycles,
            splineDistance / (fieldDiameter * (0.62 + wavelengthSetting * 0.28)) * 2.0 * kPi
                + seedPhase * 6.19 + 5.2,
            1.0);
        float baseRadius = baseHalfWidth * (0.16 + thickness * 0.62);
        float radiusLongAmount = radiusAmplitude * 0.57;
        float radiusMediumAmount = radiusAmplitude * 0.33;
        float radiusDetailAmount = radiusAmplitude * 0.10;
        float radiusEdgeAmount = min(
            0.10,
            diameter * (0.008 + waviness * 0.010) / max(0.35, baseRadius));
        float radiusWave = radiusLongAmount * radiusLong
            + radiusMediumAmount * radiusMedium
            + radiusDetailAmount * radiusDetail
            + radiusEdgeAmount * radiusEdge;
        float meanSquare = 1.0 + 0.5 * (
            radiusLongAmount * radiusLongAmount * loopedSineEnergy(time, radiusLongCycles)
            + radiusMediumAmount * radiusMediumAmount * loopedSineEnergy(time, radiusMediumCycles)
            + radiusDetailAmount * radiusDetailAmount * loopedSineEnergy(time, radiusDetailCycles)
            + radiusEdgeAmount * radiusEdgeAmount * loopedSineEnergy(time, radiusEdgeCycles));
        float volumeScale = rsqrt(max(0.001, meanSquare));
        float localRadius = max(0.35, baseRadius * max(0.62, 1.0 + radiusWave) * volumeScale);
        return GooField{centerOffset, localRadius};
    }

    float evaluateGooCenterSlope(
        float time,
        float splineDistance,
        float baseHalfWidth,
        float fieldDiameter,
        float4 parameters0,
        float4 parameters1,
        float seed
    ) {
        float speedCycles = parameters0.x * 2.0 * max(1.0, parameters1.w);
        float waviness = parameters0.z;
        float wavelengthSetting = parameters0.w;
        float diameter = baseHalfWidth * 2.0;
        float seedPhase = seed * 2.0 * kPi;
        float longRate = 2.0 * kPi / (fieldDiameter * (8.0 + wavelengthSetting * 6.0));
        float mediumRate = 2.0 * kPi / (fieldDiameter * (3.2 + wavelengthSetting * 3.8));
        float detailRate = 2.0 * kPi / (fieldDiameter * (0.72 + wavelengthSetting * 0.34));
        float centerLongSlope = loopedCosine(
            time,
            speedCycles * 0.73,
            splineDistance * longRate + seedPhase * 1.31,
            1.0) * longRate;
        float centerMediumSlope = loopedCosine(
            time,
            speedCycles * 1.37,
            splineDistance * mediumRate + seedPhase * 2.17 + 1.9,
            -1.0) * mediumRate;
        float centerDetailSlope = loopedCosine(
            time,
            speedCycles * 2.71,
            splineDistance * detailRate + seedPhase * 3.43 + 3.2,
            1.0) * detailRate;
        float centerAmplitude = diameter * (0.035 + waviness * 0.085);
        return centerAmplitude * (centerLongSlope * 0.64 + centerMediumSlope * 0.36)
            + diameter * (0.009 + waviness * 0.013) * centerDetailSlope;
    }

    float gooCircleDistance(float2 point, float radius) {
        return length(point) - max(0.0, radius);
    }

    struct GooBaseFrame {
        float2 position;
        float2 tangent;
        float2 normal;
        float baseHalfWidth;
    };

    struct GooStrokeFrame {
        float2 position;
        float2 tangent;
        float2 normal;
        float radius;
    };

    float2 gooCatmullPosition(float2 a, float2 b, float2 c, float2 d, float t) {
        return 0.5 * ((2.0 * b)
            + (-a + c) * t
            + (2.0 * a - 5.0 * b + 4.0 * c - d) * t * t
            + (-a + 3.0 * b - 3.0 * c + d) * t * t * t);
    }

    float2 gooCatmullDerivative(float2 a, float2 b, float2 c, float2 d, float t) {
        return 0.5 * ((-a + c)
            + 2.0 * (2.0 * a - 5.0 * b + 4.0 * c - d) * t
            + 3.0 * (-a + 3.0 * b - 3.0 * c + d) * t * t);
    }

    GooBaseFrame sampleGooBaseFrame(VertexOut input, float arcOffset) {
        float2 p0 = input.dropletCurve0.xy;
        float2 p1 = input.dropletCurve0.zw;
        float2 p2 = input.dropletCurve1.xy;
        float2 p3 = input.dropletCurve1.zw;
        float2 p4 = input.dropletCurve2.xy;
        float w0 = input.dropletCurve2.z;
        float w1 = input.dropletCurve2.w;
        float w2 = input.dropletCurve3.x;
        float w3 = input.dropletCurve3.y;
        float w4 = input.dropletCurve3.z;
        float step = max(0.001, input.dropletCurve3.w);
        float coordinate = clamp(arcOffset / step + 2.0, 0.0, 3.9999);
        int segment = int(floor(coordinate));
        float t = fract(coordinate);
        float2 a;
        float2 b;
        float2 c;
        float2 d;
        float widthStart;
        float widthEnd;
        if (segment == 0) {
            a = p0 * 2.0 - p1; b = p0; c = p1; d = p2;
            widthStart = w0; widthEnd = w1;
        } else if (segment == 1) {
            a = p0; b = p1; c = p2; d = p3;
            widthStart = w1; widthEnd = w2;
        } else if (segment == 2) {
            a = p1; b = p2; c = p3; d = p4;
            widthStart = w2; widthEnd = w3;
        } else {
            a = p2; b = p3; c = p4; d = p4 * 2.0 - p3;
            widthStart = w3; widthEnd = w4;
        }
        float2 derivative = gooCatmullDerivative(a, b, c, d, t) / step;
        if (dot(derivative, derivative) < 0.000001) { derivative = c - b; }
        float2 tangent = normalize(derivative);
        return GooBaseFrame{
            gooCatmullPosition(a, b, c, d, t),
            tangent,
            float2(-tangent.y, tangent.x),
            mix(widthStart, widthEnd, t)
        };
    }

    GooStrokeFrame sampleGooFrame(VertexOut input, float time, float splineDistance) {
        float baseArcDistance = input.dropletData.x;
        float arcOffset = splineDistance - baseArcDistance;
        GooBaseFrame base = sampleGooBaseFrame(input, arcOffset);
        float fieldDiameter = max(0.5, input.parameters1.z);
        GooField field = evaluateGooField(
            time,
            clamp(splineDistance, 0.0, input.totalLength),
            max(0.35, base.baseHalfWidth),
            fieldDiameter,
            input.parameters0,
            input.parameters1,
            input.seed);
        float centerSlope = evaluateGooCenterSlope(
            time,
            clamp(splineDistance, 0.0, input.totalLength),
            max(0.35, base.baseHalfWidth),
            fieldDiameter,
            input.parameters0,
            input.parameters1,
            input.seed);
        float epsilon = max(0.35, min(fieldDiameter * 0.04, input.dropletCurve3.w * 0.15));
        GooBaseFrame before = sampleGooBaseFrame(input, arcOffset - epsilon);
        GooBaseFrame after = sampleGooBaseFrame(input, arcOffset + epsilon);
        float2 animatedBefore = before.position
            + before.normal * (field.centerOffset - centerSlope * epsilon);
        float2 animatedAfter = after.position
            + after.normal * (field.centerOffset + centerSlope * epsilon);
        float2 tangent = animatedAfter - animatedBefore;
        if (dot(tangent, tangent) < 0.000001) { tangent = base.tangent; }
        tangent = normalize(tangent);
        return GooStrokeFrame{
            base.position + base.normal * field.centerOffset,
            tangent,
            float2(-tangent.y, tangent.x),
            field.radius
        };
    }

    float gooSmoothMin(float a, float b, float blendRadius) {
        if (blendRadius <= 0.0001) { return min(a, b); }
        float h = clamp(0.5 + 0.5 * (b - a) / blendRadius, 0.0, 1.0);
        return mix(b, a, h) - blendRadius * h * (1.0 - h);
    }

    float gooMetaballTriplet(
        float2 point,
        float2 rootCenter,
        float rootRadius,
        float2 bridgeCenter,
        float bridgeRadius,
        float2 outerCenter,
        float outerRadius,
        float blendRadius
    ) {
        float rootDistance = gooCircleDistance(point - rootCenter, rootRadius);
        float bridgeDistance = gooCircleDistance(point - bridgeCenter, bridgeRadius);
        float outerDistance = gooCircleDistance(point - outerCenter, outerRadius);
        float chain = gooSmoothMin(rootDistance, bridgeDistance, blendRadius);
        return gooSmoothMin(chain, outerDistance, blendRadius);
    }

    float2 gooEmbeddedBud(
        float time,
        float splineDistance,
        float fieldDiameter,
        float speed,
        float thickness,
        float4 eventData
    ) {
        if (eventData.x < 0.0) { return float2(0.0); }
        float encodedVariation = eventData.w;
        bool canDetach = encodedVariation >= 0.0;
        float variation = canDetach ? encodedVariation : -encodedVariation - 1.0;
        float radiusRandom = fract(variation * 7.13 + 0.37);
        float life = fract(time - eventData.z + 1.0);
        float travelSpan = fieldDiameter * (1.35 + clamp(speed, 0.0, 2.0) * 0.25);
        float movingArcDistance = eventData.x + (life - 0.5) * travelSpan;
        float cycleVisibility = smoothstep(0.03, 0.10, life)
            * (1.0 - smoothstep(0.90, 0.97, life));
        float pushOut = smoothstep(0.48, 0.74, life)
            * (1.0 - smoothstep(0.86, 0.98, life));
        float detached = canDetach
            ? smoothstep(0.76, 0.82, life) * (1.0 - smoothstep(0.88, 0.94, life))
            : 0.0;
        float rootWave = sin((life + radiusRandom) * 2.0 * kPi);
        float rootRadius = fieldDiameter * (0.125 + radiusRandom * 0.070)
            * (0.94 + rootWave * 0.06) * cycleVisibility;
        float halfSpan = max(fieldDiameter * 0.08, rootRadius * (1.15 + pushOut * 0.40));
        float profile = 1.0 - smoothstep(
            halfSpan,
            halfSpan + fieldDiameter * 0.08,
            abs(splineDistance - movingArcDistance));
        float thicknessResponse = 1.0 - clamp(thickness, 0.0, 1.0) * 0.66;
        float bulge = rootRadius * (0.80 + pushOut * 1.10)
            * profile * (1.0 - detached) * thicknessResponse;
        return float2(eventData.y * bulge * 0.48, bulge * 0.55);
    }

    fragment float4 proceduralFragment(VertexOut input [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        if (input.canvasPosition.x < 0.0 || input.canvasPosition.y < 0.0
            || input.canvasPosition.x > u.canvasSize.x || input.canvasPosition.y > u.canvasSize.y) {
            discard_fragment();
        }

        float time = fract(u.phase + input.parameters1.x);
        int kind = int(round(input.kind));

        if (kind == 4) {
            float fieldDiameter = max(0.5, input.parameters1.z);
            float encodedVariation = input.dropletData.w;
            bool canDetach = encodedVariation >= 0.0;
            float variation = canDetach ? encodedVariation : -encodedVariation - 1.0;
            float radiusRandom = fract(variation * 7.13 + 0.37);
            float travelRandom = fract(variation * 13.71 + 0.19);
            float driftRandom = fract(variation * 19.17 + 0.53);
            float life = fract(time - input.dropletData.z + 1.0);
            float travelSpan = fieldDiameter
                * (1.35 + clamp(input.parameters0.x, 0.0, 2.0) * 0.25);
            float rootTangent = (life - 0.5) * travelSpan;
            float movingArcDistance = input.dropletData.x + rootTangent;
            float cycleVisibility = smoothstep(0.03, 0.10, life)
                * (1.0 - smoothstep(0.90, 0.97, life));
            float endpointInset = fieldDiameter * 0.34;
            float endpointFade = fieldDiameter * 0.55;
            float endpointVisibility = smoothstep(
                endpointInset,
                endpointInset + endpointFade,
                movingArcDistance)
                * (1.0 - smoothstep(
                    input.totalLength - endpointInset - endpointFade,
                    input.totalLength - endpointInset,
                    movingArcDistance));
            float visibility = cycleVisibility * endpointVisibility;
            if (visibility < 0.002) { discard_fragment(); }

            float pushOut = smoothstep(0.48, 0.74, life)
                * (1.0 - smoothstep(0.86, 0.98, life));
            float detached = canDetach
                ? smoothstep(0.76, 0.82, life) * (1.0 - smoothstep(0.88, 0.94, life))
                : 0.0;
            float rootWave = sin((life + radiusRandom) * 2.0 * kPi);
            float bridgeWave = sin((life + driftRandom) * 2.0 * kPi);
            float attachedTravel = fieldDiameter
                * (0.08 + travelRandom * 0.06 + rootWave * 0.025);
            float maximumTravel = fieldDiameter * (canDetach
                ? (0.45 + travelRandom * 0.53)
                : (0.20 + travelRandom * 0.10));
            float outerOutward = mix(attachedTravel, maximumTravel, pushOut);
            float outerTangent = fieldDiameter
                * (0.08 + driftRandom * 0.10 + pushOut * (0.26 + driftRandom * 0.24));
            float bridgeMix = 0.46 + bridgeWave * 0.06;
            float effectiveBridgeMix = bridgeMix * (1.0 - detached * 0.78);
            float bridgeRadiusScale = 1.0 - detached * 0.82;
            float rootRadius = fieldDiameter * (0.125 + radiusRandom * 0.070)
                * (0.94 + rootWave * 0.06) * visibility;
            float bridgeRadius = fieldDiameter * (0.065 + driftRandom * 0.055)
                * (0.96 + bridgeWave * 0.08) * bridgeRadiusScale * visibility;
            float outerRadius = fieldDiameter * (0.032 + travelRandom * 0.030)
                * (0.96 + rootWave * 0.06) * visibility;
            float rootOutward = -rootRadius * (0.55 - pushOut * 0.06);
            float bridgeOutward = mix(rootOutward, outerOutward, effectiveBridgeMix);
            float side = input.dropletData.y;
            float bridgeSplineDistance = movingArcDistance
                + outerTangent * effectiveBridgeMix;
            float outerSplineDistance = movingArcDistance + outerTangent;
            GooStrokeFrame rootFrame = sampleGooFrame(input, time, movingArcDistance);
            GooStrokeFrame bridgeFrame = sampleGooFrame(input, time, bridgeSplineDistance);
            GooStrokeFrame outerFrame = sampleGooFrame(input, time, outerSplineDistance);
            float2 rootCenter = rootFrame.position
                + rootFrame.normal * side * (rootFrame.radius + rootOutward);
            float2 bridgeCenter = bridgeFrame.position
                + bridgeFrame.normal * side * (bridgeFrame.radius + bridgeOutward);
            float2 outerCenter = outerFrame.position
                + outerFrame.normal * side * (outerFrame.radius + outerOutward);

            float attachedChainBlend = fieldDiameter * (0.090 + radiusRandom * 0.040);
            float detachedChainBlend = fieldDiameter * (0.040 + radiusRandom * 0.025);
            float chainBlend = mix(attachedChainBlend, detachedChainBlend, detached) * visibility;
            float chainDistance = gooMetaballTriplet(
                input.uv,
                rootCenter, rootRadius,
                bridgeCenter, bridgeRadius,
                outerCenter, outerRadius,
                chainBlend);
            float bodyArcOffset = input.uv.x;
            GooStrokeFrame projectedFrame = sampleGooFrame(
                input,
                time,
                input.dropletData.x + bodyArcOffset);
            bodyArcOffset += dot(
                input.uv - projectedFrame.position,
                projectedFrame.tangent);
            float bodySplineDistance = clamp(
                input.dropletData.x + bodyArcOffset,
                0.0,
                input.totalLength);
            GooStrokeFrame bodyFrame = sampleGooFrame(input, time, bodySplineDistance);
            float bodyNormalCoordinate = dot(
                input.uv - bodyFrame.position,
                bodyFrame.normal);
            float bodyDistance = abs(bodyNormalCoordinate) - bodyFrame.radius;
            float bodyBlend = fieldDiameter * (0.100 + travelRandom * 0.040) * visibility;
            float finalDistance = gooSmoothMin(bodyDistance, chainDistance, bodyBlend);

            // Evaluate one local body+triplet union, but only where the
            // triplet can influence it. The already-rendered body remains the
            // base layer; this pass fills the seamless fluid attachment.
            float antialias = max(0.006, fwidth(chainDistance));
            if (!isfinite(bodyDistance) || !isfinite(chainDistance)
                || !isfinite(finalDistance) || !isfinite(bodyBlend)
                || !isfinite(antialias)
                || chainDistance > bodyBlend + antialias * 2.0) {
                discard_fragment();
            }
            float coverage = 1.0 - smoothstep(-antialias, antialias, finalDistance);
            float detachedVisibility = smoothstep(0.08, 0.45, detached);
            float alpha = coverage * input.color1.a * detachedVisibility;
            if (!isfinite(alpha) || alpha < 0.002) { discard_fragment(); }

            return float4(input.color1.rgb * alpha, alpha);
        }

        if (kind == 5) {
            float joinDistance = clamp(input.dropletData.x, 0.0, input.totalLength);
            GooField joinField = evaluateGooField(
                time,
                joinDistance,
                max(0.5, input.baseHalfWidth),
                max(0.5, input.parameters1.z),
                input.parameters0,
                input.parameters1,
                input.seed);
            float2 joinBud = gooEmbeddedBud(
                time,
                joinDistance,
                max(0.5, input.parameters1.z),
                input.parameters0.x,
                input.parameters0.y,
                input.dropletCurve2) + gooEmbeddedBud(
                    time,
                joinDistance,
                max(0.5, input.parameters1.z),
                input.parameters0.x,
                input.parameters0.y,
                input.dropletCurve3);
            float2 joinCoordinate = float2(
                input.uv.x,
                input.uv.y - joinField.centerOffset - joinBud.x);
            float joinSDF = length(joinCoordinate) - joinField.radius - joinBud.y;
            float coverage = coverageForDistance(joinSDF);
            float alpha = coverage * input.color1.a;
            if (!isfinite(alpha) || alpha < 0.002) { discard_fragment(); }
            return float4(input.color1.rgb * alpha, alpha);
        }

        if (kind == 0) {
            if (input.parameters1.y > 0.5
                && (input.uv.x < 0.0 || input.uv.x > input.totalLength)) {
                discard_fragment();
            }
            float speed = input.parameters0.x;
            float thickness = input.parameters0.y;
            float waviness = input.parameters0.z;
            float wavelengthSetting = input.parameters0.w;
            float speedCycles = speed * 2.0 * max(1.0, input.parameters1.w);
            float baseHalfWidth = max(0.5, input.baseHalfWidth);
            float diameter = baseHalfWidth * 2.0;
            float fieldDiameter = max(0.5, input.parameters1.z);
            float segmentStart = clamp(input.dropletData.x, 0.0, input.totalLength);
            float segmentEnd = clamp(input.dropletData.y, segmentStart, input.totalLength);
            float2 segmentStartPoint = input.dropletCurve0.xy;
            float2 segmentEndPoint = input.dropletCurve0.zw;
            float2 segmentVector = segmentEndPoint - segmentStartPoint;
            float segmentLengthSquared = max(0.000001, dot(segmentVector, segmentVector));
            float segmentProgress = clamp(
                dot(input.canvasPosition - segmentStartPoint, segmentVector)
                    / segmentLengthSquared,
                0.0,
                1.0);
            float splineDistance = mix(segmentStart, segmentEnd, segmentProgress);
            float seedPhase = input.seed * 2.0 * kPi;

            // The drawn path remains the immutable spine. Two broad correlated
            // bands move the visible centerline around it in arc-length space.
            float centerLongWavelength = fieldDiameter * (8.0 + wavelengthSetting * 6.0);
            float centerMediumWavelength = fieldDiameter * (3.2 + wavelengthSetting * 3.8);
            float centerLong = loopedSine(
                time,
                speedCycles * 0.73,
                splineDistance / centerLongWavelength * 2.0 * kPi + seedPhase * 1.31,
                1.0);
            float centerMedium = loopedSine(
                time,
                speedCycles * 1.37,
                splineDistance / centerMediumWavelength * 2.0 * kPi + seedPhase * 2.17 + 1.9,
                -1.0);
            float centerDetail = loopedSine(
                time,
                speedCycles * 2.71,
                splineDistance / (fieldDiameter * (0.72 + wavelengthSetting * 0.34)) * 2.0 * kPi
                    + seedPhase * 3.43 + 3.2,
                1.0);
            float centerAmplitude = diameter * (0.035 + waviness * 0.085);
            float centerOffset = centerAmplitude * (centerLong * 0.64 + centerMedium * 0.36)
                + diameter * (0.009 + waviness * 0.013) * centerDetail;

            // Radius is a separate, differently phased field. The bands
            // overlap everywhere, so the whole stroke flows instead of waiting
            // for a single oversized pulse to pass each sparse cell.
            float radiusAmplitude = 0.12 + waviness * 0.10;
            float radiusLongCycles = speedCycles * 0.91;
            float radiusMediumCycles = speedCycles * 1.61;
            float radiusDetailCycles = speedCycles * 2.23;
            float radiusEdgeCycles = speedCycles * 2.83;
            float radiusLong = loopedSine(
                time,
                radiusLongCycles,
                splineDistance / (fieldDiameter * (5.0 + wavelengthSetting * 4.0)) * 2.0 * kPi
                    + seedPhase * 2.83 + 0.7,
                -1.0);
            float radiusMedium = loopedSine(
                time,
                radiusMediumCycles,
                splineDistance / (fieldDiameter * (2.2 + wavelengthSetting * 2.8)) * 2.0 * kPi
                    + seedPhase * 4.11 + 2.4,
                1.0);
            float radiusDetail = loopedSine(
                time,
                radiusDetailCycles,
                splineDistance / (fieldDiameter * (0.9 + wavelengthSetting * 0.5)) * 2.0 * kPi
                    + seedPhase * 5.37 + 4.1,
                -1.0);
            float radiusEdge = loopedSine(
                time,
                radiusEdgeCycles,
                splineDistance / (fieldDiameter * (0.62 + wavelengthSetting * 0.28)) * 2.0 * kPi
                    + seedPhase * 6.19 + 5.2,
                1.0);
            float baseRadius = baseHalfWidth * (0.16 + thickness * 0.62);
            float radiusLongAmount = radiusAmplitude * 0.57;
            float radiusMediumAmount = radiusAmplitude * 0.33;
            float radiusDetailAmount = radiusAmplitude * 0.10;
            float radiusEdgeAmount = min(
                0.10,
                diameter * (0.008 + waviness * 0.010) / max(0.35, baseRadius));
            float radiusWave = radiusLongAmount * radiusLong
                + radiusMediumAmount * radiusMedium
                + radiusDetailAmount * radiusDetail
                + radiusEdgeAmount * radiusEdge;

            // Preserve the expected cross-sectional area. This compensates for
            // both sine variance and the loop-safe speed interpolation's
            // changing wave energy, preventing whole-stroke breathing.
            float meanSquare = 1.0 + 0.5 * (
                radiusLongAmount * radiusLongAmount * loopedSineEnergy(time, radiusLongCycles)
                + radiusMediumAmount * radiusMediumAmount * loopedSineEnergy(time, radiusMediumCycles)
                + radiusDetailAmount * radiusDetailAmount * loopedSineEnergy(time, radiusDetailCycles)
                + radiusEdgeAmount * radiusEdgeAmount * loopedSineEnergy(time, radiusEdgeCycles));
            float volumeScale = rsqrt(max(0.001, meanSquare));
            float localRadius = max(0.35, baseRadius * max(0.62, 1.0 + radiusWave) * volumeScale);
            float2 embeddedBud = gooEmbeddedBud(
                time,
                splineDistance,
                fieldDiameter,
                speed,
                thickness,
                input.dropletCurve2) + gooEmbeddedBud(
                    time,
                splineDistance,
                fieldDiameter,
                speed,
                thickness,
                input.dropletCurve3);
            centerOffset += embeddedBud.x;
            localRadius += embeddedBud.y;

            // Evaluate the capsule in canvas space. Interpolated trapezoid UVs
            // are not physical distances on a curve and can expose corners as
            // teeth; shared endpoint normals keep neighboring capsules exact.
            float2 sharedNormal = mix(
                input.dropletCurve1.xy,
                input.dropletCurve1.zw,
                segmentProgress);
            sharedNormal *= rsqrt(max(0.000001, dot(sharedNormal, sharedNormal)));
            float2 animatedCenter = mix(
                segmentStartPoint,
                segmentEndPoint,
                segmentProgress) + sharedNormal * centerOffset;
            float gooDistance = length(input.canvasPosition - animatedCenter) - localRadius;
            float body = coverageForDistance(gooDistance);
            float alpha = body * input.color1.a;
            if (alpha < 0.002) { discard_fragment(); }
            return float4(input.color1.rgb * alpha, alpha);
        }

        if (input.parameters1.y > 0.5
            && (input.uv.x < 0.0 || input.uv.x > input.totalLength)) {
            discard_fragment();
        }
        float baseCoverage = coverageForDistance(strokeDistance(input, 1.0));
        if (baseCoverage < 0.002) { discard_fragment(); }

        if (kind == 1) {
            float speed = input.parameters0.x;
            float density = input.parameters0.y;
            float sparkleAmount = input.parameters0.z;
            float cellSize = max(1.25, input.halfWidth * (0.34 - density * 0.18));
            float2 coordinate = float2(input.uv.x, input.uv.y * input.halfWidth) / cellSize;
            float2 cell = floor(coordinate);
            float2 local = fract(coordinate) - 0.5;
            float random = hash21(cell + input.seed * 173.0);
            float2 jitter = float2(
                hash21(cell + input.seed * 307.0),
                hash21(cell + input.seed * 419.0)) - 0.5;
            local -= jitter * 0.52;
            float cycles = max(1.0, round(speed * (1.2 + random * 1.8)));
            float twinkle = speed < 0.01
                ? random
                : 0.5 + 0.5 * sin(time * 2.0 * kPi * cycles + random * 2.0 * kPi);
            float radius = 0.08 + hash21(cell + input.seed * 613.0) * 0.18;
            float roundGrain = 1.0 - smoothstep(radius, radius + 0.055, length(local));
            float diamond = 1.0 - smoothstep(radius, radius + 0.055, abs(local.x) + abs(local.y));
            float sparkleChoice = hash21(cell + input.seed * 829.0);
            float shape = sparkleChoice < 0.05 + sparkleAmount * 0.24 ? diamond : roundGrain;
            float exists = random < (0.18 + density * 0.76) ? 1.0 : 0.0;
            float grain = shape * exists * (0.20 + pow(twinkle, 1.4) * 0.80) * baseCoverage;
            float3 rgb = mix(input.color2.rgb, input.color1.rgb, grain);
            float alpha = max(input.color2.a * baseCoverage, input.color1.a * grain);
            return float4(rgb * alpha, alpha);
        }

        if (kind == 2) {
            float cycles = input.parameters0.x;
            float flow = cycles == 0.0 ? 0.0 : sin(time * 2.0 * kPi * cycles) * 0.04;
            float blend;
            if (input.parameters1.z > 0.5) {
                // Global merge: every stroke shares one canvas-anchored field,
                // so all strokes fuse into a single continuous gradient.
                float2 space = input.canvasPosition / max(0.001, u.canvasSize);
                blend = clamp(space.x * 0.62 + space.y * 0.38 + flow, 0.0, 1.0);
            } else {
                // Per-stroke merge: color depends only on where the pixel lies
                // along this stroke's own bounding-box diagonal (dropletCurve0.xy
                // = center, .zw = axis * half-length), so any pass over a given
                // pixel writes the same color and self-overlapping loops fuse
                // seamlessly. Each stroke has its own center + axis, so a
                // brand-new stroke carries its own gradient.
                float2 local = input.canvasPosition - input.dropletCurve0.xy;
                float2 axisVec = input.dropletCurve0.zw;
                float extent = max(0.001, dot(axisVec, axisVec));
                blend = clamp(0.5 + 0.5 * dot(local, axisVec) / extent + flow, 0.0, 1.0);
            }
            float4 color = mix(input.color1, input.color2, blend);
            color.a *= baseCoverage;
            return float4(color.rgb * color.a, color.a);
        }

        // Retro: the entire stroke is one solid color at a time, stepping
        // through the selected palette in order as the animation plays.
        if (kind == 6) {
            float3 c0 = input.color1.rgb;  float a0 = input.color1.a;
            float3 c1 = input.color2.rgb;  float a1 = input.color2.a;
            float3 c2 = input.dropletCurve0.rgb; float a2 = input.dropletCurve0.a;
            float3 c3 = input.dropletCurve1.rgb; float a3 = input.dropletCurve1.a;
            float3 c4 = input.dropletCurve2.rgb; float a4 = input.dropletCurve2.a;
            float cycles = input.parameters0.x;
            if (cycles < 0.01) {
                float alpha = a0 * baseCoverage;
                return float4(c0 * alpha, alpha);
            }
            int count = max(2, int(round(input.parameters1.z)));
            float pos = fract(time * cycles) * float(count);
            int idx = int(floor(pos));
            if (idx >= count) { idx = count - 1; }
            float3 rgb;
            float alpha;
            if (idx == 0) { rgb = c0; alpha = a0; }
            else if (idx == 1) { rgb = c1; alpha = a1; }
            else if (idx == 2) { rgb = c2; alpha = a2; }
            else if (idx == 3) { rgb = c3; alpha = a3; }
            else { rgb = c4; alpha = a4; }
            float finalAlpha = alpha * baseCoverage;
            if (finalAlpha < 0.002) { discard_fragment(); }
            return float4(rgb * finalAlpha, finalAlpha);
        }

        // Faded: multi-octave organic value noise erodes papery flecks and a
        // crumbly, worn silhouette across discrete animation frames. There are
        // no literal blobs or sin-based line shards — just an organic, noisy
        // mask that evolves frame by frame.
        float speed = input.parameters0.x;
        float amount = input.parameters0.y;
        float density = input.parameters0.z;
        float roughness = input.parameters0.w;
        float frameCount = speed < 0.01 ? 1.0 : max(4.0, round(5.0 + speed * 5.0));
        float frame = speed < 0.01 ? 0.0 : floor(time * frameCount);
        float cellSize = max(1.5, input.halfWidth * (0.20 + (1.0 - density) * 0.20));
        float2 coordinate = float2(input.uv.x, input.uv.y * input.halfWidth) / cellSize;
        float2 drift = float2(
            cos(frame * 0.35 + input.seed * 13.0),
            sin(frame * 0.47 + input.seed * 7.0)) * (0.4 + density * 0.9)
            + input.seed * 41.0;
        float coarse = organicNoise(coordinate * 0.62 + drift);
        float medium = organicNoise(coordinate * 1.9 - drift * 1.42 + 31.0);
        float fine = organicNoise(coordinate * 4.7 + drift * 0.6 + 97.0);
        float organic = coarse * 0.46 + medium * 0.34 + fine * 0.20;
        // Heavier erosion toward the stroke edge for a worn, ragged silhouette.
        float edge = clamp(abs(input.uv.y) * 2.2 - 0.25, 0.0, 1.0);
        float threshold = mix(0.32, amount * 0.92, edge)
            - (1.0 - density) * 0.14
            - (0.5 - amount) * 0.20;
        float hole = smoothstep(threshold, threshold + 0.20, organic) * (0.70 + roughness * 0.30);
        // Preview the same two-layer color structure as the final CPU brush:
        // solid Base underneath, independently translucent Faded color above.
        float fadedAlpha = input.color1.a * baseCoverage * (1.0 - hole * 0.92);
        float baseAlpha = input.color2.a * baseCoverage;
        float alpha = fadedAlpha + baseAlpha * (1.0 - fadedAlpha);
        if (alpha < 0.002) { discard_fragment(); }
        float3 premultiplied = input.color1.rgb * fadedAlpha
            + input.color2.rgb * baseAlpha * (1.0 - fadedAlpha);
        return float4(premultiplied, alpha);
    }
    """#
}
