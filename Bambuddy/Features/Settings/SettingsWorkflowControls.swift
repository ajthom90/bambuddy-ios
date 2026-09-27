import SwiftUI
import UIKit

/// Compact numeric input for values that live inside JSON-string settings (or anywhere a
/// key-bound `SettingsNumberField` doesn't fit). Commits on return or when focus leaves;
/// values are clamped to `range`. With `allowsEmpty`, clearing the field commits `nil`.
struct SettingsWorkflowNumberInput: View {
    let value: Double?
    var placeholder: String = ""
    var range: ClosedRange<Double>
    var integer = true
    var unit: String?
    var allowsEmpty = false
    var width: CGFloat = 64
    let onCommit: (Double?) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $draft)
                .keyboardType(integer ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .onSubmit(commit)
                .frame(width: width)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .background(.fill.tertiary, in: .rect(cornerRadius: 6))
            if let unit {
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 22, alignment: .leading)
            }
        }
        .onAppear(perform: sync)
        .onChange(of: value) { _, _ in if !focused { sync() } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func sync() {
        draft = value.map { SettingsNumberField.format($0, integer: integer) } ?? ""
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty {
            if allowsEmpty {
                if value != nil { onCommit(nil) }
            } else {
                sync()
            }
            return
        }
        guard var number = Double(trimmed), number.isFinite else { sync(); return }
        if integer { number = number.rounded() }
        number = min(max(number, range.lowerBound), range.upperBound)
        draft = SettingsNumberField.format(number, integer: integer)
        if number != value { onCommit(number) }
    }
}

/// Adds a "Done" button above the keyboard (number pads have no return key) and lets
/// scrolling dismiss the keyboard. Apply once per page.
struct SettingsWorkflowKeyboardDone: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .fontWeight(.semibold)
                }
            }
    }
}
