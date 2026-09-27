import SwiftUI

/// List of the server's notification message templates.
struct SettingsNotificationTemplatesView: View {
    @Environment(AppSession.self) private var session

    @State private var loader = Loader<[SettingsNotificationTemplate]>()
    @State private var variables: [SettingsNotificationTemplateVariables] = []
    @State private var search = ""
    @State private var editing: SettingsNotificationTemplate?

    var body: some View {
        LoadingContent(loader: loader, retry: load) { templates in
            let filtered = Self.filter(templates, query: search)
            List {
                Section {
                    ForEach(filtered) { template in
                        Button { editing = template } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(template.displayName).font(.body.weight(.medium)).foregroundStyle(.primary)
                                Text(template.titleTemplate ?? "")
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                Text(template.bodyTemplate ?? "")
                                    .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    if !filtered.isEmpty {
                        Text("Placeholders in braces, like {printer}, are replaced with details of the event when a message is sent.")
                    }
                }
            }
            .overlay {
                if templates.isEmpty {
                    ContentUnavailableView("No Templates", systemImage: "text.bubble",
                                           description: Text("The server has no notification templates."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("Message Templates")
        .searchable(text: $search, prompt: "Search templates")
        .task { await load() }
        .sheet(item: $editing) { template in
            SettingsNotificationTemplateEditor(
                template: template,
                variables: variables.first { $0.eventType == template.eventType }?.variables ?? []
            ) { updated in
                guard var list = loader.value, let index = list.firstIndex(where: { $0.id == updated.id }) else { return }
                list[index] = updated
                loader.value = list
            }
        }
    }

    private func load() async {
        let client = session.client
        async let vars: [SettingsNotificationTemplateVariables]? = try? client.get("notification-templates/variables")
        await loader.load { try await client.get("notification-templates/") }
        if let v = await vars { variables = v }
    }

    static func filter(_ templates: [SettingsNotificationTemplate], query: String) -> [SettingsNotificationTemplate] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sorted = templates.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        guard !q.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayName.localizedStandardContains(q)
                || ($0.titleTemplate ?? "").localizedStandardContains(q)
                || $0.eventType.localizedStandardContains(q)
        }
    }
}

// MARK: - Editor

/// Sheet for editing one template, with variable insertion and a live server-rendered preview.
struct SettingsNotificationTemplateEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let template: SettingsNotificationTemplate
    let variables: [String]
    var onSaved: (SettingsNotificationTemplate) -> Void

    @State private var title: String
    @State private var bodyText: String
    /// Last values saved on the server (changes after a reset).
    @State private var savedTitle: String
    @State private var savedBody: String
    @State private var titleSelection: TextSelection?
    @State private var bodySelection: TextSelection?
    @FocusState private var focus: Field?
    @State private var lastFocus: Field = .body
    @State private var preview: SettingsNotificationTemplatePreview?
    @State private var previewError: String?
    @State private var isSaving = false
    @State private var confirmReset = false
    @State private var runner = ActionRunner()

    private enum Field: Hashable { case title, body }

    init(template: SettingsNotificationTemplate, variables: [String], onSaved: @escaping (SettingsNotificationTemplate) -> Void) {
        self.template = template
        self.variables = variables
        self.onSaved = onSaved
        _title = State(initialValue: template.titleTemplate ?? "")
        _bodyText = State(initialValue: template.bodyTemplate ?? "")
        _savedTitle = State(initialValue: template.titleTemplate ?? "")
        _savedBody = State(initialValue: template.bodyTemplate ?? "")
    }

    private var canUpdate: Bool { session.can("notification_templates:update") }
    private var isDirty: Bool { title != savedTitle || bodyText != savedBody }

    private var validationError: String? {
        SettingsNotificationTemplateText.validationError(title: title, body: bodyText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, selection: $titleSelection, axis: .vertical)
                        .focused($focus, equals: .title)
                        .lineLimit(1...3)
                } header: {
                    Text("Title")
                } footer: {
                    Text("\(title.count)/\(SettingsNotificationTemplateText.titleLimit)")
                        .foregroundStyle(title.count > SettingsNotificationTemplateText.titleLimit ? .red : .secondary)
                }

                Section {
                    TextEditor(text: $bodyText, selection: $bodySelection)
                        .focused($focus, equals: .body)
                        .frame(minHeight: 140)
                        .font(.body)
                } header: {
                    Text("Message")
                } footer: {
                    Text("\(bodyText.count)/\(SettingsNotificationTemplateText.bodyLimit)")
                        .foregroundStyle(bodyText.count > SettingsNotificationTemplateText.bodyLimit ? .red : .secondary)
                }

                if !variables.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(variables, id: \.self) { variable in
                                    Button("{\(variable)}") { insert(variable) }
                                        .font(.caption.monospaced())
                                        .buttonStyle(.bordered)
                                        .buttonBorderShape(.capsule)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("Variables")
                    } footer: {
                        Text("Tap a variable to insert it at the cursor.")
                    }
                    .disabled(!canUpdate)
                }

                if session.can("notification_templates:read") {
                    Section {
                        if let previewError {
                            Label(previewError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        } else if let preview {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(preview.title ?? "").font(.headline)
                                Text(preview.body ?? "").font(.subheadline)
                            }
                            .textSelection(.enabled)
                            .padding(.vertical, 2)
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    } header: {
                        Text("Preview")
                    } footer: {
                        Text("Rendered with sample data.")
                    }
                }

                if canUpdate {
                    Section {
                        Button("Reset to Default", role: .destructive) { confirmReset = true }
                    }
                }
            }
            .disabled(isSaving)
            .navigationTitle(template.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                if canUpdate {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Button("Save", role: .confirm) { Task { await save() } }
                                .disabled(!isDirty || validationError != nil)
                        }
                    }
                }
            }
            .onChange(of: focus) { _, newValue in if let newValue { lastFocus = newValue } }
            .task(id: "\(title)\u{1F}\(bodyText)") { await refreshPreview() }
            .confirm("Reset Template?", isPresented: $confirmReset,
                     message: "The title and message go back to the built-in wording. Your changes to this template are lost.",
                     action: "Reset") {
                Task { await reset() }
            }
            .actionAlerts(runner)
        }
        .interactiveDismissDisabled(isDirty)
    }

    private func insert(_ variable: String) {
        let token = "{\(variable)}"
        switch lastFocus {
        case .title:
            let result = SettingsNotificationTemplateText.inserting(token, into: title, selection: Self.range(titleSelection, in: title))
            title = result.text
            titleSelection = TextSelection(insertionPoint: result.cursor)
        case .body:
            let result = SettingsNotificationTemplateText.inserting(token, into: bodyText, selection: Self.range(bodySelection, in: bodyText))
            bodyText = result.text
            bodySelection = TextSelection(insertionPoint: result.cursor)
        }
    }

    private static func range(_ selection: TextSelection?, in text: String) -> Range<String.Index>? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        return range
    }

    private func refreshPreview() async {
        guard session.can("notification_templates:read") else { return }
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(preview == nil ? 0 : 400))
        guard !Task.isCancelled else { return }
        guard !title.isEmpty || !bodyText.isEmpty else {
            preview = SettingsNotificationTemplatePreview(title: "", body: "")
            return
        }
        let request = SettingsNotificationTemplateRequest(eventType: template.eventType, titleTemplate: title, bodyTemplate: bodyText)
        do {
            let result: SettingsNotificationTemplatePreview = try await session.client.send(.post, "notification-templates/preview", body: request)
            guard !Task.isCancelled else { return }
            preview = result
            previewError = nil
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func save() async {
        if let validationError {
            runner.errorMessage = validationError
            return
        }
        isSaving = true
        defer { isSaving = false }
        await runner.run {
            let body = SettingsNotificationTemplateRequest(eventType: nil, titleTemplate: title, bodyTemplate: bodyText)
            let updated: SettingsNotificationTemplate = try await session.client.send(.put, "notification-templates/\(template.id)", body: body)
            onSaved(updated)
            dismiss()
        }
    }

    private func reset() async {
        await runner.run("Template reset") {
            let updated: SettingsNotificationTemplate = try await session.client.send(.post, "notification-templates/\(template.id)/reset")
            title = updated.titleTemplate ?? ""
            bodyText = updated.bodyTemplate ?? ""
            savedTitle = title
            savedBody = bodyText
            onSaved(updated)
        }
    }
}

/// Pure text helpers for the template editor.
enum SettingsNotificationTemplateText {
    static let titleLimit = 200
    static let bodyLimit = 2000

    static func validationError(title: String, body: String) -> String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The title can't be empty." }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "The message can't be empty." }
        if title.count > titleLimit { return "The title can be at most \(titleLimit) characters." }
        if body.count > bodyLimit { return "The message can be at most \(bodyLimit) characters." }
        return nil
    }

    /// Replaces `selection` (or appends when there is none / it no longer fits the text) with `token`.
    static func inserting(_ token: String, into text: String, selection: Range<String.Index>?) -> (text: String, cursor: String.Index) {
        var result = text
        if let selection, selection.lowerBound >= text.startIndex, selection.upperBound <= text.endIndex {
            let offset = text.distance(from: text.startIndex, to: selection.lowerBound)
            result.replaceSubrange(selection, with: token)
            let cursor = result.index(result.startIndex, offsetBy: offset + token.count)
            return (result, cursor)
        }
        result.append(token)
        return (result, result.endIndex)
    }
}
