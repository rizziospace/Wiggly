import SwiftUI

struct DashedBrushPopup: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: BrushPresetStore
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.12))

            DashBrushPreview(brush: editor.selectedBrush)
                .frame(height: 112)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            VStack(spacing: 17) {
                settingRow(
                    "Corner Radius",
                    value: Binding(
                        get: { editor.selectedBrush.resolvedDashCornerRadius },
                        set: { editor.selectedBrush.dashCornerRadius = $0 }
                    ),
                    range: 0...1,
                    display: { "\(Int(($0 * 100).rounded()))%" }
                )
                settingRow(
                    "Speed",
                    value: Binding(
                        get: { editor.selectedBrush.resolvedDashSpeed },
                        set: { editor.selectedBrush.dashSpeed = $0 }
                    ),
                    range: 0...4,
                    display: { "\(Int(($0 * 100).rounded()))%" }
                )
                settingRow(
                    "Length",
                    value: Binding(
                        get: { editor.selectedBrush.resolvedDashLength },
                        set: { editor.selectedBrush.dashLength = $0 }
                    ),
                    range: 0...1,
                    display: { "\(Int(($0 * 100).rounded()))%" }
                )
                settingRow(
                    "Spacing",
                    value: Binding(
                        get: { editor.selectedBrush.resolvedDashGap },
                        set: { editor.selectedBrush.dashGap = $0 }
                    ),
                    range: 0...160,
                    display: { "\(Int($0.rounded()))" }
                )
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .background(Color(white: 0.075))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onDisappear(perform: persist)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "ellipsis")
                .font(.title3.weight(.bold))
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text("Dashed")
                    .font(.headline)
                Text("Length 0% + radius 100% creates dots")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Reset") { reset() }
                .buttonStyle(.bordered)

            Button("Done") {
                persist()
                onDone()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func settingRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            Slider(value: value, in: range)
                .tint(.blue)
                .transaction { $0.animation = nil }
        }
    }

    private func reset() {
        let current = editor.selectedBrush
        var reset = BrushSettings.preset(.dashed)
        reset.id = current.id
        reset.color = current.color
        reset.secondaryColor = current.secondaryColor
        reset.size = current.size
        reset.opacity = current.opacity
        editor.selectedBrush = reset
    }

    private func persist() {
        store.saveBuiltIn(editor.selectedBrush, defaultName: BrushKind.dashed.title)
        store.rememberSelection(editor.selectedBrush)
    }
}

private struct DashBrushPreview: View {
    let brush: BrushSettings

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            Canvas { context, size in
                let thickness = max(10, min(34, brush.size * 0.62))
                let length = thickness * (1 + brush.resolvedDashLength * 4)
                let gap = max(5, min(90, brush.resolvedDashGap * 0.62))
                let pattern = length + gap
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let normalizedPhase = AnimationTiming.phase(at: seconds)
                let speedCycles = brush.resolvedDashCyclesPerLoop
                let shift = (normalizedPhase * pattern * speedCycles)
                    .truncatingRemainder(dividingBy: pattern)
                let radius = min(thickness, length) * 0.5 * brush.resolvedDashCornerRadius
                let ribbon = CGRect(
                    x: 0,
                    y: size.height / 2 - thickness / 2,
                    width: size.width,
                    height: thickness
                )
                context.fill(
                    Path(roundedRect: ribbon, cornerRadius: thickness / 2),
                    with: .color(brush.resolvedDashBackgroundColor.swiftUIColor.opacity(brush.opacity))
                )
                var x = -pattern + shift
                while x < size.width + pattern {
                    let rect = CGRect(
                        x: x,
                        y: size.height / 2 - thickness / 2,
                        width: length,
                        height: thickness
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: radius),
                        with: .color(brush.color.swiftUIColor.opacity(brush.opacity))
                    )
                    x += pattern
                }
            }
        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
        .clipped()
    }
}

#Preview {
    DashedBrushPopup(
        editor: EditorModel(document: .blank()),
        store: BrushPresetStore(),
        onDone: {}
    )
}
