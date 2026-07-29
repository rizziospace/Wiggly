import CoreGraphics
import Foundation
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
        .scatter: ScatterKernel(),
        .ghostTrail: GhostTrailKernel(),
        .dashed: DashedKernel(),
        .particle: ParticleKernel(),
        .goo: GooKernel(),
        .scribbles: ScribblesKernel(),
        .particleCloud: ParticleCloudKernel(),
        .glitter: GlitterKernel(),
        .gradient: GradientKernel(),
        .polkaDots: PolkaDotsKernel(),
        .faded: FadedKernel(),
        .charcoal: CharcoalKernel(),
        .colorNoise: ColorNoiseKernel()
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
    let taperZone = 0.15
    let taper: Double
    if progress < taperZone {
        let localProgress = progress / taperZone
        taper = brush.resolvedStartWidthScale
            + (1 - brush.resolvedStartWidthScale) * localProgress
    } else if progress > 1 - taperZone {
        let localProgress = (progress - (1 - taperZone)) / taperZone
        taper = 1 + (brush.resolvedEndWidthScale - 1) * localProgress
    } else {
        taper = 1
    }
    return max(0.35, brush.size * pressure * tilt * taper * multiplier)
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
    case .scatter: referenceSize = 12
    case .ghostTrail: referenceSize = 34
    case .dashed: referenceSize = 34
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
    }
    return max(0.05, brush.size / referenceSize)
}

nonisolated private func drawSegmentedStroke(
    points: [CGPoint],
    samples: [StrokeSample],
    brush: BrushSettings,
    in context: CGContext,
    widthMultiplier: Double = 1,
    opacityDivisor: Double = 1
) {
    let count = min(points.count, samples.count)
    guard count > 1 else { return }
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for index in 1..<count {
        let path = CGMutablePath()
        path.move(to: points[index - 1])
        path.addLine(to: points[index])
        let firstWidth = width(for: samples[index - 1], index: index - 1, count: count, brush: brush, multiplier: widthMultiplier)
        let secondWidth = width(for: samples[index], index: index, count: count, brush: brush, multiplier: widthMultiplier)
        context.setLineWidth((firstWidth + secondWidth) / 2)
        context.setStrokeColor(
            uiColor(brush.color, opacity: dynamicOpacity(for: samples[index], brush: brush) / opacityDivisor).cgColor
        )
        context.addPath(path)
        context.strokePath()
    }
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
        let samples = stroke.samples
        guard samples.count > 1 else { return }

        let brush = stroke.brush
        let phaseAngle = phase * Double.pi * 2 * Double(brush.loopCycles)
        var leftEdge = [CGPoint]()
        var rightEdge = [CGPoint]()
        var centers = [CGPoint]()
        var radii = [CGFloat]()
        leftEdge.reserveCapacity(samples.count)
        rightEdge.reserveCapacity(samples.count)

        for (index, sample) in samples.enumerated() {
            let previous = samples[max(0, index - 1)].point
            let next = samples[min(samples.count - 1, index + 1)].point
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let progress = Double(index) / Double(max(1, samples.count - 1))
            let random = seeded(brush.seed, index)
            let spatial = progress * brush.frequency * Double.pi * 2
            let wave = Foundation.sin(spatial + phaseAngle + random * 0.65)
            let secondary = Foundation.sin(spatial * 2.3 - phaseAngle + random * 2)
            let taperZone = 0.15
            let taperScale: Double
            if progress < taperZone {
                taperScale = brush.resolvedStartWidthScale
                    + (1 - brush.resolvedStartWidthScale) * (progress / taperZone)
            } else if progress > 1 - taperZone {
                taperScale = 1 + (brush.resolvedEndWidthScale - 1)
                    * ((progress - (1 - taperZone)) / taperZone)
            } else {
                taperScale = 1
            }
            let centerOffset = wave * brush.motionAmount * structureScale(for: brush) * 0.22 * taperScale
            let baseRadius = width(
                for: sample,
                index: index,
                count: samples.count,
                brush: brush
            ) / 2
            let radius = max(
                0.2,
                baseRadius * (0.78 + wave * 0.18 + secondary * 0.1 + random * 0.08)
            )
            let center = CGPoint(
                x: sample.x + normal.x * centerOffset,
                y: sample.y + normal.y * centerOffset
            )
            centers.append(center)
            radii.append(radius)
            leftEdge.append(CGPoint(x: center.x + normal.x * radius, y: center.y + normal.y * radius))
            rightEdge.append(CGPoint(x: center.x - normal.x * radius, y: center.y - normal.y * radius))
        }

        let path = CGMutablePath()
        path.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() { path.addLine(to: point) }
        for point in rightEdge.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        context.setFillColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(path)
        context.fillPath()

        for index in [0, centers.count - 1] {
            let radius = radii[index]
            context.fillEllipse(in: CGRect(
                x: centers[index].x - radius,
                y: centers[index].y - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }
    }
}

nonisolated struct ScribblesKernel: AnimatedBrushKernel {
    let kind = BrushKind.scribbles

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        guard stroke.samples.count > 1 else { return }
        let brush = stroke.brush
        let phaseAngle = phase * Double.pi * 2 * Double(brush.loopCycles)

        let lineCount = brush.resolvedScribbleLineCount
        for lineIndex in 0..<lineCount {
            let strand = -1 + Double(lineIndex) * 2 / Double(max(1, lineCount - 1))
            let usesRandomMotion = brush.resolvedScribbleMotionMode == .random
            let randomPhase = seeded(brush.seed &+ 117, lineIndex) * Double.pi * 2
            let frequencyScale = 0.72 + seeded(brush.seed &+ 431, lineIndex) * 0.56
            let timeDirection = seeded(brush.seed &+ 863, lineIndex) > 0.5 ? 1.0 : -1.0
            let points = stroke.samples.enumerated().map { index, sample in
                let previous = stroke.samples[max(0, index - 1)].point
                let next = stroke.samples[min(stroke.samples.count - 1, index + 1)].point
                let dx = next.x - previous.x
                let dy = next.y - previous.y
                let length = max(0.001, Foundation.hypot(dx, dy))
                let progress = Double(index) / Double(max(1, stroke.samples.count - 1))
                let spatialFrequency = brush.frequency * (usesRandomMotion ? frequencyScale : 1)
                let timePhase = phaseAngle * (usesRandomMotion ? timeDirection : 1)
                let wave = Foundation.sin(
                    progress * spatialFrequency * Double.pi * 2
                        + timePhase
                        + (usesRandomMotion ? randomPhase : 0)
                )
                let amplitude = usesRandomMotion
                    ? brush.motionAmount * (0.35 + abs(strand) * 0.65)
                    : strand * brush.motionAmount
                let taper = taperScale(at: progress, brush: brush)
                let offset = amplitude * wave * structureScale(for: brush) * taper
                return CGPoint(
                    x: sample.x - dy / length * offset,
                    y: sample.y + dx / length * offset
                )
            }
            drawTaperedStrand(
                points: points,
                samples: stroke.samples,
                brush: brush,
                in: context
            )
        }
    }

    private func taperScale(at progress: Double, brush: BrushSettings) -> Double {
        let taperZone = 0.15
        if progress < taperZone {
            let local = progress / taperZone
            return brush.resolvedStartWidthScale
                + (1 - brush.resolvedStartWidthScale) * local
        }
        if progress > 1 - taperZone {
            let local = (progress - (1 - taperZone)) / taperZone
            return 1 + (brush.resolvedEndWidthScale - 1) * local
        }
        return 1
    }

    private func drawTaperedStrand(
        points: [CGPoint],
        samples: [StrokeSample],
        brush: BrushSettings,
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
                multiplier: 0.82
            ) / 2
            radii.append(radius)
            leftEdge.append(CGPoint(
                x: points[index].x + normal.x * radius,
                y: points[index].y + normal.y * radius
            ))
            rightEdge.append(CGPoint(
                x: points[index].x - normal.x * radius,
                y: points[index].y - normal.y * radius
            ))
        }

        let ribbon = CGMutablePath()
        ribbon.move(to: leftEdge[0])
        for point in leftEdge.dropFirst() { ribbon.addLine(to: point) }
        for point in rightEdge.reversed() { ribbon.addLine(to: point) }
        ribbon.closeSubpath()
        context.setFillColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(ribbon)
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

nonisolated struct ParticleCloudKernel: AnimatedBrushKernel {
    let kind = BrushKind.particleCloud

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard !samples.isEmpty else { return }
        let brush = stroke.brush
        let sampleStride = max(1, Int(brush.spacing / 3))
        let phaseAngle = phase * Double.pi * 2 * Double(brush.loopCycles)
        let scale = structureScale(for: brush)

        for sampleIndex in Swift.stride(from: 0, to: samples.count, by: sampleStride) {
            let sample = samples[sampleIndex]
            let previous = samples[max(0, sampleIndex - 1)].point
            let next = samples[min(samples.count - 1, sampleIndex + 1)].point
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let tangent = CGPoint(x: dx / length, y: dy / length)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)

            for particleIndex in 0..<4 {
                let key = sampleIndex * 11 + particleIndex * 977
                let randomA = seeded(brush.seed, key)
                let randomB = seeded(brush.seed &+ 313, key)
                let randomSize = seeded(brush.seed &+ 719, key)
                let orbit = phaseAngle + randomA * Double.pi * 2
                let tangentOffset = (randomA - 0.5) * brush.spacing * scale * 1.8
                    + Foundation.cos(orbit) * brush.motionAmount * scale * 0.18
                let normalOffset = (randomB - 0.5) * brush.motionAmount * scale * 1.5
                    + Foundation.sin(orbit) * brush.motionAmount * scale * 0.28
                let center = CGPoint(
                    x: sample.x + tangent.x * tangentOffset + normal.x * normalOffset,
                    y: sample.y + tangent.y * tangentOffset + normal.y * normalOffset
                )
                let diameter = width(
                    for: sample,
                    index: sampleIndex,
                    count: samples.count,
                    brush: brush,
                    multiplier: 0.22 + randomSize * 0.72
                )
                context.setFillColor(uiColor(
                    brush.color,
                    opacity: dynamicOpacity(for: sample, brush: brush) * (0.42 + randomA * 0.58)
                ).cgColor)
                context.fillEllipse(in: CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
            }
        }
    }
}

nonisolated struct ParticleKernel: AnimatedBrushKernel {
    let kind = BrushKind.particle

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let points = stroke.samples.map(\.point)
        guard points.count > 1 else { return }

        var lengths = [Double]()
        lengths.reserveCapacity(points.count - 1)
        var totalLength = 0.0
        for index in 1..<points.count {
            let length = Foundation.hypot(
                points[index].x - points[index - 1].x,
                points[index].y - points[index - 1].y
            )
            lengths.append(length)
            totalLength += length
        }
        guard totalLength > 0.001 else { return }

        let brush = stroke.brush
        let rawProgress = phase * Double(max(1, brush.loopCycles))
        let progress = rawProgress - Foundation.floor(rawProgress)
        let targetDistance = progress * totalLength
        let edgeOpacity = min(1, progress / 0.06, (1 - progress) / 0.06)
        guard let center = point(
            at: targetDistance,
            along: points,
            lengths: lengths
        ) else { return }

        let diameter = max(2, brush.size)
        context.setFillColor(
            uiColor(brush.color, opacity: brush.opacity * max(0, edgeOpacity)).cgColor
        )
        context.fillEllipse(
            in: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        )
    }

    private func point(
        at distance: Double,
        along points: [CGPoint],
        lengths: [Double]
    ) -> CGPoint? {
        var travelled = 0.0
        for index in 1..<points.count {
            let segmentLength = lengths[index - 1]
            if travelled + segmentLength >= distance || index == points.count - 1 {
                guard segmentLength > 0.001 else {
                    travelled += segmentLength
                    continue
                }
                let local = min(1, max(0, (distance - travelled) / segmentLength))
                let start = points[index - 1]
                let end = points[index]
                return CGPoint(
                    x: start.x + (end.x - start.x) * local,
                    y: start.y + (end.y - start.y) * local
                )
            }
            travelled += segmentLength
        }
        return nil
    }
}

nonisolated struct DashedKernel: AnimatedBrushKernel {
    let kind = BrushKind.dashed

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let points = stroke.samples.map(\.point)
        guard points.count > 1 else { return }

        let brush = stroke.brush
        let strokePath = smoothPath(through: points)
        let size = max(1, brush.size)
        let dashLength = max(size * 1.8, brush.spacing * 3.2)
        let gapLength = max(size * 1.25, brush.spacing * 2.5)
        let patternLength = dashLength + gapLength
        let rawProgress = phase * Double(max(1, brush.loopCycles))
        let progress = rawProgress - Foundation.floor(rawProgress)

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(size)
        context.setStrokeColor(uiColor(brush.color, opacity: brush.opacity).cgColor)
        context.addPath(strokePath)
        context.strokePath()

        context.setLineWidth(size * 0.92)
        context.setStrokeColor(contrastColor(for: brush.color, opacity: brush.opacity).cgColor)
        context.setLineDash(phase: progress * patternLength, lengths: [dashLength, gapLength])
        context.addPath(strokePath)
        context.strokePath()
        context.restoreGState()
    }

    private func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        guard points.count > 2 else {
            path.addLine(to: points[1])
            return path
        }

        for index in 1..<(points.count - 1) {
            let midpoint = CGPoint(
                x: (points[index].x + points[index + 1].x) / 2,
                y: (points[index].y + points[index + 1].y) / 2
            )
            path.addQuadCurve(to: midpoint, control: points[index])
        }
        path.addQuadCurve(to: points.last!, control: points[points.count - 2])
        return path
    }

    private func contrastColor(for color: CodableColor, opacity: Double) -> UIColor {
        let luminance = color.red * 0.2126 + color.green * 0.7152 + color.blue * 0.0722
        if luminance > 0.48 {
            return UIColor(white: 0.02, alpha: color.alpha * opacity)
        }
        return UIColor(white: 0.98, alpha: color.alpha * opacity)
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
        let size = max(6, brush.size)
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

    func draw(stroke: AnimatedStroke, phase: Double, in context: CGContext) {
        let samples = stroke.samples
        guard samples.count > 1 else { return }
        let brush = stroke.brush
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))
        let roughness = brush.resolvedTextureRoughness
        let density = brush.resolvedTextureDensity
        let erosionStrength = Foundation.pow(abs(Foundation.sin(phaseAngle)), 0.72)
            * roughness * (0.45 + density * 0.85)

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawSegmentedStroke(
            points: samples.map(\.point),
            samples: samples,
            brush: brush,
            in: context
        )

        if erosionStrength > 0.002 {
            context.setBlendMode(.destinationOut)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            for pass in 0..<3 {
                let direction = pass.isMultiple(of: 2) ? 1.0 : -1.0
                let seedPhase = seeded(brush.seed &+ UInt64(pass * 977), pass) * Double.pi * 2
                for index in 1..<samples.count {
                    let sample = samples[index]
                    let progress = Double(index) / Double(max(1, samples.count - 1))
                    let previous = samples[max(0, index - 1)].point
                    let next = samples[min(samples.count - 1, index + 1)].point
                    let dx = next.x - previous.x
                    let dy = next.y - previous.y
                    let length = max(0.001, Foundation.hypot(dx, dy))
                    let normal = CGPoint(x: -dy / length, y: dx / length)
                    let broadNoise = 0.5 + 0.5 * Foundation.sin(
                        progress * brush.frequency * Double.pi * 2 * (1 + Double(pass) * 0.38)
                            + phaseAngle * direction + seedPhase
                    )
                    let grainNoise = 0.5 + 0.5 * Foundation.sin(
                        Double(index) * (0.19 + Double(pass) * 0.11)
                            - phaseAngle * 2 + seedPhase * 1.7
                    )
                    let cut = erosionStrength * (broadNoise * 0.62 + grainNoise * 0.38)
                    let cutThreshold = pass == 0 ? 0.34 : 0.48
                    guard cut > cutThreshold else { continue }

                    let firstWidth = width(
                        for: samples[index - 1],
                        index: index - 1,
                        count: samples.count,
                        brush: brush
                    )
                    let secondWidth = width(
                        for: sample,
                        index: index,
                        count: samples.count,
                        brush: brush
                    )
                    let averageWidth = (firstWidth + secondWidth) / 2
                    let offsetWave = Foundation.sin(
                        progress * Double.pi * 2 * (1.35 + Double(pass) * 0.72)
                            + phaseAngle * direction + seedPhase
                    )
                    let offsetRange = pass == 0 ? 0.16 : 0.38
                    let animatedDrift = Foundation.sin(phaseAngle + seedPhase) * brush.motionAmount * 0.08
                    let offset = offsetWave * Double(averageWidth) * offsetRange + animatedDrift
                    let path = CGMutablePath()
                    path.move(to: CGPoint(
                        x: samples[index - 1].x + normal.x * offset,
                        y: samples[index - 1].y + normal.y * offset
                    ))
                    path.addLine(to: CGPoint(
                        x: sample.x + normal.x * offset,
                        y: sample.y + normal.y * offset
                    ))
                    let widthScale = pass == 0 ? 1.12 : (pass == 1 ? 0.3 : 0.22)
                    let normalizedCut = min(1, max(0, (cut - cutThreshold) / max(0.01, 1 - cutThreshold)))
                    context.setLineWidth(max(0.6, averageWidth * normalizedCut * widthScale))
                    context.setStrokeColor(UIColor(white: 0, alpha: min(1, normalizedCut * 1.8)).cgColor)
                    context.addPath(path)
                    context.strokePath()
                }
            }
            context.setBlendMode(.normal)
        }

        context.endTransparencyLayer()
        context.restoreGState()
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
        let palette = [brush.color, brush.resolvedSecondaryColor, brush.resolvedTertiaryColor]
        let phaseOffset = phase * Double(max(1, brush.loopCycles))

        context.setLineCap(.round)
        context.setLineJoin(.round)
        for index in 1..<samples.count {
            let progress = Double(index) / Double(max(1, samples.count - 1))
            let colorPosition = progress * max(0.25, brush.frequency) - phaseOffset
            let color = paletteColor(at: colorPosition, palette: palette)
            let firstWidth = width(for: samples[index - 1], index: index - 1, count: samples.count, brush: brush)
            let secondWidth = width(for: samples[index], index: index, count: samples.count, brush: brush)
            let path = CGMutablePath()
            path.move(to: samples[index - 1].point)
            path.addLine(to: samples[index].point)
            context.setLineWidth((firstWidth + secondWidth) / 2)
            context.setStrokeColor(uiColor(color, opacity: dynamicOpacity(for: samples[index], brush: brush)).cgColor)
            context.addPath(path)
            context.strokePath()
        }
    }

    private func paletteColor(at position: Double, palette: [CodableColor]) -> CodableColor {
        let wrapped = position - Foundation.floor(position)
        let scaled = wrapped * Double(palette.count)
        let firstIndex = Int(Foundation.floor(scaled)) % palette.count
        let secondIndex = (firstIndex + 1) % palette.count
        let blend = scaled - Foundation.floor(scaled)
        let first = palette[firstIndex]
        let second = palette[secondIndex]
        return CodableColor(
            red: first.red + (second.red - first.red) * blend,
            green: first.green + (second.green - first.green) * blend,
            blue: first.blue + (second.blue - first.blue) * blend,
            alpha: first.alpha + (second.alpha - first.alpha) * blend
        )
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
        drawSegmentedStroke(points: samples.map(\.point), samples: samples, brush: brush, in: context)

        let density = brush.resolvedGlitterDensity
        let grainsPerSample = max(1, Int(1 + density * 5))
        let sampleStride = max(1, Int(brush.spacing / 2))
        let sparkleAmount = brush.resolvedSparkleAmount
        let phaseAngle = phase * Double.pi * 2 * Double(max(1, brush.loopCycles))

        for index in Swift.stride(from: 0, to: samples.count, by: sampleStride) {
            let sample = samples[index]
            let previous = samples[max(0, index - 1)].point
            let next = samples[min(samples.count - 1, index + 1)].point
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(0.001, Foundation.hypot(dx, dy))
            let tangent = CGPoint(x: dx / length, y: dy / length)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let envelope = width(for: sample, index: index, count: samples.count, brush: brush)

            for grain in 0..<grainsPerSample {
                let key = index * 37 + grain * 977
                let across = (seeded(brush.seed, key) - 0.5) * Double(envelope) * 0.82
                let along = (seeded(brush.seed &+ 211, key) - 0.5) * brush.spacing
                let center = CGPoint(
                    x: sample.x + normal.x * across + tangent.x * along,
                    y: sample.y + normal.y * across + tangent.y * along
                )
                let grainSize = max(0.65, Double(envelope) * (0.018 + seeded(brush.seed &+ 419, key) * 0.045))
                let brightness = 0.62 + seeded(brush.seed &+ 617, key) * 0.38
                let grainColor = mixed(brush.color, brush.resolvedSecondaryColor, amount: brightness * 0.48)
                context.setFillColor(uiColor(grainColor, opacity: brush.opacity * (0.28 + brightness * 0.42)).cgColor)
                context.fillEllipse(in: CGRect(
                    x: center.x - grainSize / 2,
                    y: center.y - grainSize / 2,
                    width: grainSize,
                    height: grainSize
                ))
            }

            let sparkleKey = index * 53
            let sparkleGate = seeded(brush.seed &+ 991, sparkleKey)
            guard sparkleGate < sparkleAmount * 0.42 else { continue }
            let across = (seeded(brush.seed &+ 1201, sparkleKey) - 0.5) * Double(envelope) * 0.62
            let center = CGPoint(x: sample.x + normal.x * across, y: sample.y + normal.y * across)
            let individualPhase = seeded(brush.seed &+ 1429, sparkleKey) * Double.pi * 2
            let twinkle = Foundation.pow(max(0, Foundation.sin(phaseAngle + individualPhase)), 4)
            guard twinkle > 0.015 else { continue }
            drawSparkle(
                at: center,
                radius: max(1.5, envelope * CGFloat(0.10 + 0.12 * twinkle)),
                color: brush.resolvedSecondaryColor,
                opacity: brush.opacity * twinkle,
                in: context
            )
        }
    }

    private func mixed(_ first: CodableColor, _ second: CodableColor, amount: Double) -> CodableColor {
        let blend = min(1, max(0, amount))
        return CodableColor(
            red: first.red + (second.red - first.red) * blend,
            green: first.green + (second.green - first.green) * blend,
            blue: first.blue + (second.blue - first.blue) * blend,
            alpha: first.alpha + (second.alpha - first.alpha) * blend
        )
    }

    private func drawSparkle(
        at center: CGPoint,
        radius: CGFloat,
        color: CodableColor,
        opacity: Double,
        in context: CGContext
    ) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addLine(to: CGPoint(x: center.x + radius * 0.22, y: center.y - radius * 0.22))
        path.addLine(to: CGPoint(x: center.x + radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + radius * 0.22, y: center.y + radius * 0.22))
        path.addLine(to: CGPoint(x: center.x, y: center.y + radius))
        path.addLine(to: CGPoint(x: center.x - radius * 0.22, y: center.y + radius * 0.22))
        path.addLine(to: CGPoint(x: center.x - radius, y: center.y))
        path.addLine(to: CGPoint(x: center.x - radius * 0.22, y: center.y - radius * 0.22))
        path.closeSubpath()
        context.setFillColor(uiColor(color, opacity: opacity).cgColor)
        context.addPath(path)
        context.fillPath()
    }
}

nonisolated enum AnimatedDrawingRenderer {
    private static let fillFrameCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private static let importedImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func preloadFillFrames(fillID: UUID, frames: [Data]) {
        for (index, data) in frames.enumerated() {
            autoreleasepool {
                guard let source = UIImage(data: data) else { return }
                let image = source.preparingForDisplay() ?? source
                let key = "\(fillID.uuidString)-\(index)" as NSString
                fillFrameCache.setObject(
                    image,
                    forKey: key,
                    cost: Int(image.size.width * image.size.height * 4)
                )
            }
        }
    }

    static func image(
        document: WiggleDocument,
        phase: Double,
        outputSize: CGSize? = nil,
        transparent: Bool = false,
        showTransparencyGrid: Bool = false,
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

        for layer in document.layers where layer.isVisible {
            context.saveGState()
            context.setAlpha(layer.opacity)
            if let image = cachedImportedImage(for: layer) {
                context.setAlpha(1)
                drawImportedImage(image, layer: layer, document: document, opacity: layer.opacity, in: context)
                context.setAlpha(layer.opacity)
            }
            for stroke in layer.strokes {
                BrushKernelRegistry.kernels[stroke.brush.kind]?.draw(
                    stroke: stroke,
                    phase: phase,
                    in: context
                )
            }
            context.restoreGState()
        }

        if let previewStroke, previewStroke.samples.count > 1 {
            BrushKernelRegistry.kernels[previewStroke.brush.kind]?.draw(
                stroke: previewStroke,
                phase: phase,
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
        guard let source = UIImage(data: data) else { return nil }
        let image = source.preparingForDisplay() ?? source
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
        guard let source = UIImage(data: data) else { return nil }
        let image = source.preparingForDisplay() ?? source
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
