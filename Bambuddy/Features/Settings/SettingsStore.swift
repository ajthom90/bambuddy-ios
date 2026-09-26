import SwiftUI

/// The server's application settings (`GET /settings/`), kept as raw JSON keyed by the
/// server's snake_case names.
///
/// Writes go through `PUT /settings/` carrying only the changed keys: the backend applies
/// `model_dump(exclude_unset=True)`, so omitted keys are left alone. An explicit `null` is
/// persisted as the literal string "None" (only meaningful for nullable fields such as
/// `default_printer_id`, `open_in_slicer` and `ams_temp_alarm`).
@MainActor
@Observable
final class ServerSettingsStore {
    /// Current values, including optimistic edits that are still being saved.
    private(set) var values: [String: JSONValue] = [:]
    /// Last values confirmed by the server (used to roll back failed saves).
    @ObservationIgnored private var confirmed: [String: JSONValue] = [:]
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var isSaving = false
    /// Set when a save fails; shown as an alert by `SettingsForm`.
    var saveError: String?
    /// Bumped after every successful save, for "Saved" feedback.
    private(set) var saveCount = 0

    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private var pending: [String: JSONValue] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    init(values: [String: JSONValue] = [:]) {
        self.values = values
        self.confirmed = values
        self.hasLoaded = !values.isEmpty
    }

    func attach(_ session: AppSession) { self.session = session }

    var canEdit: Bool { session?.can("settings:update") ?? false }

    // MARK: Loading

    func load() async {
        guard let client = session?.client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let raw: JSONValue = try await client.get("settings/")
            apply(serverResponse: raw)
            loadError = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Replaces the confirmed values with a full settings payload, keeping edits that are still queued.
    func apply(serverResponse raw: JSONValue) {
        guard let object = raw.objectValue else { return }
        confirmed = object
        var merged = object
        for (k, v) in pending { merged[k] = v }
        values = merged
        hasLoaded = true
    }

    // MARK: Reading

    subscript(key: String) -> JSONValue? { values[key] }

    func bool(_ key: String, default fallback: Bool = false) -> Bool { values[key]?.boolValue ?? fallback }
    func string(_ key: String, default fallback: String = "") -> String {
        guard let v = values[key], !v.isNull else { return fallback }
        let s = v.stringValue ?? fallback
        return s == "None" ? fallback : s
    }
    func int(_ key: String) -> Int? {
        guard let v = values[key], !v.isNull else { return nil }
        return v.intValue
    }
    func double(_ key: String) -> Double? {
        guard let v = values[key], !v.isNull else { return nil }
        return v.doubleValue
    }

    /// Settings that the server stores as JSON-encoded strings (drying presets, g-code snippets, …).
    func jsonString(_ key: String) -> JSONValue? {
        let s = string(key)
        guard !s.isEmpty, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: Writing

    /// Applies changes optimistically and saves them right away. Returns `true` on success.
    @discardableResult
    func save(_ changes: [String: JSONValue]) async -> Bool {
        guard !changes.isEmpty else { return true }
        for (k, v) in changes { values[k] = v }
        return await send(changes)
    }

    /// Applies a change optimistically and saves it shortly afterwards, coalescing rapid edits
    /// (steppers, toggles flipped in quick succession) into a single request.
    func stage(_ key: String, _ value: JSONValue) {
        values[key] = value
        pending[key] = value
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Sends any staged edits immediately.
    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        let changes = pending
        pending = [:]
        guard !changes.isEmpty else { return }
        await send(changes)
    }

    @discardableResult
    private func send(_ changes: [String: JSONValue]) async -> Bool {
        guard let client = session?.client else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            let response: JSONValue = try await client.send(.put, "settings/", body: JSONValue.object(changes))
            if response.objectValue != nil {
                apply(serverResponse: response)
            } else {
                for (k, v) in changes { confirmed[k] = v }
            }
            saveCount += 1
            return true
        } catch {
            for k in changes.keys where pending[k] == nil { values[k] = confirmed[k] }
            saveError = error.localizedDescription
            return false
        }
    }

    // MARK: Bindings

    func boolBinding(_ key: String, default fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { self.bool(key, default: fallback) }, set: { self.stage(key, .bool($0)) })
    }

    func stringBinding(_ key: String, default fallback: String = "") -> Binding<String> {
        Binding(get: { self.string(key, default: fallback) }, set: { self.stage(key, .string($0)) })
    }

    func intBinding(_ key: String, default fallback: Int = 0) -> Binding<Int> {
        Binding(get: { self.int(key) ?? fallback }, set: { self.stage(key, .number(Double($0))) })
    }

    func doubleBinding(_ key: String, default fallback: Double = 0) -> Binding<Double> {
        Binding(get: { self.double(key) ?? fallback }, set: { self.stage(key, .number($0)) })
    }

    func valueBinding(_ key: String) -> Binding<JSONValue> {
        Binding(get: { self.values[key] ?? .null }, set: { self.stage(key, $0) })
    }
}

// MARK: - Form building blocks

/// Standard container for a page backed by `ServerSettingsStore`: loads the blob on first
/// appearance, supports pull to refresh, shows a saving indicator and save errors.
struct SettingsForm<Content: View>: View {
    @Environment(ServerSettingsStore.self) private var store
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if store.hasLoaded {
                Form { content() }
                    .refreshable { await store.load() }
            } else if let error = store.loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Settings", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await store.load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { if !store.isLoading { await store.load() } }
            }
        }
        .navigationTitle(title)
        .toolbar {
            if store.isSaving {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
        .alert("Couldn't Save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.saveError ?? "") }
        .onDisappear { Task { await store.flush() } }
    }
}

/// A title with an optional secondary explanation, used as the label of settings controls.
struct SettingsLabel: View {
    let title: String
    var help: String?
    init(_ title: String, help: String? = nil) { self.title = title; self.help = help }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let help, !help.isEmpty {
                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Toggle bound to a boolean setting (saved automatically).
struct SettingsToggle: View {
    @Environment(ServerSettingsStore.self) private var store
    let title: String
    let key: String
    var help: String?
    var defaultValue = false

    init(_ title: String, key: String, help: String? = nil, default defaultValue: Bool = false) {
        self.title = title; self.key = key; self.help = help; self.defaultValue = defaultValue
    }

    var body: some View {
        Toggle(isOn: store.boolBinding(key, default: defaultValue)) { SettingsLabel(title, help: help) }
            .disabled(!store.canEdit)
    }
}

/// Picker bound to a string (or other scalar) setting (saved automatically).
struct SettingsPicker: View {
    @Environment(ServerSettingsStore.self) private var store
    let title: String
    let key: String
    let options: [(value: JSONValue, label: String)]
    var help: String?

    init(_ title: String, key: String, options: [(value: JSONValue, label: String)], help: String? = nil) {
        self.title = title; self.key = key; self.options = options; self.help = help
    }

    /// Convenience for string-valued settings.
    init(_ title: String, key: String, choices: [(String, String)], help: String? = nil) {
        self.init(title, key: key, options: choices.map { (JSONValue.string($0.0), $0.1) }, help: help)
    }

    var body: some View {
        let current = store[key] ?? .null
        let known = options.contains { $0.value == current }
        Picker(selection: store.valueBinding(key)) {
            ForEach(options.indices, id: \.self) { i in Text(options[i].label).tag(options[i].value) }
            if !known, !current.isNull { Text(current.displayString).tag(current) }
        } label: { SettingsLabel(title, help: help) }
            .disabled(!store.canEdit)
    }
}

/// Text field bound to a string setting. Edits are committed on return or when focus leaves.
struct SettingsTextField: View {
    @Environment(ServerSettingsStore.self) private var store
    let title: String
    let key: String
    var prompt: String?
    var help: String?
    var secure = false
    var keyboard: UIKeyboardType = .default
    var readOnly = false

    @State private var draft = ""
    @FocusState private var focused: Bool

    init(_ title: String, key: String, prompt: String? = nil, help: String? = nil, secure: Bool = false,
         keyboard: UIKeyboardType = .default, readOnly: Bool = false) {
        self.title = title; self.key = key; self.prompt = prompt; self.help = help
        self.secure = secure; self.keyboard = keyboard; self.readOnly = readOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsLabel(title, help: help)
            Group {
                if secure {
                    SecureField(prompt ?? title, text: $draft)
                } else {
                    TextField(prompt ?? title, text: $draft)
                }
            }
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
            .onSubmit(commit)
            .padding(8)
            .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            .disabled(!store.canEdit || readOnly)
        }
        .padding(.vertical, 2)
        .onAppear(perform: sync)
        .onChange(of: store.string(key)) { _, _ in if !focused { sync() } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func sync() {
        let value = store.string(key)
        draft = value
    }

    private func commit() {
        guard !readOnly, draft != store.string(key) else { return }
        let value = draft
        Task { await store.save([key: .string(value)]) }
    }
}

/// Numeric field bound to a number setting. Committed on return/focus loss; values outside
/// `range` are clamped.
struct SettingsNumberField: View {
    @Environment(ServerSettingsStore.self) private var store
    let title: String
    let key: String
    var unit: String?
    var help: String?
    var integer = true
    var range: ClosedRange<Double>?
    var allowsEmpty = false

    @State private var draft = ""
    @FocusState private var focused: Bool

    init(_ title: String, key: String, unit: String? = nil, help: String? = nil, integer: Bool = true,
         range: ClosedRange<Double>? = nil, allowsEmpty: Bool = false) {
        self.title = title; self.key = key; self.unit = unit; self.help = help
        self.integer = integer; self.range = range; self.allowsEmpty = allowsEmpty
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField(allowsEmpty ? "Off" : "0", text: $draft)
                    .keyboardType(integer ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(commit)
                    .frame(maxWidth: 100)
                    .disabled(!store.canEdit)
                if let unit { Text(unit).foregroundStyle(.secondary) }
            }
        } label: { SettingsLabel(title, help: help) }
        .onAppear(perform: sync)
        .onChange(of: store.double(key)) { _, _ in if !focused { sync() } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func sync() { draft = Self.format(store.double(key), integer: integer) }

    static func format(_ value: Double?, integer: Bool) -> String {
        guard let value else { return "" }
        if integer || value.rounded() == value { return String(Int(value.rounded())) }
        return value.formatted(.number.precision(.fractionLength(0...4)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty {
            if allowsEmpty, store.double(key) != nil { Task { await store.save([key: .null]) } } else { sync() }
            return
        }
        guard var value = Double(trimmed) else { sync(); return }
        if integer { value = value.rounded() }
        if let range { value = min(max(value, range.lowerBound), range.upperBound) }
        draft = Self.format(value, integer: integer)
        guard value != store.double(key) else { return }
        Task { await store.save([key: .number(value)]) }
    }
}

/// Stepper bound to an integer setting (saved automatically, rapid taps coalesced).
struct SettingsStepper: View {
    @Environment(ServerSettingsStore.self) private var store
    let title: String
    let key: String
    let range: ClosedRange<Int>
    var step = 1
    var unit: String?
    var help: String?
    var defaultValue: Int

    init(_ title: String, key: String, range: ClosedRange<Int>, step: Int = 1, unit: String? = nil, help: String? = nil, default defaultValue: Int? = nil) {
        self.title = title; self.key = key; self.range = range; self.step = step
        self.unit = unit; self.help = help; self.defaultValue = defaultValue ?? range.lowerBound
    }

    var body: some View {
        let value = store.int(key) ?? defaultValue
        Stepper(value: store.intBinding(key, default: defaultValue), in: range, step: step) {
            HStack {
                SettingsLabel(title, help: help)
                Spacer()
                Text(unit.map { "\(value) \($0)" } ?? "\(value)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .disabled(!store.canEdit)
    }
}

/// Inline connection-test result line.
struct SettingsTestResultLabel: View {
    let success: Bool
    let message: String
    var body: some View {
        Label(message, systemImage: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .font(.footnote)
            .foregroundStyle(success ? .green : .red)
    }
}
