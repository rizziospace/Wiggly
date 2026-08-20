import Foundation
import SwiftUI

nonisolated struct CodableColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let black = CodableColor(red: 0.08, green: 0.07, blue: 0.1, alpha: 1)
    static let white = CodableColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let amber = CodableColor(red: 1, green: 0.44, blue: 0.15, alpha: 1)

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        red = Double(resolved.red)
        green = Double(resolved.green)
        blue = Double(resolved.blue)
        alpha = Double(resolved.opacity)
    }
}

nonisolated enum CanvasPreset: String, CaseIterable, Identifiable {
    case square
    case portrait
    case landscape
    case custom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var size: CGSize {
        switch self {
        case .square: CGSize(width: 2048, height: 2048)
        case .portrait: CGSize(width: 2048, height: 2732)
        case .landscape: CGSize(width: 2732, height: 2048)
        case .custom: CGSize(width: 2048, height: 2048)
        }
    }
}

nonisolated struct StrokeSample: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var pressure: Double
    var tilt: Double
    var azimuth: Double
    var timestamp: Double

    var point: CGPoint { CGPoint(x: x, y: y) }

    private enum CodingKeys: String, CodingKey {
        case x, y, pressure, tilt, azimuth, timestamp
    }

    init(
        x: Double,
        y: Double,
        pressure: Double,
        tilt: Double,
        azimuth: Double,
        timestamp: Double
    ) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tilt = tilt
        self.azimuth = azimuth
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        // New documents use a compact positional representation because sample
        // keys repeated hundreds of thousands of times dominated save size and
        // encoding time. Continue accepting the original keyed representation.
        if var values = try? decoder.unkeyedContainer() {
            x = try values.decode(Double.self)
            y = try values.decode(Double.self)
            pressure = try values.decode(Double.self)
            tilt = try values.decode(Double.self)
            azimuth = try values.decode(Double.self)
            timestamp = try values.decode(Double.self)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(Double.self, forKey: .x)
        y = try values.decode(Double.self, forKey: .y)
        pressure = try values.decode(Double.self, forKey: .pressure)
        tilt = try values.decode(Double.self, forKey: .tilt)
        azimuth = try values.decode(Double.self, forKey: .azimuth)
        timestamp = try values.decode(Double.self, forKey: .timestamp)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(x)
        try values.encode(y)
        try values.encode(pressure)
        try values.encode(tilt)
        try values.encode(azimuth)
        try values.encode(timestamp)
    }
}

nonisolated enum BrushKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case wiggle
    case jitter
    case pulse
    case cutMarker
    case solidColor
    case softAirbrush
    case gouache
    case flatChisel
    case scatter
    case ghostTrail
    case dashed
    case star
    case dotted
    case particle
    case goo
    case scribbles
    case particleCloud
    case glitter
    case gradient
    case polkaDots
    case checker
    case faded
    case charcoal
    case colorNoise
    case dryOutline
    case retro
    case outlineFill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wiggle: "Wiggle Line"
        case .jitter: "Jitter Pencil"
        case .pulse: "Pulse Marker"
        case .cutMarker: "Cut Marker"
        case .solidColor: "Coloring"
        case .softAirbrush: "Soft Airbrush"
        case .gouache: "Gouache"
        case .flatChisel: "Flat Chisel"
        case .scatter: "Scatter Dots"
        case .ghostTrail: "Ghost Trail"
        case .dashed: "Dashed"
        case .star: "Star"
        case .dotted: "Dotted Line"
        case .particle: "Particle"
        case .goo: "Goo"
        case .scribbles: "Scribbles"
        case .particleCloud: "Drizzle"
        case .glitter: "Glitter"
        case .gradient: "Gradient"
        case .polkaDots: "Polka Dots"
        case .checker: "Checker"
        case .faded: "Faded"
        case .charcoal: "Charcoal"
        case .colorNoise: "Color Noise"
        case .dryOutline: "Grainy Ink"
        case .retro: "Trippy"
        case .outlineFill: "Outline Fill"
        }
    }

    var symbol: String {
        switch self {
        case .wiggle: "waveform.path"
        case .jitter: "pencil.and.scribble"
        case .pulse: "dot.radiowaves.left.and.right"
        case .cutMarker: "highlighter"
        case .solidColor: "paintbrush.fill"
        case .softAirbrush: "cloud.fill"
        case .gouache: "paintpalette.fill"
        case .flatChisel: "rectangle.fill"
        case .scatter: "circle.hexagongrid"
        case .ghostTrail: "sparkles"
        case .dashed: "ellipsis"
        case .star: "star.fill"
        case .dotted: "circle.dotted"
        case .particle: "circle.fill"
        case .goo: "drop.fill"
        case .scribbles: "scribble.variable"
        case .particleCloud: "circle.grid.cross"
        case .glitter: "sparkles"
        case .gradient: "rainbow"
        case .polkaDots: "circle.grid.3x3.fill"
        case .checker: "square.grid.2x2.fill"
        case .faded: "paintbrush.pointed.fill"
        case .charcoal: "pencil.line"
        case .colorNoise: "aqi.medium"
        case .dryOutline: "pencil.tip"
        case .retro: "rays"
        case .outlineFill: "circle.circle"
        }
    }

    static var catalogCases: [BrushKind] {
        [.solidColor, .dashed, .star, .particle, .goo, .scribbles, .particleCloud, .glitter, .gradient, .polkaDots, .checker, .faded, .dryOutline, .retro, .outlineFill]
    }

    var isAvailableInCatalog: Bool {
        Self.catalogCases.contains(self)
    }

    /// Brush kinds animated entirely on the GPU. Committed strokes of these
    /// kinds stay animated (kept out of the baked bitmap) in playback.
    var isGPUAnimated: Bool {
        switch self {
        case .solidColor, .dashed, .star, .particle, .goo, .scribbles, .particleCloud,
             .glitter, .gradient, .checker, .dryOutline, .retro, .outlineFill:
            true
        default: false
        }
    }

    var supportsGlobalWave: Bool {
        switch self {
        case .dashed, .solidColor, .star, .particle, .checker, .scribbles,
             .particleCloud, .glitter, .outlineFill:
            true
        default:
            false
        }
    }
}

nonisolated enum ScribbleMotionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case synchronized
    case random

    var id: String { rawValue }
    var title: String {
        switch self {
        case .synchronized: "Sync"
        case .random: "Random"
        }
    }
}

nonisolated enum StarRotationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case synced
    case random

    var id: String { rawValue }
    var title: String {
        switch self {
        case .synced: "Synced"
        case .random: "Random"
        }
    }
}

nonisolated enum BrushEndStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case rounded
    case cut

    var id: String { rawValue }
    var title: String { self == .rounded ? "Rounded" : "Cut" }
}

nonisolated struct BrushSettings: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: BrushKind
    var color: CodableColor
    var size: Double
    var opacity: Double
    var smoothing: Double
    var spacing: Double
    var motionAmount: Double
    var frequency: Double
    var loopCycles: Int
    var pressureSize: Double
    var pressureOpacity: Double
    var tiltResponse: Double
    var seed: UInt64
    var startWidthScale: Double? = nil
    var endWidthScale: Double? = nil
    var scribbleLineCount: Int? = nil
    var scribbleMotionMode: ScribbleMotionMode? = nil
    var secondaryColor: CodableColor? = nil
    var tertiaryColor: CodableColor? = nil
    var polkaRowCount: Int? = nil
    var checkerSpeed: Double? = nil
    var glitterDensity: Double? = nil
    var sparkleAmount: Double? = nil
    var textureDensity: Double? = nil
    var textureRoughness: Double? = nil
    var charcoalLineCount: Int? = nil
    var dashGap: Double? = nil
    var dotGap: Double? = nil
    var dashCornerRadius: Double? = nil
    var dashSpeed: Double? = nil
    var dashLength: Double? = nil
    var particleSpeed: Double? = nil
    var particleLength: Double? = nil
    var particleDelay: Double? = nil
    var gooSpeed: Double? = nil
    var gooThickness: Double? = nil
    var gooWaviness: Double? = nil
    var gooWaveLength: Double? = nil
    var gooDroplets: Double? = nil
    var scribbleSpeed: Double? = nil
    var scribbleThickness: Double? = nil
    var particleCloudSpeed: Double? = nil
    var particleCloudThickness: Double? = nil
    var particleCloudFallOff: Double? = nil
    var particleCloudScale: Double? = nil
    var glitterSpeed: Double? = nil
    var gradientSpeed: Double? = nil
    var coloringUsesGradient: Bool? = nil
    var waveAmount: Double? = nil
    var fadedSpeed: Double? = nil
    var fadedAmount: Double? = nil
    var borderSpeed: Double? = nil
    var starRotationSpeed: Double? = nil
    var starRotationMode: StarRotationMode? = nil
    var starGradientAcrossStroke: Bool? = nil
    var gradientMergesAcrossStrokes: Bool? = nil
    var quaternaryColor: CodableColor? = nil
    var quinaryColor: CodableColor? = nil
    var trippyColorCount: Int? = nil
    var endStyle: BrushEndStyle? = nil
    var outlineWidth: Double? = nil
    var wobbleAmount: Double? = nil
    var wobbleSpeed: Double? = nil
    var fadedBaseOpacity: Double? = nil
    var fadedTextureOpacity: Double? = nil

    var resolvedStartWidthScale: Double { startWidthScale ?? 1 }
    var resolvedEndWidthScale: Double { endWidthScale ?? 1 }
    var resolvedScribbleLineCount: Int { min(12, max(2, scribbleLineCount ?? 2)) }
    var resolvedScribbleMotionMode: ScribbleMotionMode { scribbleMotionMode ?? .synchronized }
    var resolvedSecondaryColor: CodableColor { secondaryColor ?? CodableColor(red: 1, green: 0.12, blue: 0.55) }
    var resolvedDashBackgroundColor: CodableColor { secondaryColor ?? .white }
    var resolvedTertiaryColor: CodableColor { tertiaryColor ?? CodableColor(red: 1, green: 0.72, blue: 0.08) }
    var resolvedQuaternaryColor: CodableColor { quaternaryColor ?? CodableColor(red: 0.0, green: 0.88, blue: 1.0) }
    var resolvedQuinaryColor: CodableColor { quinaryColor ?? CodableColor(red: 0.22, green: 1.0, blue: 0.06) }
    var resolvedTrippyColorCount: Int { min(5, max(2, trippyColorCount ?? 5)) }
    var resolvedOutlineWidth: Double { min(20, max(0.5, outlineWidth ?? 6)) }
    var resolvedWobbleAmount: Double { min(1, max(0, wobbleAmount ?? 0.35)) }
    var resolvedWobbleSpeed: Double { min(4, max(0, wobbleSpeed ?? 1)) }
    var resolvedEndStyle: BrushEndStyle { endStyle ?? .rounded }
    var resolvedPolkaRowCount: Int { min(8, max(1, polkaRowCount ?? 4)) }
    var resolvedCheckerSpeed: Double { min(4, max(0, checkerSpeed ?? 1)) }
    var resolvedGlitterDensity: Double { min(1, max(0.05, glitterDensity ?? 0.55)) }
    var resolvedSparkleAmount: Double { min(1, max(0, sparkleAmount ?? 0.5)) }
    var resolvedTextureDensity: Double { min(1, max(0.05, textureDensity ?? 0.6)) }
    var resolvedTextureRoughness: Double { min(1, max(0, textureRoughness ?? 0.5)) }
    var resolvedCharcoalLineCount: Int { min(8, max(2, charcoalLineCount ?? 4)) }
    var resolvedDashGap: Double { max(0, dashGap ?? max(size * 1.25, spacing * 2.5)) }
    var resolvedDashCornerRadius: Double { min(1, max(0, dashCornerRadius ?? 1)) }
    var resolvedDashSpeed: Double { min(4, max(0, dashSpeed ?? 0.4)) }
    var resolvedDashLength: Double { min(1, max(0, dashLength ?? 0.2)) }
    var resolvedParticleSpeed: Double { min(4, max(0, particleSpeed ?? 0.4)) }
    var resolvedParticleLength: Double { min(1, max(0, particleLength ?? 0.2)) }
    var resolvedParticleDelay: Double { min(0.9, max(0, particleDelay ?? 0.12)) }
    var resolvedGooSpeed: Double { min(2, max(0, gooSpeed ?? 0.55)) }
    var resolvedGooThickness: Double { min(1, max(0, gooThickness ?? 0.5)) }
    var resolvedGooWaviness: Double { min(1, max(0, gooWaviness ?? 0.45)) }
    var resolvedGooWaveLength: Double { min(1, max(0, gooWaveLength ?? 0.55)) }
    var resolvedGooDroplets: Double { min(1, max(0, gooDroplets ?? 1)) }
    var resolvedScribbleSpeed: Double { min(4, max(0, scribbleSpeed ?? 0.65)) }
    var resolvedScribbleThickness: Double { min(1, max(0, scribbleThickness ?? 0.4)) }
    var resolvedParticleCloudSpeed: Double { min(4, max(0, particleCloudSpeed ?? 0.5)) }
    var resolvedParticleCloudThickness: Double { min(1, max(0, particleCloudThickness ?? 0.2)) }
    var resolvedParticleCloudFallOff: Double { min(1, max(0, particleCloudFallOff ?? 0.29)) }
    var resolvedParticleCloudScale: Double { min(1, max(0, particleCloudScale ?? 0.2)) }
    var resolvedGlitterSpeed: Double { min(4, max(0, glitterSpeed ?? 1)) }
    var resolvedGradientSpeed: Double { min(4, max(0, gradientSpeed ?? 1)) }
    var resolvedColoringUsesGradient: Bool { coloringUsesGradient ?? true }
    var resolvedWaveAmount: Double { min(100, max(0, waveAmount ?? 0)) }
    var resolvedFadedSpeed: Double { min(4, max(0, fadedSpeed ?? 1)) }
    var resolvedFadedAmount: Double { min(1, max(0, fadedAmount ?? 0.72)) }
    var resolvedFadedBaseColor: CodableColor { secondaryColor ?? color }
    var resolvedFadedBaseOpacity: Double { min(1, max(0, fadedBaseOpacity ?? 0)) }
    var resolvedFadedTextureOpacity: Double { min(1, max(0, fadedTextureOpacity ?? 1)) }
    var resolvedBorderSpeed: Double { min(4, max(0, borderSpeed ?? 1)) }
    var resolvedStarRotationSpeed: Double { min(4, max(0, starRotationSpeed ?? 1)) }
    var resolvedStarRotationMode: StarRotationMode { starRotationMode ?? .synced }
    var resolvedStarGradientAcrossStroke: Bool { starGradientAcrossStroke ?? false }
    var resolvedGradientMergesAcrossStrokes: Bool { gradientMergesAcrossStrokes ?? false }
    /// Whole pattern cycles keep the animation seamless at the loop boundary.
    /// Ten cycles at the maximum setting is fast without making the default race.
    var resolvedDashCyclesPerLoop: Double { (resolvedDashSpeed * 2.5).rounded() }
    /// Checker travel must land on a complete two-column pattern at phase 1.
    var resolvedCheckerCyclesPerLoop: Double {
        resolvedCheckerSpeed < 0.01 ? 0 : max(1, (resolvedCheckerSpeed * 2).rounded())
    }
    /// Gradient and Trippy color motion always completes whole temporal cycles.
    var resolvedGradientCyclesPerLoop: Double {
        resolvedGradientSpeed < 0.01 ? 0 : max(1, (resolvedGradientSpeed * 2).rounded())
    }
    /// A partially rotated star cannot meet its starting frame at the seam.
    var resolvedStarRotationCyclesPerLoop: Double {
        resolvedStarRotationSpeed < 0.01 ? 0 : max(1, resolvedStarRotationSpeed.rounded())
    }
    var resolvedDotGap: Double {
        max(0, dotGap ?? (max(size * 1.5, spacing * 2.2) - size))
    }

    static func preset(_ kind: BrushKind) -> BrushSettings {
        switch kind {
        case .wiggle:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 16, opacity: 1, smoothing: 0.35, spacing: 12, motionAmount: 18, frequency: 2.2, loopCycles: 1, pressureSize: 0.7, pressureOpacity: 0, tiltResponse: 0.15, seed: 101)
        case .jitter:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 8, opacity: 0.72, smoothing: 0.2, spacing: 7, motionAmount: 9, frequency: 4.5, loopCycles: 2, pressureSize: 0.8, pressureOpacity: 0.35, tiltResponse: 0.45, seed: 202)
        case .pulse:
            BrushSettings(name: kind.title, kind: kind, color: .amber, size: 30, opacity: 0.78, smoothing: 0.55, spacing: 10, motionAmount: 0.35, frequency: 1, loopCycles: 1, pressureSize: 0.55, pressureOpacity: 0.2, tiltResponse: 0.1, seed: 303)
        case .cutMarker:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.96, green: 0.18, blue: 0.12), size: 46, opacity: 0.94, smoothing: 0.62, spacing: 5, motionAmount: 5, frequency: 1.4, loopCycles: 1, pressureSize: 0.3, pressureOpacity: 0.08, tiltResponse: 0.65, seed: 1717, textureDensity: 0.52, textureRoughness: 0.4)
        case .solidColor:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 1, green: 0.68, blue: 0.08), size: 44, opacity: 1, smoothing: 0.72, spacing: 4, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 1818, secondaryColor: CodableColor(red: 0.56, green: 0.10, blue: 0.86), gradientSpeed: 0, coloringUsesGradient: true, gradientMergesAcrossStrokes: false)
        case .softAirbrush:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.18, green: 0.48, blue: 0.96), size: 110, opacity: 0.42, smoothing: 0.78, spacing: 3, motionAmount: 8, frequency: 1, loopCycles: 1, pressureSize: 0.58, pressureOpacity: 0.3, tiltResponse: 0.18, seed: 1919)
        case .gouache:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.92, green: 0.2, blue: 0.32), size: 78, opacity: 0.96, smoothing: 0.58, spacing: 4, motionAmount: 10, frequency: 1.35, loopCycles: 1, pressureSize: 0.5, pressureOpacity: 0.08, tiltResponse: 0.25, seed: 2020, textureDensity: 0.48, textureRoughness: 0.44)
        case .flatChisel:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.48, green: 0.16, blue: 0.92), size: 64, opacity: 1, smoothing: 0.68, spacing: 4, motionAmount: 12, frequency: 1.2, loopCycles: 1, pressureSize: 0.42, pressureOpacity: 0, tiltResponse: 0.8, seed: 2121)
        case .scatter:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 12, opacity: 0.85, smoothing: 0.15, spacing: 20, motionAmount: 24, frequency: 2.5, loopCycles: 1, pressureSize: 0.65, pressureOpacity: 0.3, tiltResponse: 0.5, seed: 404)
        case .ghostTrail:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.48, green: 0.08, blue: 0.95), size: 34, opacity: 0.9, smoothing: 0.55, spacing: 5, motionAmount: 18, frequency: 2.4, loopCycles: 1, pressureSize: 0.65, pressureOpacity: 0.15, tiltResponse: 0.1, seed: 505)
        case .dashed:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 34, opacity: 1, smoothing: 0.5, spacing: 22, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 606, secondaryColor: .white, dashGap: 42, dashCornerRadius: 1, dashSpeed: 0.4, dashLength: 0.2)
        case .star:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.95, green: 0.72, blue: 0.08), size: 26, opacity: 1, smoothing: 0.55, spacing: 20, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 2626, secondaryColor: .white, tertiaryColor: CodableColor(red: 0.98, green: 0.42, blue: 0.12), dashGap: 44, dashSpeed: 0.4, dashLength: 0.35, starRotationSpeed: 1, starRotationMode: .synced, starGradientAcrossStroke: false)
        case .dotted:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 22, opacity: 1, smoothing: 0.55, spacing: 14, motionAmount: 0.45, frequency: 1, loopCycles: 1, pressureSize: 0.3, pressureOpacity: 0, tiltResponse: 0, seed: 2606)
        case .particle:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 30, opacity: 1, smoothing: 0.5, spacing: 10, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 707, secondaryColor: .white, particleSpeed: 0.4, particleLength: 0.2, particleDelay: 0.12)
        case .goo:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 30, opacity: 1, smoothing: 0.55, spacing: 5, motionAmount: 9, frequency: 2.2, loopCycles: 1, pressureSize: 0.45, pressureOpacity: 0, tiltResponse: 0.1, seed: 808, gooSpeed: 0.55, gooThickness: 0.5, gooWaviness: 0.45, gooWaveLength: 0.55)
        case .scribbles:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 5, opacity: 1, smoothing: 0.68, spacing: 5, motionAmount: 22, frequency: 1.6, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 909, scribbleLineCount: 3, scribbleMotionMode: .random, scribbleSpeed: 0.65, scribbleThickness: 0.4)
        case .particleCloud:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 6, opacity: 1, smoothing: 0.62, spacing: 6, motionAmount: 16, frequency: 2, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 1010, particleCloudSpeed: 0.5, particleCloudThickness: 0.2, particleCloudFallOff: 0.29, particleCloudScale: 0.2)
        case .glitter:
            BrushSettings(name: kind.title, kind: kind, color: .white, size: 48, opacity: 1, smoothing: 0.68, spacing: 5, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 1111, secondaryColor: CodableColor(red: 0.18, green: 0.36, blue: 0.92), glitterDensity: 0.72, sparkleAmount: 0.58, glitterSpeed: 1)
        case .gradient:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 1, green: 0.68, blue: 0.08), size: 44, opacity: 1, smoothing: 0.72, spacing: 4, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 1212, secondaryColor: CodableColor(red: 0.56, green: 0.10, blue: 0.86), gradientSpeed: 1, gradientMergesAcrossStrokes: false)
        case .polkaDots:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.96, green: 0.22, blue: 0.78), size: 40, opacity: 0.96, smoothing: 0.55, spacing: 10, motionAmount: 0.16, frequency: 2, loopCycles: 1, pressureSize: 0.35, pressureOpacity: 0.08, tiltResponse: 0.1, seed: 1313, polkaRowCount: 3)
        case .checker:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 36, opacity: 1, smoothing: 0.55, spacing: 6, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 1515, secondaryColor: .white, tertiaryColor: CodableColor(red: 1, green: 0.38, blue: 0.08), checkerSpeed: 1, quaternaryColor: CodableColor(red: 0.0, green: 0.78, blue: 1.0))
        case .faded:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.08, green: 0.32, blue: 0.9), size: 34, opacity: 1, smoothing: 0.7, spacing: 4, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 1414, secondaryColor: CodableColor(red: 0.50, green: 0.72, blue: 1.0), textureDensity: 0.82, textureRoughness: 0.9, fadedSpeed: 1, fadedAmount: 0.86, fadedBaseOpacity: 1, fadedTextureOpacity: 1)
        case .charcoal:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 22, opacity: 0.88, smoothing: 0.35, spacing: 5, motionAmount: 2.5, frequency: 2.2, loopCycles: 1, pressureSize: 0.75, pressureOpacity: 0.35, tiltResponse: 0.45, seed: 1515, textureDensity: 0.72, textureRoughness: 0.68, charcoalLineCount: 4)
        case .colorNoise:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 1, green: 0.06, blue: 0.48), size: 40, opacity: 0.92, smoothing: 0.3, spacing: 5, motionAmount: 9, frequency: 2, loopCycles: 1, pressureSize: 0.45, pressureOpacity: 0.18, tiltResponse: 0.2, seed: 1616, secondaryColor: CodableColor(red: 0.58, green: 0.02, blue: 0.3), textureDensity: 0.72, textureRoughness: 0.65)
        case .dryOutline:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 22, opacity: 1, smoothing: 0.76, spacing: 3, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 2424, textureDensity: 0.82, textureRoughness: 0.42, borderSpeed: 1)
        case .retro:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 1.0, green: 0.12, blue: 0.61), size: 44, opacity: 1, smoothing: 0.72, spacing: 4, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 2727, secondaryColor: CodableColor(red: 0.48, green: 0.17, blue: 1.0), tertiaryColor: CodableColor(red: 0.0, green: 0.88, blue: 1.0), gradientSpeed: 1, quaternaryColor: CodableColor(red: 1.0, green: 0.90, blue: 0.0), quinaryColor: CodableColor(red: 0.22, green: 1.0, blue: 0.06))
        case .outlineFill:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.10, green: 0.10, blue: 0.12), size: 32, opacity: 1, smoothing: 0.62, spacing: 4, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 2929, secondaryColor: CodableColor(red: 0.98, green: 0.62, blue: 0.10))
        }
    }
}

nonisolated struct AnimatedStroke: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var samples: [StrokeSample]
    var brush: BrushSettings
    // True for a stroke still being drawn live under the pencil. Kernels that
    // animate committed artwork (e.g. Goo's droplets) skip those extras for
    // preview strokes so they only appear once the stroke is committed.
    var isPreview = false

    /// Catalog brushes retain their specialized Metal renderer for either cap
    /// style; CPU export uses the same setting through the shared endpoint clip.
    var usesGPUAnimatedRenderer: Bool {
        brush.kind.isGPUAnimated
    }

    private enum CodingKeys: String, CodingKey {
        case id, samples, brush
    }

    /// Keeps live rendering work bounded on unusually long Pencil gestures.
    /// The original samples are still committed and persisted losslessly; only
    /// the transient under-Pencil preview is uniformly resampled.
    func limitedForLivePreview(maxSamples: Int = 1_024) -> AnimatedStroke {
        guard maxSamples > 2, samples.count > maxSamples else { return self }
        let last = samples.count - 1
        var reduced: [StrokeSample] = []
        reduced.reserveCapacity(maxSamples)
        for slot in 0..<maxSamples {
            let index = Int((Double(slot) * Double(last) / Double(maxSamples - 1)).rounded())
            reduced.append(samples[index])
        }
        var copy = self
        copy.samples = reduced
        return copy
    }

    /// Returns a decimated sample list for baking cached ribbon geometry.
    /// Slow Pencil gestures can yield a sample per canvas point, so ribbons
    /// and droplet paths built from every sample produce far more vertices
    /// than the rendered stroke needs. A point is dropped when it lies within
    /// `tolerance` of the straight run through its kept predecessor and next
    /// source point (so curves and corners are preserved exactly) unless it
    /// is already `maxSpacing` away, which bounds interpolation coarseness.
    /// The committed document is untouched; decimation happens only at
    /// bake/render time, and endpoints are always preserved.
    func bakedSamples(
        tolerance: CGFloat = 0.15,
        maxSpacing: CGFloat = 4.0,
        maxSamples: Int = 4_096
    ) -> [StrokeSample] {
        guard samples.count > 12, maxSpacing > tolerance else { return samples }
        var kept: [StrokeSample] = []
        kept.reserveCapacity(min(samples.count, maxSamples))
        kept.append(samples[0])
        for index in 1..<(samples.count - 1) {
            let point = samples[index]
            guard let previous = kept.last else { break }
            let next = samples[index + 1]
            let dx = point.x - previous.x
            let dy = point.y - previous.y
            let distanceFromPrevious = (dx * dx + dy * dy).squareRoot()
            var deviation: CGFloat = 0
            let vx = next.x - previous.x
            let vy = next.y - previous.y
            let lengthSquared = vx * vx + vy * vy
            if lengthSquared > 0.000_001 {
                let projection = min(
                    1,
                    max(0, (dx * vx + dy * vy) / lengthSquared)
                )
                deviation = Foundation.hypot(
                    point.x - (previous.x + vx * projection),
                    point.y - (previous.y + vy * projection)
                )
            } else {
                deviation = distanceFromPrevious
            }
            if deviation > tolerance || distanceFromPrevious >= maxSpacing {
                kept.append(point)
            }
        }
        if let last = samples.last, kept.last != last {
            kept.append(last)
        }
        guard kept.count > maxSamples else { return kept }
        let lastIndex = kept.count - 1
        var capped: [StrokeSample] = []
        capped.reserveCapacity(maxSamples)
        for slot in 0..<maxSamples {
            let index = Int((Double(slot) * Double(lastIndex) / Double(maxSamples - 1)).rounded())
            capped.append(kept[index])
        }
        return capped
    }
}

nonisolated struct CanvasFill: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var samples: [StrokeSample]
    var color: CodableColor
    var maskData: Data? = nil
    var animatedMaskFrames: [Data]? = nil
    var animatedContours: [[StrokeSample]]? = nil
}

nonisolated struct DrawingLayer: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isVisible = true
    var opacity = 1.0
    var imageData: Data? = nil
    var imageName: String? = nil
    var imageScale: Double? = nil
    var imageOffsetX: Double? = nil
    var imageOffsetY: Double? = nil
    var groupID: UUID? = nil
    var contentScale: Double? = nil
    var contentOffsetX: Double? = nil
    var contentOffsetY: Double? = nil
    var fills: [CanvasFill]? = nil
    var strokes: [AnimatedStroke] = []

    var resolvedImageScale: Double {
        min(8, max(0.1, imageScale ?? 1))
    }

    var resolvedImageOffset: CGPoint {
        CGPoint(x: imageOffsetX ?? 0, y: imageOffsetY ?? 0)
    }

    var resolvedContentScale: Double {
        min(16, max(0.05, contentScale ?? 1))
    }

    var resolvedContentOffset: CGPoint {
        CGPoint(x: contentOffsetX ?? 0, y: contentOffsetY ?? 0)
    }
}

nonisolated struct LayerGroup: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var isVisible = true
    var isCollapsed = false
    var parentGroupID: UUID? = nil
}

nonisolated struct WiggleDocument: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var name: String
    var width: Int
    var height: Int
    var background: CodableColor
    var backgroundVisible: Bool? = nil
    var layers: [DrawingLayer]
    var layerGroups: [LayerGroup]? = nil
    var selectedLayerID: UUID
    var createdAt = Date()
    var modifiedAt = Date()

    static func blank(name: String = "Untitled", size: CGSize = CanvasPreset.square.size) -> WiggleDocument {
        let layer = DrawingLayer(name: "Ink")
        return WiggleDocument(
            name: name,
            width: Int(size.width),
            height: Int(size.height),
            background: .white,
            layers: [layer],
            selectedLayerID: layer.id
        )
    }

    var selectedLayerIndex: Int {
        layers.firstIndex(where: { $0.id == selectedLayerID }) ?? 0
    }

    var resolvedBackgroundVisible: Bool {
        backgroundVisible ?? true
    }


    /// Whether a group (and every group above it in the folder hierarchy) is
    /// visible. Hiding a parent folder hides its whole subtree.
    func isGroupEffectivelyVisible(_ groupID: UUID) -> Bool {
        var currentID: UUID? = groupID
        var visited: Set<UUID> = []
        while let id = currentID {
            // Old documents may contain a malformed folder cycle. Treat the
            // cycle as visible so committed strokes do not disappear.
            guard visited.insert(id).inserted else { return true }
            guard let group = layerGroups?.first(where: { $0.id == id }) else { return true }
            guard group.isVisible else { return false }
            currentID = group.parentGroupID
        }
        return true
    }

    func isLayerEffectivelyVisible(_ layer: DrawingLayer) -> Bool {
        guard layer.isVisible else { return false }
        guard let groupID = layer.groupID else { return true }
        return isGroupEffectivelyVisible(groupID)
    }

    /// All group IDs nested (recursively) beneath the given group, excluding the
    /// group itself. Guards against malformed cycles.
    func descendantGroupIDs(of groupID: UUID) -> Set<UUID> {
        var result: Set<UUID> = []
        var stack = [groupID]
        while let id = stack.popLast() {
            for group in layerGroups ?? [] where group.parentGroupID == id {
                if result.insert(group.id).inserted { stack.append(group.id) }
            }
        }
        return result
    }

    /// Layer IDs that live directly inside a group or transitively inside one of
    /// its nested folders, in document order. Used for whole-folder transforms
    /// and moves.
    func groupLayerIDs(_ groupID: UUID) -> [UUID] {
        let groupSet = descendantGroupIDs(of: groupID).union([groupID])
        return layers.compactMap { layer in
            layer.groupID.map { groupSet.contains($0) ? layer.id : nil } ?? nil
        }
    }

    /// Whether `ancestor` is the group itself or contains `descendant` (directly
    /// or nested). Prevents dropping a folder into one of its own subfolders.
    func group(_ ancestor: UUID, contains descendant: UUID) -> Bool {
        if ancestor == descendant { return true }
        return descendantGroupIDs(of: ancestor).contains(descendant)
    }
}

enum CanvasInputPolicy: String, CaseIterable, Identifiable {
    case pencilOnly
    case pencilAndFinger

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pencilOnly: "Pencil only"
        case .pencilAndFinger: "Pencil + finger"
        }
    }
}
