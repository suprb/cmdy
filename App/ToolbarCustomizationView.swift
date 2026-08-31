import AppKit
import SwiftUI

final class ToolbarCustomizationPanel: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        super.close()
        onClose?()
    }
}

struct ToolbarCustomizationOption: Identifiable, Equatable {
    let id: String
    let label: String
    let symbol: String
    var isSelected: Bool
}

@MainActor
final class ToolbarCustomizationModel: ObservableObject {
    @Published private(set) var options: [ToolbarCustomizationOption]

    private let setSelection: (String, Bool) -> Bool
    private let clearSelection: () -> Bool

    init(
        options: [ToolbarCustomizationOption],
        setSelection: @escaping (String, Bool) -> Bool,
        clearSelection: @escaping () -> Bool
    ) {
        self.options = options
        self.setSelection = setSelection
        self.clearSelection = clearSelection
    }

    func toggle(_ identifier: String) {
        guard let index = options.firstIndex(where: { $0.id == identifier })
        else { return }
        let selected = !options[index].isSelected
        guard setSelection(identifier, selected) else { return }
        options[index].isSelected = selected
    }

    func clear() {
        guard clearSelection() else { return }
        for index in options.indices {
            options[index].isSelected = false
        }
    }

    func synchronize(selectedIdentifiers: Set<String>) {
        var next = options
        for index in next.indices {
            next[index].isSelected = selectedIdentifiers.contains(next[index].id)
        }
        guard next != options else { return }
        options = next
    }
}

struct ToolbarCustomizationView: View {
    @ObservedObject var model: ToolbarCustomizationModel
    let done: () -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 132), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Customize Toolbar")
                    .font(.title2.weight(.semibold))
                Text("Choose the controls to keep in the title bar. Changes appear immediately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.vertical) {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.options) { option in
                        Button {
                            model.toggle(option.id)
                        } label: {
                            VStack(spacing: 7) {
                                Image(systemName: option.symbol)
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundStyle(Color(nsColor: .labelColor)
                                        .opacity(option.isSelected ? 1 : 0.76))
                                    .frame(width: 39, height: 39)
                                    .background {
                                        RoundedRectangle(
                                            cornerRadius: 9,
                                            style: .continuous)
                                            .fill(option.isSelected
                                                ? Color(nsColor:
                                                    .unemphasizedSelectedContentBackgroundColor)
                                                : Color.clear)
                                    }
                                    .overlay {
                                        RoundedRectangle(
                                            cornerRadius: 9,
                                            style: .continuous)
                                            .stroke(option.isSelected
                                                ? Color(nsColor: .separatorColor)
                                                    .opacity(0.7)
                                                : Color.clear,
                                                lineWidth: 0.5)
                                    }
                                Text(option.label)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, minHeight: 72)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor),
                                        lineWidth: 1)
                        }
                        .help(option.label)
                        .accessibilityValue(option.isSelected
                                            ? "In toolbar" : "Not in toolbar")
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 4)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button("Clear Toolbar") { model.clear() }
                    .disabled(!model.options.contains(where: \.isSelected))
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        // Keep a little of the next row in view so the picker reads as a
        // scrollable collection without becoming another full-screen palette.
        .frame(minWidth: 520, minHeight: 380)
    }
}
