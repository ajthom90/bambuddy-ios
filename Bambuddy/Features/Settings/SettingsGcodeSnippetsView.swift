import SwiftUI

/// Settings → G-code Snippets: start/end g-code injected into queued prints, per printer model
/// (stored in the `gcode_snippets` setting as a JSON object keyed by model).
struct SettingsGcodeSnippetsView: View {
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printerStore

    private let key = "gcode_snippets"

    @State private var editing: SettingsGcodeEditTarget?
    @State private var pendingRemoval: String?
    @State private var showAddModel = false
    @State private var newModelName = ""

    private var snippets: [String: SettingsGcodeSnippet] { SettingsGcodeSnippets.parse(store.string(key)) }

    /// Models of the configured printers.
    private var printerModels: Set<String> {
        Set(printerStore.printers.compactMap { $0.model?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Printer models plus any model that already has snippets saved.
    private var models: [String] {
        printerModels.union(snippets.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.hasLoaded {
                list
            } else if let error = store.loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Settings", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await store.load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("G-code Snippets")
        .toolbar {
            if store.isSaving {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
            if store.canEdit, store.hasLoaded {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Model", systemImage: "plus") {
                        newModelName = ""
                        showAddModel = true
                    }
                }
            }
        }
        .task {
            if !store.hasLoaded, !store.isLoading { await store.load() }
            if printerStore.printers.isEmpty, !printerStore.isLoading { await printerStore.refresh() }
        }
        .sheet(item: $editing) { target in
            SettingsGcodeEditorSheet(model: target.model, snippet: snippets[target.model] ?? SettingsGcodeSnippet(),
                                     readOnly: !store.canEdit) { updated in
                await save(model: target.model, snippet: updated)
            }
        }
        .confirm("Remove snippets for \(pendingRemoval ?? "")?",
                 isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                 message: "Queued prints for this model will no longer have g-code injected.",
                 action: "Remove") {
            if let model = pendingRemoval {
                Task { await save(model: model, snippet: SettingsGcodeSnippet()) }
            }
        }
        .alert("Add Printer Model", isPresented: $showAddModel) {
            TextField("Model (e.g. P1S)", text: $newModelName)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                let model = newModelName.trimmingCharacters(in: .whitespaces)
                if !model.isEmpty { editing = SettingsGcodeEditTarget(model: model) }
            }
        } message: {
            Text("Enter the model name exactly as the printer reports it.")
        }
        .alert("Couldn't Save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.saveError ?? "") }
    }

    private var list: some View {
        List {
            Section {
            } footer: {
                Text("Custom g-code added to the start and/or end of queued prints, for automation add-ons such as plate changers or auto-ejectors. It is only injected when \"Inject G-code\" is turned on for a queue item.")
            }
            if models.isEmpty {
                Section {
                    ContentUnavailableView("No Printers", systemImage: "printer",
                                           description: Text("Add a printer, or add a model manually, to configure g-code snippets."))
                }
            } else {
                Section("Printer Models") {
                    ForEach(models, id: \.self) { model in
                        row(model)
                    }
                }
            }
        }
        .refreshable {
            await store.load()
            await printerStore.refresh()
        }
    }

    private func row(_ model: String) -> some View {
        let snippet = snippets[model]
        let configured = !(snippet?.isEmpty ?? true)
        return Button {
            editing = SettingsGcodeEditTarget(model: model)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(summary(snippet))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !printerModels.contains(model) {
                        Text("No printer of this model")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if configured { StatusBadge(text: "Configured", color: .green) }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if configured, store.canEdit {
                Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = model }
            }
        }
        .contextMenu {
            Button(store.canEdit ? "Edit" : "View", systemImage: store.canEdit ? "pencil" : "eye") {
                editing = SettingsGcodeEditTarget(model: model)
            }
            if configured, store.canEdit {
                Button("Remove", systemImage: "trash", role: .destructive) { pendingRemoval = model }
            }
        }
    }

    private func summary(_ snippet: SettingsGcodeSnippet?) -> String {
        guard let snippet, !snippet.isEmpty else { return "No snippets" }
        func count(_ text: String) -> Int {
            text.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        }
        let start = count(snippet.startGcode), end = count(snippet.endGcode)
        func lines(_ n: Int) -> String { n == 1 ? "1 line" : "\(n) lines" }
        return "Start: \(start == 0 ? "none" : lines(start)) · End: \(end == 0 ? "none" : lines(end))"
    }

    @discardableResult
    private func save(model: String, snippet: SettingsGcodeSnippet) async -> Bool {
        var next = snippets
        next[model] = snippet.isEmpty ? nil : snippet
        return await store.save([key: .string(SettingsGcodeSnippets.serialize(next))])
    }
}

private struct SettingsGcodeEditTarget: Identifiable {
    let model: String
    var id: String { model }
}

/// Sheet with monospaced editors for a model's start and end g-code.
private struct SettingsGcodeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: String
    let original: SettingsGcodeSnippet
    let readOnly: Bool
    let onSave: (SettingsGcodeSnippet) async -> Bool

    @State private var start: String
    @State private var end: String
    @State private var saving = false

    init(model: String, snippet: SettingsGcodeSnippet, readOnly: Bool, onSave: @escaping (SettingsGcodeSnippet) async -> Bool) {
        self.model = model
        self.original = snippet
        self.readOnly = readOnly
        self.onSave = onSave
        _start = State(initialValue: snippet.startGcode)
        _end = State(initialValue: snippet.endGcode)
    }

    private var hasChanges: Bool { start != original.startGcode || end != original.endGcode }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    editor($start, placeholder: "G-code run before the print starts")
                } header: {
                    Text("Start G-code")
                } footer: {
                    Text("Inserted before the print's own start sequence.")
                }
                Section {
                    editor($end, placeholder: "G-code run after the print ends")
                } header: {
                    Text("End G-code")
                } footer: {
                    Text("Appended after the print finishes. Leave both empty to remove the snippets for \(model).")
                }
            }
            .navigationTitle(model)
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readOnly ? "Done" : "Cancel") { dismiss() }
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                        } else {
                            Button("Save") {
                                saving = true
                                Task {
                                    let ok = await onSave(SettingsGcodeSnippet(startGcode: start, endGcode: end))
                                    saving = false
                                    if ok { dismiss() }
                                }
                            }
                            .disabled(!hasChanges)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges && !readOnly)
        }
    }

    private func editor(_ text: Binding<String>, placeholder: String) -> some View {
        TextEditor(text: text)
            .font(.system(.callout, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(minHeight: 160)
            .disabled(readOnly)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }
}
