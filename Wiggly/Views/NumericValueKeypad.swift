import Foundation
import SwiftUI

struct NumericValueButton: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var fractionDigits = 2
    var suffix = ""
    var valueScale = 1.0
    var width: CGFloat? = nil
    var arrowEdge: Edge = .leading
    var onCommit: ((Double) -> Void)? = nil

    @State private var showsKeypad = false

    var body: some View {
        Button {
            showsKeypad = true
        } label: {
            Text(formatted(value * valueScale))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(width: width)
            .background(.black.opacity(0.16), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Set \(title) precisely")
        .popover(isPresented: $showsKeypad, arrowEdge: arrowEdge) {
            CompactNumericKeypad(
                title: title,
                initialValue: value * valueScale,
                range: (range.lowerBound * valueScale)...(range.upperBound * valueScale),
                fractionDigits: fractionDigits,
                suffix: suffix
            ) { newValue in
                if let onCommit {
                    onCommit(newValue / valueScale)
                } else {
                    value = newValue / valueScale
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private func formatted(_ number: Double) -> String {
        var text = String(format: "%.*f", fractionDigits, number)
        if fractionDigits > 0 {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        return text + suffix
    }
}

private struct CompactNumericKeypad: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialValue: Double
    let range: ClosedRange<Double>
    let fractionDigits: Int
    let suffix: String
    let commit: (Double) -> Void

    @State private var input = ""
    @State private var startedTyping = false

    private let rows = [["7", "8", "9"], ["4", "5", "6"], ["1", "2", "3"]]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(format(range.lowerBound))–\(format(range.upperBound))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(input.isEmpty ? "0" : input)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { digit in key(digit) }
                }
            }

            HStack(spacing: 8) {
                if fractionDigits > 0 {
                    key(".")
                } else {
                    Color.clear.frame(width: 60, height: 48)
                }
                key("0")
                Button {
                    if !startedTyping {
                        input = ""
                        startedTyping = true
                    } else if !input.isEmpty {
                        input.removeLast()
                    }
                } label: {
                    Image(systemName: "delete.left.fill")
                        .font(.title3)
                        .frame(width: 60, height: 48)
                }
                .buttonStyle(KeypadButtonStyle())
            }

            HStack(spacing: 10) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Done") {
                    let parsed = Double(input) ?? initialValue
                    commit(min(range.upperBound, max(range.lowerBound, parsed)))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 236)
        .onAppear { input = format(initialValue) }
    }

    private func key(_ character: String) -> some View {
        Button {
            if !startedTyping {
                input = character == "." ? "0." : character
                startedTyping = true
                return
            }
            if character == "." && input.contains(".") { return }
            let fractionalCount = input.split(separator: ".", omittingEmptySubsequences: false).last?.count ?? 0
            if input.contains("."), character != ".", fractionalCount >= fractionDigits { return }
            if input.count < 9 { input.append(character) }
        } label: {
            Text(character)
                .font(.title3.monospacedDigit())
                .frame(width: 60, height: 48)
        }
        .buttonStyle(KeypadButtonStyle())
    }

    private func format(_ number: Double) -> String {
        var text = String(format: "%.*f", fractionDigits, number)
        if fractionDigits > 0 {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        return text
    }
}

private struct KeypadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.14 : 0.075),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

#Preview("Numeric Keypad") {
    CompactNumericKeypad(
        title: "Motion Amount",
        initialValue: 2.8,
        range: 0...100,
        fractionDigits: 1,
        suffix: "",
        commit: { _ in }
    )
}
