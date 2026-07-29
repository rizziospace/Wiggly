import SwiftUI

struct BrushGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Create a brush") {
                    Label("Open Brush Studio and choose the closest built-in engine.", systemImage: "1.circle.fill")
                    Label("Tune stroke, motion, and Apple Pencil dynamics while watching the live preview.", systemImage: "2.circle.fill")
                    Label("Give it a name, randomize or enter a deterministic seed, then tap Save Preset.", systemImage: "3.circle.fill")
                }
                Section("Loop-safe motion") {
                    Text("Wiggly evaluates every animation at a normalized phase from 0 to 1. Motion uses whole loop cycles, so the end returns to the beginning without adding a duplicate export frame.")
                }
                Section("Brush engines") {
                    GuideRow(title: "Wiggle Line", detail: "Moves points perpendicular to the stroke with a traveling sine wave.")
                    GuideRow(title: "Jitter Pencil", detail: "Layers seeded, rotating offsets for a rough graphite edge.")
                    GuideRow(title: "Pulse Marker", detail: "Changes width rhythmically while preserving the original path.")
                    GuideRow(title: "Scatter Dots", detail: "Places seeded particles that orbit each sampled point.")
                }
                Section("Apple Pencil") {
                    Text("Pressure can drive width and opacity. Tilt and azimuth are stored in every sample, ready for richer kernels as the engine grows.")
                }
            }
            .navigationTitle("Brush Guide")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

private struct GuideRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
