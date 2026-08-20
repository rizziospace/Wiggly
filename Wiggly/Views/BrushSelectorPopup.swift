import SwiftUI

struct BrushSelectorPopup: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var store: BrushPresetStore
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Brushes")
                .font(.headline)
                .padding(.horizontal, 4)

            ForEach(BrushKind.catalogCases) { kind in
                let selected = editor.selectedBrush.kind == kind
                Button {
                    editor.selectedBrush = store.builtInBrush(default: .preset(kind))
                    store.rememberSelection(editor.selectedBrush)
                    onSelect()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: kind.symbol)
                            .frame(width: 34, height: 34)
                            .foregroundStyle(selected ? .white : .blue)
                            .background(selected ? Color.blue : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                                .font(.subheadline.weight(.semibold))
                            Text(kind == .solidColor
                                ? "Plain one-color brush"
                                : (kind == .particle ? "One moving particle" : "Moving segmented path"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected { Image(systemName: "checkmark").foregroundStyle(.blue) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(Color(white: 0.075))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}
