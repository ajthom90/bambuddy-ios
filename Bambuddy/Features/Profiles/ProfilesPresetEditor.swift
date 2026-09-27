import SwiftUI
import UniformTypeIdentifiers

// MARK: - Templates (stored on this device)

struct ProfilesPresetTemplate: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String
    /// "filament", "print" or "printer".
    var type: String
    var settings: [String: JSONValue]
    var showInModal: Bool?

    var kind: ProfilesPresetKind { ProfilesPresetKind(any: type) ?? .filament }
}

enum ProfilesTemplateStorage {
    static let key = "profiles.presetTemplates"

    static func load() -> [ProfilesPresetTemplate] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ProfilesPresetTemplate].self, from: data)) ?? []
    }

    static func save(_ templates: [ProfilesPresetTemplate]) {
        if let data = try? JSONEncoder().encode(templates) { UserDefaults.standard.set(data, forKey: key) }
    }
}

// MARK: - Preset editor (create / duplicate / edit)

struct ProfilesPresetEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let seed: ProfilesEditorSeed
    let allPresets: ProfilesSlicerSettingsResponse
    let onSaved: () async -> Void

    @State private var kind: ProfilesPresetKind
    @State private var baseId: String
    @State private var name: String
    @State private var settings: [String: JSONValue]
    @State private var baseValues: [String: JSONValue] = [:]
    @State private var loadingBase = false
    @State private var fieldDefs: [ProfilesFieldDefinition] = []
    @State private var templates = ProfilesTemplateStorage.load()
    @State private var appliedTemplate: String?
    @State private var showDiff = false
    @State private var showImporter = false
    @State private var showSaveTemplate = false
    @State private var newTemplateName = ""
    @State private var newTemplateDesc = ""
    @State private var showAddField = false
    @State private var newFieldKey = ""
    @State private var runner = ActionRunner()

    init(seed: ProfilesEditorSeed, allPresets: ProfilesSlicerSettingsResponse, onSaved: @escaping () async -> Void) {
        self.seed = seed
        self.allPresets = allPresets
        self.onSaved = onSaved
        _kind = State(initialValue: seed.kind)
        _baseId = State(initialValue: seed.baseId)
        _name = State(initialValue: seed.name)
        _settings = State(initialValue: seed.setting.isEmpty ? ["inherits": ""] : seed.setting)
    }

    private var isEdit: Bool { seed.mode == .edit }
    private var basePresets: [ProfilesSlicerSetting] {
        allPresets.presets(kind).filter { !$0.isUserPreset }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var baseName: String? { allPresets.presets(kind).first { $0.settingId == baseId }?.name }
    private var overrideKeys: [String] { settings.keys.filter { $0 != "inherits" }.sorted() }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (isEdit || !baseId.isEmpty) && session.can("cloud:auth")
    }

    /// Known field definitions plus any other key seen in the base preset or the overrides.
    private var allFields: [ProfilesFieldDefinition] {
        let known = Set(fieldDefs.map(\.key))
        let excluded: Set<String> = ["inherits", "updated_time", "compatible_printers", "compatible_prints"]
        let discovered = Set(baseValues.keys).union(settings.keys).subtracting(known).subtracting(excluded).sorted()
        return fieldDefs + discovered.map { ProfilesFieldDefinition(key: $0, label: ProfilesPresetMeta.humanize($0), type: "text", category: "discovered") }
    }

    private var title: String {
        switch seed.mode {
        case .edit: return "Edit Preset"
        case .duplicate: return "Duplicate Preset"
        case .create, .template: return "New Preset"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(ProfilesPresetKind.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(isEdit)
                    .onChange(of: kind) { _, _ in if !isEdit { baseId = "" } }
                    NavigationLink {
                        ProfilesBasePresetPicker(presets: basePresets, selection: $baseId)
                    } label: {
                        LabeledContent("Base Preset") {
                            Text(baseName ?? (baseId.isEmpty ? "Choose…" : baseId)).lineLimit(1)
                        }
                    }
                    .disabled(isEdit)
                    TextField("Preset Name", text: $name)
                } footer: {
                    if let baseName {
                        HStack(spacing: 4) {
                            Text("Inherits from \(baseName)")
                            if loadingBase { ProgressView().controlSize(.mini) }
                        }
                    } else if !isEdit {
                        Text("Custom presets inherit from a built-in preset and store only the values you change.")
                    }
                }

                templatesSection

                if !fieldDefs.isEmpty {
                    Section("Common Settings") {
                        ForEach(fieldDefs.prefix(10)) { field in fieldRow(field) }
                    }
                }

                Section {
                    if overrideKeys.isEmpty {
                        Text("No overrides yet. Values not listed here come from the base preset.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(overrideKeys, id: \.self) { key in
                        let def = fieldDefs.first { $0.key == key } ?? ProfilesFieldDefinition(key: key, label: key, type: "text")
                        fieldRow(def, showKey: true)
                            .swipeActions { Button("Remove", systemImage: "minus.circle", role: .destructive) { settings[key] = nil } }
                    }
                } header: {
                    Text("Overrides (\(overrideKeys.count))")
                }

                Section {
                    NavigationLink {
                        ProfilesAllFieldsView(fields: allFields, settings: $settings, baseValues: baseValues)
                    } label: {
                        Label("All Settings (\(allFields.count))", systemImage: "list.bullet")
                    }
                    Button("Add Custom Field", systemImage: "plus") { newFieldKey = ""; showAddField = true }
                    NavigationLink {
                        ProfilesJSONEditorView(settings: $settings)
                    } label: {
                        Label("Edit as JSON", systemImage: "curlybraces")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(!canSave || runner.isRunning)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Compare with Base", systemImage: "arrow.left.arrow.right") { showDiff = true }.disabled(baseId.isEmpty)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Import JSON", systemImage: "square.and.arrow.down") { showImporter = true }
                }
                ToolbarItem(placement: .secondaryAction) {
                    ShareLink(item: ProfilesJSONFile(fileName: name.isEmpty ? "preset" : name, value: .object([
                        "name": .string(name), "type": .string(kind.apiType), "base_id": .string(baseId), "setting": .object(settings),
                    ])), preview: SharePreview("\(name.isEmpty ? "preset" : name).json")) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .overlay { if runner.isRunning { ProgressView().controlSize(.large) } }
            .interactiveDismissDisabled(runner.isRunning)
        }
        .task(id: kind) { await loadFields() }
        .task(id: baseId) { await loadBase() }
        .onChange(of: baseId) { _, _ in
            if !isEdit, let baseName { settings["inherits"] = .string(baseName) }
        }
        .sheet(isPresented: $showDiff) {
            ProfilesDiffView(left: baseValues, right: settings,
                             leftLabel: "Base: \(baseName ?? baseId)", rightLabel: "This preset: \(name.isEmpty ? "New preset" : name)")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            importJSON(result)
        }
        .alert("Save as Template", isPresented: $showSaveTemplate) {
            TextField("Template name", text: $newTemplateName)
            TextField("Description (optional)", text: $newTemplateDesc)
            Button("Save") { saveTemplate() }.disabled(newTemplateName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the \(overrideKeys.count) current overrides as a reusable template on this device.")
        }
        .alert("Add Custom Field", isPresented: $showAddField) {
            TextField("setting_key", text: $newFieldKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Add") {
                let key = newFieldKey.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
                if !key.isEmpty, settings[key] == nil { settings[key] = baseValues[key] ?? .string("") }
            }
            Button("Cancel", role: .cancel) {}
        }
        .actionAlerts(runner)
    }

    // MARK: Templates

    @ViewBuilder
    private var templatesSection: some View {
        let forType = templates.filter { $0.kind == kind && ($0.showInModal ?? true) }
        Section {
            if let appliedTemplate {
                Label("Applied “\(appliedTemplate)”", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            ForEach(forType) { t in
                Button {
                    settings.merge(t.settings) { _, new in new }
                    appliedTemplate = t.name
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name)
                        Text("\(t.description) · \(t.settings.count) settings").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if forType.isEmpty {
                Text("No templates for \(kind.title.lowercased()) presets.").font(.subheadline).foregroundStyle(.secondary)
            }
            if !overrideKeys.isEmpty {
                Button("Save Overrides as Template", systemImage: "square.and.arrow.down.on.square") {
                    newTemplateName = ""; newTemplateDesc = ""; showSaveTemplate = true
                }
            }
        } header: {
            Label("Templates", systemImage: "sparkles")
        } footer: {
            Text("Manage templates from the Templates menu on the preset list.")
        }
    }

    private func saveTemplate() {
        var overrides = settings
        overrides["inherits"] = nil
        guard !overrides.isEmpty else { return }
        let t = ProfilesPresetTemplate(id: String(Int(Date().timeIntervalSince1970 * 1000)),
                                       name: newTemplateName.trimmingCharacters(in: .whitespaces),
                                       description: newTemplateDesc.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom template" : newTemplateDesc,
                                       type: kind.apiType, settings: overrides, showInModal: true)
        templates.append(t)
        ProfilesTemplateStorage.save(templates)
        runner.successMessage = "Template saved"
    }

    // MARK: Fields

    @ViewBuilder
    private func fieldRow(_ field: ProfilesFieldDefinition, showKey: Bool = false) -> some View {
        ProfilesFieldControl(field: field, settings: $settings, baseValue: baseValues[field.key], showKey: showKey)
    }

    // MARK: Loading & saving

    private func loadFields() async {
        let defs: ProfilesFieldDefinitions? = try? await session.client.get("cloud/fields/\(kind.rawValue)")
        fieldDefs = defs?.fields ?? []
    }

    private func loadBase() async {
        guard !baseId.isEmpty else { baseValues = [:]; return }
        loadingBase = true
        defer { loadingBase = false }
        let client = session.client
        guard let base: ProfilesSlicerSettingDetail = try? await client.get("cloud/settings/\(ProfilesAPI.escape(baseId))") else { return }
        var merged: [String: JSONValue] = [:]
        if let parentName = base.settingObject["inherits"]?.stringValue, !parentName.isEmpty,
           let parent = basePresets.first(where: { $0.name == parentName }), parent.settingId != baseId,
           let parentDetail: ProfilesSlicerSettingDetail = try? await client.get("cloud/settings/\(ProfilesAPI.escape(parent.settingId))") {
            merged = parentDetail.settingObject
        }
        merged.merge(base.settingObject) { _, new in new }
        baseValues = merged
    }

    private func importJSON(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            guard let obj = (json["setting"] ?? json).objectValue else { throw CocoaError(.fileReadCorruptFile) }
            settings.merge(obj) { _, new in new }
            runner.successMessage = "Imported \(obj.count) settings"
        } catch {
            runner.errorMessage = "That file isn't a valid preset JSON file."
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        await runner.run {
            if isEdit, let id = seed.editingId {
                try await ProfilesAPI.updateCloudPreset(session.client, id: id, name: trimmed, setting: settings)
            } else {
                var final = settings
                final[kind.settingsIdKey] = .string("\"\(trimmed)\"")
                try await ProfilesAPI.createCloudPreset(session.client, kind: kind, name: trimmed, baseId: baseId, setting: final)
            }
            await onSaved()
            dismiss()
        }
    }
}

// MARK: - Field control

/// Edits one preset setting; clearing it falls back to the base preset's value.
struct ProfilesFieldControl: View {
    let field: ProfilesFieldDefinition
    @Binding var settings: [String: JSONValue]
    let baseValue: JSONValue?
    var showKey = false

    private var current: JSONValue? { settings[field.key] }
    private var basePlaceholder: String { baseValue.map { ProfilesJSON.summary($0) } ?? "" }

    var body: some View {
        switch field.type {
        case "boolean":
            Toggle(isOn: Binding(
                get: { (current ?? baseValue).flatMap(Self.editText) == "1" },
                set: { settings[field.key] = Self.value(from: $0 ? "1" : "0", like: current ?? baseValue) }
            )) { label }
        case "select":
            Picker(selection: textBinding) {
                Text(basePlaceholder.isEmpty ? "Inherited" : "Inherited (\(basePlaceholder))").tag("")
                ForEach(field.options ?? [], id: \.value) { Text($0.label ?? $0.value).tag($0.value) }
                if let text = current.flatMap(Self.editText), !text.isEmpty, !(field.options ?? []).contains(where: { $0.value == text }) {
                    Text(text).tag(text)
                }
            } label: { label }
        default:
            VStack(alignment: .leading, spacing: 4) {
                label
                HStack {
                    TextField(basePlaceholder.isEmpty ? "Value" : basePlaceholder, text: textBinding)
                        .keyboardType(field.type == "number" ? .decimalPad : .default)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    if let unit = field.unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(field.displayLabel)
                if current != nil { Circle().fill(.tint).frame(width: 6, height: 6).accessibilityLabel("Overridden") }
            }
            if showKey || field.category == "discovered" {
                Text(field.key).font(.caption2.monospaced()).foregroundStyle(.secondary)
            } else if let d = field.description, !d.isEmpty {
                Text(d).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { current.flatMap(Self.editText) ?? "" },
            set: { new in
                settings[field.key] = new.isEmpty ? nil : Self.value(from: new, like: current ?? baseValue)
            }
        )
    }

    static func editText(_ v: JSONValue) -> String? {
        switch v {
        case .array(let a): return a.map { $0.stringValue ?? ProfilesJSON.summary($0) }.joined(separator: ", ")
        case .null: return nil
        case .object: return ProfilesJSON.summary(v)
        default: return v.stringValue
        }
    }

    /// Keeps the shape of the value it replaces (arrays stay arrays).
    static func value(from text: String, like shape: JSONValue?) -> JSONValue {
        if case .array = shape {
            return .array(text.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
        }
        return .string(text)
    }
}

// MARK: - Sub-screens

private struct ProfilesBasePresetPicker: View {
    let presets: [ProfilesSlicerSetting]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        let shown = search.isEmpty ? presets : presets.filter { $0.name.localizedCaseInsensitiveContains(search) }
        List(shown) { p in
            Button {
                selection = p.settingId
                dismiss()
            } label: {
                HStack {
                    Text(p.name).foregroundStyle(.primary)
                    Spacer()
                    if p.settingId == selection { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
        }
        .overlay { if shown.isEmpty { ContentUnavailableView.search(text: search) } }
        .searchable(text: $search, prompt: "Search built-in presets")
        .navigationTitle("Base Preset")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfilesAllFieldsView: View {
    let fields: [ProfilesFieldDefinition]
    @Binding var settings: [String: JSONValue]
    let baseValues: [String: JSONValue]
    @State private var search = ""
    @State private var onlyOverridden = false

    var body: some View {
        let shown = fields.filter { f in
            (!onlyOverridden || settings[f.key] != nil) &&
            (search.isEmpty || f.key.localizedCaseInsensitiveContains(search) || f.displayLabel.localizedCaseInsensitiveContains(search))
        }
        let grouped = Dictionary(grouping: shown, by: { $0.category ?? "other" })
        List {
            Toggle("Only Overridden", isOn: $onlyOverridden)
            ForEach(grouped.keys.sorted(), id: \.self) { category in
                Section(ProfilesPresetMeta.humanize(category)) {
                    ForEach(grouped[category] ?? []) { f in
                        ProfilesFieldControl(field: f, settings: $settings, baseValue: baseValues[f.key], showKey: true)
                    }
                }
            }
        }
        .overlay { if shown.isEmpty { ContentUnavailableView.search(text: search) } }
        .searchable(text: $search, prompt: "Search settings")
        .navigationTitle("All Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProfilesJSONEditorView: View {
    @Binding var settings: [String: JSONValue]
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            TextEditor(text: $text)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(.horizontal, 8)
        }
        .navigationTitle("JSON")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { text = ProfilesJSON.pretty(.object(settings)) }
        .onChange(of: text) { _, new in
            do {
                guard let obj = try ProfilesJSON.parse(new).objectValue else { error = "The JSON must be an object."; return }
                settings = obj
                error = nil
            } catch {
                self.error = "Invalid JSON — changes are not applied until it parses."
            }
        }
    }
}

// MARK: - Templates manager

struct ProfilesTemplatesSheet: View {
    let onApply: (ProfilesPresetTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var templates = ProfilesTemplateStorage.load()
    @State private var filter: ProfilesPresetKind?
    @State private var deleteTarget: ProfilesPresetTemplate?

    var body: some View {
        let shown = templates.filter { filter == nil || $0.kind == filter }
        NavigationStack {
            List {
                Picker("Type", selection: $filter) {
                    Text("All").tag(ProfilesPresetKind?.none)
                    ForEach(ProfilesPresetKind.allCases) { Text($0.title).tag(ProfilesPresetKind?.some($0)) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                ForEach(shown) { t in
                    NavigationLink {
                        ProfilesTemplateEditView(template: t) { updated in
                            if let i = templates.firstIndex(where: { $0.id == updated.id }) { templates[i] = updated }
                            ProfilesTemplateStorage.save(templates)
                        }
                    } label: {
                        HStack {
                            Image(systemName: t.kind.systemImage).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name)
                                Text("\(t.description) · \(t.settings.count) settings").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if t.showInModal == false {
                                Image(systemName: "eye.slash").foregroundStyle(.secondary).accessibilityLabel("Hidden in editor")
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = t }
                        Button(t.showInModal == false ? "Show" : "Hide", systemImage: t.showInModal == false ? "eye" : "eye.slash") {
                            toggleShown(t)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Use", systemImage: "wand.and.stars") { onApply(t) }.tint(.accentColor)
                    }
                    .contextMenu {
                        Button("Create Preset from Template", systemImage: "wand.and.stars") { onApply(t) }
                        Button(t.showInModal == false ? "Show in Editor" : "Hide in Editor", systemImage: "eye") { toggleShown(t) }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = t }
                    }
                }
            }
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView("No Templates", systemImage: "sparkles",
                                           description: Text("Save a preset's overrides as a template from the preset editor to reuse them later."))
                }
            }
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirm("Delete template “\(deleteTarget?.name ?? "")”?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                if let t = deleteTarget {
                    templates.removeAll { $0.id == t.id }
                    ProfilesTemplateStorage.save(templates)
                }
            }
        }
    }

    private func toggleShown(_ t: ProfilesPresetTemplate) {
        guard let i = templates.firstIndex(where: { $0.id == t.id }) else { return }
        templates[i].showInModal = !(templates[i].showInModal ?? true)
        ProfilesTemplateStorage.save(templates)
    }
}

private struct ProfilesTemplateEditView: View {
    let template: ProfilesPresetTemplate
    let onSave: (ProfilesPresetTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var desc = ""
    @State private var show = true
    @State private var json = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Description", text: $desc)
                Toggle("Show in Preset Editor", isOn: $show)
                LabeledContent("Type", value: template.kind.title)
            }
            Section {
                TextEditor(text: $json)
                    .font(.caption.monospaced())
                    .frame(minHeight: 240)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Settings (JSON)")
            } footer: {
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(template.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = template.name
            desc = template.description
            show = template.showInModal ?? true
            json = ProfilesJSON.pretty(.object(template.settings))
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        guard let obj = try ProfilesJSON.parse(json).objectValue else { error = "The JSON must be an object."; return }
                        var t = template
                        t.name = name.trimmingCharacters(in: .whitespaces)
                        t.description = desc.trimmingCharacters(in: .whitespaces)
                        t.showInModal = show
                        t.settings = obj
                        onSave(t)
                        dismiss()
                    } catch {
                        self.error = "Invalid JSON: \(error.localizedDescription)"
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
