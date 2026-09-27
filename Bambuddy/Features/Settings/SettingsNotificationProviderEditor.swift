import SwiftUI

/// Sheet for adding or editing a notification provider.
struct SettingsNotificationProviderEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss

    let provider: SettingsNotificationProvider?
    var onSaved: (SettingsNotificationProvider) -> Void

    @State private var draft: SettingsNotificationProviderDraft
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var testResult: SettingsNotificationTestResult?
    @State private var errorMessage: String?

    init(provider: SettingsNotificationProvider?, onSaved: @escaping (SettingsNotificationProvider) -> Void) {
        self.provider = provider
        self.onSaved = onSaved
        _draft = State(initialValue: provider.map(SettingsNotificationProviderDraft.init(provider:)) ?? SettingsNotificationProviderDraft())
    }

    private var isEditing: Bool { provider != nil }
    private var canEdit: Bool { session.can(isEditing ? "notifications:update" : "notifications:create") }
    private var canTestConfig: Bool { session.can("notifications:create") }

    var body: some View {
        NavigationStack {
            Form {
                basicsSection
                configSection
                testSection
                printerSection
                scheduleSection
                eventsSections
                ntfyPrioritySection
            }
            .disabled(isSaving || !canEdit)
            .navigationTitle(isEditing ? "Edit Provider" : "New Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(isEditing ? "Save" : "Add", role: .confirm) { Task { await save() } }
                            .disabled(!canEdit || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .alert("Couldn't Save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onChange(of: draft.config) { _, _ in testResult = nil }
        }
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: Sections

    private var basicsSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("e.g. My Phone"))
            Picker("Type", selection: Binding(get: { draft.providerType }, set: { newValue in
                guard newValue != draft.providerType else { return }
                draft.providerType = newValue
                draft.config = [:]
                draft.extraConfig = [:]
                testResult = nil
            })) {
                ForEach(SettingsNotificationProviderKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.systemImage).tag(kind.rawValue)
                }
                if draft.kind == nil { Text(draft.providerType).tag(draft.providerType) }
            }
            .disabled(isEditing)
            Toggle("Enabled", isOn: $draft.enabled)
        } footer: {
            if let kind = draft.kind {
                Text(kind.summary + (isEditing ? " The type can't be changed after the provider is created." : ""))
            }
        }
    }

    @ViewBuilder
    private var configSection: some View {
        if let kind = draft.kind {
            Section {
                ForEach(kind.fields.filter { $0.isVisible(draft.config) }) { field in
                    SettingsNotificationConfigFieldRow(field: field, value: configBinding(field))
                }
            } header: {
                Text("Connection")
            } footer: {
                if kind == .homeassistant {
                    Text("Uses the Home Assistant URL and token from Settings › Network.")
                } else if kind.fields.contains(where: \.required) {
                    Text("Fields marked with * are required.")
                }
            }
        }
    }

    @ViewBuilder
    private var testSection: some View {
        if canTestConfig {
            Section {
                Button {
                    Task { await testConfig() }
                } label: {
                    HStack {
                        Label("Send Test Notification", systemImage: "paperplane")
                        Spacer()
                        if isTesting { ProgressView() }
                    }
                }
                .disabled(isTesting || draft.configValidationError != nil)
                if let testResult {
                    SettingsTestResultLabel(success: testResult.success,
                                            message: testResult.message ?? (testResult.success ? "Test notification sent." : "The test failed."))
                }
            } footer: {
                if let problem = draft.configValidationError {
                    Text(problem)
                } else {
                    Text("Sends a test message with the settings above, before saving.")
                }
            }
        }
    }

    private var printerSection: some View {
        Section {
            Picker("Printer", selection: $draft.printerId) {
                Text("All Printers").tag(Int?.none)
                ForEach(printers.printers) { printer in
                    Text(printer.name).tag(Int?.some(printer.id))
                }
                if let id = draft.printerId, printers.printer(id) == nil {
                    Text("Printer \(id)").tag(Int?.some(id))
                }
            }
        } footer: {
            Text("Limit printer-related events to one printer, or receive them for all printers.")
        }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            Toggle("Quiet Hours", isOn: $draft.quietHoursEnabled.animation())
            if draft.quietHoursEnabled {
                DatePicker("From", selection: timeBinding(\.quietHoursStart), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: timeBinding(\.quietHoursEnd), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("No notifications are sent through this provider during quiet hours.")
        }
        Section {
            Toggle("Daily Digest", isOn: $draft.dailyDigestEnabled.animation())
            if draft.dailyDigestEnabled {
                DatePicker("Send At", selection: timeBinding(\.dailyDigestTime), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("Also sends a once-a-day summary of everything that was notified.")
        }
    }

    @ViewBuilder
    private var eventsSections: some View {
        ForEach(SettingsNotificationEvent.grouped()) { entry in
            Section {
                ForEach(entry.events) { event in
                    Toggle(isOn: eventBinding(event)) {
                        SettingsLabel(event.title, help: event.help)
                    }
                }
            } header: {
                HStack {
                    Text(entry.group.title)
                    Spacer()
                    let allOn = entry.events.allSatisfy { draft.events[$0.key] ?? false }
                    Button(allOn ? "None" : "All") {
                        for event in entry.events { draft.events[event.key] = !allOn }
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private var ntfyPrioritySection: some View {
        if draft.kind == .ntfy {
            let enabled = SettingsNotificationEvent.all.filter { draft.events[$0.key] ?? false }
            if !enabled.isEmpty {
                Section {
                    ForEach(enabled) { event in
                        Picker(event.title, selection: priorityBinding(event)) {
                            ForEach(SettingsNotificationNtfyPriority.levels, id: \.value) { level in
                                Text(level.label).tag(level.value)
                            }
                        }
                    }
                } header: {
                    Text("ntfy Priority")
                } footer: {
                    Text("Higher priorities can override Do Not Disturb in the ntfy app. Default leaves it to the server.")
                }
            }
        }
    }

    // MARK: Bindings

    private func configBinding(_ field: SettingsNotificationConfigField) -> Binding<String> {
        Binding(
            get: { draft.config[field.key] ?? field.defaultValue },
            set: { draft.config[field.key] = $0 }
        )
    }

    private func eventBinding(_ event: SettingsNotificationEvent) -> Binding<Bool> {
        Binding(get: { draft.events[event.key] ?? false }, set: { draft.events[event.key] = $0 })
    }

    private func priorityBinding(_ event: SettingsNotificationEvent) -> Binding<Int> {
        Binding(
            get: { draft.eventPriorities[event.key] ?? 3 },
            set: { draft.eventPriorities[event.key] = $0 == 3 ? nil : $0 }
        )
    }

    private func timeBinding(_ keyPath: WritableKeyPath<SettingsNotificationProviderDraft, String>) -> Binding<Date> {
        Binding(
            get: { SettingsNotificationProviderDraft.date(fromTime: draft[keyPath: keyPath]) },
            set: { draft[keyPath: keyPath] = SettingsNotificationProviderDraft.time(from: $0) }
        )
    }

    // MARK: Actions

    private func testConfig() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        do {
            testResult = try await session.client.send(.post, "notifications/test-config", body: draft.testBody)
        } catch is CancellationError {
        } catch {
            testResult = SettingsNotificationTestResult(success: false, message: error.localizedDescription)
        }
    }

    private func save() async {
        if let problem = draft.validationError {
            errorMessage = problem
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let saved: SettingsNotificationProvider
            if let provider {
                saved = try await session.client.send(.patch, "notifications/\(provider.id)", body: draft.body(includeType: false))
            } else {
                saved = try await session.client.send(.post, "notifications/", body: draft.body())
            }
            onSaved(saved)
            dismiss()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Config field row

private struct SettingsNotificationConfigFieldRow: View {
    let field: SettingsNotificationConfigField
    @Binding var value: String
    @State private var reveal = false

    private var title: String { field.required ? "\(field.label) *" : field.label }

    var body: some View {
        switch field.style {
        case .choice(let options):
            Picker(selection: $value) {
                ForEach(options, id: \.value) { option in Text(option.label).tag(option.value) }
                if !options.contains(where: { $0.value == value }) { Text(value).tag(value) }
            } label: {
                SettingsLabel(title, help: field.help)
            }
        case .toggle:
            Toggle(isOn: Binding(get: { value.lowercased() != "false" }, set: { value = $0 ? "true" : "false" })) {
                SettingsLabel(title, help: field.help)
            }
        case .multiline:
            VStack(alignment: .leading, spacing: 6) {
                SettingsLabel(title, help: field.help)
                TextField(field.placeholder, text: $value, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.vertical, 2)
        default:
            VStack(alignment: .leading, spacing: 6) {
                SettingsLabel(title, help: field.help)
                HStack {
                    Group {
                        if case .secret = field.style, !reveal {
                            SecureField(field.placeholder, text: $value)
                        } else {
                            TextField(field.placeholder, text: $value)
                        }
                    }
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    if case .secret = field.style {
                        Button {
                            reveal.toggle()
                        } label: {
                            Image(systemName: reveal ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(reveal ? "Hide" : "Show")
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var keyboard: UIKeyboardType {
        switch field.style {
        case .number: .numberPad
        case .url: .URL
        case .email: .emailAddress
        case .phone: .phonePad
        default: .default
        }
    }

    private var contentType: UITextContentType? {
        switch field.style {
        case .email: .emailAddress
        case .url: .URL
        case .phone: .telephoneNumber
        default: nil
        }
    }
}
