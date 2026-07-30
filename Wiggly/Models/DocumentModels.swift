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
}

nonisolated enum BrushKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case wiggle
    case jitter
    case pulse
    case scatter
    case ghostTrail
    case dashed
    case particle
    case goo
    case scribbles
    case particleCloud
    case glitter
    case gradient
    case polkaDots
    case faded
    case charcoal
    case colorNoise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wiggle: "Wiggle Line"
        case .jitter: "Jitter Pencil"
        case .pulse: "Pulse Marker"
        case .scatter: "Scatter Dots"
        case .ghostTrail: "Ghost Trail"
        case .dashed: "Dashed"
        case .particle: "Particle"
        case .goo: "Goo"
        case .scribbles: "Scribbles"
        case .particleCloud: "Particles"
        case .glitter: "Glitter"
        case .gradient: "Gradient"
        case .polkaDots: "Polka Dots"
        case .faded: "Faded"
        case .charcoal: "Charcoal"
        case .colorNoise: "Color Noise"
        }
    }

    var symbol: String {
        switch self {
        case .wiggle: "waveform.path"
        case .jitter: "pencil.and.scribble"
        case .pulse: "dot.radiowaves.left.and.right"
        case .scatter: "circle.hexagongrid"
        case .ghostTrail: "sparkles"
        case .dashed: "ellipsis"
        case .particle: "circle.fill"
        case .goo: "drop.fill"
        case .scribbles: "scribble.variable"
        case .particleCloud: "circle.grid.cross"
        case .glitter: "sparkles"
        case .gradient: "rainbow"
        case .polkaDots: "circle.grid.3x3.fill"
        case .faded: "paintbrush.pointed.fill"
        case .charcoal: "pencil.line"
        case .colorNoise: "aqi.medium"
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
    var glitterDensity: Double? = nil
    var sparkleAmount: Double? = nil
    var textureDensity: Double? = nil
    var textureRoughness: Double? = nil
    var charcoalLineCount: Int? = nil

    var resolvedStartWidthScale: Double { startWidthScale ?? 1 }
    var resolvedEndWidthScale: Double { endWidthScale ?? 1 }
    var resolvedScribbleLineCount: Int { min(12, max(2, scribbleLineCount ?? 2)) }
    var resolvedScribbleMotionMode: ScribbleMotionMode { scribbleMotionMode ?? .synchronized }
    var resolvedSecondaryColor: CodableColor { secondaryColor ?? CodableColor(red: 1, green: 0.12, blue: 0.55) }
    var resolvedTertiaryColor: CodableColor { tertiaryColor ?? CodableColor(red: 1, green: 0.72, blue: 0.08) }
    var resolvedPolkaRowCount: Int { min(8, max(1, polkaRowCount ?? 4)) }
    var resolvedGlitterDensity: Double { min(1, max(0.05, glitterDensity ?? 0.55)) }
    var resolvedSparkleAmount: Double { min(1, max(0, sparkleAmount ?? 0.5)) }
    var resolvedTextureDensity: Double { min(1, max(0.05, textureDensity ?? 0.6)) }
    var resolvedTextureRoughness: Double { min(1, max(0, textureRoughness ?? 0.5)) }
    var resolvedCharcoalLineCount: Int { min(8, max(2, charcoalLineCount ?? 4)) }

    static func preset(_ kind: BrushKind) -> BrushSettings {
        switch kind {
        case .wiggle:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 16, opacity: 1, smoothing: 0.35, spacing: 12, motionAmount: 18, frequency: 2.2, loopCycles: 1, pressureSize: 0.7, pressureOpacity: 0, tiltResponse: 0.15, seed: 101)
        case .jitter:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 8, opacity: 0.72, smoothing: 0.2, spacing: 7, motionAmount: 9, frequency: 4.5, loopCycles: 2, pressureSize: 0.8, pressureOpacity: 0.35, tiltResponse: 0.45, seed: 202)
        case .pulse:
            BrushSettings(name: kind.title, kind: kind, color: .amber, size: 30, opacity: 0.78, smoothing: 0.55, spacing: 10, motionAmount: 0.35, frequency: 1, loopCycles: 1, pressureSize: 0.55, pressureOpacity: 0.2, tiltResponse: 0.1, seed: 303)
        case .scatter:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 12, opacity: 0.85, smoothing: 0.15, spacing: 20, motionAmount: 24, frequency: 2.5, loopCycles: 1, pressureSize: 0.65, pressureOpacity: 0.3, tiltResponse: 0.5, seed: 404)
        case .ghostTrail:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.48, green: 0.08, blue: 0.95), size: 34, opacity: 0.9, smoothing: 0.55, spacing: 5, motionAmount: 18, frequency: 2.4, loopCycles: 1, pressureSize: 0.65, pressureOpacity: 0.15, tiltResponse: 0.1, seed: 505)
        case .dashed:
            BrushSettings(name: kind.title, kind: kind, color: .white, size: 34, opacity: 1, smoothing: 0.5, spacing: 22, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 606)
        case .particle:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 30, opacity: 1, smoothing: 0.5, spacing: 10, motionAmount: 0, frequency: 1, loopCycles: 1, pressureSize: 0, pressureOpacity: 0, tiltResponse: 0, seed: 707)
        case .goo:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 30, opacity: 1, smoothing: 0.55, spacing: 5, motionAmount: 9, frequency: 2.2, loopCycles: 1, pressureSize: 0.45, pressureOpacity: 0, tiltResponse: 0.1, seed: 808)
        case .scribbles:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 5, opacity: 0.95, smoothing: 0.45, spacing: 5, motionAmount: 22, frequency: 1.6, loopCycles: 1, pressureSize: 0.35, pressureOpacity: 0, tiltResponse: 0.1, seed: 909)
        case .particleCloud:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 6, opacity: 0.88, smoothing: 0.25, spacing: 6, motionAmount: 16, frequency: 2, loopCycles: 1, pressureSize: 0.45, pressureOpacity: 0.2, tiltResponse: 0.2, seed: 1010)
        case .glitter:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.18, green: 0.36, blue: 0.92), size: 48, opacity: 1, smoothing: 0.55, spacing: 7, motionAmount: 0.45, frequency: 2, loopCycles: 1, pressureSize: 0.4, pressureOpacity: 0, tiltResponse: 0.1, seed: 1111, secondaryColor: .white, glitterDensity: 0.62, sparkleAmount: 0.58)
        case .gradient:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.94, green: 0.12, blue: 0.62), size: 44, opacity: 1, smoothing: 0.55, spacing: 6, motionAmount: 0.65, frequency: 1.25, loopCycles: 1, pressureSize: 0.4, pressureOpacity: 0, tiltResponse: 0.1, seed: 1212, secondaryColor: CodableColor(red: 1, green: 0.68, blue: 0.08), tertiaryColor: CodableColor(red: 0.34, green: 0.12, blue: 0.95))
        case .polkaDots:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.96, green: 0.22, blue: 0.78), size: 40, opacity: 0.96, smoothing: 0.55, spacing: 10, motionAmount: 0.16, frequency: 2, loopCycles: 1, pressureSize: 0.35, pressureOpacity: 0.08, tiltResponse: 0.1, seed: 1313, polkaRowCount: 3)
        case .faded:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 0.08, green: 0.32, blue: 0.9), size: 34, opacity: 0.92, smoothing: 0.5, spacing: 6, motionAmount: 7, frequency: 1.6, loopCycles: 1, pressureSize: 0.4, pressureOpacity: 0.1, tiltResponse: 0.12, seed: 1414, textureDensity: 0.66, textureRoughness: 0.72)
        case .charcoal:
            BrushSettings(name: kind.title, kind: kind, color: .black, size: 22, opacity: 0.88, smoothing: 0.35, spacing: 5, motionAmount: 2.5, frequency: 2.2, loopCycles: 1, pressureSize: 0.75, pressureOpacity: 0.35, tiltResponse: 0.45, seed: 1515, textureDensity: 0.72, textureRoughness: 0.68, charcoalLineCount: 4)
        case .colorNoise:
            BrushSettings(name: kind.title, kind: kind, color: CodableColor(red: 1, green: 0.06, blue: 0.48), size: 40, opacity: 0.92, smoothing: 0.3, spacing: 5, motionAmount: 9, frequency: 2, loopCycles: 1, pressureSize: 0.45, pressureOpacity: 0.18, tiltResponse: 0.2, seed: 1616, secondaryColor: CodableColor(red: 0.58, green: 0.02, blue: 0.3), textureDensity: 0.72, textureRoughness: 0.65)
        }
    }
}

nonisolated struct AnimatedStroke: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var samples: [StrokeSample]
    var brush: BrushSettings
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
    var fills: [CanvasFill]? = nil
    var strokes: [AnimatedStroke] = []

    var resolvedImageScale: Double {
        min(8, max(0.1, imageScale ?? 1))
    }

    var resolvedImageOffset: CGPoint {
        CGPoint(x: imageOffsetX ?? 0, y: imageOffsetY ?? 0)
    }
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
