import SwiftUI

struct ParticleBrushPopup: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: BrushPresetStore
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 38, height: 38)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Particle")
                        .font(.headline)
                    Text("One moving particle on a two-color path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset", action: reset).buttonStyle(.bordered)
                Button("Done") { persist(); onDone() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Divider().overlay(.white.opacity(0.12))

            ParticleBrushPreview(brush: editor.selectedBrush)
                .frame(height: 92)
                .padding(16)

            VStack(spacing: 16) {
                settingRow("Corner Radius", value: particleCornerRadius, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                settingRow("Speed", value: particleSpeed, range: 0...4) { "\(Int(($0 * 100).rounded()))%" }
                settingRow("Length", value: particleLength, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
                settingRow("Delay", value: particleDelay, range: 0...0.9) { "\(Int(($0 * 100).rounded()))%" }
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

    private var particleSpeed: Binding<Double> {
        Binding(get: { editor.selectedBrush.resolvedParticleSpeed }, set: { editor.selectedBrush.particleSpeed = $0 })
    }

    private var particleCornerRadius: Binding<Double> {
        Binding(get: { editor.selectedBrush.resolvedDashCornerRadius }, set: { editor.selectedBrush.dashCornerRadius = $0 })
    }

    private var particleLength: Binding<Double> {
        Binding(get: { editor.selectedBrush.resolvedParticleLength }, set: { editor.selectedBrush.particleLength = $0 })
    }

    private var particleDelay: Binding<Double> {
        Binding(get: { editor.selectedBrush.resolvedParticleDelay }, set: { editor.selectedBrush.particleDelay = $0 })
    }

    private func settingRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            Slider(value: value, in: range).tint(.blue).transaction { $0.animation = nil }
        }
    }

    private func reset() {
        let current = editor.selectedBrush
        var value = BrushSettings.preset(.particle)
        value.id = current.id
        value.color = current.color
        value.secondaryColor = current.secondaryColor
        value.size = current.size
        value.opacity = current.opacity
        editor.selectedBrush = value
    }

    private func persist() {
        store.saveBuiltIn(editor.selectedBrush, defaultName: BrushKind.particle.title)
        store.rememberSelection(editor.selectedBrush)
    }
}

private struct ParticleBrushPreview: View {
    let brush: BrushSettings

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            Canvas { context, size in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let unit = AnimationTiming.phase(at: seconds)
                let thickness = max(12, min(30, brush.size * 0.62))
                let path = CGRect(x: 8, y: size.height / 2 - thickness / 2, width: size.width - 16, height: thickness)
                let radius = thickness * brush.resolvedDashCornerRadius / 2
                context.fill(Path(roundedRect: path, cornerRadius: radius), with: .color(brush.resolvedDashBackgroundColor.swiftUIColor.opacity(brush.opacity)))
                let length = max(thickness * 0.35, thickness * (0.35 + brush.resolvedParticleLength * 4))
                let delay = brush.resolvedParticleDelay
                let activeDuration = max(0.05, 1 - delay)
                let overshoot = path.width > 0 ? min(1, length / path.width) : 0
                let travel = unit < activeDuration
                    ? unit / activeDuration
                    : 1 + (unit - activeDuration) / max(0.05, 1 - activeDuration) * overshoot
                let x = path.minX + CGFloat(travel) * path.width
                let particle = CGRect(x: x - length / 2, y: path.minY, width: length, height: path.height)
                context.fill(Path(roundedRect: particle, cornerRadius: radius), with: .color(brush.color.swiftUIColor.opacity(brush.opacity)))
            }
        }
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.09), lineWidth: 1) }
    }
}
