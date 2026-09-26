import SwiftUI

/// API keys, long-lived camera tokens and the streaming-overlay URL builder.
/// Pushed from Settings (no NavigationStack of its own).
struct APIKeysView: View {
    @Environment(AppSession.self) private var session
    @State private var keys = Loader<[AdminAPIKey]>()
    @State private var runner = ActionRunner()
    @State private var editing: AdminAPIKeyEditTarget?
    @State private var created: AdminAPIKey?
    @State private var toDelete: AdminAPIKey?
    @State private var tokens = AdminCameraTokenStore()

    var body: some View {
        List {
            if session.can("api_keys:read") {
                apiKeysSection
            }
            AdminCameraTokenSections(store: tokens)
            Section {
                NavigationLink {
                    AdminOverlayBuilder()
                } label: {
                    Label("Streaming Overlay URL", systemImage: "rectangle.on.rectangle")
                }
            } footer: {
                Text("Build a URL for a full-screen camera view with live print data, for OBS or a wall display.")
            }
        }
        .navigationTitle("API Keys & Tokens")
        .toolbar {
            if session.can("api_keys:create") {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new } label: { Label("New API Key", systemImage: "plus") }
                }
            }
        }
        .refreshable { await load(); await tokens.load(session) }
        .task { await load() }
        .actionAlerts(runner)
        .adminCameraTokenPresentation(tokens)
        .sheet(item: $editing) { target in
            AdminAPIKeyEditor(target: target) { key in
                if key.key != nil { created = key }
                Task { await load() }
            }
        }
        .sheet(item: $created) { key in
            AdminAPIKeyCreatedSheet(apiKey: key)
        }
        .confirm("Delete “\(toDelete?.name ?? "key")”?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                 message: "Anything using this key will stop working immediately.") {
            if let k = toDelete { Task { await delete(k) } }
        }
    }

    @ViewBuilder
    private var apiKeysSection: some View {
        Section {
            LoadingContent(loader: keys, retry: load) { list in
                if list.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No API keys").font(.headline)
                        Text("Keys let scripts, Home Assistant and other tools use the Bambuddy API without a user session.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                ForEach(list) { key in
                    Button { if session.can("api_keys:update") { editing = .edit(key) } } label: {
                        AdminAPIKeyRow(key: key)
                    }
                    .tint(.primary)
                    .swipeActions {
                        if session.can("api_keys:delete") {
                            Button(role: .destructive) { toDelete = key } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if session.can("api_keys:update") {
                            Button { Task { await setEnabled(key, !key.enabled) } } label: {
                                Label(key.enabled ? "Disable" : "Enable", systemImage: key.enabled ? "pause.circle" : "play.circle")
                            }
                            .tint(key.enabled ? .orange : .green)
                        }
                    }
                    .contextMenu {
                        if session.can("api_keys:update") {
                            Button { editing = .edit(key) } label: { Label("Edit", systemImage: "pencil") }
                            Button { Task { await setEnabled(key, !key.enabled) } } label: {
                                Label(key.enabled ? "Disable" : "Enable", systemImage: key.enabled ? "pause.circle" : "play.circle")
                            }
                        }
                        if session.can("api_keys:delete") {
                            Button(role: .destructive) { toDelete = key } label: { Label("Delete…", systemImage: "trash") }
                        }
                    }
                }
            }
        } header: {
            Text("API Keys")
        } footer: {
            Text("Send a key in the X-API-Key header. Webhook endpoints such as /api/v1/webhook/status accept keys too.")
        }
    }

    private func load() async {
        guard session.can("api_keys:read") else { return }
        await keys.load { try await session.client.get("api-keys/") }
    }

    private func delete(_ key: AdminAPIKey) async {
        await runner.run("API key deleted") {
            try await session.client.call(.delete, "api-keys/\(key.id)")
            await load()
        }
    }

    private func setEnabled(_ key: AdminAPIKey, _ enabled: Bool) async {
        struct Body: Encodable { var enabled: Bool }
        await runner.run(enabled ? "Key enabled" : "Key disabled") {
            let _: AdminAPIKey = try await session.client.send(.patch, "api-keys/\(key.id)", body: Body(enabled: enabled))
            await load()
        }
    }
}

private struct AdminAPIKeyRow: View {
    let key: AdminAPIKey
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "key.fill").foregroundStyle(key.enabled && !key.isExpired ? Color.accentColor : .secondary)
                Text(key.name).font(.body.weight(.medium))
                Spacer()
                if !key.enabled { StatusBadge(text: "Disabled", color: .orange) }
                if key.isExpired { StatusBadge(text: "Expired", color: .red) }
                if key.userId == nil { StatusBadge(text: "Legacy", color: .secondary) }
            }
            Text(key.keyPrefix.hasSuffix("...") ? "\(key.keyPrefix)" : "\(key.keyPrefix)…")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            let labels = AdminAPIKeyScopes(key).labels
            if !labels.isEmpty {
                Text(labels.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Created \(Fmt.date(key.createdAt, style: .dateTime.month(.abbreviated).day().year()))")
                if let last = key.lastUsed { Text("Used \(Fmt.relative(last))") } else { Text("Never used") }
                if let exp = key.expiresAt, !key.isExpired { Text("Expires \(Fmt.date(exp, style: .dateTime.month(.abbreviated).day().year()))") }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if let ids = key.printerIds, !ids.isEmpty {
                Label("Limited to \(ids.count) printer\(ids.count == 1 ? "" : "s")", systemImage: "printer").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

fileprivate enum AdminAPIKeyEditTarget: Identifiable {
    case new
    case edit(AdminAPIKey)
    var id: String {
        switch self {
        case .new: "new"
        case .edit(let k): "key-\(k.id)"
        }
    }
}

private struct AdminAPIKeyEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss
    let target: AdminAPIKeyEditTarget
    var onSave: (AdminAPIKey) -> Void

    @State private var name = ""
    @State private var scopes = AdminAPIKeyScopes()
    @State private var enabled = true
    @State private var limitPrinters = false
    @State private var printerIds: Set<Int> = []
    @State private var expires = false
    @State private var expiresAt = Calendar.current.date(byAdding: .day, value: 90, to: Date()) ?? Date()
    @State private var runner = ActionRunner()

    private var existing: AdminAPIKey? { if case .edit(let k) = target { return k }; return nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Home Assistant)", text: $name)
                    if existing != nil { Toggle("Enabled", isOn: $enabled) }
                }
                Section {
                    ForEach(AdminAPIKeyScopes.all, id: \.1) { item in
                        Toggle(isOn: Binding(get: { scopes[keyPath: item.0] }, set: { scopes[keyPath: item.0] = $0 })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.1)
                                Text(item.2).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    if scopes.canAccessCloud { Text("Cloud access acts with the Bambu Cloud account of the user who owns this key.") }
                }
                Section {
                    Toggle("Limit to Specific Printers", isOn: $limitPrinters.animation())
                    if limitPrinters {
                        ForEach(printers.printers) { p in
                            Button {
                                if printerIds.contains(p.id) { printerIds.remove(p.id) } else { printerIds.insert(p.id) }
                            } label: {
                                HStack {
                                    Text(p.name).foregroundStyle(.primary)
                                    Spacer()
                                    if printerIds.contains(p.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Printers")
                } footer: {
                    Text(limitPrinters ? "The key can only see and act on the selected printers." : "The key can reach every printer.")
                }
                Section("Expiry") {
                    Toggle("Expires", isOn: $expires.animation())
                    if expires {
                        DatePicker("Expires On", selection: $expiresAt, in: Date()..., displayedComponents: .date)
                    }
                }
            }
            .navigationTitle(existing == nil ? "New API Key" : "Edit API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Create" : "Save") { Task { await save() } }
                        .disabled(runner.isRunning || (limitPrinters && printerIds.isEmpty))
                }
            }
            .actionAlerts(runner)
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let k = existing else { return }
        name = k.name
        scopes = AdminAPIKeyScopes(k)
        enabled = k.enabled
        if let ids = k.printerIds, !ids.isEmpty { limitPrinters = true; printerIds = Set(ids) }
        if let e = k.expiresAt, let d = APICoders.parseDate(e) { expires = true; expiresAt = d }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let payload = AdminAPIKeyPayload(
            name: trimmed.isEmpty ? (existing == nil ? "Unnamed key" : nil) : trimmed,
            scopes: scopes,
            printerIds: limitPrinters ? Array(printerIds).sorted() : nil,
            enabled: existing == nil ? nil : enabled,
            expiresAt: expires ? Calendar.current.startOfDay(for: expiresAt).addingTimeInterval(86_399) : nil
        )
        await runner.run {
            let key: AdminAPIKey
            if let k = existing {
                key = try await session.client.send(.patch, "api-keys/\(k.id)", body: payload)
            } else {
                key = try await session.client.send(.post, "api-keys/", body: payload)
            }
            onSave(key)
            dismiss()
        }
    }
}

private struct AdminAPIKeyCreatedSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let apiKey: AdminAPIKey

    private var pairingPayload: String {
        let base = session.serverURL?.absoluteString ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
        let url = base.addingPercentEncoding(withAllowedCharacters: allowed) ?? base
        let key = (apiKey.key ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return "bambuddy://config?v=1&url=\(url)&key=\(key)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Copy this key now. It won't be shown again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    AdminSecretField(title: apiKey.name, value: apiKey.key ?? "")
                }
                Section {
                    HStack {
                        Spacer()
                        AdminQRCodeView(text: pairingPayload, size: 200)
                        Spacer()
                    }
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text("Scan with a companion app to set up the server address and key in one step. Anyone who sees this code can use the key.")
                }
            }
            .navigationTitle("API Key Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .interactiveDismissDisabled()
        }
    }
}

// MARK: - Long-lived camera tokens

/// State for the long-lived camera / camera-wall / overlay tokens (`/auth/tokens`).
/// Owned by the screen that shows `AdminCameraTokenSections`, which also applies
/// `.adminCameraTokenPresentation(store)` so sheets survive list cell reuse.
@MainActor
@Observable
final class AdminCameraTokenStore {
    var mine = Loader<[AdminCameraToken]>()
    var all: [AdminCameraToken] = []
    var userNames: [Int: String] = [:]
    var showCreate = false
    var created: AdminCameraToken?
    var toRevoke: AdminCameraToken?
    let runner = ActionRunner()

    func load(_ session: AppSession) async {
        guard session.isAuthEnabled, session.can("camera:view") else { return }
        let client = session.client
        await mine.load { try await client.get("auth/tokens") }
        if session.user?.isAdmin == true {
            all = (try? await client.get("auth/tokens/all")) ?? []
            if let slim: [JSONValue] = try? await client.get("users/slim") {
                userNames = Dictionary(slim.compactMap { u in u["id"]?.intValue.map { ($0, u["username"]?.stringValue ?? "") } }, uniquingKeysWith: { a, _ in a })
            }
        }
    }

    func revoke(_ token: AdminCameraToken, session: AppSession) async {
        await runner.run("Token revoked") {
            try await session.client.call(.delete, "auth/tokens/\(token.id)")
            await load(session)
        }
    }
}

/// List sections for camera tokens. Embed inside a `List`.
struct AdminCameraTokenSections: View {
    @Environment(AppSession.self) private var session
    let store: AdminCameraTokenStore

    var body: some View {
        if !session.isAuthEnabled {
            Section {
                Label("Long-lived camera tokens belong to a user account, so they need sign-in to be enabled on the server.", systemImage: "person.badge.key")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Camera Tokens")
            }
        } else if session.can("camera:view") {
            Section {
                LoadingContent(loader: store.mine, retry: { await store.load(session) }) { list in
                    if list.isEmpty {
                        Text("No tokens yet").foregroundStyle(.secondary)
                    }
                    ForEach(list) { token in
                        AdminCameraTokenRow(token: token, owner: nil)
                            .swipeActions { revokeButton(token) }
                            .contextMenu { revokeButton(token) }
                    }
                }
                Button { store.showCreate = true } label: { Label("New Token", systemImage: "plus.circle") }
            } header: {
                Text("My Camera Tokens")
            } footer: {
                Text("Tokens for Home Assistant, Frigate, kiosk displays and stream overlays. They last up to 365 days and can be revoked any time.")
            }
            if session.user?.isAdmin == true {
                let others = store.all.filter { $0.userId != session.user?.id }
                Section("All Users' Tokens") {
                    if others.isEmpty { Text("No tokens from other users").foregroundStyle(.secondary) }
                    ForEach(others) { token in
                        AdminCameraTokenRow(token: token, owner: token.userId.map { store.userNames[$0] ?? "User #\($0)" })
                            .swipeActions { revokeButton(token) }
                            .contextMenu { revokeButton(token) }
                    }
                }
            }
        }
    }

    private func revokeButton(_ token: AdminCameraToken) -> some View {
        Button(role: .destructive) { store.toRevoke = token } label: { Label("Revoke", systemImage: "xmark.circle") }
    }
}

private struct AdminCameraTokenPresentation: ViewModifier {
    @Environment(AppSession.self) private var session
    @Bindable var store: AdminCameraTokenStore

    func body(content: Content) -> some View {
        content
            .task { await store.load(session) }
            .sheet(isPresented: $store.showCreate) {
                AdminCameraTokenCreateSheet { token in
                    store.created = token
                    Task { await store.load(session) }
                }
            }
            .sheet(item: $store.created) { token in AdminCameraTokenCreatedSheet(token: token) }
            .confirm("Revoke “\(store.toRevoke?.name ?? "token")”?", isPresented: Binding(get: { store.toRevoke != nil }, set: { if !$0 { store.toRevoke = nil } }),
                     message: "Any device using it loses access immediately. This can't be undone.", action: "Revoke") {
                if let t = store.toRevoke { Task { await store.revoke(t, session: session) } }
            }
            .actionAlerts(store.runner)
    }
}

extension View {
    /// Loads camera tokens and hosts their create / reveal / revoke presentations.
    func adminCameraTokenPresentation(_ store: AdminCameraTokenStore) -> some View {
        modifier(AdminCameraTokenPresentation(store: store))
    }
}

private struct AdminCameraTokenRow: View {
    let token: AdminCameraToken
    let owner: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(token.name).font(.body.weight(.medium))
                StatusBadge(text: token.scopeLabel, color: .blue)
                Spacer()
                if token.isExpired { StatusBadge(text: "Expired", color: .red) }
            }
            HStack(spacing: 10) {
                if let owner { Label(owner, systemImage: "person").labelStyle(.titleAndIcon) }
                if let p = token.lookupPrefix { Text("\(p)…").monospaced() }
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("Expires \(Fmt.date(token.expiresAt, style: .dateTime.month(.abbreviated).day().year()))")
                Text(token.lastUsedAt.map { "Used \(Fmt.relative($0))" } ?? "Never used")
            }
            .font(.caption2).foregroundStyle(token.isExpired ? .red : .secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct AdminCameraTokenCreateSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var onCreate: (AdminCameraToken) -> Void

    @State private var name = ""
    @State private var scope: AdminCameraTokenScope = .cameraStream
    @State private var days = 90
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Home Assistant)", text: $name)
                    Picker("Scope", selection: $scope) {
                        ForEach(AdminCameraTokenScope.allCases) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text(scope.explanation)
                }
                Section {
                    Stepper(value: $days, in: 1...365) {
                        LabeledContent("Valid For", value: "\(days) day\(days == 1 ? "" : "s")")
                    }
                    HStack {
                        ForEach([7, 30, 90, 365], id: \.self) { d in
                            Button("\(d)d") { days = d }
                                .buttonStyle(.bordered).controlSize(.small)
                                .tint(days == d ? .accentColor : .secondary)
                        }
                    }
                } footer: {
                    Text("Maximum 365 days. The token is shown only once, right after it's created.")
                }
            }
            .navigationTitle("New Camera Token")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }
            }
            .actionAlerts(runner)
        }
    }

    private func create() async {
        let body = AdminCameraTokenCreate(name: name.trimmingCharacters(in: .whitespaces), expiresInDays: days, scope: scope.rawValue)
        await runner.run {
            let token: AdminCameraToken = try await session.client.send(.post, "auth/tokens", body: body)
            onCreate(token)
            dismiss()
        }
    }
}

private struct AdminCameraTokenCreatedSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss
    let token: AdminCameraToken
    @State private var overlayPrinter: Int?

    private var plaintext: String { token.token ?? "" }

    private func url(_ path: String) -> String {
        guard let base = session.serverURL else { return "" }
        var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "token", value: plaintext)]
        return comps?.url?.absoluteString ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Copy this token now. It won't be shown again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    AdminSecretField(title: "\(token.name) · \(token.scopeLabel)", value: plaintext)
                }
                if token.scope == AdminCameraTokenScope.camwall.rawValue {
                    Section {
                        AdminSecretField(title: "Camera Wall URL", value: url("camwall"))
                    } footer: {
                        Text("Open this on the display. Anyone with the URL can watch the wall; revoke the token to cut it off.")
                    }
                }
                if token.scope == AdminCameraTokenScope.overlay.rawValue {
                    Section {
                        Picker("Printer", selection: $overlayPrinter) {
                            ForEach(printers.printers) { Text($0.name).tag(Optional($0.id)) }
                        }
                        if let id = overlayPrinter ?? printers.printers.first?.id {
                            AdminSecretField(title: "Overlay URL", value: url("overlay/\(id)"))
                        }
                    } footer: {
                        Text("Add this as a browser source in OBS. Anyone with the URL can watch the stream; revoke the token to cut it off.")
                    }
                }
            }
            .navigationTitle("Token Created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .interactiveDismissDisabled()
            .onAppear { overlayPrinter = printers.printers.first?.id }
        }
    }
}

// MARK: - Streaming overlay URL builder

private struct AdminOverlayBuilder: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers

    private static let fields: [(String, String)] = [
        ("printer", "Printer name"), ("filename", "File name"), ("status", "Status"),
        ("progress", "Progress bar"), ("layers", "Layer count"), ("eta", "Time remaining & ETA"),
        ("nozzle", "Nozzle temperature"), ("bed", "Bed temperature"), ("chamber", "Chamber temperature"),
    ]

    @State private var printerId: Int?
    @State private var selected: Set<String> = ["progress", "layers", "eta", "filename", "status"]
    @State private var size = "medium"
    @State private var fps = 15
    @State private var showCamera = true
    @State private var token = ""

    private var url: String {
        guard let base = session.serverURL else { return "" }
        let id = printerId ?? printers.printers.first?.id ?? 1
        var items = [URLQueryItem(name: "show", value: Self.fields.map(\.0).filter(selected.contains).joined(separator: ","))]
        if size != "medium" { items.append(URLQueryItem(name: "size", value: size)) }
        if fps != 15 { items.append(URLQueryItem(name: "fps", value: String(fps))) }
        if !showCamera { items.append(URLQueryItem(name: "camera", value: "false")) }
        let t = token.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { items.append(URLQueryItem(name: "token", value: t)) }
        var comps = URLComponents(url: base.appending(path: "overlay/\(id)"), resolvingAgainstBaseURL: false)
        comps?.queryItems = items
        return comps?.url?.absoluteString ?? ""
    }

    var body: some View {
        Form {
            Section {
                Picker("Printer", selection: $printerId) {
                    ForEach(printers.printers) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Text Size", selection: $size) {
                    Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                }
                Stepper("Camera Frame Rate: \(fps) fps", value: $fps, in: 1...30)
                Toggle("Show Camera", isOn: $showCamera)
            }
            Section("Fields") {
                ForEach(Self.fields, id: \.0) { field in
                    Toggle(field.1, isOn: Binding(
                        get: { selected.contains(field.0) },
                        set: { if $0 { selected.insert(field.0) } else { selected.remove(field.0) } }
                    ))
                }
            }
            Section {
                TextField("Overlay token (if sign-in is on)", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .font(.body.monospaced())
            } footer: {
                Text("With sign-in enabled, create a Streaming Overlay token on the previous screen and paste it here.")
            }
            Section("URL") {
                AdminSecretField(title: "Overlay URL", value: url)
                if let u = URL(string: url) {
                    Link(destination: u) { Label("Preview in Browser", systemImage: "safari") }
                }
            }
        }
        .navigationTitle("Streaming Overlay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if printerId == nil { printerId = printers.printers.first?.id } }
    }
}
