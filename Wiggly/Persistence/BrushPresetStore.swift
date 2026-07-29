import Combine
import Foundation

@MainActor
final class BrushPresetStore: ObservableObject {
    @Published private(set) var presets: [BrushSettings] = []
    @Published private(set) var builtInOverrides: [String: BrushSettings] = [:]
    private let key = "wiggly.custom-brushes.v1"
    private let overrideKey = "wiggly.builtin-brush-overrides.v1"
    private let legacyKey = "amberwiggle.custom-brushes.v1"
    private let legacyOverrideKey = "amberwiggle.builtin-brush-overrides.v1"
    private let builtInNames: Set<String> = [
        "Wiggle Line", "Jitter Pencil", "Pulse Marker", "Scatter Dots", "Ghost Trail", "Dashed", "Particle", "Goo", "Scribbles", "Particles", "Glitter", "Gradient", "Polka Dots", "Faded", "Charcoal", "Color Noise",
        "Soft Wiggle", "Charcoal Jitter", "Neon Pulse", "Confetti Dots", "Flow Ribbon"
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: overrideKey)
            ?? UserDefaults.standard.data(forKey: legacyOverrideKey),
           let decoded = try? JSONDecoder().decode([String: BrushSettings].self, from: data) {
            builtInOverrides = decoded
        }
        if let data = UserDefaults.standard.data(forKey: key)
            ?? UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([BrushSettings].self, from: data) {
            for brush in decoded {
                if builtInNames.contains(brush.name) {
                    builtInOverrides[brush.name] = builtInOverrides[brush.name] ?? brush
                } else if !presets.contains(where: { $0.id == brush.id }) {
                    presets.append(brush)
                }
            }
            persist()
        }
    }

    func save(_ brush: BrushSettings) {
        var copy = brush
        if copy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.name = copy.kind.title
        }
        if let index = presets.firstIndex(where: { $0.id == copy.id }) {
            presets[index] = copy
        } else {
            presets.append(copy)
        }
        persist()
    }

    func builtInBrush(default defaultBrush: BrushSettings) -> BrushSettings {
        builtInOverrides[defaultBrush.name] ?? defaultBrush
    }

    func saveBuiltIn(_ brush: BrushSettings, defaultName: String) {
        var copy = brush
        copy.name = defaultName
        builtInOverrides[defaultName] = copy
        persist()
    }

    func resetBuiltIn(named defaultName: String) {
        builtInOverrides.removeValue(forKey: defaultName)
        persist()
    }

    @discardableResult
    func duplicate(_ brush: BrushSettings) -> BrushSettings {
        var copy = brush
        copy.id = UUID()
        copy.name += " Copy"
        presets.append(copy)
        persist()
        return copy
    }

    func delete(_ brush: BrushSettings) {
        presets.removeAll { $0.id == brush.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if let data = try? JSONEncoder().encode(builtInOverrides) {
            UserDefaults.standard.set(data, forKey: overrideKey)
        }
    }
}
