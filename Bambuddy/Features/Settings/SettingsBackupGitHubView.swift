import SwiftUI

/// Git repository backup (GitHub, GitLab, Gitea, Forgejo): configuration, manual runs, history
/// and restore.
struct SettingsGitHubBackupView: View {
    @Environment(AppSession.self) private var session

    @State private var config: SettingsGitHubBackupConfig?
    @State private var loaded = false
    @State private var loadError: String?
    @State private var status: SettingsGitHubBackupStatus?
    @State private var logs: [SettingsGitHubBackupLog] = []
    @State private var runner = ActionRunner()
    @State private var testResult: SettingsGitHubTestResult?
    @State private var isTesting = false
    @State private var showEditor = false
    @State private var showRestore = false
    @State private var confirmRemove = false
    @State private var confirmClearLogs = false

    private var canManage: Bool { session.can("github:backup") }
    private var canRestore: Bool { session.can("github:restore") }
    private var busy: Bool { status?.isRunning == true || status?.restoreRunning == true }

    var body: some View {
        Group {
            if loaded {
                list
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Git Backup", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) } actions: {
                    Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Git Backup")
        .toolbar {
            if config != nil && canManage {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { showEditor = true }
                }
            }
        }
        .task { await load() }
        .task(id: busy) {
            guard busy else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await loadStatus()
                if !busy { await load(); break }
            }
        }
        .actionAlerts(runner)
        .sheet(isPresented: $showEditor) {
            SettingsGitHubBackupEditor(config: config) { await load() }
        }
        .sheet(isPresented: $showRestore, onDismiss: { Task { await load() } }) {
            SettingsGitHubRestoreSheet()
        }
        .confirm("Remove Git Backup?", isPresented: $confirmRemove,
                 message: "The configuration, stored access token and backup history are deleted. The repository itself is not touched.",
                 action: "Remove") {
            Task { await removeConfig() }
        }
        .confirm("Clear Backup History?", isPresented: $confirmClearLogs, message: "All entries in the backup history are deleted.", action: "Clear") {
            Task { await clearLogs() }
        }
    }

    private var list: some View {
        List {
            if let config {
                statusSection(config)
                configSection(config)
                actionsSection
                historySection
            } else {
                Section {
                    ContentUnavailableView {
                        Label("Not Set Up", systemImage: "arrow.triangle.branch")
                    } description: {
                        Text("Back up K-profiles, cloud presets, settings, spool inventory and archive history to a private Git repository.")
                    } actions: {
                        if canManage { Button("Set Up Git Backup") { showEditor = true }.buttonStyle(.borderedProminent) }
                    }
                }
            }
        }
        .refreshable { await load() }
    }

    // MARK: Sections

    private func statusSection(_ config: SettingsGitHubBackupConfig) -> some View {
        Section {
            if canManage {
                Toggle("Enabled", isOn: Binding(get: { config.enabled == true }, set: { on in Task { await patch(["enabled": .bool(on)], success: on ? "Git backup turned on" : "Git backup turned off") } }))
                    .disabled(runner.isRunning)
            }
            if busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(status?.progress ?? (status?.restoreRunning == true ? "Restoring…" : "Backing up…")).font(.subheadline)
                }
            }
            LabeledContent("Last Backup") {
                if let last = status?.lastBackupAt ?? config.lastBackupAt {
                    HStack(spacing: 6) {
                        SettingsGitHubStatusBadge(status: status?.lastBackupStatus ?? config.lastBackupStatus)
                        Text(Fmt.relative(last)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Never").foregroundStyle(.secondary)
                }
            }
            if let message = config.lastBackupMessage, !message.isEmpty, (status?.lastBackupStatus ?? config.lastBackupStatus) == "failed" {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            if let sha = config.lastBackupCommitSha, !sha.isEmpty {
                LabeledContent("Last Commit") { Text(String(sha.prefix(7))).font(.body.monospaced()).textSelection(.enabled) }
            }
            if let next = status?.nextScheduledRun ?? config.nextScheduledRun, config.scheduleEnabled == true {
                LabeledContent("Next Backup", value: Fmt.date(next))
            }
        } header: {
            Text("Status")
        }
    }

    private func configSection(_ config: SettingsGitHubBackupConfig) -> some View {
        Section {
            LabeledContent("Provider", value: SettingsGitHubBackupEditor.providerName(config.provider))
            LabeledContent("Repository") {
                Text(config.repositoryUrl ?? "—").lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            LabeledContent("Branch", value: config.branch ?? "main")
            LabeledContent("Access Token", value: config.hasToken == true ? "Saved" : "Missing")
            LabeledContent("Schedule", value: config.scheduleEnabled == true ? (config.scheduleType ?? "daily").capitalized : "Manual only")
            LabeledContent("Includes", value: includes(config))
        } header: {
            Text("Configuration")
        }
    }

    private var actionsSection: some View {
        Section {
            if canManage {
                Button {
                    Task { await runBackup() }
                } label: {
                    Label("Back Up Now", systemImage: "arrow.up.circle")
                }
                .disabled(busy || runner.isRunning || config?.enabled != true)
                Button {
                    Task { await testStored() }
                } label: {
                    HStack {
                        Label("Test Connection", systemImage: "bolt.horizontal.circle")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting)
                if let testResult { SettingsGitHubTestResultView(result: testResult) }
            }
            if canRestore {
                Button {
                    showRestore = true
                } label: {
                    Label("Restore from Repository…", systemImage: "clock.arrow.circlepath")
                }
                .disabled(busy)
            }
            if canManage {
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Remove Configuration…", systemImage: "trash")
                }
            }
        } footer: {
            if config?.enabled != true { Text("Turn the backup on to run it.") }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        Section {
            if logs.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary)
            } else {
                ForEach(logs) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            SettingsGitHubStatusBadge(status: log.status)
                            Text((log.trigger ?? "").capitalized).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.date(log.startedAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            if let sha = log.commitSha, !sha.isEmpty {
                                Label(String(sha.prefix(7)), systemImage: "number").font(.caption.monospaced())
                            }
                            if let changed = log.filesChanged, log.status == "success" || changed > 0 {
                                Text(changed == 1 ? "1 file changed" : "\(changed) files changed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let error = log.errorMessage, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text("History")
                Spacer()
                if canManage && !logs.isEmpty {
                    Button("Clear") { confirmClearLogs = true }.font(.caption).textCase(nil)
                }
            }
        }
    }

    private func includes(_ c: SettingsGitHubBackupConfig) -> String {
        var parts: [String] = []
        if c.backupKprofiles == true { parts.append("K-profiles") }
        if c.backupCloudProfiles == true { parts.append("Cloud presets") }
        if c.backupSettings == true { parts.append("Settings") }
        if c.backupSpools == true { parts.append("Spools") }
        if c.backupArchives == true { parts.append("Archives") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: ", ")
    }

    // MARK: Loading

    private func load() async {
        do {
            config = try await session.client.get("github-backup/config", as: SettingsGitHubBackupConfig?.self)
            loadError = nil
            loaded = true
        } catch is CancellationError {
            return
        } catch {
            if !loaded { loadError = error.localizedDescription } else { runner.errorMessage = error.localizedDescription }
            return
        }
        await loadStatus()
        if config != nil, canManage {
            logs = (try? await session.client.get("github-backup/logs", query: ["limit": 20])) ?? logs
        } else {
            logs = []
        }
    }

    private func loadStatus() async {
        if let s: SettingsGitHubBackupStatus = try? await session.client.get("github-backup/status") { status = s }
    }

    // MARK: Actions

    private func patch(_ changes: [String: JSONValue], success: String) async {
        await runner.run(success) {
            config = try await session.client.send(.patch, "github-backup/config", body: JSONValue.object(changes))
        }
        await loadStatus()
    }

    private func runBackup() async {
        status?.isRunning = true
        await runner.run {
            let result: SettingsGitHubTriggerResult = try await session.client.send(.post, "github-backup/run")
            guard result.success != false else {
                throw APIError(status: 200, message: result.message ?? "Backup failed.", code: nil, detail: nil)
            }
            if let changed = result.filesChanged, changed > 0 {
                runner.successMessage = changed == 1 ? "Backed up 1 changed file" : "Backed up \(changed) changed files"
            } else {
                runner.successMessage = result.message ?? "Nothing changed since the last backup"
            }
        }
        await load()
    }

    private func testStored() async {
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        do {
            testResult = try await session.client.send(.post, "github-backup/test-stored")
        } catch {
            testResult = SettingsGitHubTestResult(success: false, message: error.localizedDescription)
        }
    }

    private func removeConfig() async {
        await runner.run("Git backup removed") {
            try await session.client.call(.delete, "github-backup/config")
        }
        testResult = nil
        await load()
    }

    private func clearLogs() async {
        await runner.run("History cleared") {
            try await session.client.call(.delete, "github-backup/logs", query: ["keep_last": 0])
        }
        await load()
    }
}

// MARK: - Shared bits

private struct SettingsGitHubStatusBadge: View {
    let status: String?
    var body: some View {
        switch status {
        case "success": StatusBadge(text: "Succeeded", color: .green)
        case "failed": StatusBadge(text: "Failed", color: .red)
        case "running": StatusBadge(text: "Running", color: .blue)
        case "skipped": StatusBadge(text: "No Changes", color: .secondary)
        case nil: StatusBadge(text: "Unknown")
        case let other?: StatusBadge(text: other.capitalized)
        }
    }
}

struct SettingsGitHubTestResultView: View {
    let result: SettingsGitHubTestResult
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsTestResultLabel(success: result.success == true, message: result.message ?? (result.success == true ? "Connected" : "Connection failed"))
            if result.success == true {
                if let repo = result.repoName { Text(repo).font(.caption.monospaced()).foregroundStyle(.secondary) }
                switch result.isPrivate {
                case true?:
                    Label("The repository is private.", systemImage: "lock.fill").font(.caption).foregroundStyle(.green)
                case false?:
                    Label("The repository is public. Backups contain credentials, so a private repository is required.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                case nil:
                    Label("Couldn't confirm the repository is private, so it can't be used for backups.", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Editor

private struct SettingsGitHubBackupEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    @Environment(\.dismiss) private var dismiss
    let config: SettingsGitHubBackupConfig?
    var onSaved: () async -> Void

    @State private var draft = SettingsGitHubBackupDraft()
    @State private var baseline = SettingsGitHubBackupDraft()
    @State private var seeded = false
    @State private var runner = ActionRunner()
    @State private var testResult: SettingsGitHubTestResult?
    @State private var isTesting = false
    @State private var cloudAccounts: SettingsGitHubCloudAccounts?

    static let providers: [(String, String)] = [("github", "GitHub"), ("gitlab", "GitLab"), ("gitea", "Gitea"), ("forgejo", "Forgejo")]

    static func providerName(_ key: String?) -> String {
        providers.first { $0.0 == key }?.1 ?? (key ?? "GitHub")
    }

    private var isNew: Bool { config == nil }
    private var tokenTyped: Bool { !draft.accessToken.trimmingCharacters(in: .whitespaces).isEmpty }

    private var validation: String? {
        if draft.repositoryUrl.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the repository URL." }
        if draft.needsInsecureOptIn { return "This URL uses plain HTTP. Allow insecure HTTP or use HTTPS." }
        if isNew && !tokenTyped { return "Enter an access token." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $draft.provider) {
                        ForEach(Self.providers, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Repository URL").font(.subheadline).foregroundStyle(.secondary)
                        TextField(urlPlaceholder, text: $draft.repositoryUrl)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if draft.provider != "github" || draft.allowInsecureHttp {
                        Toggle(isOn: $draft.allowInsecureHttp) {
                            SettingsLabel("Allow Insecure HTTP", help: "For self-hosted servers without TLS. The token is sent unencrypted.")
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Access Token").font(.subheadline).foregroundStyle(.secondary)
                        SecureField(config?.hasToken == true ? "Saved — enter a new token to replace it" : "Personal access token", text: $draft.accessToken)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Branch").font(.subheadline).foregroundStyle(.secondary)
                        TextField("main", text: $draft.branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: {
                    Text("Repository")
                } footer: {
                    Text(tokenHelp)
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if isTesting { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(isTesting || draft.repositoryUrl.isEmpty || (!tokenTyped && config?.hasToken != true))
                    if let testResult { SettingsGitHubTestResultView(result: testResult) }
                } footer: {
                    Text("The repository must be private — backups include printer access codes and other credentials.")
                }

                Section {
                    Picker("Automatic Backups", selection: $draft.schedule) {
                        Text("Manual Only").tag("manual")
                        Text("Hourly").tag("hourly")
                        Text("Daily").tag("daily")
                        Text("Weekly").tag("weekly")
                    }
                    Toggle("Enabled", isOn: $draft.enabled)
                } header: { Text("Schedule") }

                Section {
                    Toggle(isOn: $draft.backupKprofiles) {
                        SettingsLabel("K-Profiles", help: kprofileHelp)
                    }
                    Toggle(isOn: $draft.backupCloudProfiles) {
                        SettingsLabel("Cloud Presets", help: cloudHelp)
                    }
                    Toggle(isOn: $draft.backupSettings) {
                        SettingsLabel("App Settings", help: "Bambuddy settings, notification providers and similar configuration.")
                    }
                    Toggle(isOn: $draft.backupSpools) {
                        SettingsLabel("Spool Inventory", help: "Spools and their usage history.")
                    }
                    Toggle(isOn: $draft.backupArchives) {
                        SettingsLabel("Print Archive History", help: "Archive records (not the 3MF files themselves).")
                    }
                } header: { Text("Include") }

                if let validation, draft != baseline || isNew {
                    Section { Label(validation, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(isNew ? "Set Up Git Backup" : "Edit Git Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(validation != nil || (!isNew && draft == baseline))
                    }
                }
            }
            .disabled(runner.isRunning)
            .interactiveDismissDisabled(runner.isRunning)
            .actionAlerts(runner)
            .onAppear {
                guard !seeded else { return }
                seeded = true
                if let config { draft = SettingsGitHubBackupDraft(config); baseline = draft }
            }
            .task { cloudAccounts = try? await session.client.get("github-backup/cloud-accounts") }
        }
    }

    private var urlPlaceholder: String {
        switch draft.provider {
        case "gitlab": "https://gitlab.com/owner/bambuddy-backup"
        case "gitea", "forgejo": "https://git.example.com/owner/bambuddy-backup"
        default: "https://github.com/owner/bambuddy-backup"
        }
    }

    private var tokenHelp: String {
        switch draft.provider {
        case "gitlab": "Use a project or personal access token with the api and write_repository scopes."
        case "gitea", "forgejo": "Use an access token with read and write access to repositories."
        default: "Use a fine-grained token with read and write access to Contents for this repository (or a classic token with the repo scope)."
        }
    }

    private var kprofileHelp: String {
        let total = printers.printers.count
        let connected = printers.statuses.values.filter(\.connected).count
        let base = "Pressure-advance calibrations read from connected printers."
        if total == 0 { return base }
        if connected == 0 { return base + " No printers are connected right now." }
        return base + " \(connected) of \(total) printers connected."
    }

    private var cloudHelp: String {
        let base = "Filament, printer and process presets from linked Bambu and Orca Cloud accounts."
        guard let cloudAccounts else { return base }
        if cloudAccounts.total == 0 { return base + " No cloud accounts are linked." }
        return base + " \(cloudAccounts.bambu ?? 0) Bambu, \(cloudAccounts.orca ?? 0) Orca account(s)."
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        let client = session.client
        do {
            if tokenTyped || config == nil {
                testResult = try await client.send(.post, "github-backup/test", query: [
                    "repo_url": .string(draft.repositoryUrl.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "token": .string(draft.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "provider": .string(draft.provider),
                ])
            } else {
                testResult = try await client.send(.post, "github-backup/test-stored")
            }
        } catch {
            testResult = SettingsGitHubTestResult(success: false, message: error.localizedDescription)
        }
    }

    private func save() async {
        let client = session.client
        let draft = draft
        let baseline = baseline
        let isNew = isNew
        await runner.run {
            if isNew {
                let _: SettingsGitHubBackupConfig = try await client.send(.post, "github-backup/config", body: draft.createBody())
            } else {
                let changes = draft.patchBody(from: baseline)
                guard !changes.isEmpty else { return }
                let _: SettingsGitHubBackupConfig = try await client.send(.patch, "github-backup/config", body: JSONValue.object(changes))
            }
        }
        guard runner.errorMessage == nil else { return }
        await onSaved()
        dismiss()
    }
}
