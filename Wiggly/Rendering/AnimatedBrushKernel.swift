import CoreGraphics
import Foundation
import ImageIO
import UIKit

nonisolated protocol AnimatedBrushKernel {
    var kind: BrushKind { get }
    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext)
}

nonisolated enum BrushKernelRegistry {
    static let kernels: [BrushKind: any AnimatedBrushKernel] = [
        .wiggle: WiggleKernel(),
        .jitter: JitterKernel(),
        .pulse: PulseKernel(),
        .cutMarker: CutMarkerKernel(),
        .solidColor: SolidColorKernel(),
        .softAirbrush: SoftAirbrushKernel(),
        .gouache: GouacheKernel(),
        .flatChisel: FlatChiselKernel(),
        .scatter: ScatterKernel(),
        .ghostTrail: GhostTrailKernel(),
        .dashed: DashedKernel(),
        .star: StarKernel(),
        .dotted: DottedKernel(),
        .particle: ParticleKernel(),
        .goo: GooKernel(),
        .scribbles: ScribblesKernel(),
        .particleCloud: ParticleCloudKernel(),
        .glitter: GlitterKernel(),
        .gradient: GradientKernel(),
        .polkaDots: PolkaDotsKernel(),
        .faded: FadedKernel(),
        .charcoal: CharcoalKernel(),
        .colorNoise: ColorNoiseKernel(),
        .dryOutline: DryOutlineKernel()
    ]
}

nonisolated private func uiColor(_ color: CodableColor, opacity: Double) -> UIColor {
    UIColor(
        red: color.red,
        green: color.green,
        blue: color.blue,
        alpha: color.alpha * opacity
    )
}

nonisolated private func seeded(_ seed: UInt64, _ index: Int) -> Double {
    var value = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15
    value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
    value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
    value ^= value >> 31
    return Double(value % 10_000) / 10_000
}

nonisolated private func width(
    for sample: StrokeSample,
    index: Int,
    count: Int,
    brush: BrushSettings,
    multiplier: Double = 1
) -> CGFloat {
    let pressure = 1 + (sample.pressure - 0.5) * brush.pressureSize
    let tilt = 1 + sample.tilt * brush.tiltResponse * 0.5
    let progress = count > 1 ? Double(index) / Double(count - 1) : 0.5
    let taper = taperScale(at: progress, brush: brush)
    return max(0.35, brush.size * pressure * tilt * taper * multiplier)
}

nonisolated private func taperScale(at progress: Double, brush: BrushSettings) -> Double {
    let taperZone = 0.15
    if progress < taperZone {
        let localProgress = progress / taperZone
        return brush.resolvedStartWidthScale
            + (1 - brush.resolvedStartWidthScale) * localProgress
    }
    if progress > 1 - taperZone {
        let localProgress = (progress - (1 - taperZone)) / taperZone
        return 1 + (brush.resolvedEndWidthScale - 1) * localProgress
    }
    return 1
}

/// Immutable render-time reconstruction shared by live Metal Goo and CPU
/// export. The stored Pencil samples remain untouched.
nonisolated struct GooSplineStation {
    var sample: StrokeSample
    var point: CGPoint
    var tangent: CGPoint
}

nonisolated enum GooSplineSampler {
    static func stations(
        source: [StrokeSample],
        brush: BrushSettings,
        scale: CGFloat,
        transform: (CGPoint) -> CGPoint
    ) -> [GooSplineStation] {
        guard let first = source.first else { return [] }
        let diameter = max(0.5, brush.size * Double(scale))
        let sourcePoints = source.map { transform($0.point) }
        guard source.count > 1 else {
            return blobStations(sample: first, point: sourcePoints[0])
        }

        var cumulative = [CGFloat](repeating: 0, count: source.count)
        for index in 1..<source.count {
            cumulative[index] = cumulative[index - 1] + distance(
                sourcePoints[index - 1],
                sourcePoints[index]
            )
        }
        let totalLength = cumulative.last ?? 0
        guard totalLength > 0.001 else {
            return blobStations(sample: first, point: sourcePoints[0])
        }

        let midpoint = interpolatedSource(
            source: source,
            points: sourcePoints,
            cumulative: cumulative,
            distance: totalLength * 0.5
        )
        if totalLength < CGFloat(diameter * 0.08) {
            return blobStations(sample: midpoint.sample, point: midpoint.point)
        }

        // A tiny gesture does not contain enough stable tangent information for
        // a full ribbon. Use a radius-matched capsule, or a blob when its ends
        // nearly meet (common for a tiny loop/tap).
        if totalLength < CGFloat(diameter * 1.25) {
            let chord = distance(sourcePoints[0], sourcePoints[sourcePoints.count - 1])
            if chord < CGFloat(diameter * 0.15) {
                return blobStations(sample: midpoint.sample, point: midpoint.point)
            }
            return capsuleStations(
                startSample: source[0],
                endSample: source[source.count - 1],
                start: sourcePoints[0],
                end: sourcePoints[sourcePoints.count - 1],
                diameter: CGFloat(diameter)
            )
        }

        // Control knots are intentionally coarser than final stations. The
        // adaptive pass below—not an arbitrary vertex multiplier—determines the
        // final density from curve error, tangent rotation, and radius change.
        let controlSpacing = max(0.5, CGFloat(diameter * 0.18))
        let controlIntervals = max(1, Int(ceil(totalLength / controlSpacing)))
        let controlCount = min(2_048, controlIntervals + 1)
        var controls: [(sample: StrokeSample, point: CGPoint)] = []
        controls.reserveCapacity(controlCount)
        for index in 0..<controlCount {
            let sampleDistance: CGFloat
            if controlIntervals + 1 <= 2_048 {
                sampleDistance = index == controlCount - 1
                    ? totalLength
                    : min(totalLength, CGFloat(index) * controlSpacing)
            } else {
                sampleDistance = totalLength * CGFloat(index) / CGFloat(controlCount - 1)
            }
            controls.append(interpolatedSource(
                source: source,
                points: sourcePoints,
                cumulative: cumulative,
                distance: sampleDistance
            ))
        }

        let qualityScale = max(
            1,
            Double(totalLength) / max(1, diameter * 0.075 * 3_600)
        )
        let normalSpacing = CGFloat(diameter * 0.08 * qualityScale)
        let capSpacing = CGFloat(diameter * 0.06 * qualityScale)
        let chordTolerance = CGFloat(0.35 * qualityScale)
        let angleTolerance = CGFloat(5 * Double.pi / 180 * qualityScale)
        let radiusTolerance = diameter * 0.012 * qualityScale
        let maximumStations = 8_192
        var result: [GooSplineStation] = []
        result.reserveCapacity(min(maximumStations, max(controlCount * 3, 64)))

        func geometry(segment: Int, u: CGFloat) -> (sample: StrokeSample, point: CGPoint, tangent: CGPoint) {
            let p1 = controls[segment]
            let p2 = controls[segment + 1]
            let p0Point = segment > 0
                ? controls[segment - 1].point
                : extrapolated(before: p1.point, next: p2.point)
            let p3Point = segment + 2 < controls.count
                ? controls[segment + 2].point
                : extrapolated(after: p2.point, previous: p1.point)
            let p0Sample = segment > 0 ? controls[segment - 1].sample : p1.sample
            let p3Sample = segment + 2 < controls.count ? controls[segment + 2].sample : p2.sample
            let point = centripetalPoint(p0Point, p1.point, p2.point, p3Point, u: u)
            let tangent = centripetalTangent(p0Point, p1.point, p2.point, p3Point, u: u)
            let sample = centripetalSample(
                p0Sample, p1.sample, p2.sample, p3Sample,
                points: (p0Point, p1.point, p2.point, p3Point),
                u: u
            )
            return (sample, point, tangent)
        }

        let firstGeometry = geometry(segment: 0, u: 0)
        result.append(GooSplineStation(
            sample: firstGeometry.sample,
            point: firstGeometry.point,
            tangent: firstGeometry.tangent
        ))

        func appendAdaptive(segment: Int, u0: CGFloat, u1: CGFloat, depth: Int) {
            guard result.count < maximumStations else { return }
            let um = (u0 + u1) * 0.5
            let uq0 = (u0 + um) * 0.5
            let uq1 = (um + u1) * 0.5
            let g0 = geometry(segment: segment, u: u0)
            let gq0 = geometry(segment: segment, u: uq0)
            let gm = geometry(segment: segment, u: um)
            let gq1 = geometry(segment: segment, u: uq1)
            let g1 = geometry(segment: segment, u: u1)
            let curveLength = distance(g0.point, gq0.point)
                + distance(gq0.point, gm.point)
                + distance(gm.point, gq1.point)
                + distance(gq1.point, g1.point)
            let maximumSpacing = segment == 0 || segment == controls.count - 2
                ? capSpacing
                : normalSpacing
            let curveError = max(
                pointToSegmentDistance(gq0.point, g0.point, g1.point),
                pointToSegmentDistance(gm.point, g0.point, g1.point),
                pointToSegmentDistance(gq1.point, g0.point, g1.point)
            )
            let tangentRotation = max(
                angle(g0.tangent, gm.tangent),
                angle(gm.tangent, g1.tangent)
            )
            let progress0 = (Double(segment) + Double(u0)) / Double(controls.count - 1)
            let progressM = (Double(segment) + Double(um)) / Double(controls.count - 1)
            let progress1 = (Double(segment) + Double(u1)) / Double(controls.count - 1)
            let radius0 = estimatedRadius(g0.sample, progress: progress0, brush: brush, scale: scale)
            let radiusM = estimatedRadius(gm.sample, progress: progressM, brush: brush, scale: scale)
            let radius1 = estimatedRadius(g1.sample, progress: progress1, brush: brush, scale: scale)
            let radiusChange = max(abs(radius1 - radius0), abs(radiusM - (radius0 + radius1) * 0.5))
            let needsSubdivision = curveLength > maximumSpacing
                || curveError > chordTolerance
                || tangentRotation > angleTolerance
                || radiusChange > radiusTolerance

            if needsSubdivision && depth < 12 && result.count < maximumStations - 1 {
                appendAdaptive(segment: segment, u0: u0, u1: um, depth: depth + 1)
                appendAdaptive(segment: segment, u0: um, u1: u1, depth: depth + 1)
            } else {
                var tangent = g1.tangent
                if let previous = result.last, dot(previous.tangent, tangent) < 0 {
                    tangent = CGPoint(x: -tangent.x, y: -tangent.y)
                }
                result.append(GooSplineStation(sample: g1.sample, point: g1.point, tangent: tangent))
            }
        }

        for segment in 0..<(controls.count - 1) {
            appendAdaptive(segment: segment, u0: 0, u1: 1, depth: 0)
            if result.count >= maximumStations { break }
        }
        if let lastControl = controls.last,
           distance(result.last?.point ?? lastControl.point, lastControl.point) > 0.001,
           result.count < maximumStations {
            let lastGeometry = geometry(segment: controls.count - 2, u: 1)
            result.append(GooSplineStation(
                sample: lastGeometry.sample,
                point: lastGeometry.point,
                tangent: lastGeometry.tangent
            ))
        }
        return result
    }

    private static func blobStations(sample: StrokeSample, point: CGPoint) -> [GooSplineStation] {
        let tangent = CGPoint(x: 1, y: 0)
        return [
            GooSplineStation(sample: sample, point: point, tangent: tangent),
            GooSplineStation(sample: sample, point: point, tangent: tangent)
        ]
    }

    private static func capsuleStations(
        startSample: StrokeSample,
        endSample: StrokeSample,
        start: CGPoint,
        end: CGPoint,
        diameter: CGFloat
    ) -> [GooSplineStation] {
        let chord = distance(start, end)
        let tangent = unitDirection(start, end)
        let intervals = max(1, Int(ceil(chord / max(0.5, diameter * 0.06))))
        return (0...intervals).map { index in
            let u = Double(index) / Double(intervals)
            return GooSplineStation(
                sample: linearSample(startSample, endSample, u),
                point: CGPoint(
                    x: start.x + (end.x - start.x) * u,
                    y: start.y + (end.y - start.y) * u
                ),
                tangent: tangent
            )
        }
    }

    private static func interpolatedSource(
        source: [StrokeSample],
        points: [CGPoint],
        cumulative: [CGFloat],
        distance target: CGFloat
    ) -> (sample: StrokeSample, point: CGPoint) {
        var segment = 1
        while segment < cumulative.count - 1 && cumulative[segment] < target {
            segment += 1
        }
        let span = max(0.0001, cumulative[segment] - cumulative[segment - 1])
        let u = Double(min(1, max(0, (target - cumulative[segment - 1]) / span)))
        let start = points[segment - 1]
        let end = points[segment]
        return (
            linearSample(source[segment - 1], source[segment], u),
            CGPoint(
                x: start.x + (end.x - start.x) * u,
                y: start.y + (end.y - start.y) * u
            )
        )
    }

    private static func linearSample(_ start: StrokeSample, _ end: StrokeSample, _ u: Double) -> StrokeSample {
        StrokeSample(
            x: start.x + (end.x - start.x) * u,
            y: start.y + (end.y - start.y) * u,
            pressure: start.pressure + (end.pressure - start.pressure) * u,
            tilt: start.tilt + (end.tilt - start.tilt) * u,
            azimuth: start.azimuth + (end.azimuth - start.azimuth) * u,
            timestamp: start.timestamp + (end.timestamp - start.timestamp) * u
        )
    }

    private static func centripetalSample(
        _ s0: StrokeSample,
        _ s1: StrokeSample,
        _ s2: StrokeSample,
        _ s3: StrokeSample,
        points: (CGPoint, CGPoint, CGPoint, CGPoint),
        u: CGFloat
    ) -> StrokeSample {
        let times = knotTimes(points.0, points.1, points.2, points.3)
        func value(_ v0: Double, _ v1: Double, _ v2: Double, _ v3: Double) -> Double {
            let raw = centripetalScalar(v0, v1, v2, v3, times: times, u: Double(u))
            return min(max(v1, v2), max(min(v1, v2), raw))
        }
        return StrokeSample(
            x: value(s0.x, s1.x, s2.x, s3.x),
            y: value(s0.y, s1.y, s2.y, s3.y),
            pressure: value(s0.pressure, s1.pressure, s2.pressure, s3.pressure),
            tilt: value(s0.tilt, s1.tilt, s2.tilt, s3.tilt),
            azimuth: value(s0.azimuth, s1.azimuth, s2.azimuth, s3.azimuth),
            timestamp: value(s0.timestamp, s1.timestamp, s2.timestamp, s3.timestamp)
        )
    }

    private static func centripetalPoint(
        _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
        u: CGFloat
    ) -> CGPoint {
        let times = knotTimes(p0, p1, p2, p3)
        return CGPoint(
            x: centripetalScalar(Double(p0.x), Double(p1.x), Double(p2.x), Double(p3.x), times: times, u: Double(u)),
            y: centripetalScalar(Double(p0.y), Double(p1.y), Double(p2.y), Double(p3.y), times: times, u: Double(u))
        )
    }

    private static func centripetalTangent(
        _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
        u: CGFloat
    ) -> CGPoint {
        let epsilon: CGFloat = 0.001
        let before = centripetalPoint(p0, p1, p2, p3, u: max(0, u - epsilon))
        let after = centripetalPoint(p0, p1, p2, p3, u: min(1, u + epsilon))
        return unitDirection(before, after)
    }

    private static func knotTimes(
        _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint
    ) -> (Double, Double, Double, Double) {
        let t0 = 0.0
        let t1 = t0 + Foundation.sqrt(max(0.000_001, Double(distance(p0, p1))))
        let t2 = t1 + Foundation.sqrt(max(0.000_001, Double(distance(p1, p2))))
        let t3 = t2 + Foundation.sqrt(max(0.000_001, Double(distance(p2, p3))))
        return (t0, t1, t2, t3)
    }

    private static func centripetalScalar(
        _ v0: Double, _ v1: Double, _ v2: Double, _ v3: Double,
        times: (Double, Double, Double, Double),
        u: Double
    ) -> Double {
        let (t0, t1, t2, t3) = times
        let t = t1 + (t2 - t1) * min(1, max(0, u))
        func mix(_ a: Double, _ b: Double, _ ta: Double, _ tb: Double) -> Double {
            let span = max(0.000_001, tb - ta)
            return (tb - t) / span * a + (t - ta) / span * b
        }
        let a1 = mix(v0, v1, t0, t1)
        let a2 = mix(v1, v2, t1, t2)
        let a3 = mix(v2, v3, t2, t3)
        let b1 = mix(a1, a2, t0, t2)
        let b2 = mix(a2, a3, t1, t3)
        return mix(b1, b2, t1, t2)
    }

    private static func estimatedRadius(
        _ sample: StrokeSample,
        progress: Double,
        brush: BrushSettings,
        scale: CGFloat
    ) -> Double {
        let pressure = 1 + (sample.pressure - 0.5) * brush.pressureSize
        let tilt = 1 + sample.tilt * brush.tiltResponse * 0.5
        let diameter = brush.size * Double(scale) * pressure * tilt * taperScale(at: progress, brush: brush)
        // Goo Thickness controls only the liquid core. Metaball dimensions use
        // the physical brush diameter independently below.
        return diameter * 0.5 * (0.10 + brush.resolvedGooThickness * 0.80)
    }

    private static func extrapolated(before point: CGPoint, next: CGPoint) -> CGPoint {
        CGPoint(x: point.x * 2 - next.x, y: point.y * 2 - next.y)
    }

    private static func extrapolated(after point: CGPoint, previous: CGPoint) -> CGPoint {
        CGPoint(x: point.x * 2 - previous.x, y: point.y * 2 - previous.y)
    }

    private static func unitDirection(_ start: CGPoint, _ end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.000_001, Foundation.hypot(dx, dy))
        return CGPoint(x: dx / length, y: dy / length)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        Foundation.hypot(b.x - a.x, b.y - a.y)
    }

    private static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        a.x * b.x + a.y * b.y
    }

    private static func angle(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        Foundation.acos(min(1, max(-1, dot(a, b))))
    }

    private static func pointToSegmentDistance(_ point: CGPoint, _ start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        guard squaredLength > 0.000_001 else { return distance(point, start) }
        let projection = min(1, max(0,
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / squaredLength
        ))
        return distance(point, CGPoint(x: start.x + dx * projection, y: start.y + dy * projection))
    }
}

nonisolated struct GooDropletEvent {
    var stationIndex: Int
    var stationFraction: Double
    var arcDistance: Double
    var side: Double
    var startPhase: Double
    var variation: Double
    var detachmentEligible: Bool
    var cellID: Int
}

/// Owns at most one event per stable arc-length cell. Sites are planned only
/// when stroke geometry is cached; animation remains entirely analytical.
nonisolated enum GooDropletPlanner {
    static func events(
        stations: [GooSplineStation],
        distances: [Double],
        brush: BrushSettings,
        strokeID: UUID,
        diameter: Double
    ) -> [GooDropletEvent] {
        guard brush.resolvedGooDroplets > 0.01,
              stations.count > 6,
              distances.count == stations.count,
              let totalLength = distances.last,
              diameter >= 2,
              totalLength >= diameter * 4 else { return [] }

        let seed = stableSeed(strokeID, base: brush.seed)
        // Every valid cell owns a continuously evaluated attached triplet.
        // Detachment is a separate, much sparser deterministic decision.
        let cellLength = diameter * (1.55 + brush.resolvedGooWaveLength * 1.25)
        let cellCount = max(1, Int(Foundation.ceil(totalLength / cellLength)))
        let edgeInset = diameter * 0.72
        let maximumTriplets = 24
        let detachmentProbability = (0.12 + brush.resolvedGooDroplets * 0.08)
            * (1 - brush.resolvedGooThickness * 0.50)
        var result: [GooDropletEvent] = []
        result.reserveCapacity(min(cellCount, maximumTriplets))

        for cellID in 0..<cellCount {
            let cellSeed = seed &+ UInt64(cellID) &* 0x9E3779B97F4A7C15
            let anchorJitter = seeded(cellSeed &+ 0xA24BAED4963EE407, 1)
            let targetDistance = min(
                totalLength,
                Double(cellID) * cellLength + cellLength * (0.18 + anchorJitter * 0.64)
            )
            guard targetDistance >= edgeInset,
                  targetDistance <= totalLength - edgeInset else { continue }
            let anchor = interpolatedAnchor(distance: targetDistance, distances: distances)
            result.append(GooDropletEvent(
                stationIndex: anchor.index,
                stationFraction: anchor.fraction,
                arcDistance: targetDistance,
                side: seeded(cellSeed &+ 0xD1B54A32D192ED03, 5) < 0.5 ? -1 : 1,
                startPhase: seeded(cellSeed &+ 0xBF58476D1CE4E5B9, 7),
                variation: seeded(cellSeed &+ 0x632BE59BD9B4E019, 9),
                detachmentEligible: seeded(cellSeed &+ 0x94D049BB133111EB, 3)
                    < detachmentProbability,
                cellID: cellID
            ))
            if result.count == maximumTriplets { break }
        }
        return result
    }

    static func interpolatedAnchor(
        distance target: Double,
        distances: [Double]
    ) -> (index: Int, fraction: Double) {
        var lower = 0
        var upper = distances.count - 1
        while lower + 1 < upper {
            let middle = (lower + upper) / 2
            if distances[middle] <= target {
                lower = middle
            } else {
                upper = middle
            }
        }
        lower = min(distances.count - 2, max(0, lower))
        let span = max(0.000_001, distances[lower + 1] - distances[lower])
        return (lower, min(1, max(0, (target - distances[lower]) / span)))
    }

    private static func stableSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }
}

nonisolated struct GooMetaballMotion {
    var movingArcDistance: Double
    var visibility: Double
    var rootRadius: Double
    var bridgeRadius: Double
    var outerRadius: Double
    var rootOutward: Double
    var bridgeOutward: Double
    var outerOutward: Double
    var rootTangent: Double
    var bridgeTangent: Double
    var outerTangent: Double
}

nonisolated func gooMetaballMotion(
    phase: Double,
    event: GooDropletEvent,
    diameter: Double,
    totalLength: Double,
    speed: Double
) -> GooMetaballMotion {
    let life = (phase - event.startPhase + 1).truncatingRemainder(dividingBy: 1)
    func random(_ multiplier: Double, _ offset: Double) -> Double {
        let value = event.variation * multiplier + offset
        return value - Foundation.floor(value)
    }
    let radiusRandom = random(7.13, 0.37)
    let travelRandom = random(13.71, 0.19)
    let driftRandom = random(19.17, 0.53)
    func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - lower) / max(0.000_001, upper - lower)))
        return t * t * (3 - 2 * t)
    }
    // The whole triplet advances monotonically through spline distance. It
    // shrinks during the hidden reset instead of reversing to its old anchor.
    let travelSpan = diameter * (1.35 + min(2, max(0, speed)) * 0.25)
    let rootTangent = (life - 0.5) * travelSpan
    let movingArcDistance = event.arcDistance + rootTangent
    let cycleVisibility = smoothstep(0.03, 0.10, life)
        * (1 - smoothstep(0.90, 0.97, life))
    let endpointInset = diameter * 0.34
    let endpointFade = diameter * 0.55
    let endpointVisibility = smoothstep(
        endpointInset,
        endpointInset + endpointFade,
        movingArcDistance
    ) * (1 - smoothstep(
        totalLength - endpointInset - endpointFade,
        totalLength - endpointInset,
        movingArcDistance
    ))
    let visibility = cycleVisibility * endpointVisibility
    let pushOut = smoothstep(0.48, 0.74, life)
        * (1 - smoothstep(0.86, 0.98, life))
    let detached = event.detachmentEligible
        ? smoothstep(0.76, 0.82, life) * (1 - smoothstep(0.88, 0.94, life))
        : 0
    let rootWave = Foundation.sin((life + radiusRandom) * Double.pi * 2)
    let bridgeWave = Foundation.sin((life + driftRandom) * Double.pi * 2)
    let attachedTravel = diameter * (0.08 + travelRandom * 0.06 + rootWave * 0.025)
    let maximumTravel = diameter * (event.detachmentEligible
        ? (0.45 + travelRandom * 0.53)
        : (0.20 + travelRandom * 0.10))
    let outerOutward = attachedTravel + (maximumTravel - attachedTravel) * pushOut
    let outerTangent = diameter
        * (0.08 + driftRandom * 0.10 + pushOut * (0.26 + driftRandom * 0.24))
    let bridgeMix = 0.46 + bridgeWave * 0.06
    let effectiveBridgeMix = bridgeMix * (1 - detached * 0.78)
    let bridgeRadiusScale = 1 - detached * 0.82
    let rawRootRadius = diameter * (0.125 + radiusRandom * 0.070)
        * (0.94 + rootWave * 0.06)
    let rootRadius = rawRootRadius * visibility
    let bridgeRadius = diameter * (0.065 + driftRandom * 0.055)
        * (0.96 + bridgeWave * 0.08) * bridgeRadiusScale * visibility
    let outerRadius = diameter * (0.032 + travelRandom * 0.030)
        * (0.96 + rootWave * 0.06) * visibility
    // Keep the root center safely inside the body boundary. The overlap is
    // radius-derived, so it remains larger than AA/export scale differences.
    let rootOutward = -rootRadius * (0.55 - pushOut * 0.06)

    return GooMetaballMotion(
        movingArcDistance: movingArcDistance,
        visibility: visibility,
        rootRadius: rootRadius,
        bridgeRadius: bridgeRadius,
        outerRadius: outerRadius,
        rootOutward: rootOutward,
        bridgeOutward: rootOutward + (outerOutward - rootOutward) * effectiveBridgeMix,
        outerOutward: outerOutward,
        rootTangent: rootTangent,
        bridgeTangent: outerTangent * effectiveBridgeMix,
        outerTangent: outerTangent
    )
}

nonisolated private func dynamicOpacity(for sample: StrokeSample, brush: BrushSettings) -> Double {
    let pressure = 1 + (sample.pressure - 0.5) * brush.pressureOpacity
    return min(1, max(0.02, brush.opacity * pressure))
}

nonisolated private func structureScale(for brush: BrushSettings) -> Double {
    let referenceSize: Double
    switch brush.kind {
    case .wiggle: referenceSize = 16
    case .jitter: referenceSize = 8
    case .pulse: referenceSize = 30
    case .cutMarker: referenceSize = 46
    case .solidColor: referenceSize = 72
    case .softAirbrush: referenceSize = 110
    case .gouache: referenceSize = 78
    case .flatChisel: referenceSize = 64
    case .scatter: referenceSize = 12
    case .ghostTrail: referenceSize = 34
    case .dashed: referenceSize = 34
    case .star: referenceSize = 26
    case .dotted: referenceSize = 22
    case .particle: referenceSize = 30
    case .goo: referenceSize = 30
    case .scribbles: referenceSize = 5
    case .particleCloud: referenceSize = 6
    case .glitter: referenceSize = 48
    case .gradient: referenceSize = 44
    case .polkaDots: referenceSize = 46
    case .faded: referenceSize = 34
    case .charcoal: referenceSize = 22
    case .colorNoise: referenceSize = 34
    case .dryOutline: referenceSize = 18
    }
    return max(0.05, brush.size / referenceSize)
}

nonisolated private func drawSegmentedStroke(
    points: [CGPoint],
    samples: [StrokeSample],
    brush: BrushSettings,
    in context: CGContext,
    widthMultiplier: Double = 1,
    opacityDivisor: Double = 1,
    roundCaps: Bool = true,
    capDepthScale: CGFloat = 1
) {
    let count = min(points.count, samples.count)
    guard count > 1 else { return }
    var upperEdge: [CGPoint] = []
    var lowerEdge: [CGPoint] = []
    var widths: [CGFloat] = []
    upperEdge.reserveCapacity(count)
    lowerEdge.reserveCapacity(count)
    widths.reserveCapacity(count)

    var opacityTotal = 0.0
    for index in 0..<count {
        let previous = points[max(0, index - 1)]
        let next = points[min(count - 1, index + 1)]
        let dx = next.x - previous.x
        let dy = next.y - previous.y
        let length = max(0.001, Foundation.hypot(dx, dy))
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let localWidth = width(
            for: samples[index],
            index: index,
            count: count,
            brush: brush,
            multiplier: widthMultiplier
        )
        let halfWidth = localWidth / 2
        widths.append(localWidth)
        upperEdge.append(CGPoint(
            x: points[index].x + normal.x * halfWidth,
            y: points[index].y + normal.y * halfWidth
        ))
        lowerEdge.append(CGPoint(
            x: points[index].x - normal.x * halfWidth,
            y: points[index].y - normal.y * halfWidth
        ))
        opacityTotal += dynamicOpacity(for: samples[index], brush: brush)
    }

    // One pressure-aware ribbon replaces one CGPath/strokePath operation per
    // sample segment. This preserves width, tilt, and taper while reducing a
    // long stroke from hundreds of CG draws to one fill plus two round caps.
    let path = CGMutablePath()
    path.move(to: upperEdge[0])
    for point in upperEdge.dropFirst() { path.addLine(to: point) }
    for point in lowerEdge.reversed() { path.addLine(to: point) }
    path.closeSubpath()

    let opacity = opacityTotal / Double(count) / opacityDivisor
    context.saveGState()
    context.setFillColor(uiColor(brush.color, opacity: opacity).cgColor)
    context.addPath(path)
    context.fillPath()
    if roundCaps {
        for index in [0, count - 1] {
            let halfWidth = widths[index] / 2
            let depth = max(0.5, halfWidth * capDepthScale)
            let neighbor = index == 0 ? points[1] : points[count - 2]
            let direction = index == 0
                ? CGPoint(x: points[0].x - neighbor.x, y: points[0].y - neighbor.y)
                : CGPoint(x: points[count - 1].x - neighbor.x, y: points[count - 1].y - neighbor.y)
            let angle = Foundation.atan2(direction.y, direction.x)
            context.saveGState()
            context.translateBy(x: points[index].x, y: points[index].y)
            context.rotate(by: angle)
            context.fillEllipse(in: CGRect(
                x: -depth,
                y: -halfWidth,
                width: depth * 2,
                height: halfWidth * 2
            ))
            context.restoreGState()
        }
    }
    context.restoreGState()
}

nonisolated private func appendOrientedTriangle(
    _ points: [CGPoint],
    to path: CGMutablePath
) {
    guard points.count == 3 else { return }
    var corners = points
    let signedArea = corners[0].x * corners[1].y
        - corners[1].x * corners[0].y
        + corners[1].x * corners[2].y
        - corners[2].x * corners[1].y
        + corners[2].x * corners[0].y
        - corners[0].x * corners[2].y
    // Rounded ribbon caps intentionally collapse their first/last station to
    // one point. Core Graphics can antialias that zero-area triangle as a long,
    // faint hairline even though it has no fillable area.
    guard abs(signedArea) > 0.5 else { return }
    if signedArea < 0 { corners.reverse() }
    path.move(to: corners[0])
    path.addLine(to: corners[1])
    path.addLine(to: corners[2])
    path.closeSubpath()
}

nonisolated struct WiggleKernel: AnimatedBrushKernel {
    let kind = BrushKind.wiggle

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        guard stroke.samples.count > 1 else { return }
        let brush = stroke.brush
        let points = stroke.samples.enumerated().map { index, sample in
            let previous = stroke.samples[max(0, index - 1)].point
            let next = stroke.samples[min(stroke.samples.count - 1, index + 1)].point
            let angle = atan2(next.y - previous.y, next.x - previous.x)
            let anglePhase = Double(index) / max(1, brush.frequency)
                + phase * Double.pi * 2 * Double(brush.loopCycles)
            let amount = Foundation.sin(anglePhase) * brush.motionAmount * structureScale(for: brush)
            return CGPoint(
                x: sample.x - Foundation.sin(Double(angle)) * amount,
                y: sample.y + Foundation.cos(Double(angle)) * amount
            )
        }
        drawSegmentedStroke(points: points, samples: stroke.samples, brush: brush, in: context)
    }
}

nonisolated struct JitterKernel: AnimatedBrushKernel {
    let kind = BrushKind.jitter

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        guard stroke.samples.count > 1 else { return }
        let brush = stroke.brush
        for pass in 0..<3 {
            let points = stroke.samples.enumerated().map { index, sample in
                let random = seeded(brush.seed &+ UInt64(pass * 991), index)
                let angle = random * Double.pi * 2 + phase * Double.pi * 2 * Double(brush.loopCycles)
                let amount = brush.motionAmount * structureScale(for: brush) * (0.25 + random * 0.75)
                return CGPoint(
                    x: sample.x + Foundation.cos(angle) * amount,
                    y: sample.y + Foundation.sin(angle) * amount
                )
            }
            drawSegmentedStroke(
                points: points,
                samples: stroke.samples,
                brush: brush,
                in: context,
                widthMultiplier: 0.55 + Double(pass) * 0.18,
                opacityDivisor: 3
            )
        }
    }
}

nonisolated struct PulseKernel: AnimatedBrushKernel {
    let kind = BrushKind.pulse

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        guard stroke.samples.count > 1 else { return }
        let brush = stroke.brush
        let pulse = max(0.05, 1 + Foundation.sin(phase * Double.pi * 2 * Double(brush.loopCycles)) * brush.motionAmount)
        drawSegmentedStroke(
            points: stroke.samples.map(\.point),
            samples: stroke.samples,
            brush: brush,
            in: context,
            widthMultiplier: pulse
        )
    }
}

nonisolated struct CutMarkerKernel: AnimatedBrushKernel {
    let kind = BrushKind.cutMarker

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        // Bounded sample count keeps long Pencil paths from rebuilding huge
        // Core Graphics paths on every display frame.
        let sourceSamples = stroke.samples
        let maxRenderSamples = 480
        let sampleStride = max(1, (sourceSamples.count + maxRenderSamples - 1) / maxRenderSamples)
        var samples = [StrokeSample]()
        samples.reserveCapacity(min(sourceSamples.count, maxRenderSamples + 1))
        for index in Swift.stride(from: 0, to: sourceSamples.count, by: sampleStride) {
            samples.append(sourceSamples[index])
        }
        if samples.last?.timestamp != sourceSamples.last?.timestamp,
           let last = sourceSamples.last {
            samples.append(last)
        }
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let roughness = brush.resolvedTextureRoughness
        let density = brush.resolvedTextureDensity
        let scale = structureScale(for: brush)

        var centers = [CGPoint]()
        var tangents = [CGPoint]()
        var normals = [CGPoint]()
        var widths = [CGFloat]()
        var upperEdge = [CGPoint]()
        var lowerEdge = [CGPoint]()
        centers.reserveCapacity(samples.count)
        tangents.reserveCapacity(samples.count)
        normals.reserveCapacity(samples.count)
        widths.reserveCapacity(samples.count)
        upperEdge.reserveCapacity(samples.count)
        lowerEdge.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            let previous = samples[max(0, index - 1)].point
            let next = samples[min(samples.count - 1, index + 1)].point
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let tangent = CGPoint(x: dx / length, y: dy / length)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let progress = Double(index) / Double(max(1, samples.count - 1))
            let wave = Foundation.sin(progress * brush.frequency * Double.pi * 2 + phaseAngle)
            let drift = wave * brush.motionAmount * scale * 0.12
            let center = CGPoint(
                x: sample.x + normal.x * drift,
                y: sample.y + normal.y * drift
            )
            let markerWidth = width(
                for: sample,
                index: index,
                count: samples.count,
                brush: brush
            )
            let halfWidth = markerWidth / 2
            let chiselSkew = halfWidth * (0.2 + CGFloat(sample.tilt * brush.tiltResponse * 0.18))

            centers.append(center)
            tangents.append(tangent)
            normals.append(normal)
            widths.append(markerWidth)
            upperEdge.append(CGPoint(
                x: center.x + normal.x * halfWidth - tangent.x * chiselSkew,
                y: center.y + normal.y * halfWidth - tangent.y * chiselSkew
            ))
            lowerEdge.append(CGPoint(
                x: center.x - normal.x * halfWidth + tangent.x * chiselSkew,
                y: center.y - normal.y * halfWidth + tangent.y * chiselSkew
            ))
        }

        let markerPath = CGMutablePath()
        markerPath.move(to: upperEdge[0])
        for point in upperEdge.dropFirst() { markerPath.addLine(to: point) }
        for point in lowerEdge.reversed() { markerPath.addLine(to: point) }
        markerPath.closeSubpath()

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(markerPath)
        context.fillPath()

        context.setBlendMode(.destinationOut)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setFillColor(UIColor.white.cgColor)
        context.setLineCap(.butt)
        let cutStride = max(3, Int((brush.spacing * (1.75 - density)).rounded()))

        for index in Swift.stride(from: 2, to: max(2, samples.count - 1), by: cutStride) {
            let tangent = tangents[index]
            let normal = normals[index]
            let animatedShift = Foundation.sin(phaseAngle + Double(index) * 0.72)
                * brush.motionAmount * scale * 0.28
            let center = CGPoint(
                x: centers[index].x + tangent.x * animatedShift,
                y: centers[index].y + tangent.y * animatedShift
            )
            let halfCutLength = widths[index] * CGFloat(0.58 + roughness * 0.18)
            let cut = CGMutablePath()
            cut.move(to: CGPoint(
                x: center.x - normal.x * halfCutLength,
                y: center.y - normal.y * halfCutLength
            ))
            cut.addLine(to: CGPoint(
                x: center.x + normal.x * halfCutLength,
                y: center.y + normal.y * halfCutLength
            ))
            context.setLineWidth(max(1.2, widths[index] * CGFloat(0.055 + roughness * 0.055)))
            context.addPath(cut)
            context.strokePath()
        }

        let biteStride = max(6, cutStride * 2)
        for index in Swift.stride(from: 3, to: max(3, samples.count - 1), by: biteStride) {
            let side: CGFloat = seeded(brush.seed, index) > 0.5 ? 1 : -1
            let normal = normals[index]
            let tangent = tangents[index]
            let edge = CGPoint(
                x: centers[index].x + normal.x * widths[index] * 0.52 * side,
                y: centers[index].y + normal.y * widths[index] * 0.52 * side
            )
            let biteLength = widths[index] * 0.16
            let biteDepth = widths[index] * CGFloat(0.16 + roughness * 0.12)
            let bite = CGMutablePath()
            bite.move(to: CGPoint(x: edge.x - tangent.x * biteLength, y: edge.y - tangent.y * biteLength))
            bite.addLine(to: CGPoint(
                x: edge.x - normal.x * biteDepth * side,
                y: edge.y - normal.y * biteDepth * side
            ))
            bite.addLine(to: CGPoint(x: edge.x + tangent.x * biteLength, y: edge.y + tangent.y * biteLength))
            bite.closeSubpath()
            context.addPath(bite)
            context.fillPath()
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }
}

nonisolated struct SolidColorKernel: AnimatedBrushKernel {
    let kind = BrushKind.solidColor

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        guard stroke.samples.count > 1 else { return }
        let brush = stroke.brush
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let breathing = 1 + Foundation.sin(phaseAngle) * min(0.12, brush.motionAmount * 0.012)
        drawSegmentedStroke(
            points: stroke.samples.map(\.point),
            samples: stroke.samples,
            brush: brush,
            in: context,
            widthMultiplier: breathing
        )
    }
}

nonisolated struct SoftAirbrushKernel: AnimatedBrushKernel {
    let kind = BrushKind.softAirbrush

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let breathing = 1 + Foundation.sin(phaseAngle) * min(0.14, brush.motionAmount * 0.012)
        let averagePressure = samples.reduce(0) { $0 + $1.pressure } / Double(samples.count)
        let opacityScale = 1 + (averagePressure - 0.5) * brush.pressureOpacity
        let alpha = min(1, brush.opacity * opacityScale)
        drawSoftPass(
            samples: samples,
            brush: brush,
            widthMultiplier: 0.78 * breathing,
            opacity: alpha * 0.18,
            blur: brush.size * 0.46,
            shadowOpacity: alpha * 0.52,
            in: context
        )
        drawSoftPass(
            samples: samples,
            brush: brush,
            widthMultiplier: 0.5 * breathing,
            opacity: alpha * 0.14,
            blur: brush.size * 0.2,
            shadowOpacity: alpha * 0.24,
            in: context
        )
    }

    private func drawSoftPass(
        samples: [StrokeSample],
        brush: BrushSettings,
        widthMultiplier: Double,
        opacity: Double,
        blur: Double,
        shadowOpacity: Double,
        in context: CGContext
    ) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShadow(
            offset: .zero,
            blur: blur,
            color: uiColor(brush.color, opacity: shadowOpacity).cgColor
        )
        context.setStrokeColor(uiColor(brush.color, opacity: opacity).cgColor)
        for index in 1..<samples.count {
            let path = CGMutablePath()
            path.move(to: samples[index - 1].point)
            path.addLine(to: samples[index].point)
            let firstWidth = width(
                for: samples[index - 1],
                index: index - 1,
                count: samples.count,
                brush: brush,
                multiplier: widthMultiplier
            )
            let secondWidth = width(
                for: samples[index],
                index: index,
                count: samples.count,
                brush: brush,
                multiplier: widthMultiplier
            )
            context.setLineWidth(max(0.5, (firstWidth + secondWidth) / 2))
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }
}

nonisolated struct GouacheKernel: AnimatedBrushKernel {
    let kind = BrushKind.gouache

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let roughness = brush.resolvedTextureRoughness
        let density = brush.resolvedTextureDensity
        let scale = structureScale(for: brush)
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let breathing = 1 + Foundation.sin(phaseAngle) * min(0.08, brush.motionAmount * 0.006)

        drawSegmentedStroke(
            points: samples.map(\.point),
            samples: samples,
            brush: brush,
            in: context,
            widthMultiplier: 0.94 * breathing,
            opacityDivisor: 1.02
        )

        for pass in 0..<2 {
            let texturedPoints = samples.enumerated().map { index, sample in
                let previous = samples[max(0, index - 1)].point
                let next = samples[min(samples.count - 1, index + 1)].point
                let dx = next.x - previous.x
                let dy = next.y - previous.y
                let length = max(0.001, Foundation.hypot(dx, dy))
                let normal = CGPoint(x: -dy / length, y: dx / length)
                let random = seeded(brush.seed &+ UInt64(pass * 991), index) - 0.5
                let animated = Foundation.sin(phaseAngle + Double(index) * 0.31 + Double(pass))
                let offset = (random * roughness * brush.size * 0.11 + animated * brush.motionAmount * 0.16) * scale
                return CGPoint(
                    x: sample.x + normal.x * offset,
                    y: sample.y + normal.y * offset
                )
            }
            drawSegmentedStroke(
                points: texturedPoints,
                samples: samples,
                brush: brush,
                in: context,
                widthMultiplier: pass == 0 ? 1.04 : 0.84,
                opacityDivisor: pass == 0 ? 5 : 7
            )
        }

        let dabStride = max(2, Int((brush.spacing * (1.7 - density)).rounded()))
        for index in Swift.stride(from: 1, to: samples.count, by: dabStride) {
            let sample = samples[index]
            let previous = samples[index - 1].point
            let next = samples[min(samples.count - 1, index + 1)].point
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let side: CGFloat = seeded(brush.seed &+ 4049, index) > 0.5 ? 1 : -1
            let localWidth = width(for: sample, index: index, count: samples.count, brush: brush)
            let edgeDistance = localWidth * CGFloat(0.4 + seeded(brush.seed &+ 8081, index) * 0.16)
            let diameter = localWidth * CGFloat(0.08 + seeded(brush.seed &+ 12011, index) * 0.13)
            let center = CGPoint(
                x: sample.x + normal.x * edgeDistance * side,
                y: sample.y + normal.y * edgeDistance * side
            )
            context.setFillColor(uiColor(brush.color, opacity: brush.opacity * (0.18 + density * 0.2)).cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter * CGFloat(0.65 + roughness * 0.45)
            ))
        }
    }
}

nonisolated struct FlatChiselKernel: AnimatedBrushKernel {
    let kind = BrushKind.flatChisel

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let scale = structureScale(for: brush)
        var upperEdge = [CGPoint]()
        var lowerEdge = [CGPoint]()
        upperEdge.reserveCapacity(samples.count)
        lowerEdge.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            let previous = samples[max(0, index - 1)].point
            let next = samples[min(samples.count - 1, index + 1)].point
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let tangent = CGPoint(x: dx / length, y: dy / length)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let progress = Double(index) / Double(max(1, samples.count - 1))
            let wave = Foundation.sin(progress * brush.frequency * Double.pi * 2 + phaseAngle)
            let drift = wave * brush.motionAmount * scale * 0.24
            let center = CGPoint(
                x: sample.x + normal.x * drift,
                y: sample.y + normal.y * drift
            )
            let markerWidth = width(for: sample, index: index, count: samples.count, brush: brush)
            let halfWidth = markerWidth / 2
            let chiselSkew = halfWidth * (0.3 + CGFloat(sample.tilt * brush.tiltResponse * 0.28))
            upperEdge.append(CGPoint(
                x: center.x + normal.x * halfWidth - tangent.x * chiselSkew,
                y: center.y + normal.y * halfWidth - tangent.y * chiselSkew
            ))
            lowerEdge.append(CGPoint(
                x: center.x - normal.x * halfWidth + tangent.x * chiselSkew,
                y: center.y - normal.y * halfWidth + tangent.y * chiselSkew
            ))
        }

        let path = CGMutablePath()
        path.move(to: upperEdge[0])
        for point in upperEdge.dropFirst() { path.addLine(to: point) }
        for point in lowerEdge.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        context.setFillColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(path)
        context.fillPath()
    }
}

nonisolated struct ScatterKernel: AnimatedBrushKernel {
    let kind = BrushKind.scatter

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let brush = stroke.brush
        let stride = max(1, Int(brush.spacing / 3))
        for index in Swift.stride(from: 0, to: stroke.samples.count, by: stride) {
            let sample = stroke.samples[index]
            let random = seeded(brush.seed, index)
            let angle = random * Double.pi * 2 + phase * Double.pi * 2 * Double(brush.loopCycles)
            let radius = brush.motionAmount * structureScale(for: brush) * (0.25 + random * 0.75)
            let center = CGPoint(
                x: sample.x + Foundation.cos(angle) * radius,
                y: sample.y + Foundation.sin(angle) * radius
            )
            let diameter = width(
                for: sample,
                index: index,
                count: stroke.samples.count,
                brush: brush,
                multiplier: 0.35 + random * 0.7
            )
            let rect = CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.setFillColor(uiColor(brush.color, opacity: dynamicOpacity(for: sample, brush: brush)).cgColor)
            context.fillEllipse(in: rect)
        }
    }
}

nonisolated struct GooKernel: AnimatedBrushKernel {
    let kind = BrushKind.goo

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let stations = GooSplineSampler.stations(
            source: stroke.samples,
            brush: stroke.brush,
            scale: 1,
            transform: { $0 }
        )
        let samples = stations.map(\.sample)
        guard samples.count > 1 else { return }

        let brush = stroke.brush
        let gooSeed = stableStrokeSeed(stroke.id, base: brush.seed)
        let animationPhase = phase - Foundation.floor(phase)
        let speedCycles = brush.resolvedGooSpeed * 2 * Double(max(1, brush.loopCycles))
        let seedPhase = Double(gooSeed & 0x00FF_FFFF) / Double(0x0100_0000) * Double.pi * 2
        let wavelengthSetting = brush.resolvedGooWaveLength
        let fieldDiameter = max(0.5, brush.size)

        var distances = [Double](repeating: 0, count: samples.count)
        var normals = [CGPoint]()
        var baseHalfWidths = [Double]()
        normals.reserveCapacity(samples.count)
        baseHalfWidths.reserveCapacity(samples.count)
        for index in samples.indices {
            if index > 0 {
                distances[index] = distances[index - 1] + Foundation.hypot(
                    stations[index].point.x - stations[index - 1].point.x,
                    stations[index].point.y - stations[index - 1].point.y
                )
            }
            let tangent = stations[index].tangent
            normals.append(CGPoint(x: -tangent.y, y: tangent.x))
            baseHalfWidths.append(Double(width(
                for: samples[index],
                index: index,
                count: samples.count,
                brush: brush
            )) / 2)
        }

        let radiusAmplitude = 0.12 + brush.resolvedGooWaviness * 0.10
        let radiusLongAmount = radiusAmplitude * 0.57
        let radiusMediumAmount = radiusAmplitude * 0.33
        let radiusDetailAmount = radiusAmplitude * 0.10
        let radiusLongCycles = speedCycles * 0.91
        let radiusMediumCycles = speedCycles * 1.61
        let radiusDetailCycles = speedCycles * 2.23
        let radiusEdgeCycles = speedCycles * 2.83
        let baseMeanSquare = 1 + 0.5 * (
            radiusLongAmount * radiusLongAmount * loopedSineEnergy(phase: animationPhase, cycles: radiusLongCycles)
                + radiusMediumAmount * radiusMediumAmount * loopedSineEnergy(phase: animationPhase, cycles: radiusMediumCycles)
                + radiusDetailAmount * radiusDetailAmount * loopedSineEnergy(phase: animationPhase, cycles: radiusDetailCycles)
        )

        var centers = [CGPoint]()
        var rawRadii = [Double]()
        centers.reserveCapacity(samples.count)
        rawRadii.reserveCapacity(samples.count)
        var targetArea = 0.0
        var animatedArea = 0.0

        for index in samples.indices {
            let distance = distances[index]
            let localDiameter = baseHalfWidths[index] * 2
            let centerLong = loopedSine(
                phase: animationPhase,
                cycles: speedCycles * 0.73,
                offset: distance / (fieldDiameter * (8 + wavelengthSetting * 6)) * Double.pi * 2
                    + seedPhase * 1.31
            )
            let centerMedium = loopedSine(
                phase: animationPhase,
                cycles: speedCycles * 1.37,
                offset: distance / (fieldDiameter * (3.2 + wavelengthSetting * 3.8)) * Double.pi * 2
                    + seedPhase * 2.17 + 1.9,
                direction: -1
            )
            let centerDetail = loopedSine(
                phase: animationPhase,
                cycles: speedCycles * 2.71,
                offset: distance / (fieldDiameter * (0.72 + wavelengthSetting * 0.34)) * Double.pi * 2
                    + seedPhase * 3.43 + 3.2
            )
            let centerAmplitude = localDiameter * (0.035 + brush.resolvedGooWaviness * 0.085)
            let centerOffset = centerAmplitude * (centerLong * 0.64 + centerMedium * 0.36)
                + localDiameter * (0.009 + brush.resolvedGooWaviness * 0.013) * centerDetail
            let normal = normals[index]
            centers.append(CGPoint(
                x: stations[index].point.x + normal.x * centerOffset,
                y: stations[index].point.y + normal.y * centerOffset
            ))

            let radiusLong = loopedSine(
                phase: animationPhase,
                cycles: radiusLongCycles,
                offset: distance / (fieldDiameter * (5 + wavelengthSetting * 4)) * Double.pi * 2
                    + seedPhase * 2.83 + 0.7,
                direction: -1
            )
            let radiusMedium = loopedSine(
                phase: animationPhase,
                cycles: radiusMediumCycles,
                offset: distance / (fieldDiameter * (2.2 + wavelengthSetting * 2.8)) * Double.pi * 2
                    + seedPhase * 4.11 + 2.4
            )
            let radiusDetail = loopedSine(
                phase: animationPhase,
                cycles: radiusDetailCycles,
                offset: distance / (fieldDiameter * (0.9 + wavelengthSetting * 0.5)) * Double.pi * 2
                    + seedPhase * 5.37 + 4.1,
                direction: -1
            )
            let radiusEdge = loopedSine(
                phase: animationPhase,
                cycles: radiusEdgeCycles,
                offset: distance / (fieldDiameter * (0.62 + wavelengthSetting * 0.28)) * Double.pi * 2
                    + seedPhase * 6.19 + 5.2
            )
            let baseRadius = baseHalfWidths[index] * (0.10 + brush.resolvedGooThickness * 0.80)
            let radiusEdgeAmount = min(
                0.10,
                localDiameter * (0.008 + brush.resolvedGooWaviness * 0.010) / max(0.35, baseRadius)
            )
            let radiusWave = radiusLongAmount * radiusLong
                + radiusMediumAmount * radiusMedium
                + radiusDetailAmount * radiusDetail
                + radiusEdgeAmount * radiusEdge
            let meanSquare = baseMeanSquare + 0.5
                * radiusEdgeAmount * radiusEdgeAmount
                * loopedSineEnergy(phase: animationPhase, cycles: radiusEdgeCycles)
            let expectedVolumeScale = 1 / Foundation.sqrt(max(0.001, meanSquare))
            let rawRadius = max(0.35, baseRadius * max(0.62, 1 + radiusWave) * expectedVolumeScale)
            rawRadii.append(rawRadius)
            targetArea += baseRadius * baseRadius
            animatedArea += rawRadius * rawRadius
        }

        // CPU export can perform an exact whole-stroke reduction. Mean radius^2
        // therefore remains constant at every frame, even for very short paths.
        let exactVolumeScale = Foundation.sqrt(targetArea / max(0.001, animatedArea))
        let radii = rawRadii.map { $0 * exactVolumeScale }
        var leftEdge = [CGPoint]()
        var rightEdge = [CGPoint]()
        leftEdge.reserveCapacity(samples.count)
        rightEdge.reserveCapacity(samples.count)
        for index in samples.indices {
            let radius = radii[index]
            leftEdge.append(CGPoint(
                x: centers[index].x + normals[index].x * radius,
                y: centers[index].y + normals[index].y * radius
            ))
            rightEdge.append(CGPoint(
                x: centers[index].x - normals[index].x * radius,
                y: centers[index].y - normals[index].y * radius
            ))
        }

        let path = CGMutablePath()
        for index in 1..<centers.count {
            appendOrientedTriangle(
                [leftEdge[index - 1], rightEdge[index - 1], leftEdge[index]],
                to: path
            )
            appendOrientedTriangle(
                [rightEdge[index - 1], rightEdge[index], leftEdge[index]],
                to: path
            )
        }
        // The caps share the same moving center and normalized local radius as
        // the ribbon, so a short tap cannot turn into a separate crescent mass.
        for index in [0, centers.count - 1] {
            let radius = radii[index]
            path.addEllipse(in: CGRect(
                x: centers[index].x - radius,
                y: centers[index].y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        let dropletEvents = GooDropletPlanner.events(
            stations: stations,
            distances: distances,
            brush: brush,
            strokeID: stroke.id,
            diameter: fieldDiameter
        )

        // Every part of a metaball triplet samples the same animated
        // centerline independently at its own global arc distance. This keeps
        // the attachment frame coherent through curves and segment joins.
        func animatedFrame(at arcDistance: Double) -> (
            position: CGPoint,
            tangent: CGPoint,
            normal: CGPoint,
            radius: Double
        )? {
            guard centers.count > 1, centers.count == radii.count else { return nil }
            let clampedDistance = min(max(0, arcDistance), distances.last ?? 0)
            let anchor = GooDropletPlanner.interpolatedAnchor(
                distance: clampedDistance,
                distances: distances
            )
            let index = anchor.index
            let nextIndex = index + 1
            guard centers.indices.contains(index), centers.indices.contains(nextIndex) else {
                return nil
            }

            func animatedPosition(at distance: Double) -> CGPoint? {
                let sample = GooDropletPlanner.interpolatedAnchor(
                    distance: min(max(0, distance), distances.last ?? 0),
                    distances: distances
                )
                let sampleNext = sample.index + 1
                guard centers.indices.contains(sample.index),
                      centers.indices.contains(sampleNext) else { return nil }
                return CGPoint(
                    x: centers[sample.index].x
                        + (centers[sampleNext].x - centers[sample.index].x) * sample.fraction,
                    y: centers[sample.index].y
                        + (centers[sampleNext].y - centers[sample.index].y) * sample.fraction
                )
            }

            guard let position = animatedPosition(at: clampedDistance) else { return nil }
            let derivativeStep = max(0.35, fieldDiameter * 0.04)
            let beforeDistance = max(0, clampedDistance - derivativeStep)
            let afterDistance = min(distances.last ?? 0, clampedDistance + derivativeStep)
            let before = animatedPosition(at: beforeDistance) ?? position
            let after = animatedPosition(at: afterDistance) ?? position
            var tangent = CGPoint(x: after.x - before.x, y: after.y - before.y)
            var tangentLength = Foundation.hypot(tangent.x, tangent.y)
            if tangentLength < 0.000_001 {
                tangent = CGPoint(
                    x: stations[index].tangent.x
                        + (stations[nextIndex].tangent.x - stations[index].tangent.x) * anchor.fraction,
                    y: stations[index].tangent.y
                        + (stations[nextIndex].tangent.y - stations[index].tangent.y) * anchor.fraction
                )
                tangentLength = max(0.000_001, Foundation.hypot(tangent.x, tangent.y))
            }
            tangent.x /= tangentLength
            tangent.y /= tangentLength
            return (
                position,
                tangent,
                CGPoint(x: -tangent.y, y: tangent.x),
                radii[index] + (radii[nextIndex] - radii[index]) * anchor.fraction
            )
        }

        for event in dropletEvents {
            let motion = gooMetaballMotion(
                phase: animationPhase,
                event: event,
                diameter: fieldDiameter,
                totalLength: distances.last ?? 0,
                speed: brush.resolvedGooSpeed
            )
            guard motion.visibility > 0.001 else { continue }
            guard let rootFrame = animatedFrame(at: motion.movingArcDistance),
                  let bridgeFrame = animatedFrame(
                    at: motion.movingArcDistance + motion.bridgeTangent
                  ),
                  let outerFrame = animatedFrame(
                    at: motion.movingArcDistance + motion.outerTangent
                  ) else { continue }
            func center(
                frame: (position: CGPoint, tangent: CGPoint, normal: CGPoint, radius: Double),
                outwardOffset: Double
            ) -> CGPoint {
                CGPoint(
                    x: frame.position.x
                        + frame.normal.x * event.side * (frame.radius + outwardOffset),
                    y: frame.position.y
                        + frame.normal.y * event.side * (frame.radius + outwardOffset)
                )
            }
            let circles = [
                (center(frame: rootFrame, outwardOffset: motion.rootOutward), motion.rootRadius),
                (center(frame: bridgeFrame, outwardOffset: motion.bridgeOutward), motion.bridgeRadius),
                (center(frame: outerFrame, outwardOffset: motion.outerOutward), motion.outerRadius)
            ]
            for (center, radius) in circles where radius > 0.01 {
                path.addEllipse(in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
        }

        // Body, caps, and every triplet are rasterized as one compound shape.
        // Core Graphics therefore performs one antialias/color composite and
        // cannot expose the old body edge through an attached lobe.
        context.setFillColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(path)
        context.fillPath()
    }

    private func loopedSine(
        phase: Double,
        cycles: Double,
        offset: Double = 0,
        direction: Double = 1
    ) -> Double {
        let safeCycles = max(0, cycles)
        let lower = Foundation.floor(safeCycles)
        let upper = lower + 1
        let blend = safeCycles - lower
        let lowerValue = Foundation.sin(
            direction * phase * Double.pi * 2 * lower + offset
        )
        let upperValue = Foundation.sin(
            direction * phase * Double.pi * 2 * upper + offset
        )
        return lowerValue + (upperValue - lowerValue) * blend
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }

    private func loopedSineEnergy(phase: Double, cycles: Double) -> Double {
        let safeCycles = max(0, cycles)
        let blend = safeCycles - Foundation.floor(safeCycles)
        let phaseDelta = phase * Double.pi * 2
        return (1 - blend) * (1 - blend) + blend * blend
            + 2 * blend * (1 - blend) * Foundation.cos(phaseDelta)
    }

}

nonisolated struct ScribblesKernel: AnimatedBrushKernel {
    let kind = BrushKind.scribbles

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        guard stroke.samples.count > 1 else { return }
        let brush = stroke.brush
        let strokeSeed = stableStrokeSeed(stroke.id, base: brush.seed)
        let normalizedPhase = phase - Foundation.floor(phase)
        let lineCount = 2 + (seeded(strokeSeed &+ 313, 0) > 0.56 ? 1 : 0)
        let speed = brush.resolvedScribbleSpeed
        let stepCount = speed < 0.01
            ? 1
            : max(2, Int((2 + speed * 7).rounded()))
        let timePosition = normalizedPhase * Double(stepCount)
        let currentStep = min(stepCount - 1, Int(Foundation.floor(timePosition)))
        let nextStep = (currentStep + 1) % stepCount
        let localTime = timePosition - Foundation.floor(timePosition)
        let rawTransition = min(1, max(0, (localTime - 0.70) / 0.30))
        let transition = rawTransition * rawTransition * (3 - 2 * rawTransition)
        let thickness = brush.resolvedScribbleThickness
        let lineWidth = max(0.45, brush.size * (0.08 + thickness * 0.24))
        let separation = brush.size * (0.42 + thickness * 0.26)

        context.setStrokeColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for lineIndex in 0..<lineCount {
            let strand = Double(lineIndex) - Double(lineCount - 1) / 2
            let baseOffset = strand * separation
            let glitchAmplitude = brush.size * (
                0.10 + seeded(strokeSeed &+ 719, lineIndex) * 0.18
            )
            let path = CGMutablePath()

            for (index, sample) in stroke.samples.enumerated() {
                let previous = stroke.samples[max(0, index - 1)].point
                let next = stroke.samples[min(stroke.samples.count - 1, index + 1)].point
                let dx = next.x - previous.x
                let dy = next.y - previous.y
                let length = max(0.001, Foundation.hypot(dx, dy))
                let normal = CGPoint(x: -dy / length, y: dx / length)
                // Long cells keep the strands mostly straight and parallel;
                // only gentle bends remain between occasional glitch updates.
                let spatialPosition = Double(index) / 18
                let cell = Int(Foundation.floor(spatialPosition))
                let cellProgress = spatialPosition - Foundation.floor(spatialPosition)
                let spatialBlend = cellProgress * cellProgress * (3 - 2 * cellProgress)

                let currentA = glitchValue(
                    seed: strokeSeed,
                    line: lineIndex,
                    cell: cell,
                    step: currentStep
                )
                let currentB = glitchValue(
                    seed: strokeSeed,
                    line: lineIndex,
                    cell: cell + 1,
                    step: currentStep
                )
                let nextA = glitchValue(
                    seed: strokeSeed,
                    line: lineIndex,
                    cell: cell,
                    step: nextStep
                )
                let nextB = glitchValue(
                    seed: strokeSeed,
                    line: lineIndex,
                    cell: cell + 1,
                    step: nextStep
                )
                let heldOffset = currentA + (currentB - currentA) * spatialBlend
                let nextOffset = nextA + (nextB - nextA) * spatialBlend
                let glitch = heldOffset + (nextOffset - heldOffset) * transition
                let offset = baseOffset + glitch * glitchAmplitude
                let point = CGPoint(
                    x: sample.x + normal.x * offset,
                    y: sample.y + normal.y * offset
                )
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }

            context.addPath(path)
            context.strokePath()
        }
    }

    private func glitchValue(seed: UInt64, line: Int, cell: Int, step: Int) -> Double {
        let key = max(0, line * 100_003 + cell * 997 + step * 7_919)
        let broad = seeded(seed &+ 1_009, key) * 2 - 1
        let fine = seeded(seed &+ 6_157, key + 37) * 2 - 1
        return broad * 0.78 + fine * 0.22
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }
}

nonisolated struct ParticleCloudKernel: AnimatedBrushKernel {
    let kind = BrushKind.particleCloud

    private struct PathMetrics {
        let cumulative: [Double]
        let total: Double
    }

    private struct PathStation {
        let point: CGPoint
        let normal: CGPoint
    }

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let normalizedPhase = phase - Foundation.floor(phase)
        let strokeSeed = stableStrokeSeed(stroke.id, base: brush.seed)
        let thickness = brush.resolvedParticleCloudThickness
        let lineWidth = max(0.35, brush.size * (0.05 + thickness * 0.55))
        let metrics = pathMetrics(samples)
        guard metrics.total > 0.001 else { return }

        // The apparent center line is primarily a dense field of overlapping
        // blobs. A very thin skeleton only keeps gaps from breaking the stroke.
        let centerLine = CGMutablePath()
        centerLine.move(to: samples[0].point)
        for sample in samples.dropFirst() { centerLine.addLine(to: sample.point) }
        context.setStrokeColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.setLineWidth(max(0.25, lineWidth * 0.30))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(centerLine)
        context.strokePath()

        let fallOff = brush.resolvedParticleCloudFallOff
        guard fallOff > 0.001, samples.count > 2 else { return }
        let scale = brush.resolvedParticleCloudScale
        let nominalBlobDiameter = brush.size * (0.11 + (1 - scale) * 0.25)
        // Amber-style body: two dense rows of attached droplets hugging the
        // solid core. Count is based on physical path length so a long stroke
        // does not stretch a fixed number of particles apart.
        let blobSpacing = max(
            0.35,
            nominalBlobDiameter
                * (0.88 - 0.44 * Foundation.sqrt(fallOff))
        )
        let naturalStationCount = max(2, Int(Foundation.floor(metrics.total / blobSpacing)) + 1)
        let centerStationCount = min(560, naturalStationCount)
        let actualSpacing = naturalStationCount > 560
            ? metrics.total / Double(max(1, centerStationCount - 1))
            : blobSpacing

        let centerBlobs = CGMutablePath()
        for stationIndex in 0..<centerStationCount {
            let distance = min(metrics.total, Double(stationIndex) * actualSpacing)
            guard let station = station(at: distance, samples: samples, metrics: metrics) else { continue }
            for sideIndex in 0..<2 {
                let key = stationIndex * 2 + sideIndex
                let side = sideIndex == 0 ? -1.0 : 1.0
                let sizeNoise = seeded(strokeSeed &+ 3_019, key)
                let offsetNoise = seeded(strokeSeed &+ 2_417, key) * 2 - 1
                let diameter = max(
                    0.48,
                    nominalBlobDiameter * (0.88 + sizeNoise * 0.34)
                )
                let edgeOffset = lineWidth * 0.38 + diameter * (0.20 + offsetNoise * 0.08)
                let center = CGPoint(
                    x: station.point.x + station.normal.x * side * edgeOffset,
                    y: station.point.y + station.normal.y * side * edgeOffset
                )
                centerBlobs.addEllipse(in: CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
            }
        }
        context.setFillColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(centerBlobs)
        context.fillPath()

        // A second, animated band sheds smaller round droplets away from both
        // edges. Density follows path length instead of using one fixed count.
        // Scale remains inverted: low = larger/fewer, high = smaller/more.
        let particlesPerHundredPoints = fallOff
            * (34 + scale * 34)
        let particleCount = min(
            480,
            max(1, Int((metrics.total / 100 * particlesPerHundredPoints).rounded()))
        )
        let speed = brush.resolvedParticleCloudSpeed
        let particlePaths = (0..<4).map { _ in CGMutablePath() }

        for particleIndex in 0..<particleCount {
            let randomA = seeded(strokeSeed &+ 101, particleIndex)
            let randomB = seeded(strokeSeed &+ 313, particleIndex)
            let randomC = seeded(strokeSeed &+ 719, particleIndex)
            let cycleCount = speed < 0.01
                ? 0
                : max(1, Int((speed * (1.15 + randomA * 1.85)).rounded()))
            let phaseOffset = seeded(strokeSeed &+ 1_237, particleIndex)
            let rawLife = normalizedPhase * Double(max(1, cycleCount)) + phaseOffset
            let life = rawLife - Foundation.floor(rawLife)
            let emissionNumber = Int(Foundation.floor(rawLife))
            let cycleSlot = cycleCount > 0
                ? ((emissionNumber % cycleCount) + cycleCount) % cycleCount
                : 0
            let location = seeded(
                strokeSeed &+ UInt64(particleIndex + 1) &* 2_009,
                cycleSlot
            )
            guard let station = station(
                at: (0.03 + location * 0.94) * metrics.total,
                samples: samples,
                metrics: metrics
            ) else { continue }
            let sideSeed = seeded(strokeSeed &+ 1_919, particleIndex * 31 + cycleSlot)
            let side = (particleIndex.isMultiple(of: 2) ? 1.0 : -1.0)
                * (sideSeed > 0.82 ? -1 : 1)

            let outward = cycleCount == 0 ? 0 : Foundation.pow(life, 0.72)
            // Drops only lift away from the ink edge briefly; they never fly
            // far across the canvas.
            let maxTravel = brush.size * (0.22 + randomB * 0.62)
            let travel = lineWidth / 2 + nominalBlobDiameter * 0.45 + outward * maxTravel
            let center = CGPoint(
                x: station.point.x + station.normal.x * side * travel,
                y: station.point.y + station.normal.y * side * travel
            )

            let fadeProgress = min(1, max(0, (life - 0.68) / 0.22))
            let fade = cycleCount == 0
                ? 1
                : 1 - fadeProgress * fadeProgress * (3 - 2 * fadeProgress)
            guard fade > 0.002 else { continue }
            let diameter = max(
                0.45,
                nominalBlobDiameter * (0.28 + randomC * 0.42)
            )
            let alphaBucket = min(3, max(0, Int((fade * 3).rounded())))
            particlePaths[alphaBucket].addEllipse(in: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }

        for (bucket, path) in particlePaths.enumerated() where !path.isEmpty {
            let bucketOpacity = brush.opacity * (Double(bucket) + 1) / 4
            context.setFillColor(uiColor(brush.color, opacity: bucketOpacity).cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }

    private func pathMetrics(_ samples: [StrokeSample]) -> PathMetrics {
        var cumulative = [Double](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            cumulative[index] = cumulative[index - 1] + Foundation.hypot(
                samples[index].x - samples[index - 1].x,
                samples[index].y - samples[index - 1].y
            )
        }
        return PathMetrics(cumulative: cumulative, total: cumulative.last ?? 0)
    }

    private func station(
        at requestedDistance: Double,
        samples: [StrokeSample],
        metrics: PathMetrics
    ) -> PathStation? {
        guard samples.count > 1, metrics.total > 0 else { return nil }
        let distance = min(metrics.total, max(0, requestedDistance))
        var index = 1
        while index < metrics.cumulative.count - 1,
              metrics.cumulative[index] < distance {
            index += 1
        }
        let startDistance = metrics.cumulative[index - 1]
        let segmentLength = max(0.001, metrics.cumulative[index] - startDistance)
        let progress = min(1, max(0, (distance - startDistance) / segmentLength))
        let start = samples[index - 1].point
        let end = samples[index].point
        let dx = end.x - start.x
        let dy = end.y - start.y
        let tangentLength = max(0.001, Foundation.hypot(dx, dy))
        return PathStation(
            point: CGPoint(
                x: start.x + dx * progress,
                y: start.y + dy * progress
            ),
            normal: CGPoint(x: -dy / tangentLength, y: dx / tangentLength)
        )
    }
}

nonisolated struct ParticleKernel: AnimatedBrushKernel {
    let kind = BrushKind.particle

    private struct Geometry {
        var centers: [CGPoint]
        var upper: [CGPoint]
        var lower: [CGPoint]
        var halfWidths: [CGFloat]
        var cumulative: [Double]
        var total: Double
    }

    private struct Station {
        var center: CGPoint
        var upper: CGPoint
        var lower: CGPoint
        var halfWidth: CGFloat
    }

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let brush = stroke.brush
        let geometry = makeGeometry(samples: stroke.samples, brush: brush)
        guard geometry.total > 0.001 else { return }

        // Quantized whole cycles keep the traversal seamless and match the
        // Dashed brush convention: default speed 0.4 maps to one full
        // traversal per animation loop. Without this the particle only
        // covered a fraction of the stroke before restarting.
        let particleCycles = (brush.resolvedParticleSpeed * 2.5).rounded()
        let rawCycle = phase * Double(max(1, brush.loopCycles)) * particleCycles
        let unit = rawCycle - Foundation.floor(rawCycle)
        let activeDuration = max(0.05, 1 - brush.resolvedParticleDelay)
        let particleLength = min(
            geometry.total * 0.45,
            max(brush.size * 0.35, brush.size * (0.35 + brush.resolvedParticleLength * 4))
        )
        // Keep moving during the delay instead of resting at the end: the
        // particle slides past the stroke end and re-enters from the start on
        // the next loop.
        let overshoot = particleLength / max(0.001, geometry.total)
        let travel = unit < activeDuration
            ? unit / activeDuration
            : 1 + (unit - activeDuration) / max(0.05, 1 - activeDuration) * overshoot
        let centerDistance = travel * geometry.total
        let start = max(0, centerDistance - particleLength / 2)
        let end = min(geometry.total, centerDistance + particleLength / 2)

        let corner = brush.resolvedDashCornerRadius
        let base = CGMutablePath()
        appendRibbon(from: 0, through: geometry.total, geometry: geometry, cornerRadius: corner, to: base)
        context.saveGState()
        context.setFillColor(uiColor(brush.resolvedDashBackgroundColor, opacity: brush.opacity).cgColor)
        context.addPath(base)
        context.fillPath()

        let particle = CGMutablePath()
        appendRibbon(from: start, through: end, geometry: geometry, cornerRadius: corner, to: particle)
        context.setFillColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(particle)
        context.fillPath()
        context.restoreGState()
    }

    private func centerPath(
        from start: Double,
        through end: Double,
        geometry: Geometry
    ) -> CGPath {
        let path = CGMutablePath()
        guard end > start,
              let first = station(at: start, geometry: geometry),
              let last = station(at: end, geometry: geometry) else { return path }
        path.move(to: first.center)
        for index in geometry.centers.indices
            where geometry.cumulative[index] > start && geometry.cumulative[index] < end {
            path.addLine(to: geometry.centers[index])
        }
        path.addLine(to: last.center)
        return path
    }

    private func makeGeometry(samples: [StrokeSample], brush: BrushSettings) -> Geometry {
        let centers = samples.map(\.point)
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        var halfWidths: [CGFloat] = []
        var cumulative = [0.0]
        var total = 0.0
        for index in samples.indices {
            let previous = centers[max(0, index - 1)]
            let next = centers[min(centers.count - 1, index + 1)]
            let length = max(0.001, Foundation.hypot(next.x - previous.x, next.y - previous.y))
            let normal = CGPoint(x: -(next.y - previous.y) / length, y: (next.x - previous.x) / length)
            let halfWidth = width(for: samples[index], index: index, count: samples.count, brush: brush) / 2
            halfWidths.append(halfWidth)
            upper.append(CGPoint(x: centers[index].x + normal.x * halfWidth, y: centers[index].y + normal.y * halfWidth))
            lower.append(CGPoint(x: centers[index].x - normal.x * halfWidth, y: centers[index].y - normal.y * halfWidth))
            if index > 0 {
                total += Foundation.hypot(centers[index].x - centers[index - 1].x, centers[index].y - centers[index - 1].y)
                cumulative.append(total)
            }
        }
        return Geometry(centers: centers, upper: upper, lower: lower, halfWidths: halfWidths, cumulative: cumulative, total: total)
    }

    private func station(at distance: Double, geometry: Geometry) -> Station? {
        guard geometry.centers.count > 1 else { return nil }
        let distance = min(geometry.total, max(0, distance))
        var index = 1
        while index < geometry.cumulative.count && geometry.cumulative[index] < distance { index += 1 }
        index = min(geometry.centers.count - 1, index)
        let start = geometry.cumulative[index - 1]
        let segment = max(0.001, geometry.cumulative[index] - start)
        let progress = min(1, max(0, (distance - start) / segment))
        return Station(
            center: interpolate(geometry.centers[index - 1], geometry.centers[index], progress),
            upper: interpolate(geometry.upper[index - 1], geometry.upper[index], progress),
            lower: interpolate(geometry.lower[index - 1], geometry.lower[index], progress),
            halfWidth: geometry.halfWidths[index - 1] + (geometry.halfWidths[index] - geometry.halfWidths[index - 1]) * CGFloat(progress)
        )
    }

    private func appendRibbon(
        from start: Double,
        through end: Double,
        geometry: Geometry,
        cornerRadius: Double = 0,
        to path: CGMutablePath
    ) {
        guard end > start else { return }
        var distances = [start, end]
        distances.append(contentsOf: geometry.cumulative.filter { $0 > start && $0 < end })
        if cornerRadius > 0.001 {
            // Physical subdivisions prevent a sparse Pencil sample from
            // turning the first cap triangle into a long one-pixel tail.
            let halfWidth = Double(geometry.halfWidths.max() ?? 1)
            let subdivision = max(0.75, min(8, halfWidth / 4))
            var distance = start + subdivision
            while distance < end {
                distances.append(distance)
                distance += subdivision
            }
            let radius = min(end - start, geometry.halfWidths.max() ?? 0)
            for step in 1..<6 {
                let inset = radius * Double(step) / 6
                if start + inset < end { distances.append(start + inset) }
                if end - inset > start { distances.append(end - inset) }
            }
        }
        distances.sort()
        var unique: [Double] = []
        for distance in distances where unique.last.map({ abs($0 - distance) > 0.0001 }) ?? true { unique.append(distance) }
        guard unique.count > 1 else { return }

        if cornerRadius > 0.001 {
            // A rounded particle must be one closed shape. Building it from
            // separate cap triangles leaves independently antialiased edges;
            // those edges can survive as a faint one-pixel line extending
            // from the tip of the particle — the same class of artifact
            // already fixed for Dashed's rounded caps, applied here too.
            var stations: [Station] = []
            stations.reserveCapacity(unique.count)
            for distance in unique {
                guard var current = station(at: distance, geometry: geometry) else { continue }
                scaleEdges(of: &current, at: distance, start: start, end: end, cornerRadius: cornerRadius)
                stations.append(current)
            }
            guard stations.count > 1 else { return }
            path.move(to: stations[0].upper)
            for current in stations.dropFirst() {
                path.addLine(to: current.upper)
            }
            for current in stations.reversed() {
                path.addLine(to: current.lower)
            }
            path.closeSubpath()
            return
        }

        for index in 1..<unique.count {
            guard let a = station(at: unique[index - 1], geometry: geometry),
                  let b = station(at: unique[index], geometry: geometry) else { continue }
            appendOrientedTriangle([a.upper, a.lower, b.upper], to: path)
            appendOrientedTriangle([a.lower, b.lower, b.upper], to: path)
        }
    }

    private func scaleEdges(of station: inout Station, at distance: Double, start: Double, end: Double, cornerRadius: Double) {
        let radius = min(Double(station.halfWidth), (end - start) / 2) * cornerRadius
        let inset = min(distance - start, end - distance)
        guard inset < radius, radius > 0.001 else { return }
        let base = Double(station.halfWidth) - radius
        let circleX = radius - max(0, inset)
        let roundedHeight = base + Foundation.sqrt(max(0, radius * radius - circleX * circleX))
        let scale = roundedHeight / Double(station.halfWidth)
        station.upper = CGPoint(x: station.center.x + (station.upper.x - station.center.x) * CGFloat(scale), y: station.center.y + (station.upper.y - station.center.y) * CGFloat(scale))
        station.lower = CGPoint(x: station.center.x + (station.lower.x - station.center.x) * CGFloat(scale), y: station.center.y + (station.lower.y - station.center.y) * CGFloat(scale))
    }

    private func interpolate(_ a: CGPoint, _ b: CGPoint, _ progress: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * progress, y: a.y + (b.y - a.y) * progress)
    }
}

nonisolated struct DashedKernel: AnimatedBrushKernel {
    let kind = BrushKind.dashed

    private struct RibbonGeometry {
        var centers: [CGPoint]
        var upper: [CGPoint]
        var lower: [CGPoint]
        var halfWidths: [CGFloat]
        var cumulative: [Double]
        var total: Double
    }

    private struct RibbonStation {
        var center: CGPoint
        var upper: CGPoint
        var lower: CGPoint
        var halfWidth: CGFloat
    }

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }

        let brush = stroke.brush
        let size = max(1, brush.size)
        // At zero length the stamp is a circle when corner radius is 100%, so
        // this single brush can move continuously from dots to long dashes.
        let dashLength = size * (1 + brush.resolvedDashLength * 4)
        let gapLength = brush.resolvedDashGap
        let patternLength = dashLength + gapLength
        // Quantized whole cycles keep the exported animation perfectly
        // seamless while still offering a clear 0–200% speed control.
        let speedCycles = brush.resolvedDashCyclesPerLoop
        let rawProgress = phase * Double(max(1, brush.loopCycles)) * speedCycles
        let progress = rawProgress - Foundation.floor(rawProgress)
        let centerline = CGMutablePath()
        centerline.move(to: samples[0].point)
        for sample in samples.dropFirst() { centerline.addLine(to: sample.point) }

        // Dashed has constant width, so Quartz's native dashed stroker is both
        // cleaner and considerably cheaper than generating a ribbon mesh for
        // every visible dash on every animation frame.
        let corner = min(1, max(0, brush.resolvedDashCornerRadius))
        let capExtension = size * corner
        let onLength = max(0.01, dashLength - capExtension)
        let offLength = max(0.01, gapLength + capExtension)

        let geometry = makeGeometry(samples: samples, brush: brush)
        var baseSegments: [CGPath] = []
        appendRibbon(
            from: 0,
            through: geometry.total,
            geometry: geometry,
            brush: brush,
            dashStart: 0,
            dashEnd: geometry.total,
            to: &baseSegments
        )
        fillRibbonSegments(
            baseSegments,
            color: brush.resolvedDashBackgroundColor,
            opacity: brush.opacity,
            in: context
        )

        context.saveGState()
        context.setLineJoin(.round)
        context.setLineWidth(size)

        context.setLineCap(corner > 0.001 ? .round : .butt)
        context.setLineDash(
            phase: CGFloat(progress * patternLength),
            lengths: [CGFloat(onLength), CGFloat(offLength)]
        )
        context.setStrokeColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(centerline)
        context.strokePath()
        context.restoreGState()
    }

    private func makeGeometry(samples: [StrokeSample], brush: BrushSettings) -> RibbonGeometry {
        let centers = samples.map(\.point)
        var upper: [CGPoint] = []
        var lower: [CGPoint] = []
        var halfWidths: [CGFloat] = []
        var cumulative = [0.0]
        upper.reserveCapacity(samples.count)
        lower.reserveCapacity(samples.count)
        halfWidths.reserveCapacity(samples.count)
        cumulative.reserveCapacity(samples.count)
        var total = 0.0
        for index in samples.indices {
            let previous = centers[max(0, index - 1)]
            let next = centers[min(centers.count - 1, index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let halfWidth = width(
                for: samples[index],
                index: index,
                count: samples.count,
                brush: brush
            ) / 2
            halfWidths.append(halfWidth)
            upper.append(CGPoint(
                x: centers[index].x + normal.x * halfWidth,
                y: centers[index].y + normal.y * halfWidth
            ))
            lower.append(CGPoint(
                x: centers[index].x - normal.x * halfWidth,
                y: centers[index].y - normal.y * halfWidth
            ))
            if index > 0 {
                total += Foundation.hypot(
                    centers[index].x - centers[index - 1].x,
                    centers[index].y - centers[index - 1].y
                )
                cumulative.append(total)
            }
        }

        return RibbonGeometry(
            centers: centers,
            upper: upper,
            lower: lower,
            halfWidths: halfWidths,
            cumulative: cumulative,
            total: total
        )
    }

    private func station(
        at distance: Double,
        geometry: RibbonGeometry
    ) -> RibbonStation? {
        guard geometry.cumulative.count == geometry.centers.count,
              geometry.centers.count > 1 else { return nil }
        let clampedDistance = min(geometry.total, max(0, distance))
        var lower = 1
        var upper = geometry.cumulative.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if geometry.cumulative[middle] < clampedDistance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let index = min(geometry.centers.count - 1, lower)
        let segmentStart = geometry.cumulative[index - 1]
        let segmentLength = max(0.001, geometry.cumulative[index] - segmentStart)
        let local = min(1, max(0, (clampedDistance - segmentStart) / segmentLength))
        return RibbonStation(
            center: interpolate(geometry.centers[index - 1], geometry.centers[index], local),
            upper: interpolate(geometry.upper[index - 1], geometry.upper[index], local),
            lower: interpolate(geometry.lower[index - 1], geometry.lower[index], local),
            halfWidth: geometry.halfWidths[index - 1]
                + (geometry.halfWidths[index] - geometry.halfWidths[index - 1]) * CGFloat(local)
        )
    }

    private func appendRibbon(
        from start: Double,
        through end: Double,
        geometry: RibbonGeometry,
        brush: BrushSettings? = nil,
        dashStart: Double? = nil,
        dashEnd: Double? = nil,
        to segments: inout [CGPath]
    ) {
        guard end > start else { return }
        var distances = [start, end]
        distances.append(contentsOf: geometry.cumulative.filter { $0 > start && $0 < end })

        if let brush, let dashStart, let dashEnd, brush.resolvedDashCornerRadius > 0 {
            // Add regular cap samples as well as the analytical radius points.
            // Coalesced Pencil touches can otherwise leave a very long first
            // triangle that rasterizes as the faint diagonal line.
            let halfWidth = Double(geometry.halfWidths.max() ?? 1)
            let subdivision = max(0.75, min(8, halfWidth / 4))
            var distance = start + subdivision
            while distance < end {
                distances.append(distance)
                distance += subdivision
            }
            let radius = min(
                max(1, brush.size) / 2,
                max(0, dashEnd - dashStart) / 2
            ) * brush.resolvedDashCornerRadius
            if radius > 0.001 {
                for step in 1..<6 {
                    let amount = radius * Double(step) / 6
                    let leading = dashStart + amount
                    let trailing = dashEnd - amount
                    if leading > start && leading < end { distances.append(leading) }
                    if trailing > start && trailing < end { distances.append(trailing) }
                }
            }
        }

        distances.sort()
        var unique: [Double] = []
        for distance in distances where unique.last.map({ abs($0 - distance) > 0.0001 }) ?? true {
            unique.append(distance)
        }
        guard unique.count > 1 else { return }

        for index in 1..<unique.count {
            guard var a = station(at: unique[index - 1], geometry: geometry),
                  var b = station(at: unique[index], geometry: geometry) else { continue }
            if let brush, let dashStart, let dashEnd {
                scaleEdges(
                    of: &a,
                    by: capScale(
                        at: unique[index - 1],
                        station: a,
                        brush: brush,
                        dashStart: dashStart,
                        dashEnd: dashEnd
                    )
                )
                scaleEdges(
                    of: &b,
                    by: capScale(
                        at: unique[index],
                        station: b,
                        brush: brush,
                        dashStart: dashStart,
                        dashEnd: dashEnd
                    )
                )
            }
            // Keep the same two-triangle topology as the Metal renderer. A
            // four-point quad can become a bow-tie at a sharp turn and its
            // winding then produces the white triangular holes in exports.
            appendTriangle([a.upper, a.lower, b.upper], to: &segments)
            appendTriangle([a.lower, b.lower, b.upper], to: &segments)
        }
    }

    private func appendTriangle(_ points: [CGPoint], to segments: inout [CGPath]) {
        guard points.count == 3 else { return }
        var corners = points
        let signedArea = corners[0].x * corners[1].y
            - corners[1].x * corners[0].y
            + corners[1].x * corners[2].y
            - corners[2].x * corners[1].y
            + corners[2].x * corners[0].y
            - corners[0].x * corners[2].y
        guard abs(signedArea) > 0.5 else { return }
        if signedArea < 0 { corners.reverse() }
        let triangle = CGMutablePath()
        triangle.move(to: corners[0])
        triangle.addLine(to: corners[1])
        triangle.addLine(to: corners[2])
        triangle.closeSubpath()
        segments.append(triangle)
    }

    private func fillRibbonSegments(
        _ segments: [CGPath],
        color: CodableColor,
        opacity: Double,
        in context: CGContext
    ) {
        guard !segments.isEmpty else { return }
        // Normalize every quad to the same winding before combining them.
        // Tight overlapping turns then form a union instead of cancelling and
        // punching triangular holes through the exported ribbon.
        let union = CGMutablePath()
        for segment in segments {
            union.addPath(segment)
        }
        context.saveGState()
        context.setFillColor(uiColor(color, opacity: opacity).cgColor)
        context.addPath(union)
        context.fillPath()
        context.restoreGState()
    }

    private func capScale(
        at distance: Double,
        station: RibbonStation,
        brush: BrushSettings,
        dashStart: Double,
        dashEnd: Double
    ) -> CGFloat {
        let corner = brush.resolvedDashCornerRadius
        guard corner > 0, station.halfWidth > 0.001 else { return 1 }
        let radius = min(
            Double(station.halfWidth),
            max(0, dashEnd - dashStart) / 2
        ) * corner
        guard radius > 0.001 else { return 1 }
        let inset = min(distance - dashStart, dashEnd - distance)
        guard inset < radius else { return 1 }
        let clampedInset = max(0, inset)
        let base = Double(station.halfWidth) - radius
        let circleX = radius - clampedInset
        let roundedHeight = base + Foundation.sqrt(max(0, radius * radius - circleX * circleX))
        return min(1, max(0, CGFloat(roundedHeight / Double(station.halfWidth))))
    }

    private func scaleEdges(of station: inout RibbonStation, by scale: CGFloat) {
        station.upper = CGPoint(
            x: station.center.x + (station.upper.x - station.center.x) * scale,
            y: station.center.y + (station.upper.y - station.center.y) * scale
        )
        station.lower = CGPoint(
            x: station.center.x + (station.lower.x - station.center.x) * scale,
            y: station.center.y + (station.lower.y - station.center.y) * scale
        )
    }

    private func interpolate(_ start: CGPoint, _ end: CGPoint, _ progress: Double) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        )
    }
}

nonisolated struct StarKernel: AnimatedBrushKernel {
    let kind = BrushKind.star

    // Pre-rendered star-gradient images keyed by paint settings. Each frame
    // draws a small rotated image per star instead of re-evaluating a clip +
    // radial gradient fill per star, which was the dominant frame cost.
    private static var spriteCache: [SpriteKey: CGImage] = [:]
    private static let spriteCacheLimit = 32

    private struct SpriteKey: Hashable {
        var color: CodableColor
        var tertiary: CodableColor
        var opacity: Double
        var outer: Double
    }

    private struct PathMetrics {
        let cumulative: [Double]
        let total: Double
    }

    private struct PathStation {
        let point: CGPoint
        let tangent: CGPoint
    }

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let size = max(1, brush.size)
        let starDiameter = size * (1 + brush.resolvedDashLength * 4)
        let gap = max(0.5, brush.resolvedDashGap)
        let pattern = starDiameter + gap

        // Quantized whole cycles keep the traversal seamless and match the
        // Dashed brush convention.
        let speedCycles = brush.resolvedDashCyclesPerLoop
        let rawProgress = phase * Double(max(1, brush.loopCycles)) * speedCycles
        let progress = rawProgress - Foundation.floor(rawProgress)
        let shift = progress * pattern

        // Extend the path at both ends so stars sweep in from outside the
        // stroke and keep going out the far end instead of popping at the edge.
        let overhang = pattern * 1.5
        let extended = extendedSamples(samples, overhang: overhang)
        let metrics = pathMetrics(extended)
        guard metrics.total > 0.001 else { return }

        let outerRadius = starDiameter / 2
        let innerRadius = outerRadius * 0.48
        let stripWidth = starDiameter * 1.3
        let starGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                uiColor(brush.color, opacity: brush.opacity).cgColor,
                uiColor(brush.resolvedTertiaryColor, opacity: brush.opacity).cgColor
            ] as CFArray,
            locations: [0, 1]
        )

        // The strip only spans the real stroke so it never sticks out past
        // where the pencil is drawing.
        let strokeLine = CGMutablePath()
        strokeLine.move(to: samples[0].point)
        for sample in samples.dropFirst() { strokeLine.addLine(to: sample.point) }

        context.saveGState()

        // Background strip: a solid ribbon, wider than the stars.
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setLineWidth(stripWidth)
        context.setStrokeColor(uiColor(brush.resolvedDashBackgroundColor, opacity: brush.opacity).cgColor)
        context.addPath(strokeLine)
        context.strokePath()

        // Clip the stars to the strip shape so they slide in/out exactly at
        // the strip's ends and never stick past where the line ends.
        context.saveGState()
        context.setLineWidth(stripWidth)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(strokeLine)
        context.replacePathWithStrokedPath()
        context.clip()

        // Stars sweeping along the strip.
        var stations: [(PathStation, Int)] = []
        var index = 0
        while true {
            let centerDistance = shift + starDiameter / 2 + Double(index) * pattern
            if centerDistance > metrics.total + pattern { break }
            if centerDistance >= -pattern {
                if let station = station(at: centerDistance, samples: extended, metrics: metrics) {
                    stations.append((station, index))
                }
            }
            index += 1
        }

        if brush.resolvedStarGradientAcrossStroke {
            // One linear gradient spans the whole strip, clipped to all stars,
            // so the color flows along the layer instead of per star.
            context.saveGState()
            let allStars = CGMutablePath()
            for (station, starIndex) in stations {
                allStars.addPath(makeStarPath(
                    center: station.point,
                    outer: outerRadius,
                    inner: innerRadius,
                    rotation: starRotation(station: station, index: starIndex, phase: phase, brush: brush)
                ))
            }
            context.addPath(allStars)
            context.clip()
            if let starGradient {
                let start = extended.first!.point
                let end = extended.last!.point
                context.drawLinearGradient(
                    starGradient,
                    start: start,
                    end: end,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            context.restoreGState()
        } else {
            // Sprite path: each star is a cached gradient image drawn with a
            // rotate + translate transform. Far cheaper than a per-star clip
            // and radial gradient fill when a stroke carries many stars.
            if let sprite = starSprite(outer: outerRadius, inner: innerRadius, brush: brush) {
                for (station, starIndex) in stations {
                    let rotation = starRotation(station: station, index: starIndex, phase: phase, brush: brush)
                    context.saveGState()
                    context.translateBy(x: station.point.x, y: station.point.y)
                    context.rotate(by: -rotation)
                    context.draw(
                        sprite,
                        in: CGRect(
                            x: -outerRadius,
                            y: -outerRadius,
                            width: outerRadius * 2,
                            height: outerRadius * 2
                        )
                    )
                    context.restoreGState()
                }
            }
        }
        context.restoreGState()
        context.restoreGState()
    }

    private func starSprite(
        outer: CGFloat,
        inner: CGFloat,
        brush: BrushSettings
    ) -> CGImage? {
        let key = SpriteKey(
            color: brush.color,
            tertiary: brush.resolvedTertiaryColor,
            opacity: brush.opacity,
            outer: Double(outer)
        )
        if let cached = Self.spriteCache[key] { return cached }

        let supersample: CGFloat = 3
        let sidePixels = Int(ceil(outer * 2 * supersample))
        guard sidePixels > 0, sidePixels <= 2048 else { return nil }
        guard let spriteContext = CGContext(
            data: nil,
            width: sidePixels,
            height: sidePixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let center = CGPoint(x: outer, y: outer)
        spriteContext.scaleBy(x: supersample, y: supersample)
        spriteContext.addPath(makeStarPath(
            center: center,
            outer: outer,
            inner: inner,
            rotation: 0
        ))
        spriteContext.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                uiColor(brush.color, opacity: brush.opacity).cgColor,
                uiColor(brush.resolvedTertiaryColor, opacity: brush.opacity).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            spriteContext.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: outer,
                options: []
            )
        }
        guard let image = spriteContext.makeImage() else { return nil }
        if Self.spriteCache.count >= Self.spriteCacheLimit {
            Self.spriteCache.removeAll(keepingCapacity: true)
        }
        Self.spriteCache[key] = image
        return image
    }

    private func extendedSamples(_ samples: [StrokeSample], overhang: Double) -> [StrokeSample] {
        guard samples.count > 1 else { return samples }
        let first = samples[0].point
        let second = samples[1].point
        let startLength = max(0.001, Foundation.hypot(second.x - first.x, second.y - first.y))
        let start = CGPoint(
            x: first.x - (second.x - first.x) / startLength * overhang,
            y: first.y - (second.y - first.y) / startLength * overhang
        )
        let last = samples[samples.count - 1].point
        let previous = samples[samples.count - 2].point
        let endLength = max(0.001, Foundation.hypot(last.x - previous.x, last.y - previous.y))
        let end = CGPoint(
            x: last.x + (last.x - previous.x) / endLength * overhang,
            y: last.y + (last.y - previous.y) / endLength * overhang
        )
        let leading = StrokeSample(x: start.x, y: start.y, pressure: 0, tilt: 0, azimuth: 0, timestamp: 0)
        let trailing = StrokeSample(x: end.x, y: end.y, pressure: 0, tilt: 0, azimuth: 0, timestamp: 0)
        return [leading] + samples + [trailing]
    }

    private func starRotation(
        station: PathStation,
        index: Int,
        phase: Double,
        brush: BrushSettings
    ) -> CGFloat {
        let pathAngle = Foundation.atan2(station.tangent.y, station.tangent.x)
        let spin = CGFloat(phase * Double.pi * 2 * brush.resolvedStarRotationSpeed)
        switch brush.resolvedStarRotationMode {
        case .synced:
            return pathAngle + spin
        case .random:
            let offset = CGFloat(seeded(brush.seed &+ 5_999, index) * Double.pi * 2)
            return pathAngle + spin + offset
        }
    }

    private func makeStarPath(
        center: CGPoint,
        outer: CGFloat,
        inner: CGFloat,
        rotation: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        let pointCount = 5
        for pointIndex in 0..<(pointCount * 2) {
            let radius = pointIndex.isMultiple(of: 2) ? outer : inner
            let angle = rotation + CGFloat(pointIndex) * .pi / CGFloat(pointCount)
            let point = CGPoint(
                x: center.x + Foundation.cos(angle) * radius,
                y: center.y + Foundation.sin(angle) * radius
            )
            if pointIndex == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    private func pathMetrics(_ samples: [StrokeSample]) -> PathMetrics {
        var cumulative = [Double](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            cumulative[index] = cumulative[index - 1] + Foundation.hypot(
                samples[index].x - samples[index - 1].x,
                samples[index].y - samples[index - 1].y
            )
        }
        return PathMetrics(cumulative: cumulative, total: cumulative.last ?? 0)
    }

    private func station(
        at requestedDistance: Double,
        samples: [StrokeSample],
        metrics: PathMetrics
    ) -> PathStation? {
        guard samples.count > 1, metrics.total > 0 else { return nil }
        let distance = min(metrics.total, max(0, requestedDistance))
        var low = 1
        var high = metrics.cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if metrics.cumulative[middle] < distance {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low
        let startDistance = metrics.cumulative[index - 1]
        let segmentLength = max(0.001, metrics.cumulative[index] - startDistance)
        let progress = min(1, max(0, (distance - startDistance) / segmentLength))
        let start = samples[index - 1].point
        let end = samples[index].point
        let dx = end.x - start.x
        let dy = end.y - start.y
        let tangentLength = max(0.001, Foundation.hypot(dx, dy))
        return PathStation(
            point: CGPoint(
                x: start.x + dx * progress,
                y: start.y + dy * progress
            ),
            tangent: CGPoint(x: dx / tangentLength, y: dy / tangentLength)
        )
    }
}

nonisolated struct DottedKernel: AnimatedBrushKernel {
    let kind = BrushKind.dotted

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }

        let brush = stroke.brush
        let baseSize = max(1, brush.size)
        let gapLength = max(0.5, baseSize + brush.resolvedDotGap)
        let rawProgress = phase * Double(max(1, brush.loopCycles))
        let progress = rawProgress - Foundation.floor(rawProgress)
        let pulse = 1 + Foundation.sin(progress * Double.pi * 2)
            * min(0.16, brush.motionAmount * 0.08)
        let metrics = pathMetrics(samples)
        guard metrics.total > 0.001 else { return }

        context.saveGState()
        var distance = gapLength - progress * gapLength
        while distance <= metrics.total {
            guard let location = point(
                at: distance,
                samples: samples,
                cumulative: metrics.cumulative
            ) else { break }
            let sample = samples[location.index]
            let diameter = width(
                for: sample,
                index: location.index,
                count: samples.count,
                brush: brush,
                multiplier: pulse
            )
            context.setFillColor(uiColor(
                brush.color,
                opacity: dynamicOpacity(for: sample, brush: brush)
            ).cgColor)
            context.fillEllipse(in: CGRect(
                x: location.point.x - diameter / 2,
                y: location.point.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
            distance += gapLength
        }
        context.restoreGState()
    }

    private func pathMetrics(_ samples: [StrokeSample]) -> (cumulative: [Double], total: Double) {
        var cumulative = [0.0]
        cumulative.reserveCapacity(samples.count)
        var total = 0.0
        for index in 1..<samples.count {
            total += Foundation.hypot(
                samples[index].x - samples[index - 1].x,
                samples[index].y - samples[index - 1].y
            )
            cumulative.append(total)
        }
        return (cumulative, total)
    }

    private func point(
        at distance: Double,
        samples: [StrokeSample],
        cumulative: [Double]
    ) -> (point: CGPoint, index: Int)? {
        guard cumulative.count == samples.count else { return nil }
        for index in 1..<samples.count where cumulative[index] >= distance {
            let segmentStart = cumulative[index - 1]
            let segmentLength = max(0.001, cumulative[index] - segmentStart)
            let local = min(1, max(0, (distance - segmentStart) / segmentLength))
            let start = samples[index - 1].point
            let end = samples[index].point
            return (
                CGPoint(
                    x: start.x + (end.x - start.x) * local,
                    y: start.y + (end.y - start.y) * local
                ),
                local < 0.5 ? index - 1 : index
            )
        }
        return nil
    }
}

nonisolated struct GhostTrailKernel: AnimatedBrushKernel {
    let kind = BrushKind.ghostTrail

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let path = stroke.samples.map(\.point)
        guard path.count > 1 else { return }

        let metrics = pathMetrics(path)
        guard metrics.total > 0.001 else { return }

        let brush = stroke.brush
        let rawProgress = phase * Double(max(1, brush.loopCycles))
        let progress = rawProgress - Foundation.floor(rawProgress)
        let headDistance = progress * metrics.total
        let sampleIndex = min(stroke.samples.count - 1, Int(progress * Double(stroke.samples.count - 1)))
        let size = max(0.6, width(
            for: stroke.samples[sampleIndex],
            index: sampleIndex,
            count: stroke.samples.count,
            brush: brush
        ))
        let tailLength = min(metrics.total, size * 4)
        let tailStart = max(0, headDistance - tailLength)
        let visibleLength = headDistance - tailStart
        let fadeDistance = 0.1
        let edgeOpacity = min(1, progress / fadeDistance, (1 - progress) / fadeDistance)
        let opacity = brush.opacity * max(0, edgeOpacity)
        guard opacity > 0.001,
              let head = point(at: headDistance, path: path, lengths: metrics.lengths)
        else { return }

        let trail = sampledPath(
            from: tailStart,
            through: headDistance,
            visibleLength: visibleLength,
            path: path,
            lengths: metrics.lengths
        )

        drawTrail(trail, size: size, color: brush.color, opacity: opacity * 0.13, widthScale: 1.65, in: context)
        drawTrail(trail, size: size, color: brush.color, opacity: opacity * 0.25, widthScale: 1.3, in: context)
        drawTrail(trail, size: size, color: brush.color, opacity: opacity, widthScale: 1, in: context)
        drawHead(at: head.point, tangent: head.tangent, size: size, color: brush.color, opacity: opacity, in: context)
    }

    private func pathMetrics(_ path: [CGPoint]) -> (lengths: [Double], total: Double) {
        var lengths = [Double]()
        lengths.reserveCapacity(path.count - 1)
        var total = 0.0
        for index in 1..<path.count {
            let length = Foundation.hypot(
                path[index].x - path[index - 1].x,
                path[index].y - path[index - 1].y
            )
            lengths.append(length)
            total += length
        }
        return (lengths, total)
    }

    private func point(
        at distance: Double,
        path: [CGPoint],
        lengths: [Double]
    ) -> (point: CGPoint, tangent: CGPoint)? {
        var travelled = 0.0
        for index in 1..<path.count {
            let segmentLength = lengths[index - 1]
            if travelled + segmentLength >= distance || index == path.count - 1 {
                guard segmentLength > 0.001 else {
                    travelled += segmentLength
                    continue
                }
                let local = min(1, max(0, (distance - travelled) / segmentLength))
                let start = path[index - 1]
                let end = path[index]
                return (
                    CGPoint(
                        x: start.x + (end.x - start.x) * local,
                        y: start.y + (end.y - start.y) * local
                    ),
                    CGPoint(
                        x: (end.x - start.x) / segmentLength,
                        y: (end.y - start.y) / segmentLength
                    )
                )
            }
            travelled += segmentLength
        }
        return nil
    }

    private func sampledPath(
        from start: Double,
        through end: Double,
        visibleLength: Double,
        path: [CGPoint],
        lengths: [Double]
    ) -> [CGPoint] {
        guard visibleLength > 0.001 else { return [] }
        let sampleCount = max(3, min(28, Int(visibleLength / 5) + 1))
        return (0..<sampleCount).compactMap { index in
            let progress = Double(index) / Double(sampleCount - 1)
            return point(at: start + visibleLength * progress, path: path, lengths: lengths)?.point
        }
    }

    private func drawTrail(
        _ points: [CGPoint],
        size: CGFloat,
        color: CodableColor,
        opacity: Double,
        widthScale: Double,
        in context: CGContext
    ) {
        guard points.count > 1 else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(uiColor(color, opacity: opacity).cgColor)

        for index in 1..<points.count {
            let progress = Double(index) / Double(points.count - 1)
            let path = CGMutablePath()
            path.move(to: points[index - 1])
            path.addLine(to: points[index])
            context.setLineWidth(max(0.6, size * (0.06 + 0.68 * Foundation.pow(progress, 0.72)) * widthScale))
            context.addPath(path)
            context.strokePath()
        }
    }

    private func drawHead(
        at point: CGPoint,
        tangent: CGPoint,
        size: CGFloat,
        color: CodableColor,
        opacity: Double,
        in context: CGContext
    ) {
        let angle = Foundation.atan2(tangent.y, tangent.x)
        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)

        for (scale, alpha) in [(1.45, 0.12), (1.2, 0.22), (1.0, 1.0)] {
            let width = size * 1.2 * scale
            let height = size * scale
            context.setFillColor(uiColor(color, opacity: opacity * alpha).cgColor)
            context.fillEllipse(in: CGRect(x: -width * 0.55, y: -height / 2, width: width, height: height))
        }

        context.setFillColor(UIColor(white: 0.04, alpha: min(1, opacity * 0.92)).cgColor)
        let dot = max(1.1, size * 0.08)
        for center in [
            CGPoint(x: size * 0.16, y: -size * 0.18),
            CGPoint(x: size * 0.16, y: size * 0.18),
            CGPoint(x: size * 0.37, y: 0)
        ] {
            context.fillEllipse(in: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2))
        }
        context.restoreGState()
    }
}

nonisolated struct FadedKernel: AnimatedBrushKernel {
    let kind = BrushKind.faded

    private final class GeometryBox: NSObject {
        let centerPath: CGPath
        let metrics: PathMetrics

        init(centerPath: CGPath, metrics: PathMetrics) {
            self.centerPath = centerPath
            self.metrics = metrics
        }
    }

    private final class CutPathBox: NSObject {
        let path: CGPath
        let estimatedCost: Int

        init(path: CGPath, estimatedCost: Int) {
            self.path = path
            self.estimatedCost = estimatedCost
        }
    }

    private static let geometryCache: NSCache<NSString, GeometryBox> = {
        let cache = NSCache<NSString, GeometryBox>()
        cache.countLimit = 1_024
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private static let cutPathCache: NSCache<NSString, CutPathBox> = {
        let cache = NSCache<NSString, CutPathBox>()
        cache.countLimit = 2_048
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let last = samples[samples.count - 1]
        let geometryKey = "\(stroke.id.uuidString)-\(samples.count)-\(Int(last.x * 10))-\(Int(last.y * 10))" as NSString
        let geometry: GeometryBox
        if let cached = Self.geometryCache.object(forKey: geometryKey) {
            geometry = cached
        } else {
            let generated = GeometryBox(
                centerPath: smoothedCenterPath(samples),
                metrics: pathMetrics(samples)
            )
            Self.geometryCache.setObject(
                generated,
                forKey: geometryKey,
                cost: samples.count * 48
            )
            geometry = generated
        }
        let centerPath = geometry.centerPath
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.setLineWidth(brush.size)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(centerPath)
        context.strokePath()

        let amount = brush.resolvedFadedAmount
        let metrics = geometry.metrics
        if amount > 0.001, metrics.total > 0.001 {
            let speed = brush.resolvedFadedSpeed
            let normalizedPhase = phase - Foundation.floor(phase)
            let frameCount = speed < 0.01
                ? 1
                : max(4, Int((5 + speed * 5).rounded()))
            let globalFrame = speed < 0.01
                ? 0
                : min(
                    frameCount - 1,
                    Int(Foundation.floor(normalizedPhase * Double(frameCount)))
                )
            let strokeSeed = stableStrokeSeed(stroke.id, base: brush.seed)
            let frameOffset = frameCount == 1
                ? 0
                : Int(seeded(strokeSeed &+ 503, 0) * Double(frameCount))
            let frameIndex = (globalFrame + frameOffset) % frameCount
            let frameSeed = strokeSeed
                &+ UInt64(frameIndex + 1) &* 0x9E3779B97F4A7C15
            let cutKey = "\(geometryKey)-\(frameIndex)-\(Int(brush.size * 10))-\(Int(amount * 100))" as NSString
            let cutBox: CutPathBox
            if let cached = Self.cutPathCache.object(forKey: cutKey) {
                cutBox = cached
            } else {
                let generated = makeCrustPath(
                    frameSeed: frameSeed,
                    strength: amount,
                    stroke: stroke,
                    metrics: metrics
                )
                cutBox = generated
                Self.cutPathCache.setObject(
                    generated,
                    forKey: cutKey,
                    cost: generated.estimatedCost
                )
            }
            context.setBlendMode(.destinationOut)
            context.setFillColor(UIColor(
                white: 0,
                alpha: min(1, 0.78 + amount * 0.22)
            ).cgColor)
            context.addPath(cutBox.path)
            context.fillPath()
            context.setBlendMode(.normal)
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }

    private struct PathMetrics {
        let cumulative: [Double]
        let total: Double
    }

    private struct PathStation {
        let point: CGPoint
        let normal: CGPoint
        let tangent: CGPoint
    }

    private func makeCrustPath(
        frameSeed: UInt64,
        strength: Double,
        stroke: AnimatedStroke,
        metrics: PathMetrics
    ) -> CutPathBox {
        let brush = stroke.brush
        let samples = stroke.samples
        let cutPath = CGMutablePath()
        var elementEstimate = 0

        let groupCount = max(2, Int((2 + strength * 1.8).rounded()))
        for group in 0..<groupCount {
            let centerDistance = seeded(frameSeed &+ 911, group) * metrics.total
            let groupLength = min(
                metrics.total * 0.40,
                max(
                    brush.size * 2,
                    metrics.total * (0.08 + seeded(frameSeed &+ 1_213, group) * 0.20)
                )
            )
            let fragmentCount = Int((12 + strength * 27).rounded())

            for fragment in 0..<fragmentCount {
                let key = group * 1_003 + fragment
                let alongNoise = seeded(frameSeed &+ 1_607, key) * 2 - 1
                let acrossNoise = seeded(frameSeed &+ 2_003, key) * 2 - 1
                let distance = min(
                    metrics.total,
                    max(0, centerDistance + alongNoise * groupLength / 2)
                )
                guard let station = station(
                    at: distance,
                    samples: samples,
                    metrics: metrics
                ) else { continue }

                let center = CGPoint(
                    x: station.point.x + station.normal.x * acrossNoise * brush.size * 0.43,
                    y: station.point.y + station.normal.y * acrossNoise * brush.size * 0.43
                )
                let lengthNoise = seeded(frameSeed &+ 2_417, key)
                let widthNoise = seeded(frameSeed &+ 2_819, key)
                let shardLength = brush.size
                    * (0.12 + lengthNoise * (lengthNoise > 0.78 ? 1.45 : 0.78))
                    * (0.72 + strength * 0.62)
                let shardWidth = max(
                    0.55,
                    brush.size * (0.025 + widthNoise * 0.14) * (0.75 + strength * 0.5)
                )
                addCrustShard(
                    center: center,
                    tangent: station.tangent,
                    normal: station.normal,
                    length: shardLength,
                    width: shardWidth,
                    asymmetry: seeded(frameSeed &+ 3_229, key),
                    to: cutPath
                )
                elementEstimate += 5
            }

            // Partial circles bite into both outside edges, creating the torn,
            // crusted silhouette visible in the reference frames.
            let biteCount = Int((8 + strength * 13).rounded())
            for bite in 0..<biteCount {
                let key = group * 509 + bite
                let distance = min(
                    metrics.total,
                    max(
                        0,
                        centerDistance
                            + (seeded(frameSeed &+ 3_631, key) * 2 - 1) * groupLength / 2
                    )
                )
                guard let station = station(
                    at: distance,
                    samples: samples,
                    metrics: metrics
                ) else { continue }
                let side = seeded(frameSeed &+ 4_039, key) < 0.5 ? -1.0 : 1.0
                let diameter = brush.size * (0.10 + seeded(frameSeed &+ 4_421, key) * 0.27)
                let center = CGPoint(
                    x: station.point.x + station.normal.x * side * brush.size * 0.46,
                    y: station.point.y + station.normal.y * side * brush.size * 0.46
                )
                cutPath.addEllipse(in: CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
                elementEstimate += 6
            }

            // Dense granular pores make the transition around each broken
            // cluster look grungy instead of like a clean vector cut.
            let grainCount = Int((15 + strength * 28).rounded())
            for grain in 0..<grainCount {
                let key = group * 2_003 + grain
                let distance = min(
                    metrics.total,
                    max(
                        0,
                        centerDistance
                            + (seeded(frameSeed &+ 4_829, key) * 2 - 1) * groupLength * 0.62
                    )
                )
                guard let station = station(
                    at: distance,
                    samples: samples,
                    metrics: metrics
                ) else { continue }
                let across = (seeded(frameSeed &+ 5_239, key) * 2 - 1) * brush.size * 0.49
                let center = CGPoint(
                    x: station.point.x + station.normal.x * across,
                    y: station.point.y + station.normal.y * across
                )
                let diameter = max(
                    0.45,
                    brush.size * (0.012 + seeded(frameSeed &+ 5_647, key) * 0.075)
                )
                cutPath.addEllipse(in: CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
                elementEstimate += 6
            }
        }
        return CutPathBox(
            path: cutPath,
            estimatedCost: max(1_024, elementEstimate * 48)
        )
    }

    private func addCrustShard(
        center: CGPoint,
        tangent: CGPoint,
        normal: CGPoint,
        length: CGFloat,
        width: CGFloat,
        asymmetry: Double,
        to destination: CGMutablePath
    ) {
        let halfLength = length / 2
        let halfWidth = width / 2
        let skew = CGFloat((asymmetry - 0.5) * 0.9) * width
        let path = CGMutablePath()
        path.move(to: CGPoint(
            x: center.x - tangent.x * halfLength + normal.x * (halfWidth + skew),
            y: center.y - tangent.y * halfLength + normal.y * (halfWidth + skew)
        ))
        path.addLine(to: CGPoint(
            x: center.x + tangent.x * halfLength + normal.x * halfWidth * 0.35,
            y: center.y + tangent.y * halfLength + normal.y * halfWidth * 0.35
        ))
        path.addLine(to: CGPoint(
            x: center.x + tangent.x * halfLength * 0.82 - normal.x * halfWidth,
            y: center.y + tangent.y * halfLength * 0.82 - normal.y * halfWidth
        ))
        path.addLine(to: CGPoint(
            x: center.x - tangent.x * halfLength * 0.72 - normal.x * halfWidth * 0.55,
            y: center.y - tangent.y * halfLength * 0.72 - normal.y * halfWidth * 0.55
        ))
        path.closeSubpath()
        destination.addPath(path)
    }

    private func pathMetrics(_ samples: [StrokeSample]) -> PathMetrics {
        var cumulative = [Double](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            cumulative[index] = cumulative[index - 1] + Foundation.hypot(
                samples[index].x - samples[index - 1].x,
                samples[index].y - samples[index - 1].y
            )
        }
        return PathMetrics(cumulative: cumulative, total: cumulative.last ?? 0)
    }

    private func station(
        at requestedDistance: Double,
        samples: [StrokeSample],
        metrics: PathMetrics
    ) -> PathStation? {
        guard samples.count > 1, metrics.total > 0 else { return nil }
        let distance = min(metrics.total, max(0, requestedDistance))
        var low = 1
        var high = metrics.cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if metrics.cumulative[middle] < distance {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let index = low
        let startDistance = metrics.cumulative[index - 1]
        let segmentLength = max(0.001, metrics.cumulative[index] - startDistance)
        let progress = min(1, max(0, (distance - startDistance) / segmentLength))
        let start = samples[index - 1].point
        let end = samples[index].point
        let dx = end.x - start.x
        let dy = end.y - start.y
        let tangentLength = max(0.001, Foundation.hypot(dx, dy))
        return PathStation(
            point: CGPoint(
                x: start.x + dx * progress,
                y: start.y + dy * progress
            ),
            normal: CGPoint(x: -dy / tangentLength, y: dx / tangentLength),
            tangent: CGPoint(x: dx / tangentLength, y: dy / tangentLength)
        )
    }

    private func smoothedCenterPath(_ samples: [StrokeSample]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = samples.first?.point else { return path }
        path.move(to: first)
        guard samples.count > 2 else {
            if let last = samples.last?.point { path.addLine(to: last) }
            return path
        }
        let firstMidpoint = CGPoint(
            x: (samples[0].x + samples[1].x) / 2,
            y: (samples[0].y + samples[1].y) / 2
        )
        path.addLine(to: firstMidpoint)
        for index in 1..<(samples.count - 1) {
            let control = samples[index].point
            let next = samples[index + 1].point
            path.addQuadCurve(
                to: CGPoint(
                    x: (control.x + next.x) / 2,
                    y: (control.y + next.y) / 2
                ),
                control: control
            )
        }
        if let last = samples.last?.point {
            path.addQuadCurve(to: last, control: last)
        }
        return path
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }
}

nonisolated struct DryOutlineKernel: AnimatedBrushKernel {
    let kind = BrushKind.dryOutline

    private struct PathMetrics {
        let cumulative: [Double]
        let total: Double
    }

    private struct PathStation {
        let point: CGPoint
        let tangent: CGPoint
        let normal: CGPoint
    }

    private final class GeometryBox: NSObject {
        let centerPath: CGPath
        let metrics: PathMetrics

        init(centerPath: CGPath, metrics: PathMetrics) {
            self.centerPath = centerPath
            self.metrics = metrics
        }
    }

    private final class EdgeFrameBox: NSObject {
        let paths: [CGPath]
        let estimatedCost: Int

        init(paths: [CGPath], estimatedCost: Int) {
            self.paths = paths
            self.estimatedCost = estimatedCost
        }
    }

    private static let geometryCache: NSCache<NSString, GeometryBox> = {
        let cache = NSCache<NSString, GeometryBox>()
        cache.countLimit = 1_024
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    private static let edgeFrameCache: NSCache<NSString, EdgeFrameBox> = {
        let cache = NSCache<NSString, EdgeFrameBox>()
        cache.countLimit = 2_048
        cache.totalCostLimit = 36 * 1024 * 1024
        return cache
    }()

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let density = brush.resolvedTextureDensity
        let roughness = brush.resolvedTextureRoughness
        let last = samples[samples.count - 1]
        let geometryKey = "grain-\(stroke.id.uuidString)-\(samples.count)-\(Int(last.x * 10))-\(Int(last.y * 10))" as NSString
        let geometry: GeometryBox
        if let cached = Self.geometryCache.object(forKey: geometryKey) {
            geometry = cached
        } else {
            let generated = GeometryBox(
                centerPath: smoothedCenterPath(samples),
                metrics: pathMetrics(samples)
            )
            Self.geometryCache.setObject(
                generated,
                forKey: geometryKey,
                cost: samples.count * 48
            )
            geometry = generated
        }

        // Stable pressure/taper-aware core. It never changes with animation
        // phase, but Start Width and End Width remain fully editable per brush.
        let coreWidth = brush.size * (0.94 - roughness * 0.08)
        drawSegmentedStroke(
            points: samples.map(\.point),
            samples: samples,
            brush: brush,
            in: context,
            widthMultiplier: coreWidth / max(0.001, brush.size),
            roundCaps: true
        )

        guard density > 0.01, roughness > 0.01, geometry.metrics.total > 0.001 else { return }
        let speed = brush.resolvedBorderSpeed
        let frameCount = speed < 0.01
            ? 1
            : max(4, Int((5 + speed * 4).rounded()))
        let normalizedPhase = phase - Foundation.floor(phase)
        let globalFrame = speed < 0.01
            ? 0
            : min(
                frameCount - 1,
                Int(Foundation.floor(normalizedPhase * Double(frameCount)))
            )
        let strokeSeed = stableStrokeSeed(stroke.id, base: brush.seed)
        let offset = frameCount == 1
            ? 0
            : Int(seeded(strokeSeed &+ 503, 0) * Double(frameCount))
        let frameIndex = (globalFrame + offset) % frameCount
        let frameSeed = strokeSeed
            &+ UInt64(frameIndex + 1) &* 0xD6E8FEB86659FD93
        let frameKey = "\(geometryKey)-\(frameIndex)-\(Int(brush.size * 10))-\(Int(density * 100))-\(Int(roughness * 100))-\(Int(brush.resolvedStartWidthScale * 100))-\(Int(brush.resolvedEndWidthScale * 100))" as NSString
        let edgeFrame: EdgeFrameBox
        if let cached = Self.edgeFrameCache.object(forKey: frameKey) {
            edgeFrame = cached
        } else {
            let generated = makeEdgeFrame(
                frameSeed: frameSeed,
                brush: brush,
                coreWidth: coreWidth,
                metrics: geometry.metrics,
                samples: samples
            )
            Self.edgeFrameCache.setObject(
                generated,
                forKey: frameKey,
                cost: generated.estimatedCost
            )
            edgeFrame = generated
        }

        let alphaLevels = [0.55, 0.78, 0.92, 1.0]
        for (index, path) in edgeFrame.paths.enumerated() where !path.isEmpty {
            context.setFillColor(uiColor(
                brush.color,
                opacity: brush.opacity * alphaLevels[index]
            ).cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    private func makeEdgeFrame(
        frameSeed: UInt64,
        brush: BrushSettings,
        coreWidth: CGFloat,
        metrics: PathMetrics,
        samples: [StrokeSample]
    ) -> EdgeFrameBox {
        let density = brush.resolvedTextureDensity
        let roughness = brush.resolvedTextureRoughness
        // Procreate-style powder grain: many tiny flecks close to the soft
        // shape edge, rather than a few visibly detached circles.
        let spacing = max(0.5, brush.size * (0.032 - density * 0.020))
        let naturalCount = max(1, Int(Foundation.floor(metrics.total / spacing)) + 1)
        let grainCount = min(4_096, naturalCount)
        let paths = (0..<4).map { _ in CGMutablePath() }
        var elementEstimate = 0

        for grain in 0..<grainCount {
            let distance = min(
                metrics.total,
                Double(grain) * spacing + seeded(frameSeed &+ 211, grain) * spacing * 0.48
            )
            guard let station = station(
                at: distance,
                samples: samples,
                metrics: metrics
            ) else { continue }
            let side = seeded(frameSeed &+ 419, grain) < 0.5 ? -1.0 : 1.0
            let sizeNoise = seeded(frameSeed &+ 617, grain)
            let outwardNoise = seeded(frameSeed &+ 821, grain)
            let alongNoise = seeded(frameSeed &+ 1_019, grain) * 2 - 1
            // Larger, chunkier flecks (with occasional bigger flakes) read as
            // grungy dry ink instead of a faint powder, and move visibly
            // between animation frames.
            let isChunk = sizeNoise > 0.82
            let diameter = max(
                0.5,
                brush.size
                    * (0.010 + roughness * (0.012 + sizeNoise * 0.045))
                    * (isChunk ? 1.6 : 1.0)
            )
            let strokeProgress = metrics.total > 0 ? distance / metrics.total : 0.5
            let localCoreWidth = coreWidth * taperScale(at: strokeProgress, brush: brush)
            // A share of the grains sit inside the body — paper showing through
            // dry ink — and animate with the same frames as the edge grain.
            let interior = seeded(frameSeed &+ 1_103, grain) < density * 0.28
            let radialOffset = interior
                ? CGFloat(0)
                : (localCoreWidth / 2
                    + diameter * (0.12 + outwardNoise * 0.40)
                    + brush.size * roughness * (outwardNoise - 0.5) * 0.045)
            let center = CGPoint(
                x: station.point.x
                    + station.normal.x * side * radialOffset
                    + station.tangent.x * alongNoise * spacing * 0.34,
                y: station.point.y
                    + station.normal.y * side * radialOffset
                    + station.tangent.y * alongNoise * spacing * 0.34
            )
            let bucket = interior
                ? 0
                : min(3, Int(seeded(frameSeed &+ 1_221, grain) * 4))

            let aspect = 0.72 + seeded(frameSeed &+ 1_429, grain) * 0.56
            let transform = CGAffineTransform(
                translationX: center.x,
                y: center.y
            ).rotated(by: Foundation.atan2(station.tangent.y, station.tangent.x))
            paths[bucket].addEllipse(
                in: CGRect(
                    x: -diameter * aspect / 2,
                    y: -diameter / 2,
                    width: diameter * aspect,
                    height: diameter
                ),
                transform: transform
            )
            elementEstimate += 6
        }

        addCapGrains(
            sample: samples[0],
            tangent: station(at: 0, samples: samples, metrics: metrics)?.tangent ?? .zero,
            isStart: true,
            frameSeed: frameSeed &+ 2_003,
            brush: brush,
            coreWidth: coreWidth * brush.resolvedStartWidthScale,
            paths: paths,
            elementEstimate: &elementEstimate
        )
        addCapGrains(
            sample: samples[samples.count - 1],
            tangent: station(at: metrics.total, samples: samples, metrics: metrics)?.tangent ?? .zero,
            isStart: false,
            frameSeed: frameSeed &+ 2_417,
            brush: brush,
            coreWidth: coreWidth * brush.resolvedEndWidthScale,
            paths: paths,
            elementEstimate: &elementEstimate
        )

        return EdgeFrameBox(
            paths: paths,
            estimatedCost: max(1_024, elementEstimate * 48)
        )
    }

    private func addCapGrains(
        sample: StrokeSample,
        tangent: CGPoint,
        isStart: Bool,
        frameSeed: UInt64,
        brush: BrushSettings,
        coreWidth: CGFloat,
        paths: [CGMutablePath],
        elementEstimate: inout Int
    ) {
        let roughness = brush.resolvedTextureRoughness
        let count = max(12, Int((16 + brush.resolvedTextureDensity * 26).rounded()))
        let baseAngle = Foundation.atan2(tangent.y, tangent.x) + (isStart ? Double.pi : 0)
        for index in 0..<count {
            let progress = Double(index) / Double(max(1, count - 1))
            let angle = baseAngle - Double.pi / 2 + progress * Double.pi
                + (seeded(frameSeed &+ 307, index) - 0.5) * 0.18
            let diameter = max(
                0.34,
                brush.size * (0.005 + roughness * (0.004 + seeded(frameSeed &+ 701, index) * 0.018))
            )
            let distance = coreWidth / 2 + diameter * seeded(frameSeed &+ 991, index) * 0.36
            let center = CGPoint(
                x: sample.x + Foundation.cos(angle) * distance,
                y: sample.y + Foundation.sin(angle) * distance
            )
            let bucket = min(3, Int(seeded(frameSeed &+ 1_201, index) * 4))
            paths[bucket].addEllipse(in: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
            elementEstimate += 6
        }
    }

    private func pathMetrics(_ samples: [StrokeSample]) -> PathMetrics {
        var cumulative = [Double](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            cumulative[index] = cumulative[index - 1] + Foundation.hypot(
                samples[index].x - samples[index - 1].x,
                samples[index].y - samples[index - 1].y
            )
        }
        return PathMetrics(cumulative: cumulative, total: cumulative.last ?? 0)
    }

    private func station(
        at requestedDistance: Double,
        samples: [StrokeSample],
        metrics: PathMetrics
    ) -> PathStation? {
        guard samples.count > 1, metrics.total > 0 else { return nil }
        let distance = min(metrics.total, max(0, requestedDistance))
        var low = 1
        var high = metrics.cumulative.count - 1
        while low < high {
            let middle = (low + high) / 2
            if metrics.cumulative[middle] < distance { low = middle + 1 } else { high = middle }
        }
        let index = low
        let startDistance = metrics.cumulative[index - 1]
        let segmentLength = max(0.001, metrics.cumulative[index] - startDistance)
        let progress = min(1, max(0, (distance - startDistance) / segmentLength))
        let start = samples[index - 1].point
        let end = samples[index].point
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(0.001, Foundation.hypot(dx, dy))
        let tangent = CGPoint(x: dx / length, y: dy / length)
        return PathStation(
            point: CGPoint(x: start.x + dx * progress, y: start.y + dy * progress),
            tangent: tangent,
            normal: CGPoint(x: -tangent.y, y: tangent.x)
        )
    }

    private func smoothedCenterPath(_ samples: [StrokeSample]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = samples.first?.point else { return path }
        path.move(to: first)
        guard samples.count > 2 else {
            if let last = samples.last?.point { path.addLine(to: last) }
            return path
        }
        let firstMidpoint = CGPoint(
            x: (samples[0].x + samples[1].x) / 2,
            y: (samples[0].y + samples[1].y) / 2
        )
        path.addLine(to: firstMidpoint)
        for index in 1..<(samples.count - 1) {
            let control = samples[index].point
            let next = samples[index + 1].point
            path.addQuadCurve(
                to: CGPoint(x: (control.x + next.x) / 2, y: (control.y + next.y) / 2),
                control: control
            )
        }
        if let last = samples.last?.point { path.addQuadCurve(to: last, control: last) }
        return path
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }
}

nonisolated struct CharcoalKernel: AnimatedBrushKernel {
    let kind = BrushKind.charcoal

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let lines = brush.resolvedCharcoalLineCount
        let normalizedPhase = phase - Foundation.floor(phase)
        let phaseAngle = normalizedPhase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let roughness = brush.resolvedTextureRoughness
        let density = brush.resolvedTextureDensity
        let grainCount = max(1, Int(1 + density * 3))

        for lineIndex in 0..<lines {
            let linePosition = lines == 1 ? 0 : -1 + Double(lineIndex) * 2 / Double(lines - 1)
            let linePhase = Double(lineIndex) / Double(lines) * Double.pi * 2
            let animationStrength = abs(Foundation.sin(phaseAngle))
            let linePulse = 0.5 + 0.5 * Foundation.sin(phaseAngle + linePhase) * animationStrength
            let widthMultiplier = (0.38 + linePulse * 0.62) / Double(lines)
            var points = [CGPoint]()
            points.reserveCapacity(samples.count)

            for (index, sample) in samples.enumerated() {
                let previous = samples[max(0, index - 1)].point
                let next = samples[min(samples.count - 1, index + 1)].point
                let dx = next.x - previous.x
                let dy = next.y - previous.y
                let length = max(0.001, Foundation.hypot(dx, dy))
                let normal = CGPoint(x: -dy / length, y: dx / length)
                let envelope = width(for: sample, index: index, count: samples.count, brush: brush)
                let coherentRoughness = Foundation.sin(
                    Double(index) * 0.17 + linePhase + phaseAngle
                ) * Double(envelope) * roughness * 0.045
                let animatedJitter = Foundation.sin(phaseAngle + linePhase) * brush.motionAmount * 0.16
                let offset = linePosition * Double(envelope) * 0.36
                    + coherentRoughness
                    + animatedJitter
                points.append(CGPoint(
                    x: sample.x + normal.x * offset,
                    y: sample.y + normal.y * offset
                ))
            }

            drawStrand(
                points: points,
                samples: samples,
                brush: brush,
                widthMultiplier: widthMultiplier,
                opacity: brush.opacity * (0.55 + linePulse * 0.45),
                in: context
            )

            guard roughness > 0.02 else { continue }
            for index in Swift.stride(from: 0, to: points.count, by: 3) {
                let previous = points[max(0, index - 1)]
                let next = points[min(points.count - 1, index + 1)]
                let dx = next.x - previous.x
                let dy = next.y - previous.y
                let length = max(0.001, Foundation.hypot(dx, dy))
                let tangent = CGPoint(x: dx / length, y: dy / length)
                let normal = CGPoint(x: -tangent.y, y: tangent.x)
                let localWidth = width(
                    for: samples[index],
                    index: index,
                    count: samples.count,
                    brush: brush,
                    multiplier: widthMultiplier
                )
                for grain in 0..<grainCount {
                    let key = index * 41 + lineIndex * 719 + grain * 997
                    let randomAcross = seeded(brush.seed &+ 211, key)
                    let randomAlong = seeded(brush.seed &+ 503, key)
                    let randomSize = seeded(brush.seed &+ 829, key)
                    let orbit = phaseAngle + randomAcross * Double.pi * 2
                    let center = CGPoint(
                        x: points[index].x
                            + normal.x * ((randomAcross - 0.5) * Double(localWidth) * 3 + Foundation.sin(orbit) * brush.motionAmount * 0.16)
                            + tangent.x * (randomAlong - 0.5) * brush.spacing,
                        y: points[index].y
                            + normal.y * ((randomAcross - 0.5) * Double(localWidth) * 3 + Foundation.sin(orbit) * brush.motionAmount * 0.16)
                            + tangent.y * (randomAlong - 0.5) * brush.spacing
                    )
                    let grainSize = max(0.45, localWidth * CGFloat(0.2 + randomSize * 0.55))
                    let twinkle = 0.45 + 0.55 * (0.5 + 0.5 * Foundation.sin(orbit + linePhase))
                    context.setFillColor(uiColor(
                        brush.color,
                        opacity: min(1, brush.opacity * roughness * twinkle * 0.62)
                    ).cgColor)
                    context.fillEllipse(in: CGRect(
                        x: center.x - grainSize / 2,
                        y: center.y - grainSize / 2,
                        width: grainSize,
                        height: grainSize
                    ))
                }
            }
        }
    }

    private func drawStrand(
        points: [CGPoint],
        samples: [StrokeSample],
        brush: BrushSettings,
        widthMultiplier: Double,
        opacity: Double,
        in context: CGContext
    ) {
        guard points.count > 1 else { return }
        var leftEdge = [CGPoint]()
        var rightEdge = [CGPoint]()
        var radii = [CGFloat]()
        leftEdge.reserveCapacity(points.count)
        rightEdge.reserveCapacity(points.count)
        radii.reserveCapacity(points.count)

        for index in points.indices {
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let radius = width(
                for: samples[index],
                index: index,
                count: points.count,
                brush: brush,
                multiplier: widthMultiplier
            ) / 2
            radii.append(radius)
            leftEdge.append(CGPoint(x: points[index].x + normal.x * radius, y: points[index].y + normal.y * radius))
            rightEdge.append(CGPoint(x: points[index].x - normal.x * radius, y: points[index].y - normal.y * radius))
        }

        let path = CGMutablePath()
        path.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() { path.addLine(to: point) }
        for point in rightEdge.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        context.setFillColor(uiColor(brush.color, opacity: opacity).cgColor)
        context.addPath(path)
        context.fillPath()

        for index in [0, points.count - 1] {
            let radius = radii[index]
            context.fillEllipse(in: CGRect(
                x: points[index].x - radius,
                y: points[index].y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }
}

nonisolated struct ColorNoiseKernel: AnimatedBrushKernel {
    let kind = BrushKind.colorNoise

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let normalizedPhase = phase - Foundation.floor(phase)
        let phaseAngle = normalizedPhase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let density = brush.resolvedTextureDensity
        let roughness = brush.resolvedTextureRoughness
        let metrics = pathMetrics(samples.map(\.point))
        guard metrics.total > 0.001 else { return }

        let stationSpacing = max(2, brush.spacing * (1.35 - density * 0.55))
        let stationCount = max(1, Int(Foundation.floor(metrics.total / stationSpacing)) + 1)
        let particlesPerStation = max(1, Int(1 + density * 2))

        for station in 0..<stationCount {
            for particle in 0..<particlesPerStation {
                let key = station * 43 + particle * 977
                let randomA = seeded(brush.seed, key)
                let randomB = seeded(brush.seed &+ 307, key)
                let randomC = seeded(brush.seed &+ 701, key)
                let randomD = seeded(brush.seed &+ 1213, key)
                let distance = min(
                    metrics.total,
                    Double(station) * stationSpacing + (randomA - 0.5) * stationSpacing * 0.86
                )
                guard let pathPoint = point(
                    at: max(0, distance),
                    samples: samples,
                    cumulative: metrics.cumulative,
                    total: metrics.total
                ) else { continue }

                let sampleIndex = min(samples.count - 1, Int(pathPoint.progress * Double(samples.count - 1)))
                let sample = samples[sampleIndex]
                let envelope = width(for: sample, index: sampleIndex, count: samples.count, brush: brush)
                let normal = CGPoint(x: -pathPoint.tangent.y, y: pathPoint.tangent.x)
                let spatialPhase = pathPoint.progress * brush.frequency * Double.pi * 2
                let orbit = phaseAngle + spatialPhase + randomA * Double.pi * 2
                let across = (randomB - 0.5) * Double(envelope) * 0.94
                    + Foundation.sin(orbit) * brush.motionAmount * structureScale(for: brush) * roughness * 0.42
                let along = (randomC - 0.5) * stationSpacing
                    + Foundation.cos(orbit) * brush.motionAmount * structureScale(for: brush) * 0.2
                let center = CGPoint(
                    x: pathPoint.point.x + normal.x * across + pathPoint.tangent.x * along,
                    y: pathPoint.point.y + normal.y * across + pathPoint.tangent.y * along
                )
                let twinkle = 0.42 + 0.58 * (0.5 + 0.5 * Foundation.sin(phaseAngle * 2 + randomD * Double.pi * 2))
                let shardSize = max(0.8, Double(envelope) * (0.035 + randomC * 0.13))
                let tangentAngle = Foundation.atan2(pathPoint.tangent.y, pathPoint.tangent.x)
                let shardAngle = tangentAngle
                    + (randomD - 0.5) * Double.pi * 1.35
                    + Foundation.sin(orbit) * 0.24
                let color = mixedColor(
                    brush.color,
                    brush.resolvedSecondaryColor,
                    amount: randomA * 0.58
                )
                context.setFillColor(uiColor(
                    color,
                    opacity: dynamicOpacity(for: sample, brush: brush) * twinkle * (0.62 + randomB * 0.38)
                ).cgColor)
                drawShard(
                    at: center,
                    size: shardSize,
                    angle: shardAngle,
                    shape: randomD,
                    in: context
                )
            }
        }
    }

    private func pathMetrics(_ points: [CGPoint]) -> (cumulative: [Double], total: Double) {
        var cumulative = [0.0]
        cumulative.reserveCapacity(points.count)
        var total = 0.0
        for index in 1..<points.count {
            total += Foundation.hypot(
                points[index].x - points[index - 1].x,
                points[index].y - points[index - 1].y
            )
            cumulative.append(total)
        }
        return (cumulative, total)
    }

    private func point(
        at distance: Double,
        samples: [StrokeSample],
        cumulative: [Double],
        total: Double
    ) -> (point: CGPoint, tangent: CGPoint, progress: Double)? {
        guard cumulative.count == samples.count, samples.count > 1 else { return nil }
        var lower = 1
        var upper = cumulative.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if cumulative[middle] < distance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let index = min(samples.count - 1, lower)
        let segmentStart = cumulative[index - 1]
        let segment = max(0.001, cumulative[index] - segmentStart)
        let local = min(1, max(0, (distance - segmentStart) / segment))
        let start = samples[index - 1].point
        let end = samples[index].point
        return (
            CGPoint(x: start.x + (end.x - start.x) * local, y: start.y + (end.y - start.y) * local),
            CGPoint(x: (end.x - start.x) / segment, y: (end.y - start.y) / segment),
            total > 0 ? distance / total : 0
        )
    }

    private func drawShard(
        at center: CGPoint,
        size: Double,
        angle: Double,
        shape: Double,
        in context: CGContext
    ) {
        if shape < 0.28 {
            context.fillEllipse(in: CGRect(
                x: center.x - size * (0.55 + shape),
                y: center.y - size * 0.36,
                width: size * (1.1 + shape * 2),
                height: size * 0.72
            ))
            return
        }

        let axis = CGPoint(x: Foundation.cos(angle), y: Foundation.sin(angle))
        let perpendicular = CGPoint(x: -axis.y, y: axis.x)
        let halfLength = size * (0.62 + shape * 0.62)
        let halfWidth = size * (0.28 + (1 - shape) * 0.32)
        let path = CGMutablePath()
        path.move(to: CGPoint(
            x: center.x + axis.x * halfLength + perpendicular.x * halfWidth * 0.72,
            y: center.y + axis.y * halfLength + perpendicular.y * halfWidth * 0.72
        ))
        path.addLine(to: CGPoint(
            x: center.x - axis.x * halfLength * 0.86 + perpendicular.x * halfWidth,
            y: center.y - axis.y * halfLength * 0.86 + perpendicular.y * halfWidth
        ))
        path.addLine(to: CGPoint(
            x: center.x - axis.x * halfLength - perpendicular.x * halfWidth * 0.68,
            y: center.y - axis.y * halfLength - perpendicular.y * halfWidth * 0.68
        ))
        if shape < 0.9 {
            path.addLine(to: CGPoint(
                x: center.x + axis.x * halfLength * 0.82 - perpendicular.x * halfWidth,
                y: center.y + axis.y * halfLength * 0.82 - perpendicular.y * halfWidth
            ))
        }
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
    }

    private func mixedColor(_ first: CodableColor, _ second: CodableColor, amount: Double) -> CodableColor {
        let blend = min(1, max(0, amount))
        return CodableColor(
            red: first.red + (second.red - first.red) * blend,
            green: first.green + (second.green - first.green) * blend,
            blue: first.blue + (second.blue - first.blue) * blend,
            alpha: first.alpha + (second.alpha - first.alpha) * blend
        )
    }
}

nonisolated struct GradientKernel: AnimatedBrushKernel {
    let kind = BrushKind.gradient

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let centerPath = smoothedCenterPath(samples)

        // One stroked clipping path unions all segments and all self-overlaps
        // made before the Pencil is lifted. The gradient is then drawn once,
        // so retracing never reveals round caps or segment boundaries.
        context.saveGState()
        context.addPath(centerPath)
        context.setLineWidth(brush.size)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()

        let points = samples.map(\.point)
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? minX + 1
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? minY + 1
        let horizontal = maxX - minX >= maxY - minY
        let normalizedPhase = phase - Foundation.floor(phase)
        let speed = brush.resolvedGradientSpeed
        let cycles = speed < 0.01
            ? 0
            : max(1, Int((speed * 2).rounded()))
        let flow = cycles == 0
            ? 0
            : Foundation.sin(normalizedPhase * Double.pi * 2 * Double(cycles)) * 0.28
        let stopCount = 9
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        colors.reserveCapacity(stopCount)
        locations.reserveCapacity(stopCount)

        for index in 0..<stopCount {
            let location = Double(index) / Double(stopCount - 1)
            let blend = min(1, max(0, location + flow))
            colors.append(uiColor(
                mixedColor(brush.color, brush.resolvedSecondaryColor, amount: blend),
                opacity: brush.opacity
            ).cgColor)
            locations.append(CGFloat(location))
        }

        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) {
            let centerX = (minX + maxX) / 2
            let centerY = (minY + maxY) / 2
            let start = horizontal
                ? CGPoint(x: minX - brush.size / 2, y: centerY)
                : CGPoint(x: centerX, y: minY - brush.size / 2)
            let end = horizontal
                ? CGPoint(x: maxX + brush.size / 2, y: centerY)
                : CGPoint(x: centerX, y: maxY + brush.size / 2)
            context.drawLinearGradient(
                gradient,
                start: start,
                end: end,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    private func mixedColor(
        _ first: CodableColor,
        _ second: CodableColor,
        amount: Double
    ) -> CodableColor {
        let blend = min(1, max(0, amount))
        return CodableColor(
            red: first.red + (second.red - first.red) * blend,
            green: first.green + (second.green - first.green) * blend,
            blue: first.blue + (second.blue - first.blue) * blend,
            alpha: first.alpha + (second.alpha - first.alpha) * blend
        )
    }

    private func smoothedCenterPath(_ samples: [StrokeSample]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = samples.first?.point else { return path }
        path.move(to: first)
        guard samples.count > 2 else {
            if let last = samples.last?.point { path.addLine(to: last) }
            return path
        }

        let firstMidpoint = CGPoint(
            x: (samples[0].x + samples[1].x) / 2,
            y: (samples[0].y + samples[1].y) / 2
        )
        path.addLine(to: firstMidpoint)
        for index in 1..<(samples.count - 1) {
            let control = samples[index].point
            let next = samples[index + 1].point
            path.addQuadCurve(
                to: CGPoint(
                    x: (control.x + next.x) / 2,
                    y: (control.y + next.y) / 2
                ),
                control: control
            )
        }
        if let last = samples.last?.point {
            path.addQuadCurve(to: last, control: last)
        }
        return path
    }
}

nonisolated struct PolkaDotsKernel: AnimatedBrushKernel {
    let kind = BrushKind.polkaDots

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let rows = brush.resolvedPolkaRowCount
        let metrics = pathMetrics(samples.map(\.point))
        guard metrics.total > 0.001 else { return }

        let referenceDiameter = max(1.5, brush.size / Double(rows) * 0.82)
        let columnSpacing = max(2, referenceDiameter * 1.22, brush.spacing)
        let columnCount = max(1, Int(Foundation.floor(metrics.total / columnSpacing)) + 1)
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))

        for row in 0..<rows {
            let stagger = row.isMultiple(of: 2) ? 0 : columnSpacing * 0.5
            for column in 0..<columnCount {
                let distance = Double(column) * columnSpacing + stagger
                guard distance <= metrics.total,
                      let pathPoint = point(at: distance, samples: samples, cumulative: metrics.cumulative, total: metrics.total)
                else { continue }

                let sampleIndex = min(samples.count - 1, Int(pathPoint.progress * Double(samples.count - 1)))
                let sample = samples[sampleIndex]
                let envelope = width(for: sample, index: sampleIndex, count: samples.count, brush: brush)
                let baseDiameter = max(1.5, envelope / CGFloat(Double(rows) + 0.42))
                let rowSpacing = rows == 1 ? 0 : (envelope - baseDiameter) / CGFloat(rows - 1)
                let centeredRow = CGFloat(row) - CGFloat(rows - 1) / 2
                let normal = CGPoint(x: -pathPoint.tangent.y, y: pathPoint.tangent.x)
                let center = CGPoint(
                    x: pathPoint.point.x + normal.x * centeredRow * rowSpacing,
                    y: pathPoint.point.y + normal.y * centeredRow * rowSpacing
                )

                let travel = distance / columnSpacing * 0.58 + Double(row) * 0.38
                let wave = 0.5 + 0.5 * Foundation.sin(phaseAngle + travel)
                let pulseAmount = 0.055 + brush.motionAmount * 0.24
                let pulse = 1 + (wave * 2 - 1) * pulseAmount
                let diameter = baseDiameter * max(0.76, pulse)
                let opacity = dynamicOpacity(for: sample, brush: brush)
                let rect = CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                let lowColor = darkened(brush.color, amount: 0.3)
                let highColor = highlighted(brush.color, amount: 0.48)
                let animatedColor = blended(lowColor, highColor, amount: wave)

                context.setFillColor(uiColor(brush.color, opacity: opacity * (0.12 + wave * 0.28)).cgColor)
                context.fillEllipse(in: rect.insetBy(dx: -diameter * (0.34 + wave * 0.2), dy: -diameter * (0.34 + wave * 0.2)))
                context.setFillColor(uiColor(animatedColor, opacity: opacity).cgColor)
                context.fillEllipse(in: rect)
            }
        }
    }

    private func pathMetrics(_ points: [CGPoint]) -> (cumulative: [Double], total: Double) {
        var cumulative = [0.0]
        cumulative.reserveCapacity(points.count)
        var total = 0.0
        for index in 1..<points.count {
            total += Foundation.hypot(
                points[index].x - points[index - 1].x,
                points[index].y - points[index - 1].y
            )
            cumulative.append(total)
        }
        return (cumulative, total)
    }

    private func point(
        at distance: Double,
        samples: [StrokeSample],
        cumulative: [Double],
        total: Double
    ) -> (point: CGPoint, tangent: CGPoint, progress: Double)? {
        guard cumulative.count == samples.count, samples.count > 1 else { return nil }
        var lower = 1
        var upper = cumulative.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if cumulative[middle] < distance {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let index = min(samples.count - 1, lower)
        let segmentStart = cumulative[index - 1]
        let segment = max(0.001, cumulative[index] - segmentStart)
        let local = min(1, max(0, (distance - segmentStart) / segment))
        let start = samples[index - 1].point
        let end = samples[index].point
        return (
            CGPoint(x: start.x + (end.x - start.x) * local, y: start.y + (end.y - start.y) * local),
            CGPoint(x: (end.x - start.x) / segment, y: (end.y - start.y) / segment),
            total > 0 ? distance / total : 0
        )
    }

    private func blended(_ first: CodableColor, _ second: CodableColor, amount: Double) -> CodableColor {
        let blend = min(1, max(0, amount))
        return CodableColor(
            red: first.red + (second.red - first.red) * blend,
            green: first.green + (second.green - first.green) * blend,
            blue: first.blue + (second.blue - first.blue) * blend,
            alpha: first.alpha + (second.alpha - first.alpha) * blend
        )
    }

    private func darkened(_ color: CodableColor, amount: Double) -> CodableColor {
        let scale = 1 - min(1, max(0, amount))
        return CodableColor(
            red: color.red * scale,
            green: color.green * scale,
            blue: color.blue * scale,
            alpha: color.alpha
        )
    }

    private func highlighted(_ color: CodableColor, amount: Double) -> CodableColor {
        let blend = min(1, max(0, amount))
        return CodableColor(
            red: color.red + (1 - color.red) * blend,
            green: color.green + (1 - color.green) * blend,
            blue: color.blue + (1 - color.blue) * blend,
            alpha: color.alpha
        )
    }
}

nonisolated struct GlitterKernel: AnimatedBrushKernel {
    let kind = BrushKind.glitter

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let centerPath = smoothedCenterPath(samples)

        // A single stroked path naturally unions every segment and every
        // self-overlap belonging to this stroke. Other strokes stay separate.
        context.saveGState()
        context.setStrokeColor(uiColor(
            brush.resolvedSecondaryColor,
            opacity: brush.opacity
        ).cgColor)
        context.setLineWidth(brush.size)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(centerPath)
        context.strokePath()
        context.restoreGState()

        var cumulative = [Double](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            cumulative[index] = cumulative[index - 1] + Foundation.hypot(
                samples[index].x - samples[index - 1].x,
                samples[index].y - samples[index - 1].y
            )
        }
        guard let total = cumulative.last, total > 0.001 else { return }

        // Glitter is clipped to the merged stroke silhouette, so its animated
        // particles can never leak outside the background fill.
        context.saveGState()
        context.addPath(centerPath)
        context.setLineWidth(brush.size)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.replacePathWithStrokedPath()
        context.clip()

        let density = brush.resolvedGlitterDensity
        let spacing = max(1.35, brush.size * (0.14 - density * 0.09))
        let naturalCount = max(1, Int(Foundation.floor(total / spacing)) + 1)
        // Never redistribute existing grains as a live stroke grows. The old
        // capped layout recomputed total/count spacing and made every sparkle
        // visibly slide after a few long passes with the Pencil still down.
        let grainCount = min(4_096, naturalCount)
        let actualSpacing = spacing
        let sparkleAmount = brush.resolvedSparkleAmount
        let speed = brush.resolvedGlitterSpeed
        let normalizedPhase = phase - Foundation.floor(phase)
        let strokeSeed = stableStrokeSeed(stroke.id, base: brush.seed)
        let alphaPaths = (0..<8).map { _ in CGMutablePath() }
        var segment = 1

        for grainIndex in 0..<grainCount {
            let jitter = seeded(strokeSeed &+ 211, grainIndex) * actualSpacing * 0.72
            let distance = min(total, Double(grainIndex) * actualSpacing + jitter)
            while segment < cumulative.count - 1, cumulative[segment] < distance {
                segment += 1
            }
            let startDistance = cumulative[segment - 1]
            let segmentLength = max(0.001, cumulative[segment] - startDistance)
            let progress = min(1, max(0, (distance - startDistance) / segmentLength))
            let start = samples[segment - 1].point
            let end = samples[segment].point
            let dx = end.x - start.x
            let dy = end.y - start.y
            let tangentLength = max(0.001, Foundation.hypot(dx, dy))
            let normal = CGPoint(x: -dy / tangentLength, y: dx / tangentLength)
            let pathPoint = CGPoint(
                x: start.x + dx * progress,
                y: start.y + dy * progress
            )
            let across = (seeded(strokeSeed &+ 419, grainIndex) * 2 - 1)
                * brush.size * 0.43
            let center = CGPoint(
                x: pathPoint.x + normal.x * across,
                y: pathPoint.y + normal.y * across
            )

            let phaseOffset = seeded(strokeSeed &+ 617, grainIndex) * Double.pi * 2
            let cycles = max(1, Int((speed * (1.2 + seeded(strokeSeed &+ 821, grainIndex) * 1.8)).rounded()))
            let twinkle = speed < 0.01
                ? seeded(strokeSeed &+ 1_019, grainIndex)
                : 0.5 + 0.5 * Foundation.sin(
                    normalizedPhase * Double.pi * 2 * Double(cycles) + phaseOffset
                )
            let alpha = 0.20 + Foundation.pow(twinkle, 1.4) * 0.80
            let bucket = min(7, max(0, Int((alpha * 7).rounded())))
            let baseSize = max(
                0.75,
                brush.size * (0.018 + seeded(strokeSeed &+ 1_229, grainIndex) * 0.055)
            )
            let isSparkle = seeded(strokeSeed &+ 1_429, grainIndex)
                < 0.05 + sparkleAmount * 0.24
            // Position and geometry remain fixed; only opacity twinkles.
            let particleSize = baseSize * (isSparkle ? 1.55 : 1)

            if isSparkle {
                addDiamond(
                    center: center,
                    radius: particleSize,
                    to: alphaPaths[bucket]
                )
            } else {
                alphaPaths[bucket].addEllipse(in: CGRect(
                    x: center.x - particleSize / 2,
                    y: center.y - particleSize / 2,
                    width: particleSize,
                    height: particleSize
                ))
            }
        }

        for (bucket, path) in alphaPaths.enumerated() where !path.isEmpty {
            let opacity = brush.opacity * (0.125 + Double(bucket) * 0.125)
            context.setFillColor(uiColor(brush.color, opacity: opacity).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.restoreGState()
    }

    private func addDiamond(center: CGPoint, radius: CGFloat, to path: CGMutablePath) {
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x + radius * 0.72, y: center.y))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x - radius * 0.72, y: center.y))
        path.closeSubpath()
    }

    private func smoothedCenterPath(_ samples: [StrokeSample]) -> CGMutablePath {
        let path = CGMutablePath()
        guard let first = samples.first?.point else { return path }
        path.move(to: first)
        guard samples.count > 2 else {
            if let last = samples.last?.point { path.addLine(to: last) }
            return path
        }

        // Each captured point becomes a quadratic control point. Midpoint
        // endpoints remove the visible straight joins without changing the
        // user's overall Pencil path.
        for index in 1..<samples.count {
            let control = samples[index].point
            let next = index + 1 < samples.count
                ? samples[index + 1].point
                : control
            let endpoint = CGPoint(
                x: (control.x + next.x) / 2,
                y: (control.y + next.y) / 2
            )
            path.addQuadCurve(to: endpoint, control: control)
        }
        return path
    }

    private func stableStrokeSeed(_ id: UUID, base: UInt64) -> UInt64 {
        var hash = base ^ 0xCBF29CE484222325
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return hash
    }
}

nonisolated enum AnimatedDrawingRenderer {
    private static let fillFrameCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    private static let importedImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private static let failedFillImageCache = NSCache<NSString, NSNumber>()
    private static let failedImportedImageCache = NSCache<NSString, NSNumber>()

    private static func decodedFillImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else { return nil }
        return UIImage(cgImage: image)
    }

    static func preloadFillFrames(fillID: UUID, frames: [Data]) {
        for (index, data) in frames.enumerated() {
            autoreleasepool {
                let key = "\(fillID.uuidString)-\(index)" as NSString
                guard fillFrameCache.object(forKey: key) == nil,
                      failedFillImageCache.object(forKey: key) == nil else { return }
                guard let image = decodedFillImage(from: data) else {
                    failedFillImageCache.setObject(1, forKey: key)
                    return
                }
                fillFrameCache.setObject(
                    image,
                    forKey: key,
                    cost: Int(image.size.width * image.size.height * 4)
                )
            }
        }
    }

    /// A deterministic per-stroke phase offset in [0, 1) derived from the
    /// stroke's id. A stroke keeps the same offset frame to frame while the
    /// global animation clock advances, so enabling randomization simply
    /// shifts each stroke to its own point in the animation loop instead of
    /// having every stroke move in lockstep.
    static func strokePhaseOffset(_ id: UUID) -> Double {
        var hash: UInt64 = 0x9E3779B97F4A7C15
        for byte in id.uuidString.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001B3
        }
        return Double(hash % 10_000) / 10_000.0
    }

    static func image(
        document: WiggleDocument,
        phase: Double,
        outputSize: CGSize? = nil,
        transparent: Bool = false,
        showTransparencyGrid: Bool = false,
        randomizeStrokePhase: Bool = false,
        previewStroke: AnimatedStroke? = nil
    ) -> CGImage? {
        let target = outputSize ?? CGSize(width: document.width, height: document.height)
        guard target.width > 0, target.height > 0 else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: Int(target.width),
            height: Int(target.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: target.height)
        context.scaleBy(
            x: target.width / CGFloat(document.width),
            y: -target.height / CGFloat(document.height)
        )

        if document.resolvedBackgroundVisible && !transparent {
            context.setFillColor(uiColor(document.background, opacity: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: document.width, height: document.height))
        } else if !document.resolvedBackgroundVisible && showTransparencyGrid {
            drawTransparencyGrid(document: document, in: context)
        }

        for layer in document.layers where document.isLayerEffectivelyVisible(layer) {
            context.saveGState()
            let canvasCenter = CGPoint(x: CGFloat(document.width) / 2, y: CGFloat(document.height) / 2)
            let contentOffset = layer.resolvedContentOffset
            let contentScale = CGFloat(layer.resolvedContentScale)
            context.translateBy(
                x: canvasCenter.x + contentOffset.x,
                y: canvasCenter.y + contentOffset.y
            )
            context.scaleBy(x: contentScale, y: contentScale)
            context.translateBy(x: -canvasCenter.x, y: -canvasCenter.y)
            context.setAlpha(layer.opacity)
            if let image = cachedImportedImage(for: layer) {
                context.setAlpha(1)
                drawImportedImage(image, layer: layer, document: document, opacity: layer.opacity, in: context)
                context.setAlpha(layer.opacity)
            }
            for fill in layer.fills ?? [] {
                drawFill(fill, document: document, phase: phase, in: context)
            }
            for stroke in layer.strokes {
                let effectivePhase = randomizeStrokePhase
                    ? (phase + Self.strokePhaseOffset(stroke.id)).truncatingRemainder(dividingBy: 1)
                    : phase
                BrushKernelRegistry.kernels[stroke.brush.kind]?.draw(
                    stroke: stroke,
                    phase: effectivePhase,
                    in: context
                )
            }
            context.restoreGState()
        }

        if let previewStroke, previewStroke.samples.count > 1 {
            let effectivePhase = randomizeStrokePhase
                ? (phase + Self.strokePhaseOffset(previewStroke.id)).truncatingRemainder(dividingBy: 1)
                : phase
            BrushKernelRegistry.kernels[previewStroke.brush.kind]?.draw(
                stroke: previewStroke,
                phase: effectivePhase,
                in: context
            )
        }
        return context.makeImage()
    }

    private static func drawTransparencyGrid(document: WiggleDocument, in context: CGContext) {
        let width = CGFloat(document.width)
        let height = CGFloat(document.height)
        let tile = max(24, max(width, height) / 32)
        let columns = Int(ceil(width / tile))
        let rows = Int(ceil(height / tile))
        let light = UIColor(white: 0.94, alpha: 1).cgColor
        let dark = UIColor(white: 0.82, alpha: 1).cgColor

        for row in 0..<rows {
            for column in 0..<columns {
                context.setFillColor((row + column).isMultiple(of: 2) ? light : dark)
                context.fill(CGRect(
                    x: CGFloat(column) * tile,
                    y: CGFloat(row) * tile,
                    width: tile,
                    height: tile
                ))
            }
        }
    }

    private static func drawFill(
        _ fill: CanvasFill,
        document: WiggleDocument,
        phase: Double,
        in context: CGContext
    ) {
        let rect = CGRect(x: 0, y: 0, width: document.width, height: document.height)
        if let contours = fill.animatedContours, !contours.isEmpty {
            let normalizedPhase = phase - Foundation.floor(phase)
            let framePosition = normalizedPhase * Double(contours.count)
            let firstIndex = Int(Foundation.floor(framePosition)) % contours.count
            let secondIndex = (firstIndex + 1) % contours.count
            let blend = framePosition - Foundation.floor(framePosition)
            let contour = interpolatedContour(
                from: contours[firstIndex],
                to: contours[secondIndex],
                progress: blend
            )
            drawContour(contour, color: fill.color, opacity: 1, in: context)
            return
        }

        if let frames = fill.animatedMaskFrames, !frames.isEmpty {
            let normalizedPhase = phase - Foundation.floor(phase)
            let framePosition = normalizedPhase * Double(frames.count)
            let firstIndex = Int(Foundation.floor(framePosition)) % frames.count
            let secondIndex = (firstIndex + 1) % frames.count
            let blend = framePosition - Foundation.floor(framePosition)
            let firstImage = cachedFillImage(fillID: fill.id, index: firstIndex, data: frames[firstIndex])
            let secondImage = cachedFillImage(fillID: fill.id, index: secondIndex, data: frames[secondIndex])

            context.interpolationQuality = .medium
            if let mask = firstImage?.cgImage {
                drawFillMask(mask, color: fill.color, opacity: 1 - blend, in: rect, context: context)
            }
            if let mask = secondImage?.cgImage {
                drawFillMask(mask, color: fill.color, opacity: blend, in: rect, context: context)
            }
            return
        }

        if fill.samples.count > 2 {
            drawContour(fill.samples, color: fill.color, opacity: 1, in: context)
            return
        }

        if let maskData = fill.maskData,
           let image = cachedFillImage(fillID: fill.id, index: -1, data: maskData),
           let mask = image.cgImage {
            context.interpolationQuality = .medium
            drawFillMask(mask, color: fill.color, opacity: 1, in: rect, context: context)
        }
    }

    private static func interpolatedContour(
        from first: [StrokeSample],
        to second: [StrokeSample],
        progress: Double
    ) -> [StrokeSample] {
        guard first.count == second.count, !first.isEmpty else {
            return progress < 0.5 ? first : second
        }
        return zip(first, second).map { start, end in
            StrokeSample(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress,
                pressure: 0.5,
                tilt: 0,
                azimuth: 0,
                timestamp: 0
            )
        }
    }

    private static func drawContour(
        _ samples: [StrokeSample],
        color: CodableColor,
        opacity: Double,
        in context: CGContext
    ) {
        guard samples.count > 2, opacity > 0 else { return }
        let points = samples.map(\.point)
        let firstMidpoint = CGPoint(
            x: (points.last!.x + points[0].x) / 2,
            y: (points.last!.y + points[0].y) / 2
        )
        let path = CGMutablePath()
        path.move(to: firstMidpoint)
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            let midpoint = CGPoint(x: (points[index].x + next.x) / 2, y: (points[index].y + next.y) / 2)
            path.addQuadCurve(to: midpoint, control: points[index])
        }
        path.closeSubpath()
        context.setFillColor(uiColor(color, opacity: opacity).cgColor)
        context.addPath(path)
        context.fillPath()
    }

    private static func drawFillMask(
        _ mask: CGImage,
        color: CodableColor,
        opacity: Double,
        in rect: CGRect,
        context: CGContext
    ) {
        guard opacity > 0 else { return }
        context.saveGState()
        context.clip(to: rect, mask: mask)
        context.setFillColor(uiColor(color, opacity: opacity).cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    private static func cachedFillImage(fillID: UUID, index: Int, data: Data) -> UIImage? {
        let key = "\(fillID.uuidString)-\(index)" as NSString
        if let cached = fillFrameCache.object(forKey: key) { return cached }
        guard failedFillImageCache.object(forKey: key) == nil else { return nil }
        guard let image = decodedFillImage(from: data) else {
            failedFillImageCache.setObject(1, forKey: key)
            return nil
        }
        fillFrameCache.setObject(
            image,
            forKey: key,
            cost: Int(image.size.width * image.size.height * 4)
        )
        return image
    }

    private static func cachedImportedImage(for layer: DrawingLayer) -> UIImage? {
        guard let data = layer.imageData else { return nil }
        let key = layer.id.uuidString as NSString
        if let cached = importedImageCache.object(forKey: key) { return cached }
        guard failedImportedImageCache.object(forKey: key) == nil else { return nil }
        guard let image = decodedFillImage(from: data) else {
            failedImportedImageCache.setObject(1, forKey: key)
            return nil
        }
        importedImageCache.setObject(
            image,
            forKey: key,
            cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        )
        return image
    }

    private static func drawImportedImage(
        _ image: UIImage,
        layer: DrawingLayer,
        document: WiggleDocument,
        opacity: Double,
        in context: CGContext
    ) {
        let canvas = CGSize(width: document.width, height: document.height)
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let fittedScale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
        let scale = fittedScale * layer.resolvedImageScale
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let offset = layer.resolvedImageOffset
        let rect = CGRect(
            x: (canvas.width - size.width) / 2 + offset.x,
            y: (canvas.height - size.height) / 2 + offset.y,
            width: size.width,
            height: size.height
        )
        context.saveGState()
        context.interpolationQuality = .high
        UIGraphicsPushContext(context)
        image.draw(in: rect, blendMode: .normal, alpha: opacity)
        UIGraphicsPopContext()
        context.restoreGState()
    }
}
