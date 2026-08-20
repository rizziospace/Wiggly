import SwiftUI

struct BrushPanelPopup: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: BrushPresetStore
    let onDone: () -> Void

    private let accent = Color(red: 0.56, green: 0.40, blue: 1)

    var body: some View {
        VStack(spacing: 0) {
            header

            HStack(spacing: 0) {
                brushLibrary
                    .frame(width: 238)

                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1)

                inspector
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 620, height: 500)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(red: 0.15, green: 0.15, blue: 0.17))
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 34, y: 18)
        .onDisappear(perform: persist)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Brush Studio")
                .font(.headline)

            Spacer()

            Button {
                reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(BrushPanelSecondaryButtonStyle())

            Button {
                persist()
                onDone()
            } label: {
                Text("Done")
                    .frame(minWidth: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.large)
        }
        .padding(.horizontal, 18)
        .frame(height: 72)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var brushLibrary: some View {
        let brushes: [BrushKind] = [.solidColor, .dashed, .star, .particle, .checker, .goo, .scribbles, .particleCloud, .glitter, .gradient, .faded, .dryOutline, .retro, .outlineFill]
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("BRUSHES")
                    .font(.caption2.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                Text("\(brushes.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.06), in: Capsule())
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(brushes, id: \.self) { kind in
                        brushCard(kind)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: .infinity)

            Label("Changes are saved automatically", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.36))
        }
        .padding(14)
        .background(Color.black.opacity(0.12))
    }

    private func brushCard(_ kind: BrushKind) -> some View {
        let isSelected = editor.selectedBrush.kind == kind
        let brush = isSelected ? editor.selectedBrush : store.builtInBrush(default: .preset(kind))

        return Button {
            select(kind, brush: brush)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text(kind.title)
                        .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 4)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                }

                BrushPanelPreview(brush: brush, accent: accent)
                    .frame(height: 34)
                    .allowsHitTesting(false)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? accent.opacity(0.11) : .white.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.58) : .white.opacity(0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.title) brush")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var inspector: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editor.selectedBrush.kind.title)
                            .font(.title2.bold())
                    }
                    Spacer()
                    Label("Live", systemImage: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.green.opacity(0.1), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 13) {
                    panelEndStyle("Start / End", selection: endStyle)
                    if editor.selectedBrush.kind.supportsGlobalWave {
                        panelSlider("Wave", value: brushWaveAmount, range: 0...100) { "\(Int($0.rounded()))" }
                    }
                    if editor.selectedBrush.kind == .goo {
                        panelSlider("Speed", value: gooSpeed, range: 0...2, display: percent)
                        panelSlider("Thickness", value: gooThickness, range: 0...1, display: percent)
                        panelSlider("Waviness", value: gooWaviness, range: 0...1, display: percent)
                        panelSlider("Wave Length", value: gooWaveLength, range: 0...1, display: percent)
                        panelToggle("Droplets", value: gooDroplets)
                        panelSlider("Start Width", value: startWidth, range: 0.05...2, display: percent)
                        panelSlider("End Width", value: endWidth, range: 0.05...2, display: percent)
                    } else if editor.selectedBrush.kind == .scribbles {
                        panelSlider("Speed", value: scribbleSpeed, range: 0...4, display: percent)
                        panelSlider("Thickness", value: scribbleThickness, range: 0...1, display: percent)
                    } else if editor.selectedBrush.kind == .particleCloud {
                        panelSlider("Speed", value: particleCloudSpeed, range: 0...4, display: percent)
                        panelSlider("Thickness", value: particleCloudThickness, range: 0...1, display: percent)
                        panelSlider("Fall Off", value: particleCloudFallOff, range: 0...1, display: percent)
                        panelSlider("Scale", value: particleCloudScale, range: 0...1, display: percent)
                    } else if editor.selectedBrush.kind == .glitter {
                        panelSlider("Speed", value: glitterSpeed, range: 0...4, display: percent)
                        panelSlider("Density", value: glitterDensity, range: 0.05...1, display: percent)
                        panelSlider("Sparkle", value: sparkleAmount, range: 0...1, display: percent)
                    } else if editor.selectedBrush.kind == .gradient || editor.selectedBrush.kind == .solidColor {
                        if editor.selectedBrush.kind == .gradient {
                            panelSlider("Speed", value: gradientSpeed, range: 0...4, display: percent)
                        } else {
                            panelToggle("Two-color gradient", value: coloringUsesGradient)
                        }
                        if editor.selectedBrush.kind == .gradient || editor.selectedBrush.resolvedColoringUsesGradient {
                            panelToggle("Merge strokes together", value: gradientMerge)
                        }
                    } else if editor.selectedBrush.kind == .retro {
                        panelSlider("Color Cycle", value: gradientSpeed, range: 0...4, display: percent)
                        panelPicker("Colors", selection: trippyColorCount)
                    } else if editor.selectedBrush.kind == .faded {
                        panelSlider("Speed", value: fadedSpeed, range: 0...4, display: percent)
                        panelSlider("Fade", value: fadedAmount, range: 0...1, display: percent)
                        panelSlider("Base Opacity", value: fadedBaseOpacity, range: 0...1, display: percent)
                        panelSlider("Faded Opacity", value: fadedTextureOpacity, range: 0...1, display: percent)
                    } else if editor.selectedBrush.kind == .dryOutline {
                        panelSlider("Speed", value: borderSpeed, range: 0...4, display: percent)
                        panelSlider("Grain", value: textureDensity, range: 0.05...1, display: percent)
                        panelSlider("Roughness", value: textureRoughness, range: 0...1, display: percent)
                        panelSlider("Smoothness", value: brushSmoothness, range: 0...1, display: percent)
                        panelSlider("Start Width", value: startWidth, range: 0.05...2, display: percent)
                        panelSlider("End Width", value: endWidth, range: 0.05...2, display: percent)
                    } else if editor.selectedBrush.kind == .particle {
                        panelSlider("Corner Radius", value: dashCorner, range: 0...1, display: percent)
                        panelSlider("Speed", value: particleSpeed, range: 0...4, display: percent)
                        panelSlider("Length", value: particleLength, range: 0...1, display: percent)
                        panelSlider("Delay", value: particleDelay, range: 0...0.9, display: percent)
                    } else if editor.selectedBrush.kind == .checker {
                        panelSlider("Flow", value: checkerSpeed, range: 0...4, display: percent)
                        panelSlider("Start Width", value: startWidth, range: 0.05...2, display: percent)
                        panelSlider("End Width", value: endWidth, range: 0.05...2, display: percent)
                    } else if editor.selectedBrush.kind == .star {
                        panelSlider("Flow", value: dashSpeed, range: 0...4, display: percent)
                        panelSlider("Size", value: dashLength, range: 0...1, display: percent)
                        panelSlider("Distance", value: dashGap, range: 0...200, display: points)
                        panelSlider("Rotation", value: starRotationSpeed, range: 0...4, display: percent)
                        panelSegmented("Star rotation", selection: starRotationMode)
                        panelToggle("Gradient across layer", value: starGradientAcrossStroke)
                    } else if editor.selectedBrush.kind == .outlineFill {
                        panelSlider("Outline width", value: outlineWidth, range: 0.5...20) { String(format: "%.1f", $0) }
                        panelSlider("Wiggle", value: wobbleAmount, range: 0...1, display: percent)
                        panelSlider("Wiggle speed", value: wobbleSpeed, range: 0...4, display: percent)
                    } else {
                        panelSlider("Corner Radius", value: dashCorner, range: 0...1, display: percent)
                        panelSlider("Speed", value: dashSpeed, range: 0...4, display: percent)
                        panelSlider("Length", value: dashLength, range: 0...1, display: percent)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.07), lineWidth: 1)
                }
            }
            .padding(20)
        }
    }

    private func panelSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text(display(value.wrappedValue))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white.opacity(0.56))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            }
            Slider(value: value, in: range)
                .tint(accent)
                .transaction { $0.animation = nil }
        }
    }

    private func panelToggle(_ title: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
        }
        .tint(accent)
        .toggleStyle(.switch)
        .transaction { $0.animation = nil }
    }

    private func panelSegmented(_ title: String, selection: Binding<StarRotationMode>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
            Picker(title, selection: selection) {
                ForEach(StarRotationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func panelEndStyle(_ title: String, selection: Binding<BrushEndStyle>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
            Picker(title, selection: selection) {
                ForEach(BrushEndStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func panelPicker(_ title: String, selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.72))
            Picker(title, selection: selection) {
                ForEach(2...5, id: \.self) { count in
                    Text("\(count)").tag(count)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var dashCorner: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedDashCornerRadius }, set: { editor.selectedBrush.dashCornerRadius = $0 }) }
    private var dashSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedDashSpeed }, set: { editor.selectedBrush.dashSpeed = $0 }) }
    private var dashLength: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedDashLength }, set: { editor.selectedBrush.dashLength = $0 }) }
    private var dashGap: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedDashGap }, set: { editor.selectedBrush.dashGap = $0 }) }
    private var particleSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedParticleSpeed }, set: { editor.selectedBrush.particleSpeed = $0 }) }
    private var particleLength: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedParticleLength }, set: { editor.selectedBrush.particleLength = $0 }) }
    private var particleDelay: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedParticleDelay }, set: { editor.selectedBrush.particleDelay = $0 }) }
    private var checkerSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedCheckerSpeed }, set: { editor.selectedBrush.checkerSpeed = $0 }) }
    private var gooSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedGooSpeed }, set: { editor.selectedBrush.gooSpeed = $0 }) }
    private var gooThickness: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedGooThickness }, set: { editor.selectedBrush.gooThickness = $0 }) }
    private var gooWaviness: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedGooWaviness }, set: { editor.selectedBrush.gooWaviness = $0 }) }
    private var gooWaveLength: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedGooWaveLength }, set: { editor.selectedBrush.gooWaveLength = $0 }) }
    private var gooDroplets: Binding<Bool> { Binding(get: { editor.selectedBrush.resolvedGooDroplets > 0.01 }, set: { editor.selectedBrush.gooDroplets = $0 ? 1 : 0 }) }
    private var starRotationSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedStarRotationSpeed }, set: { editor.selectedBrush.starRotationSpeed = $0 }) }
    private var starRotationMode: Binding<StarRotationMode> { Binding(get: { editor.selectedBrush.resolvedStarRotationMode }, set: { editor.selectedBrush.starRotationMode = $0 }) }
    private var starGradientAcrossStroke: Binding<Bool> { Binding(get: { editor.selectedBrush.resolvedStarGradientAcrossStroke }, set: { editor.selectedBrush.starGradientAcrossStroke = $0 }) }
    private var scribbleSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedScribbleSpeed }, set: { editor.selectedBrush.scribbleSpeed = $0 }) }
    private var scribbleThickness: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedScribbleThickness }, set: { editor.selectedBrush.scribbleThickness = $0 }) }
    private var particleCloudSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedParticleCloudSpeed }, set: { editor.selectedBrush.particleCloudSpeed = $0 }) }
    private var particleCloudThickness: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedParticleCloudThickness }, set: { editor.selectedBrush.particleCloudThickness = $0 }) }
    private var particleCloudFallOff: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedParticleCloudFallOff }, set: { editor.selectedBrush.particleCloudFallOff = $0 }) }
    private var particleCloudScale: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedParticleCloudScale }, set: { editor.selectedBrush.particleCloudScale = $0 }) }
    private var glitterSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedGlitterSpeed }, set: { editor.selectedBrush.glitterSpeed = $0 }) }
    private var glitterDensity: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedGlitterDensity }, set: { editor.selectedBrush.glitterDensity = $0 }) }
    private var sparkleAmount: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedSparkleAmount }, set: { editor.selectedBrush.sparkleAmount = $0 }) }
    private var gradientSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedGradientSpeed }, set: { editor.selectedBrush.gradientSpeed = $0 }) }
    private var coloringUsesGradient: Binding<Bool> { Binding(get: { editor.selectedBrush.resolvedColoringUsesGradient }, set: { editor.selectedBrush.coloringUsesGradient = $0 }) }
    private var brushWaveAmount: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedWaveAmount }, set: { editor.selectedBrush.waveAmount = $0 }) }
    private var gradientMerge: Binding<Bool> { Binding(get: { editor.selectedBrush.resolvedGradientMergesAcrossStrokes }, set: { editor.selectedBrush.gradientMergesAcrossStrokes = $0 }) }
    private var trippyColorCount: Binding<Int> { Binding(get: { editor.selectedBrush.resolvedTrippyColorCount }, set: { editor.selectedBrush.trippyColorCount = max(2, min(5, $0)) }) }
    private var fadedSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedFadedSpeed }, set: { editor.selectedBrush.fadedSpeed = $0 }) }
    private var fadedAmount: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedFadedAmount }, set: { editor.selectedBrush.fadedAmount = $0 }) }
    private var fadedBaseOpacity: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedFadedBaseOpacity }, set: { editor.selectedBrush.fadedBaseOpacity = $0 }) }
    private var fadedTextureOpacity: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedFadedTextureOpacity }, set: { editor.selectedBrush.fadedTextureOpacity = $0 }) }
    private var borderSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedBorderSpeed }, set: { editor.selectedBrush.borderSpeed = $0 }) }
    private var textureDensity: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedTextureDensity }, set: { editor.selectedBrush.textureDensity = $0 }) }
    private var textureRoughness: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedTextureRoughness }, set: { editor.selectedBrush.textureRoughness = $0 }) }
    private var brushSmoothness: Binding<Double> { Binding(get: { editor.selectedBrush.smoothing }, set: { editor.selectedBrush.smoothing = min(1, max(0, $0)) }) }
    private var startWidth: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedStartWidthScale }, set: { editor.selectedBrush.startWidthScale = $0 }) }
    private var endWidth: Binding<Double> { Binding(get: { editor.selectedBrush.resolvedEndWidthScale }, set: { editor.selectedBrush.endWidthScale = $0 }) }
    private var endStyle: Binding<BrushEndStyle> { Binding(get: { editor.selectedBrush.resolvedEndStyle }, set: { editor.selectedBrush.endStyle = $0 }) }
    private var outlineWidth: Binding<Double> { Binding(get: { editor.selectedBrush.outlineWidth ?? 6 }, set: { editor.selectedBrush.outlineWidth = $0 }) }
    private var wobbleAmount: Binding<Double> { Binding(get: { editor.selectedBrush.wobbleAmount ?? 0.35 }, set: { editor.selectedBrush.wobbleAmount = $0 }) }
    private var wobbleSpeed: Binding<Double> { Binding(get: { editor.selectedBrush.wobbleSpeed ?? 1 }, set: { editor.selectedBrush.wobbleSpeed = $0 }) }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func points(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }

    private func select(_ kind: BrushKind, brush: BrushSettings) {
        guard editor.selectedBrush.kind != kind else { return }
        store.saveBuiltIn(
            editor.selectedBrush,
            defaultName: editor.selectedBrush.kind.title
        )
        editor.selectedBrush = brush
        store.rememberSelection(brush)
    }

    private func reset() {
        let current = editor.selectedBrush
        var reset = BrushSettings.preset(current.kind)
        reset.id = current.id
        editor.selectedBrush = reset
        store.resetBuiltIn(named: current.kind.title)
    }

    private func persist() {
        store.saveBuiltIn(editor.selectedBrush, defaultName: editor.selectedBrush.kind.title)
        store.rememberSelection(editor.selectedBrush)
    }
}

private struct BrushPanelSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background(.white.opacity(configuration.isPressed ? 0.1 : 0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct BrushPanelPreview: View {
    let brush: BrushSettings
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            Canvas { context, size in
                drawPreview(&context, size: size, elapsed: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.24))
                LinearGradient(
                    colors: [accent.opacity(0.06), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.06), lineWidth: 1)
        }
    }

    private func drawPreview(_ context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let thickness = max(12, min(30, brush.size * 0.55))
        let base = CGRect(x: 14, y: size.height / 2 - thickness / 2, width: max(0, size.width - 28), height: thickness)

        if brush.kind == .gradient || brush.kind == .solidColor {
            let speed = brush.kind == .solidColor ? 0 : brush.resolvedGradientSpeed
            let flow = speed < 0.01
                ? 0
                : Foundation.sin(elapsed * speed * 1.6) * 0.28
            let stops = (0..<9).map { index -> Gradient.Stop in
                let location = Double(index) / 8
                let blend = min(1, max(0, location + flow))
                return Gradient.Stop(
                    color: previewMixedColor(
                        brush.color,
                        brush.kind == .solidColor && !brush.resolvedColoringUsesGradient ? brush.color : brush.resolvedSecondaryColor,
                        amount: blend
                    ).swiftUIColor.opacity(brush.opacity),
                    location: location
                )
            }
            var previewPath = Path()
            previewPath.move(to: CGPoint(x: base.minX, y: size.height / 2 + 2))
            previewPath.addCurve(
                to: CGPoint(x: base.maxX, y: size.height / 2 - 1),
                control1: CGPoint(x: base.minX + base.width * 0.28, y: size.height / 2 - 7),
                control2: CGPoint(x: base.minX + base.width * 0.68, y: size.height / 2 + 7)
            )
            context.stroke(
                previewPath,
                with: .linearGradient(
                    Gradient(stops: stops),
                    startPoint: CGPoint(x: base.minX, y: size.height / 2),
                    endPoint: CGPoint(x: base.maxX, y: size.height / 2)
                ),
                style: StrokeStyle(
                    lineWidth: thickness * 0.72,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            return
        }

        if brush.kind == .dryOutline {
            func inkPoint(_ progress: Double) -> CGPoint {
                CGPoint(
                    x: base.minX + progress * base.width,
                    y: size.height / 2
                        + Foundation.sin(progress * Double.pi * 2) * thickness * 0.11
                )
            }

            let coreWidth = thickness * 0.62
            var core = Path()
            for index in 0...36 {
                let progress = Double(index) / 36
                let point = inkPoint(progress)
                if index == 0 { core.move(to: point) } else { core.addLine(to: point) }
            }
            context.stroke(
                core,
                with: .color(brush.color.swiftUIColor.opacity(brush.opacity)),
                style: StrokeStyle(lineWidth: coreWidth, lineCap: .round, lineJoin: .round)
            )

            let speed = brush.resolvedBorderSpeed
            let frame = speed < 0.01
                ? 0
                : Int(Foundation.floor(elapsed * (2.5 + speed * 2.5)))
            let density = brush.resolvedTextureDensity
            let roughness = brush.resolvedTextureRoughness
            let grainCount = max(24, Int((42 + density * 76).rounded()))
            var edge = Path()
            for index in 0..<grainCount {
                let key = index * 139 + frame * 7_919
                let progress = min(
                    1,
                    max(0, (Double(index) + (previewNoise(key + 17) + 1) * 0.24) / Double(grainCount))
                )
                let point = inkPoint(progress)
                let slope = Foundation.cos(progress * Double.pi * 2)
                    * Double.pi * 2 * thickness * 0.11 / max(1, base.width)
                let normalLength = Foundation.sqrt(1 + slope * slope)
                let normal = CGPoint(x: -slope / normalLength, y: 1 / normalLength)
                let side = previewNoise(key + 43) < 0 ? -1.0 : 1.0
                let sizeNoise = (previewNoise(key + 71) + 1) / 2
                let diameter = max(0.45, thickness * (0.018 + roughness * (0.018 + sizeNoise * 0.042)))
                let distance = coreWidth / 2 + diameter * (0.04 + sizeNoise * 0.18)
                let center = CGPoint(
                    x: point.x + normal.x * side * distance,
                    y: point.y + normal.y * side * distance
                )
                edge.addEllipse(in: CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                ))
            }
            context.fill(
                edge,
                with: .color(brush.color.swiftUIColor.opacity(brush.opacity * 0.88))
            )
            return
        }

        if brush.kind == .faded {
            func fadedPoint(_ progress: Double) -> CGPoint {
                CGPoint(
                    x: base.minX + progress * base.width,
                    y: size.height / 2
                        + Foundation.sin(progress * Double.pi * 2) * thickness * 0.16
                )
            }

            var strokePath = Path()
            for index in 0...36 {
                let progress = Double(index) / 36
                let point = fadedPoint(progress)
                if index == 0 { strokePath.move(to: point) } else { strokePath.addLine(to: point) }
            }
            let strokeStyle = StrokeStyle(
                lineWidth: thickness * 0.72,
                lineCap: .round,
                lineJoin: .round
            )
            if brush.resolvedFadedBaseOpacity > 0.001 {
                context.stroke(
                    strokePath,
                    with: .color(brush.resolvedFadedBaseColor.swiftUIColor.opacity(
                        brush.opacity * brush.resolvedFadedBaseOpacity
                    )),
                    style: strokeStyle
                )
            }

            context.drawLayer { fadedContext in
                fadedContext.stroke(
                    strokePath,
                    with: .color(brush.color.swiftUIColor.opacity(
                        brush.opacity * brush.resolvedFadedTextureOpacity
                    )),
                    style: strokeStyle
                )

            let speed = brush.resolvedFadedSpeed
            let frameCount = speed < 0.01 ? 1 : max(4, Int((5 + speed * 5).rounded()))
            let frameIndex = speed < 0.01
                ? 0
                : min(
                    frameCount - 1,
                    Int(Foundation.floor(
                        AnimationTiming.phase(at: elapsed) * Double(frameCount)
                    ))
                )
            let strength = brush.resolvedFadedAmount
                fadedContext.blendMode = .destinationOut
                let groupCount = max(2, Int((2 + strength * 3.2).rounded()))
                for group in 0..<groupCount {
                    let groupSeed = frameIndex * 10_007 + group * 997
                    let groupCenter = (previewNoise(groupSeed + 11) + 1) / 2
                    let groupLength = 0.12
                        + (previewNoise(groupSeed + 29) + 1) * 0.10
                    let fragmentCount = Int((15 + strength * 36).rounded())
                    for fragment in 0..<fragmentCount {
                        let key = groupSeed + fragment * 83
                        let along = (previewNoise(key + 41) + 1) / 2
                        let across = previewNoise(key + 67)
                        let centerProgress = min(
                            1,
                            max(0, groupCenter + (along - 0.5) * groupLength)
                        )
                        let fragmentLength = 0.010
                            + (previewNoise(key + 89) + 1) * 0.026
                        let start = max(0, centerProgress - fragmentLength / 2)
                        let end = min(1, centerProgress + fragmentLength / 2)
                        var startPoint = fadedPoint(start)
                        var endPoint = fadedPoint(end)
                        let offset = across * thickness * 0.30
                        startPoint.y += offset
                        endPoint.y += offset + previewNoise(key + 107) * thickness * 0.035
                        var shard = Path()
                        shard.move(to: startPoint)
                        shard.addLine(to: endPoint)
                        let widthNoise = (previewNoise(key + 131) + 1) / 2
                        fadedContext.stroke(
                            shard,
                            with: .color(.white.opacity(0.6 + strength * 0.4)),
                            style: StrokeStyle(
                                lineWidth: max(0.6, thickness * (0.025 + widthNoise * 0.13)),
                                lineCap: .butt,
                                lineJoin: .bevel
                            )
                        )
                    }

                }
                fadedContext.blendMode = .normal
            }
            return
        }

        if brush.kind == .glitter {
            context.fill(
                Path(roundedRect: base, cornerRadius: thickness / 2),
                with: .color(brush.resolvedSecondaryColor.swiftUIColor.opacity(brush.opacity))
            )
            let grainCount = Int((38 + brush.resolvedGlitterDensity * 82).rounded())
            let speed = brush.resolvedGlitterSpeed
            for index in 0..<grainCount {
                let randomX = (previewNoise(index * 83 + 7) + 1) / 2
                let randomY = (previewNoise(index * 149 + 19) + 1) / 2
                let phaseOffset = (previewNoise(index * 211 + 31) + 1) * Double.pi
                let cycles = max(1, Int((speed * (1.2 + randomY * 1.8)).rounded()))
                let twinkle = speed < 0.01
                    ? randomX
                    : 0.5 + 0.5 * Foundation.sin(
                        elapsed * speed * 2.2 + Double(cycles) * 0.35 + phaseOffset
                    )
                let particleSize = max(0.8, thickness * (0.035 + randomY * 0.08))
                let center = CGPoint(
                    x: base.minX + randomX * base.width,
                    y: base.minY + 2 + randomY * max(0, base.height - 4)
                )
                let isSparkle = randomX < 0.05 + brush.resolvedSparkleAmount * 0.24
                let particlePath: Path
                if isSparkle {
                    var diamond = Path()
                    diamond.move(to: CGPoint(x: center.x, y: center.y - particleSize))
                    diamond.addLine(to: CGPoint(x: center.x + particleSize * 0.72, y: center.y))
                    diamond.addLine(to: CGPoint(x: center.x, y: center.y + particleSize))
                    diamond.addLine(to: CGPoint(x: center.x - particleSize * 0.72, y: center.y))
                    diamond.closeSubpath()
                    particlePath = diamond
                } else {
                    particlePath = Path(ellipseIn: CGRect(
                        x: center.x - particleSize / 2,
                        y: center.y - particleSize / 2,
                        width: particleSize,
                        height: particleSize
                    ))
                }
                context.fill(
                    particlePath,
                    with: .color(brush.color.swiftUIColor.opacity(brush.opacity * (0.2 + twinkle * 0.8)))
                )
            }
            return
        }

        if brush.kind == .goo {
            var gooPath = Path()
            let waveFrequency = 0.35 + (1 - brush.resolvedGooWaveLength) * 1.8
            let coreWidth = thickness * (0.12 + brush.resolvedGooThickness * 0.88)
            for index in 0...28 {
                let progress = Double(index) / 28
                let wave = Foundation.sin(progress * waveFrequency * Double.pi * 2 + elapsed * brush.resolvedGooSpeed * 2.2)
                let point = CGPoint(
                    x: base.minX + progress * base.width,
                    y: size.height / 2 + wave * brush.resolvedGooWaviness * thickness * 0.25
                )
                if index == 0 { gooPath.move(to: point) } else { gooPath.addLine(to: point) }
            }
            context.stroke(
                gooPath,
                with: .color(brush.color.swiftUIColor.opacity(brush.opacity)),
                style: StrokeStyle(lineWidth: coreWidth, lineCap: .round, lineJoin: .round)
            )
            var texture = Path()
            for index in 0...28 {
                let progress = Double(index) / 28
                let ripple = Foundation.sin(progress * 10 * Double.pi * 2 - elapsed * brush.resolvedGooSpeed * 3)
                let point = CGPoint(
                    x: base.minX + progress * base.width,
                    y: size.height / 2 + ripple * coreWidth * 0.32
                )
                if index == 0 { texture.move(to: point) } else { texture.addLine(to: point) }
            }
            context.stroke(texture, with: .color(brush.color.swiftUIColor.opacity(brush.opacity * 0.18)), style: StrokeStyle(lineWidth: max(0.5, coreWidth * 0.16), lineCap: .round))

            for index in 0..<8 {
                let progress = Double(index + 1) / 9
                let pulse = 0.5 + 0.5 * Foundation.sin(elapsed * brush.resolvedGooSpeed * 2 + progress * 14)
                let point = CGPoint(
                    x: base.minX + progress * base.width,
                    y: size.height / 2 + Foundation.sin(progress * waveFrequency * Double.pi * 2 + elapsed * brush.resolvedGooSpeed * 2.2) * brush.resolvedGooWaviness * thickness * 0.25
                )
                let end = CGPoint(x: point.x, y: point.y - coreWidth * (0.25 + pulse * 1.4))
                let dropSize = max(1.2, coreWidth * (0.16 + pulse * 0.32))
                context.fill(Path(ellipseIn: CGRect(x: end.x - dropSize / 2, y: end.y - dropSize / 2, width: dropSize, height: dropSize)), with: .color(brush.color.swiftUIColor.opacity(brush.opacity * (0.4 + pulse * 0.3))))
            }
            return
        }

        if brush.kind == .scribbles {
            let speed = brush.resolvedScribbleSpeed
            let time = elapsed * speed * 6
            let step = Int(Foundation.floor(time))
            let local = time - Foundation.floor(time)
            let rawBlend = min(1, max(0, (local - 0.70) / 0.30))
            let blend = rawBlend * rawBlend * (3 - 2 * rawBlend)
            let lineWidth = max(0.8, 0.8 + brush.resolvedScribbleThickness * 2.2)

            for lineIndex in 0..<3 {
                var path = Path()
                let baseOffset = Double(lineIndex - 1) * (2.4 + brush.resolvedScribbleThickness * 2)
                for index in 0...30 {
                    let progress = Double(index) / 30
                    let cell = index / 10
                    let current = previewNoise(lineIndex * 10_007 + cell * 97 + step * 1_009)
                    let next = previewNoise(lineIndex * 10_007 + cell * 97 + (step + 1) * 1_009)
                    let glitch = current + (next - current) * blend
                    let point = CGPoint(
                        x: base.minX + progress * base.width,
                        y: size.height / 2 + baseOffset + glitch * 1.25
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(
                    path,
                    with: .color(brush.color.swiftUIColor.opacity(brush.opacity)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
            return
        }

        if brush.kind == .particleCloud {
            let centerWidth = max(0.8, 0.8 + brush.resolvedParticleCloudThickness * 6)
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: base.minX, y: size.height / 2))
            centerLine.addLine(to: CGPoint(x: base.maxX, y: size.height / 2))
            context.stroke(
                centerLine,
                with: .color(brush.color.swiftUIColor.opacity(brush.opacity)),
                style: StrokeStyle(lineWidth: max(0.5, centerWidth * 0.25), lineCap: .round)
            )

            let density = brush.resolvedParticleCloudFallOff
            let scale = brush.resolvedParticleCloudScale
            let nominalDiameter = max(0.65, 3.4 - scale * 2.3)
            let spacing = max(0.35, nominalDiameter * (0.88 - 0.44 * Foundation.sqrt(density)))
            let centerStationCount = min(190, max(2, Int(base.width / spacing) + 1))
            for stationIndex in 0..<centerStationCount {
                let progress = Double(stationIndex) / Double(max(1, centerStationCount - 1))
                for sideIndex in 0..<2 {
                    let index = stationIndex * 2 + sideIndex
                    let side = sideIndex == 0 ? -1.0 : 1.0
                    let randomA = (previewNoise(index * 83 + 5) + 1) / 2
                    let randomB = (previewNoise(index * 149 + 17) + 1) / 2
                    let diameter = nominalDiameter * (0.88 + randomB * 0.34)
                    let edgeOffset = centerWidth * 0.38 + diameter * (0.12 + randomA * 0.16)
                    let center = CGPoint(
                        x: base.minX + progress * base.width,
                        y: size.height / 2 + side * edgeOffset
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - diameter / 2,
                            y: center.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )),
                        with: .color(brush.color.swiftUIColor.opacity(brush.opacity))
                    )
                }
            }

            let particleCount = min(
                80,
                Int((base.width / 100 * density * (34 + scale * 34)).rounded())
            )
            guard particleCount > 0 else { return }
            for index in 0..<particleCount {
                let randomA = (previewNoise(index * 101 + 7) + 1) / 2
                let randomB = (previewNoise(index * 211 + 19) + 1) / 2
                let phaseOffset = (previewNoise(index * 307 + 31) + 1) / 2
                let speed = max(0.03, brush.resolvedParticleCloudSpeed)
                let rawLife = elapsed * speed * (0.7 + randomB * 0.8) + phaseOffset
                let life = rawLife - Foundation.floor(rawLife)
                let fadeProgress = min(1, max(0, (life - 0.68) / 0.22))
                let opacity = 1 - fadeProgress * fadeProgress * (3 - 2 * fadeProgress)
                let side = index.isMultiple(of: 2) ? 1.0 : -1.0
                let travel = 3 + life * (4 + randomB * 6)
                let diameter = max(0.8, (3.8 - scale * 2.6) * (0.72 + randomB * 0.56))
                let center = CGPoint(
                    x: base.minX + randomA * base.width,
                    y: size.height / 2 + side * (centerWidth / 2 + travel)
                )
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: center.x - diameter / 2,
                        y: center.y - diameter / 2,
                        width: diameter,
                        height: diameter
                    )),
                    with: .color(brush.color.swiftUIColor.opacity(brush.opacity * opacity))
                )
            }
            return
        }

        context.fill(Path(roundedRect: base, cornerRadius: thickness * brush.resolvedDashCornerRadius / 2), with: .color(brush.resolvedDashBackgroundColor.swiftUIColor.opacity(brush.opacity)))
        if brush.kind == .star {
            let starSize = min(thickness * 0.8, thickness * (0.5 + brush.resolvedDashLength * 1.4))
            let gap = max(8, min(base.width * 0.5, brush.resolvedDashGap * 0.35))
            let pitch = starSize + gap
            let offset = (elapsed * max(0.08, brush.resolvedDashSpeed) * pitch * 0.22).truncatingRemainder(dividingBy: pitch)
            let outer = starSize / 2
            let inner = outer * 0.48
            let spin = elapsed * Double.pi * 2 * brush.resolvedStarRotationSpeed
            let gradient = Gradient(stops: [
                .init(color: brush.color.swiftUIColor.opacity(brush.opacity), location: 0),
                .init(color: brush.resolvedTertiaryColor.swiftUIColor.opacity(brush.opacity), location: 1)
            ])

            // Star layer on top of the wide strip. Clipped to the strip so
            // stars slide in/out at the ends and never stick past the line.
            var starPaths: [Path] = []
            var starCenters: [CGPoint] = []
            var starIndex = 0
            var x = base.minX - pitch * 2 - offset
            while x < base.maxX + pitch {
                let center = CGPoint(x: x + starSize / 2, y: size.height / 2)
                let baseAngle = brush.resolvedStarRotationMode == .random
                    ? previewNoise(starIndex + 7) * .pi
                    : 0
                let rotation = baseAngle + spin
                var starPath = Path()
                for pointIndex in 0..<10 {
                    let radius = pointIndex.isMultiple(of: 2) ? outer : inner
                    let angle = rotation + Double(pointIndex) * .pi / 5
                    let point = CGPoint(
                        x: center.x + Foundation.cos(angle) * radius,
                        y: center.y + Foundation.sin(angle) * radius
                    )
                    if pointIndex == 0 { starPath.move(to: point) } else { starPath.addLine(to: point) }
                }
                starPath.closeSubpath()
                starPaths.append(starPath)
                starCenters.append(center)
                starIndex += 1
                x += pitch
            }

            context.drawLayer { layer in
                layer.clip(to: Path(base))
                if brush.resolvedStarGradientAcrossStroke {
                    var combined = Path()
                    for starPath in starPaths { combined.addPath(starPath) }
                    layer.clip(to: combined)
                    layer.fill(
                        Path(base),
                        with: .linearGradient(
                            gradient,
                            startPoint: CGPoint(x: base.minX, y: size.height / 2),
                            endPoint: CGPoint(x: base.maxX, y: size.height / 2)
                        )
                    )
                } else {
                    for (index, center) in starCenters.enumerated() {
                        layer.fill(
                            starPaths[index],
                            with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: outer)
                        )
                    }
                }
            }
        } else if brush.kind == .particle {
            let travel = (elapsed * max(0.08, brush.resolvedParticleSpeed) * 0.32).truncatingRemainder(dividingBy: 1)
            let length = max(thickness * 0.55, thickness * (0.6 + brush.resolvedParticleLength * 3.5))
            let particle = CGRect(x: base.minX + travel * (base.width + length) - length, y: base.minY, width: length, height: base.height)
            context.fill(Path(roundedRect: particle, cornerRadius: thickness * brush.resolvedDashCornerRadius / 2), with: .color(brush.color.swiftUIColor.opacity(brush.opacity)))
        } else if brush.kind == .checker {
            let cell = max(2, base.height / 2)
            let period = cell * 2
            let offset = (elapsed * brush.resolvedCheckerSpeed * 0.7 * cell)
                .truncatingRemainder(dividingBy: period)
            let colors = [
                brush.color.swiftUIColor.opacity(brush.opacity),
                brush.resolvedDashBackgroundColor.swiftUIColor.opacity(brush.opacity),
                brush.resolvedTertiaryColor.swiftUIColor.opacity(brush.opacity),
                brush.resolvedQuaternaryColor.swiftUIColor.opacity(brush.opacity)
            ]
            var x = base.minX - period + offset
            var index = -2
            while x < base.maxX + cell {
                for row in 0..<2 {
                    let rect = CGRect(x: x, y: base.minY + CGFloat(row) * cell, width: cell, height: cell)
                    let parity = ((index % 2) + 2) % 2
                    context.fill(Path(rect), with: .color(colors[parity + row * 2]))
                }
                index += 1
                x += cell
            }
        } else {
            let dashWidth = max(thickness * 0.8, thickness * (1 + brush.resolvedDashLength * 3))
            let gap = max(6, min(base.width * 0.45, brush.resolvedDashGap * 0.28))
            let pitch = dashWidth + gap
            let offset = (elapsed * max(0.08, brush.resolvedDashSpeed) * pitch * 0.22).truncatingRemainder(dividingBy: pitch)
            var x = base.minX - pitch - offset
            while x < base.maxX {
                let dash = CGRect(x: x, y: base.minY, width: dashWidth, height: base.height)
                context.fill(Path(roundedRect: dash, cornerRadius: thickness * brush.resolvedDashCornerRadius / 2), with: .color(brush.color.swiftUIColor.opacity(brush.opacity)))
                x += pitch
            }
        }
    }

    private func previewNoise(_ value: Int) -> Double {
        let raw = Foundation.sin(Double(value) * 12.9898 + 78.233) * 43_758.5453
        return (raw - Foundation.floor(raw)) * 2 - 1
    }

    private func previewMixedColor(
        _ first: CodableColor,
        _ second: CodableColor,
        amount: Double
    ) -> CodableColor {
        let blend = min(1, max(0, amount))
        return CodableColor(
            red: first.red + (second.red - first.red) * blend,
            green: first.green + (second.green - first.green) * blend,
            blue: first.blue + (second.blue - first.blue) * blend,
            alpha: first.alpha + (second.alpha - first.alpha) * blend
        )
    }
}
