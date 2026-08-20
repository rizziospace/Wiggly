import SwiftUI

struct BrushGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Dashed brush") {
                    Label("Tap the active brush icon to open its compact settings.", systemImage: "1.circle.fill")
                    Label("Set Length to 0% and Corner Radius to 100% for dots.", systemImage: "2.circle.fill")
                    Label("Lower Corner Radius for square or block-like animated marks.", systemImage: "3.circle.fill")
                }
                Section("Loop-safe motion") {
                    Text("Speed maps to whole animation cycles so canvas playback and exported loops return to the exact starting frame.")
                }
                Section("Apple Pencil") {
                    Text("Size and opacity remain available on the left toolbar. Color remains available in the top toolbar.")
                }
            }
            .navigationTitle("Brush Guide")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
