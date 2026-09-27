import SwiftUI

// MARK: - Models

/// `GET/PUT /settings/spoolman`. The server stores these as strings ("true"/"false"); boolean
/// fields are decoded loosely so real JSON booleans work too.
struct SettingsSpoolmanConfig: Codable, Sendable, Equatable {
    var spoolmanEnabled: JSONValue?
    var spoolmanUrl: String?
    var spoolmanSyncMode: String?
    var spoolmanDisableWeightSync: JSONValue?
    var spoolmanReportPartialUsage: JSONValue?
    var autoAddUnknownRfid: JSONValue?

    var enabled: Bool { Self.flag(spoolmanEnabled, default: false) }
    var url: String { spoolmanUrl ?? "" }
    var syncMode: String { (spoolmanSyncMode ?? "").isEmpty ? "auto" : spoolmanSyncMode! }
    var disablesWeightSync: Bool { Self.flag(spoolmanDisableWeightSync, default: false) }
    var reportsPartialUsage: Bool { Self.flag(spoolmanReportPartialUsage, default: true) }
    var autoAddsUnknownRfid: Bool { Self.flag(autoAddUnknownRfid, default: true) }

    /// Interprets a stored flag; an empty string means "use the default".
    static func flag(_ value: JSONValue?, default fallback: Bool) -> Bool {
        switch value {
        case .bool(let b)?: return b
        case .number(let n)?: return n != 0
        case .string(let s)?:
            let v = s.trimmingCharacters(in: .whitespaces).lowercased()
            if v.isEmpty { return fallback }
            if ["true", "1", "yes", "on"].contains(v) { return true }
            if ["false", "0", "no", "off"].contains(v) { return false }
            return fallback
        default: return fallback
        }
    }

    /// Body for `PUT /settings/spoolman` changing a single key (booleans are sent as "true"/"false").
    static func body(_ key: String, _ value: Bool) -> JSONValue { .object([key: .string(value ? "true" : "false")]) }
    static func body(_ key: String, _ value: String) -> JSONValue { .object([key: .string(value)]) }
}

/// `GET /spoolman/status`.
struct SettingsSpoolmanStatus: Codable, Sendable, Equatable {
    var enabled: Bool?
    var connected: Bool?
    var url: String?
}

/// A spool the AMS → Spoolman sync could not match.
struct SettingsSpoolmanSkippedSpool: Codable, Sendable, Hashable {
    var location: String?
    var reason: String?
    var filamentType: String?
    var color: String?
}

/// `POST /spoolman/sync-all` and `POST /spoolman/sync/{printer_id}`.
struct SettingsSpoolmanSyncResult: Codable, Sendable {
    var success: Bool?
    var syncedCount: Int?
    var skippedCount: Int?
    var skipped: [SettingsSpoolmanSkippedSpool]?
    var errors: [String]?
}

/// `POST /inventory/sync-ams-weights` and `POST /spoolman/inventory/sync-ams-weights`.
struct SettingsSpoolmanWeightSyncResult: Codable, Sendable {
    var synced: Int?
    var skipped: Int?
}

/// `POST /spoolman/connect`.
struct SettingsSpoolmanMessage: Codable, Sendable {
    var success: Bool?
    var message: String?
}

// MARK: - State

/// Loads and mutates the Spoolman integration. Owned by the Filament & AMS page so its
/// polling and alerts live at page level rather than inside a list row.
@MainActor
@Observable
final class SettingsSpoolmanModel {
    var config: SettingsSpoolmanConfig?
    var loadError: String?
    var status: SettingsSpoolmanStatus?
    var statusLoading = false
    var saving = false
    var connectError: String?
    var connecting = false
    var syncing = false
    var lastSync: SettingsSpoolmanSyncResult?
    let runner = ActionRunner()

    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private weak var store: ServerSettingsStore?

    func attach(session: AppSession, store: ServerSettingsStore) {
        self.session = session
        self.store = store
    }

    /// Loads the configuration, then keeps the connection status fresh until cancelled.
    func run() async {
        await loadConfig()
        while !Task.isCancelled {
            await loadStatus()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func reload() async {
        await loadConfig()
        await loadStatus()
    }

    func loadConfig() async {
        guard let client = session?.client else { return }
        do {
            let value: SettingsSpoolmanConfig = try await client.get("settings/spoolman")
            config = value
            loadError = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            if config == nil { loadError = error.localizedDescription }
        }
    }

    func loadStatus() async {
        guard let session, session.can("filaments:read") else { return }
        statusLoading = true
        defer { statusLoading = false }
        if let value: SettingsSpoolmanStatus = try? await session.client.get("spoolman/status") {
            status = value
        }
    }

    func update(_ body: JSONValue) async {
        guard let client = session?.client else { return }
        saving = true
        defer { saving = false }
        do {
            let updated: SettingsSpoolmanConfig = try await client.send(.put, "settings/spoolman", body: body)
            config = updated
            connectError = nil
            runner.successMessage = "Saved"
            // The general settings blob mirrors these values; keep it current for other pages.
            await store?.load()
            await loadStatus()
        } catch {
            runner.errorMessage = error.localizedDescription
        }
    }

    func connect() async {
        guard let client = session?.client else { return }
        connecting = true
        defer { connecting = false }
        do {
            let _: SettingsSpoolmanMessage = try await client.send(.post, "spoolman/connect")
            connectError = nil
        } catch {
            connectError = error.localizedDescription
        }
        await loadStatus()
    }

    func syncAMS(printerId: Int?) async {
        guard let client = session?.client else { return }
        syncing = true
        defer { syncing = false }
        await runner.run(nil) {
            let path = printerId.map { "spoolman/sync/\($0)" } ?? "spoolman/sync-all"
            let result: SettingsSpoolmanSyncResult = try await client.send(.post, path)
            lastSync = result
            let count = result.syncedCount ?? 0
            runner.successMessage = "Synced \(count) \(count == 1 ? "spool" : "spools")"
        }
    }

    func syncInventoryWeights() async {
        guard let client = session?.client else { return }
        await runner.run(nil) {
            let result: SettingsSpoolmanWeightSyncResult = try await client.send(.post, "inventory/sync-ams-weights")
            runner.successMessage = "Updated \(result.synced ?? 0), skipped \(result.skipped ?? 0)"
        }
    }

    func syncSpoolmanWeights() async {
        guard let client = session?.client else { return }
        runner.isRunning = true
        defer { runner.isRunning = false }
        do {
            let result: SettingsSpoolmanWeightSyncResult = try await client.send(.post, "spoolman/inventory/sync-ams-weights")
            runner.successMessage = "Updated \(result.synced ?? 0), skipped \(result.skipped ?? 0)"
        } catch let error as APIError where error.status == 503 {
            runner.errorMessage = "Spoolman couldn't be reached. Check that the server is running."
        } catch let error as APIError where error.status == 400 {
            runner.errorMessage = "Spoolman isn't set up yet. Enable it and enter the server URL first."
        } catch is CancellationError {
        } catch {
            runner.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Sections

/// Filament tracking mode (built-in inventory vs. Spoolman) and the Spoolman integration,
/// rendered as a group of `Form` sections. The owning page runs `model.run()` and shows
/// `model.runner`'s alerts.
struct SettingsSpoolmanSection: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printerStore
    let model: SettingsSpoolmanModel

    @State private var urlDraft = ""
    @FocusState private var urlFocused: Bool
    @State private var syncPrinterId: Int?
    @State private var showAllSkipped = false
    @State private var confirmInventoryWeights = false
    @State private var confirmSpoolmanWeights = false

    private var canEdit: Bool { session.can("settings:update") }

    var body: some View {
        modeSection
        if let config = model.config {
            if config.enabled {
                serverSection(config)
                connectionSection(config)
                if model.status?.connected == true {
                    syncSection
                    if let lastSync = model.lastSync { syncResultSection(lastSync) }
                }
            } else {
                builtInSection
            }
        }
    }

    // MARK: Sections

    private var modeSection: some View {
        Section {
            if let config = model.config {
                Picker(selection: Binding(get: { config.enabled }, set: { value in
                    Task { await model.update(SettingsSpoolmanConfig.body("spoolman_enabled", value)) }
                })) {
                    SettingsLabel("Built-in Inventory", help: "RFID matching and usage tracking inside Bambuddy.").tag(false)
                    SettingsLabel("Spoolman", help: "Track filament in an external Spoolman server.").tag(true)
                } label: {
                    Text("Tracking Mode")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!canEdit || model.saving)

                Toggle(isOn: Binding(get: { config.autoAddsUnknownRfid }, set: { value in
                    Task { await model.update(SettingsSpoolmanConfig.body("auto_add_unknown_rfid", value)) }
                })) {
                    SettingsLabel("Auto-Add Unknown RFID Spools",
                                  help: "Create an inventory entry when a spool with an unrecognized RFID tag is loaded. Turn off if you register new spools yourself, to avoid duplicates.")
                }
                .disabled(!canEdit || model.saving)
            } else if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                Button("Try Again") { Task { await model.reload() } }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            HStack {
                Text("Filament Tracking")
                if model.saving { ProgressView().controlSize(.small) }
            }
        } footer: {
            if model.config != nil {
                Text("Switching modes keeps the slot assignments of both, so you can switch back.")
            }
        }
    }

    private var builtInSection: some View {
        Section {
            Button("Sync Spool Weights from AMS…", systemImage: "arrow.triangle.2.circlepath") { confirmInventoryWeights = true }
                .disabled(!session.can("inventory:update") || model.runner.isRunning)
                .confirm("Sync Spool Weights from AMS?", isPresented: $confirmInventoryWeights,
                         message: "Every assigned inventory spool's weight will be overwritten with the remaining percentage reported by the AMS. Use this to recover from bad weight data. Printers must be online.",
                         action: "Sync Weights", role: nil) {
                    Task { await model.syncInventoryWeights() }
                }
        } header: {
            Text("Built-in Inventory")
        } footer: {
            Text("Bambu Lab RFID spools are recognized automatically and usage is tracked per print. Third-party spools can be assigned to AMS slots manually. The sync overwrites stored weights with the AMS estimates.")
        }
    }

    private func serverSection(_ config: SettingsSpoolmanConfig) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                SettingsLabel("Server URL")
                TextField("http://192.168.1.100:7912", text: $urlDraft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($urlFocused)
                    .onSubmit(commitURL)
                    .padding(8)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    .disabled(!canEdit)
            }
            .padding(.vertical, 2)
            .onAppear { if !urlFocused { urlDraft = config.url } }
            .onChange(of: config.url) { _, url in if !urlFocused { urlDraft = url } }
            .onChange(of: urlFocused) { _, focused in if !focused { commitURL() } }

            Picker(selection: Binding(get: { config.syncMode }, set: { value in
                Task { await model.update(SettingsSpoolmanConfig.body("spoolman_sync_mode", value)) }
            })) {
                Text("Automatic").tag("auto")
                Text("Manual").tag("manual")
                if !["auto", "manual"].contains(config.syncMode) { Text(config.syncMode).tag(config.syncMode) }
            } label: {
                SettingsLabel("Sync Mode", help: config.syncMode == "manual"
                              ? "AMS data is only sent to Spoolman when you sync manually."
                              : "AMS changes are sent to Spoolman as soon as they're detected.")
            }
            .disabled(!canEdit || model.saving)

            if config.syncMode == "auto" {
                Toggle(isOn: Binding(get: { config.disablesWeightSync }, set: { value in
                    Task { await model.update(SettingsSpoolmanConfig.body("spoolman_disable_weight_sync", value)) }
                })) {
                    SettingsLabel("Skip AMS Weight Estimates",
                                  help: "Don't overwrite remaining weight with the AMS percentage estimate; rely on Spoolman's own usage tracking. New spools still start from the AMS estimate.")
                }
                .disabled(!canEdit || model.saving)
            }
            if config.disablesWeightSync {
                Toggle(isOn: Binding(get: { config.reportsPartialUsage }, set: { value in
                    Task { await model.update(SettingsSpoolmanConfig.body("spoolman_report_partial_usage", value)) }
                })) {
                    SettingsLabel("Report Usage of Failed Prints",
                                  help: "When a print fails or is canceled, report the filament used so far, estimated from layer progress.")
                }
                .disabled(!canEdit || model.saving)
            }
        } header: {
            Text("Spoolman Server")
        } footer: {
            Text("Bambu Lab RFID spools sync automatically and missing Spoolman spools are created. Third-party spools are skipped unless assigned to a slot. To link an existing Spoolman spool, set its \"tag\" extra field to the spool's RFID tag.")
        }
    }

    private func connectionSection(_ config: SettingsSpoolmanConfig) -> some View {
        Section {
            LabeledContent("Status") {
                if model.statusLoading, model.status == nil {
                    ProgressView()
                } else if model.status?.connected == true {
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Not Connected", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            if model.status?.connected != true {
                Button {
                    Task { await model.connect() }
                } label: {
                    HStack {
                        Label("Connect", systemImage: "link")
                        if model.connecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(!canEdit || model.connecting || config.url.isEmpty)
            }
            Button("Check Again", systemImage: "arrow.clockwise") { Task { await model.loadStatus() } }
                .disabled(model.statusLoading)
            if let error = model.connectError {
                SettingsTestResultLabel(success: false, message: error)
            }
        } header: {
            Text("Connection")
        } footer: {
            if config.url.isEmpty {
                Text("Enter the Spoolman server URL to connect.")
            }
        }
    }

    private var syncSection: some View {
        Section {
            Picker("Printer", selection: $syncPrinterId) {
                Text("All Printers").tag(Int?.none)
                ForEach(printerStore.printers) { printer in
                    Text(printer.name).tag(Int?.some(printer.id))
                }
            }
            Button {
                showAllSkipped = false
                Task { await model.syncAMS(printerId: syncPrinterId) }
            } label: {
                HStack {
                    Label("Sync AMS to Spoolman", systemImage: "arrow.triangle.2.circlepath")
                    if model.syncing { Spacer(); ProgressView() }
                }
            }
            .disabled(model.syncing || !session.can("filaments:update"))
            Button("Sync Spoolman Weights from AMS…", systemImage: "scalemass") { confirmSpoolmanWeights = true }
                .disabled(model.runner.isRunning || !session.can("inventory:update"))
                .confirm("Sync Spoolman Weights from AMS?", isPresented: $confirmSpoolmanWeights,
                         message: "Remaining weight in Spoolman will be updated from the AMS remaining percentage for every assigned spool. Printers must be online.",
                         action: "Sync Weights", role: nil) {
                    Task { await model.syncSpoolmanWeights() }
                }
        } header: {
            Text("Sync")
        } footer: {
            Text("Sends the spools currently loaded in the AMS to Spoolman.")
        }
    }

    private func syncResultSection(_ result: SettingsSpoolmanSyncResult) -> some View {
        let synced = result.syncedCount ?? 0
        let errors = result.errors ?? []
        let skipped = result.skipped ?? []
        let skippedCount = result.skippedCount ?? skipped.count
        let visibleSkipped = showAllSkipped ? skipped : Array(skipped.prefix(5))
        let succeeded = result.success ?? errors.isEmpty
        let spools = synced == 1 ? "spool" : "spools"
        return Section("Last Sync") {
            Label(errors.isEmpty ? "Synced \(synced) \(spools)"
                  : "Synced \(synced) \(spools) with \(errors.count) \(errors.count == 1 ? "error" : "errors")",
                  systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(succeeded ? .green : .orange)
            if skippedCount > 0 {
                DisclosureGroup("\(skippedCount) skipped") {
                    ForEach(Array(visibleSkipped.enumerated()), id: \.offset) { _, spool in
                        HStack(spacing: 8) {
                            if let color = spool.color, !color.isEmpty { ColorSwatch(hex: color, size: 14) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text([spool.location, spool.filamentType].compactMap { $0 }.joined(separator: " · "))
                                    .font(.subheadline)
                                if let reason = spool.reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    if skipped.count > 5 {
                        Button(showAllSkipped ? "Show Less" : "Show All \(skipped.count)") { showAllSkipped.toggle() }
                    }
                }
            }
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                Label(error, systemImage: "xmark.octagon").font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func commitURL() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespaces)
        guard let config = model.config, trimmed != config.url else { return }
        Task { await model.update(SettingsSpoolmanConfig.body("spoolman_url", trimmed)) }
    }
}

