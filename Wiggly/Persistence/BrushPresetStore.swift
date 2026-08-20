import Combine
import Foundation

@MainActor
final class BrushPresetStore: ObservableObject {
    @Published private(set) var presets: [BrushSettings] = []
    @Published private(set) var builtInOverrides: [String: BrushSettings] = [:]
    @Published private(set) var lastSelectedBrush: BrushSettings?
    private let key = "wiggly.custom-brushes.v1"
    private let overrideKey = "wiggly.builtin-brush-overrides.v1"
    private let selectedBrushKey = "wiggly.last-selected-brush.v1"
    private let coloringMotionMigrationKey = "wiggly.coloring-gradient.v3"
    private let dryOutlineMotionMigrationKey = "wiggly.dry-outline-motion.v2"
    private let legacyKey = "amberwiggle.custom-brushes.v1"
    private let legacyOverrideKey = "amberwiggle.builtin-brush-overrides.v1"
    private let builtInNames: Set<String> = [
        "Solid Coloring",
        "Coloring",
        "Dashed",
        "Star",
        "Particle",
        "Goo",
        "Scribbles",
        "Particles",
        "Glitter",
        "Gradient",
        "Checker",
        "Faded",
        "Grainy Ink"
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: selectedBrushKey),
           let decoded = try? JSONDecoder().decode(BrushSettings.self, from: data),
           decoded.kind.isAvailableInCatalog {
            lastSelectedBrush = decoded
        }
        if let data = UserDefaults.standard.data(forKey: overrideKey)
            ?? UserDefaults.standard.data(forKey: legacyOverrideKey),
           let decoded = try? JSONDecoder().decode([String: BrushSettings].self, from: data) {
            // Discard legacy/corrupted entries where (for example) a Goo
            // brush was accidentally saved under the "Dashed" key.
            builtInOverrides = decoded.filter {
                $0.value.kind.isAvailableInCatalog && $0.key == $0.value.kind.title
            }
        }
        if let data = UserDefaults.standard.data(forKey: key)
            ?? UserDefaults.standard.data(forKey: legacyKey),
           let decoded = try? JSONDecoder().decode([BrushSettings].self, from: data) {
            for brush in decoded where brush.kind.isAvailableInCatalog {
                if builtInNames.contains(brush.name), brush.name == brush.kind.title {
                    builtInOverrides[brush.name] = builtInOverrides[brush.name] ?? brush
                } else if !builtInNames.contains(brush.name),
                          !presets.contains(where: { $0.id == brush.id }) {
                    presets.append(brush)
                }
            }
            persist()
        }

        if lastSelectedBrush == nil {
            lastSelectedBrush = .preset(.dashed)
            if let lastSelectedBrush,
               let data = try? JSONEncoder().encode(lastSelectedBrush) {
                UserDefaults.standard.set(data, forKey: selectedBrushKey)
            }
        }

        if !UserDefaults.standard.bool(forKey: dryOutlineMotionMigrationKey) {
            builtInOverrides.removeValue(forKey: BrushKind.dryOutline.title)
            if lastSelectedBrush?.kind == .dryOutline {
                lastSelectedBrush = .preset(.dryOutline)
                if let lastSelectedBrush,
                   let data = try? JSONEncoder().encode(lastSelectedBrush) {
                    UserDefaults.standard.set(data, forKey: selectedBrushKey)
                }
            }
            UserDefaults.standard.set(true, forKey: dryOutlineMotionMigrationKey)
            persist()
        }

        if !UserDefaults.standard.bool(forKey: coloringMotionMigrationKey) {
            builtInOverrides.removeValue(forKey: "Solid Coloring")
            builtInOverrides.removeValue(forKey: BrushKind.solidColor.title)
            if lastSelectedBrush?.kind == .solidColor {
                lastSelectedBrush = .preset(.solidColor)
            }
            UserDefaults.standard.set(true, forKey: coloringMotionMigrationKey)
            if let lastSelectedBrush,
               let data = try? JSONEncoder().encode(lastSelectedBrush) {
                UserDefaults.standard.set(data, forKey: selectedBrushKey)
            }
            persist()
        }
        persist()
    }

    func save(_ brush: BrushSettings) {
        guard brush.kind.isAvailableInCatalog else { return }
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
        guard let override = builtInOverrides[defaultBrush.kind.title],
              override.kind == defaultBrush.kind else {
            return defaultBrush
        }
        return override
    }

    func saveBuiltIn(_ brush: BrushSettings, defaultName: String) {
        guard brush.kind.isAvailableInCatalog else { return }
        var copy = brush
        let canonicalName = brush.kind.title
        copy.name = canonicalName
        builtInOverrides[canonicalName] = copy
        persist()
    }

    func resetBuiltIn(named defaultName: String) {
        builtInOverrides.removeValue(forKey: defaultName)
        persist()
    }

    @discardableResult
    func duplicate(_ brush: BrushSettings) -> BrushSettings {
        guard brush.kind.isAvailableInCatalog else { return .preset(.dashed) }
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

    func rememberSelection(_ brush: BrushSettings) {
        let selection = brush.kind.isAvailableInCatalog ? brush : .preset(.dashed)
        lastSelectedBrush = selection
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: selectedBrushKey)
        }
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
