import CoreGraphics
import Foundation

enum QuickShapeKind: Int, CaseIterable, Sendable {
    case line
    case curve
    case ellipse
    case triangle
    case rectangle
    case pentagon
    case hexagon

    var vertexCount: Int? {
        switch self {
        case .line, .curve, .ellipse: return nil
        case .triangle: return 3
        case .rectangle: return 4
        case .pentagon: return 5
        case .hexagon: return 6
        }
    }
}

/// Result of classifying a held stroke. Carries the fitted sample path used for
/// the live "snapped" preview plus the geometry needed to regenerate a perfect
/// (regular) version when the user confirms with a second finger.
struct ShapeFit {
    let kind: QuickShapeKind
    let samples: [StrokeSample]
    let isClosed: Bool
    let center: CGPoint
    let radii: CGSize
    let angle: CGFloat
    let circular: Bool
    let cornerAngles: [CGFloat]
    let radius: CGFloat
}

enum QuickShapeFitter {
    /// A turn sharper than this (in degrees) counts as a polygon corner.
    static let cornerThresholdDegrees: Double = 150

    // MARK: - Public

    static func fit(_ samples: [StrokeSample]) -> ShapeFit? {
        guard samples.count >= 3 else { return nil }
        let points = samples.map(\.point)
        guard let bounds = boundingBox(of: points) else { return nil }
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal >= 20 else { return nil }
        let centroid = average(of: points)
        let first = points[0]
        let last = points[points.count - 1]
        let gap = hypot(first.x - last.x, first.y - last.y)
        if gap < diagonal * 0.22 {
            return closedShapeFit(points: points, centroid: centroid, bounds: bounds, samples: samples)
        }
        // Open stroke: straight enough stays a line; otherwise treat it as a
        // curve and snap it into a smooth arc/bezier path.
        if lineDeviation(of: points, diagonal: diagonal) < 0.08 {
            return lineFit(points: points, centroid: centroid, samples: samples)
        }
        return curveFit(points: points, centroid: centroid, samples: samples)
    }

    static func perfectSamples(for fit: ShapeFit) -> [StrokeSample] {
        switch fit.kind {
        case .line:
            return fit.samples
        case .curve:
            return fit.samples
        case .ellipse:
            if fit.circular {
                let radius = (fit.radii.width + fit.radii.height) / 2
                let points = ellipsePoints(center: fit.center, radii: CGSize(width: radius, height: radius), angle: 0, count: 96)
                return generateSamples(points, closed: true, prototype: fit.samples.last ?? prototypeSample(fit))
            }
            return fit.samples
        case .triangle, .rectangle, .pentagon, .hexagon:
            guard let sides = fit.kind.vertexCount else { return fit.samples }
            let radius = max(8, fit.radius)
            let baseAngle = fit.cornerAngles.first ?? fit.angle
            var points: [CGPoint] = []
            for side in 0..<sides {
                let theta = baseAngle + CGFloat(side) * 2 * .pi / CGFloat(sides)
                let v = CGPoint(x: fit.center.x + radius * cos(theta), y: fit.center.y + radius * sin(theta))
                points.append(v)
            }
            return generateSamples(points, closed: true, prototype: fit.samples.last ?? prototypeSample(fit))
        }
    }

    // MARK: - Closed shapes

    /// Builds a densely-sampled straight line between two endpoints, reusing the
    /// stroke prototype (pressure/tilt) so its texture matches the freehand one.
    static func lineSamples(from: CGPoint, to: CGPoint, prototype: StrokeSample) -> [StrokeSample] {
        generateSamples([from, to], closed: false, prototype: prototype)
    }

    /// Maps an existing path of points to stroke samples without resampling,
    /// preserving density. Used to transform a locked shape as the pen moves.
    static func samples(fromPoints points: [CGPoint], prototype: StrokeSample) -> [StrokeSample] {
        points.enumerated().map { index, point in
            StrokeSample(
                x: Double(point.x),
                y: Double(point.y),
                pressure: prototype.pressure,
                tilt: prototype.tilt,
                azimuth: prototype.azimuth,
                timestamp: prototype.timestamp + Double(index) * 0.004
            )
        }
    }

    private static func closedShapeFit(
        points: [CGPoint],
        centroid: CGPoint,
        bounds: CGRect,
        samples: [StrokeSample]
    ) -> ShapeFit {
        let resampled = resample(points, count: 72)
        let corners = detectCorners(resampled)
        let kind: QuickShapeKind
        switch corners.count {
        case 0, 1, 2: kind = .ellipse
        case 3: kind = .triangle
        case 4: kind = .rectangle
        case 5: kind = .pentagon
        case 6: kind = .hexagon
        default: kind = .ellipse
        }

        let radii = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        let circular = radii.width > 0
            && min(radii.width, radii.height) / max(radii.width, radii.height) > 0.82

        let prototype = averagePrototype(samples)

        switch kind {
        case .ellipse:
            let angle = principalAngle(points)
            let fitted = ellipsePoints(center: centroid, radii: radii, angle: angle, count: 96)
            return ShapeFit(
                kind: .ellipse,
                samples: generateSamples(fitted, closed: true, prototype: prototype),
                isClosed: true,
                center: centroid,
                radii: radii,
                angle: angle,
                circular: circular,
                cornerAngles: [],
                radius: 0
            )
        default:
            let avgRadius = points.reduce(CGFloat(0)) { $0 + distance($1, centroid) } / CGFloat(points.count)
            let cornerAngles = corners.map { idx in
                atan2(resampled[idx].y - centroid.y, resampled[idx].x - centroid.x)
            }
            var vertices: [CGPoint] = []
            for angle in cornerAngles {
                vertices.append(CGPoint(
                    x: centroid.x + avgRadius * cos(angle),
                    y: centroid.y + avgRadius * sin(angle)
                ))
            }
            return ShapeFit(
                kind: kind,
                samples: generateSamples(vertices, closed: true, prototype: prototype),
                isClosed: true,
                center: centroid,
                radii: radii,
                angle: cornerAngles.first ?? principalAngle(points),
                circular: circular,
                cornerAngles: cornerAngles,
                radius: avgRadius
            )
        }
    }

    private static func lineFit(
        points: [CGPoint],
        centroid: CGPoint,
        samples: [StrokeSample]
    ) -> ShapeFit {
        let direction = principalDirection(points)
        var minT = CGFloat.greatestFiniteMagnitude
        var maxT = -CGFloat.greatestFiniteMagnitude
        for point in points {
            let t = (point.x - centroid.x) * direction.x + (point.y - centroid.y) * direction.y
            minT = min(minT, t)
            maxT = max(maxT, t)
        }
        let start = CGPoint(x: centroid.x + direction.x * minT, y: centroid.y + direction.y * minT)
        let end = CGPoint(x: centroid.x + direction.x * maxT, y: centroid.y + direction.y * maxT)
        let prototype = averagePrototype(samples)
        let fitted = generateSamples([start, end], closed: false, prototype: prototype)
        return ShapeFit(
            kind: .line,
            samples: fitted,
            isClosed: false,
            center: centroid,
            radii: .zero,
            angle: atan2(direction.y, direction.x),
            circular: false,
            cornerAngles: [],
            radius: 0
        )
    }

    /// Fits an open, non-straight stroke into a smooth curve: the raw path is
    /// arc-length resampled then corner-cutting (Chaikin) refined so the locked
    /// stroke reads as a clean arc while keeping its overall shape and endpoints.
    private static func curveFit(
        points: [CGPoint],
        centroid: CGPoint,
        samples: [StrokeSample]
    ) -> ShapeFit {
        let resampled = resample(points, count: 24)
        let smooth = chaikin(resampled, iterations: 2)
        let prototype = averagePrototype(samples)
        let fitted = QuickShapeFitter.samples(fromPoints: smooth, prototype: prototype)
        return ShapeFit(
            kind: .curve,
            samples: fitted,
            isClosed: false,
            center: centroid,
            radii: .zero,
            angle: principalAngle(points),
            circular: false,
            cornerAngles: [],
            radius: 0
        )
    }

    /// RMS perpendicular distance from the best-fit line, normalized by the
    /// stroke diagonal. Small values mean the stroke is essentially straight.
    private static func lineDeviation(of points: [CGPoint], diagonal: CGFloat) -> CGFloat {
        guard points.count > 2, diagonal > 0 else { return 0 }
        let centroid = average(of: points)
        let direction = principalDirection(points)
        let nx = -direction.y
        let ny = direction.x
        var sum: CGFloat = 0
        for point in points {
            let d = (point.x - centroid.x) * nx + (point.y - centroid.y) * ny
            sum += d * d
        }
        return sqrt(sum / CGFloat(points.count)) / diagonal
    }

    /// Corner-cutting subdivision: rounds the polyline, preserving endpoints.
    private static func chaikin(_ points: [CGPoint], iterations: Int) -> [CGPoint] {
        var current = points
        for _ in 0..<iterations {
            guard current.count > 2 else { break }
            var next: [CGPoint] = []
            next.reserveCapacity(current.count * 2)
            next.append(current[0])
            for i in 0..<(current.count - 1) {
                let a = current[i]
                let b = current[i + 1]
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
            next.append(current[current.count - 1])
            current = next
        }
        return current
    }

    // MARK: - Geometry helpers

    private static func boundingBox(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func average(of points: [CGPoint]) -> CGPoint {
        var x: CGFloat = 0, y: CGFloat = 0
        for point in points { x += point.x; y += point.y }
        return CGPoint(x: x / CGFloat(points.count), y: y / CGFloat(points.count))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func averagePrototype(_ samples: [StrokeSample]) -> StrokeSample {
        guard let first = samples.first else {
            return StrokeSample(x: 0, y: 0, pressure: 0.5, tilt: 0, azimuth: 0, timestamp: 0)
        }
        var pressure = 0.0, tilt = 0.0, azimuth = 0.0
        for sample in samples {
            pressure += sample.pressure
            tilt += sample.tilt
            azimuth += sample.azimuth
        }
        let count = Double(samples.count)
        return StrokeSample(
            x: first.x,
            y: first.y,
            pressure: pressure / count,
            tilt: tilt / count,
            azimuth: azimuth / count,
            timestamp: (samples.last?.timestamp ?? 0)
        )
    }

    private static func prototypeSample(_ fit: ShapeFit) -> StrokeSample {
        fit.samples.last ?? StrokeSample(x: 0, y: 0, pressure: 0.5, tilt: 0, azimuth: 0, timestamp: 0)
    }

    /// Resamples the path to `count` points evenly spaced by arc length.
    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 2, count > 2 else { return points }
        var lengths: [CGFloat] = []
        lengths.reserveCapacity(points.count)
        var cumulative: [CGFloat] = [0]
        for i in 1..<points.count {
            let segment = distance(points[i - 1], points[i])
            lengths.append(segment)
            cumulative.append(cumulative[i - 1] + segment)
        }
        let total = cumulative[points.count - 1]
        guard total > 0 else { return points }

        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var segmentIndex = 0
        for slot in 0..<count {
            let target = CGFloat(slot) * total / CGFloat(count)
            while segmentIndex < points.count - 2 && cumulative[segmentIndex + 1] < target {
                segmentIndex += 1
            }
            let segmentStart = cumulative[segmentIndex]
            let segmentLength = max(0.0001, lengths[segmentIndex])
            let t = min(1, max(0, (target - segmentStart) / segmentLength))
            let a = points[segmentIndex]
            let b = points[min(points.count - 1, segmentIndex + 1)]
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }

    /// Detects sharp corners on a closed, resampled loop. Returns indices into
    /// `points` (each a local maximum of turning sharpness, non-max suppressed).
    private static func detectCorners(_ points: [CGPoint]) -> [Int] {
        let n = points.count
        let k = max(2, n / 24)
        var sharpness = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = points[(i - k + n) % n]
            let b = points[i]
            let c = points[(i + k) % n]
            let v1x = b.x - a.x
            let v1y = b.y - a.y
            let v2x = c.x - b.x
            let v2y = c.y - b.y
            let len1 = hypot(v1x, v1y)
            let len2 = hypot(v2x, v2y)
            guard len1 > 0.0001, len2 > 0.0001 else { continue }
            let dot = (v1x * v2x + v1y * v2y) / (len1 * len2)
            let clamped = min(1, max(-1, dot))
            let angleDegrees = acos(Double(clamped)) * 180 / Double.pi
            if angleDegrees < cornerThresholdDegrees {
                sharpness[i] = 1 - cos(angleDegrees * Double.pi / 180)
            }
        }

        var corners: [Int] = []
        let window = max(2, n / 16)
        var i = 0
        while i < n {
            if sharpness[i] <= 0 {
                i += 1
                continue
            }
            var best = i
            var j = i + 1
            while j < n && (j - i) <= window {
                if sharpness[j] > sharpness[best] { best = j }
                j += 1
            }
            corners.append(best)
            i = j
        }
        return corners
    }

    /// Principal direction (largest eigenvector) of the point covariance.
    private static func principalDirection(_ points: [CGPoint]) -> CGPoint {
        let centroid = average(of: points)
        var m00: CGFloat = 0, m01: CGFloat = 0, m11: CGFloat = 0
        for point in points {
            let dx = point.x - centroid.x
            let dy = point.y - centroid.y
            m00 += dx * dx
            m01 += dx * dy
            m11 += dy * dy
        }
        let theta = 0.5 * atan2(2 * m01, m00 - m11)
        return CGPoint(x: cos(theta), y: sin(theta))
    }

    private static func principalAngle(_ points: [CGPoint]) -> CGFloat {
        atan2(principalDirection(points).y, principalDirection(points).x)
    }

    private static func ellipsePoints(center: CGPoint, radii: CGSize, angle: CGFloat, count: Int) -> [CGPoint] {
        (0..<count).map { index in
            let theta = CGFloat(index) * 2 * .pi / CGFloat(count)
            let x = radii.width * cos(theta)
            let y = radii.height * sin(theta)
            let rotatedX = x * cos(angle) - y * sin(angle)
            let rotatedY = x * sin(angle) + y * cos(angle)
            return CGPoint(x: center.x + rotatedX, y: center.y + rotatedY)
        }
    }

    /// Turns a sparse set of points into a densely-sampled stroke, closing the
    /// loop when `closed` is true.
    private static func generateSamples(
        _ points: [CGPoint],
        closed: Bool,
        prototype: StrokeSample
    ) -> [StrokeSample] {
        var poly = points
        if closed, let first = points.first, let last = points.last,
           hypot(first.x - last.x, first.y - last.y) > 0.5 {
            poly.append(first)
        }
        let perSegment = 10
        var path: [CGPoint] = []
        for i in 0..<(poly.count - 1) {
            let a = poly[i]
            let b = poly[i + 1]
            for step in 0..<perSegment {
                let t = CGFloat(step) / CGFloat(perSegment)
                path.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if !closed, let last = poly.last { path.append(last) }

        return path.enumerated().map { index, point in
            StrokeSample(
                x: Double(point.x),
                y: Double(point.y),
                pressure: prototype.pressure,
                tilt: prototype.tilt,
                azimuth: prototype.azimuth,
                timestamp: prototype.timestamp + Double(index) * 0.004
            )
        }
    }
}
