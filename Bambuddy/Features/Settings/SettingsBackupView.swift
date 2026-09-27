import SwiftUI
import UniformTypeIdentifiers

/// Backup & restore: full backup download/restore, scheduled local backups on the server, and
/// the entry point to Git repository backups.
struct SettingsBackupView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store

    @State private var status = Loader<SettingsLocalBackupStatus>()
    @State private var pathCheck: SettingsLocalBackupPathCheck?
    @State private var files = Loader<[SettingsLocalBackupFile]>()
    @State private var gitStatus: SettingsGitHubBackupStatus?
    @State private var runner = ActionRunner()
    @State private var busyMessage: String?
    @State private var sharedFile: SettingsBackupDownloadedFile?
    @State private var showImporter = false
    @State private var pendingUpload: SettingsBackupPendingUpload?
    @State private var confirmText = ""
    @State private var pendingServerRestore: SettingsLocalBackupFile?
    @State private var pendingDelete: SettingsLocalBackupFile?
    @State private var restoreOutcome: String?

    private var canBackup: Bool { session.can("settings:backup") }
    private var canRestore: Bool { session.can("settings:restore") }

    var body: some View {
        List {
            Section {
                Label("Backups contain your whole database, including printer access codes, API tokens and the key that protects stored secrets. Keep them somewhere safe.", systemImage: "lock.shield")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            fullBackupSection
            if canBackup {
                scheduleSection
                savedBackupsSection
            }
            if session.can("github:backup") || session.can("github:restore") {
                gitSection
            }
        }
        .navigationTitle("Backup & Restore")
        .disabled(busyMessage != nil)
        .overlay {
            if let busyMessage {
                SettingsBackupBusyOverlay(message: busyMessage)
            }
        }
        .task { await reload() }
        .task(id: status.value?.isRunning == true) {
            // Poll while a scheduled/manual backup is running on the server.
            guard status.value?.isRunning == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await loadStatus()
                if status.value?.isRunning != true { await loadFiles(); break }
            }
        }
        .task(id: store.saveCount) { await loadStatus(); await loadPathCheck() }
        .refreshable { await reload(includeStore: true) }
        .actionAlerts(runner)
        .modifier(SettingsAuthSaveErrorAlert())
        .sheet(item: $sharedFile) { SettingsBackupFileSheet(file: $0) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip]) { result in
            handleImport(result)
        }
        .alert("Replace Everything on the Server?", isPresented: Binding(get: { pendingUpload != nil }, set: { if !$0 { pendingUpload = nil; confirmText = "" } })) {
            TextField("RESTORE", text: $confirmText)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) { confirmText = "" }
            Button("Restore", role: .destructive) {
                if let upload = pendingUpload { Task { await restoreUpload(upload) } }
            }
            .disabled(confirmText.trimmingCharacters(in: .whitespaces).uppercased() != "RESTORE")
        } message: {
            Text("All data on the server — printers, archives, inventory, settings and users — will be replaced with the contents of \(pendingUpload?.name ?? "the backup"). This can't be undone. Type RESTORE to continue.")
        }
        .confirmationDialog("Restore \(pendingServerRestore?.filename ?? "Backup")?", isPresented: Binding(get: { pendingServerRestore != nil }, set: { if !$0 { pendingServerRestore = nil } }), titleVisibility: .visible, presenting: pendingServerRestore) { file in
            Button("Replace All Data and Restore", role: .destructive) { Task { await restoreServerFile(file) } }
        } message: { _ in
            Text("Everything on the server will be replaced with this backup. This can't be undone, and Bambuddy needs a restart afterwards.")
        }
        .confirmationDialog("Delete \(pendingDelete?.filename ?? "Backup")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { file in
            Button("Delete", role: .destructive) { Task { await delete(file) } }
        } message: { _ in
            Text("The backup file is removed from the server.")
        }
        .alert("Restore Complete", isPresented: Binding(get: { restoreOutcome != nil }, set: { if !$0 { restoreOutcome = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(restoreOutcome ?? "") }
    }

    // MARK: Full backup

    private var fullBackupSection: some View {
        Section {
            if canBackup {
                Button { Task { await downloadFullBackup() } } label: {
                    Label("Download Backup", systemImage: "arrow.down.doc")
                }
            }
            if canRestore {
                Button(role: .destructive) { showImporter = true } label: {
                    Label("Restore from File…", systemImage: "arrow.counterclockwise")
                }
            }
            if !canBackup && !canRestore {
                Text("You don't have permission to create or restore backups.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Full Backup")
        } footer: {
            Text("A ZIP with the database and all files (archives, thumbnails, timelapses, library). Restoring replaces everything on the server and requires restarting Bambuddy afterwards.")
        }
    }

    // MARK: Scheduled local backups

    @ViewBuilder
    private var scheduleSection: some View {
        let s = status.value
        let enabled = store.hasLoaded ? store.bool("local_backup_enabled") : (s?.enabled ?? false)
        Section {
            if store.hasLoaded {
                SettingsToggle("Scheduled Backups", key: "local_backup_enabled", help: "Create a full backup on the server automatically.")
                if enabled {
                    SettingsPicker("Frequency", key: "local_backup_schedule", choices: [("hourly", "Hourly"), ("daily", "Daily"), ("weekly", "Weekly")])
                    if store.string("local_backup_schedule", default: "daily") != "hourly" {
                        DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                            .environment(\.timeZone, .gmt)
                            .disabled(!store.canEdit)
                    }
                    SettingsStepper("Keep", key: "local_backup_retention", range: 1...100, unit: "backups", default: 5)
                    SettingsTextField("Folder", key: "local_backup_path", prompt: s?.defaultPath ?? "Default folder",
                                      help: "Leave empty to use \(s?.defaultPath ?? "the server's data folder").")
                }
            } else if let s {
                LabeledContent("Scheduled Backups", value: s.enabled == true ? "On" : "Off")
                if s.enabled == true {
                    LabeledContent("Frequency", value: (s.schedule ?? "daily").capitalized)
                    if s.schedule != "hourly" { LabeledContent("Time", value: s.time ?? "03:00") }
                    LabeledContent("Keep", value: "\(s.retention ?? 5) backups")
                    LabeledContent("Folder", value: (s.path ?? "").isEmpty ? (s.defaultPath ?? "Default") : (s.path ?? ""))
                }
            }
            if let check = pathCheck { pathCheckRows(check) }
            if let s {
                if let last = s.lastBackupAt {
                    LabeledContent("Last Backup") {
                        HStack(spacing: 6) {
                            StatusBadge(text: s.lastStatus == "success" ? "Succeeded" : (s.lastStatus ?? "Unknown").capitalized,
                                        color: s.lastStatus == "success" ? .green : .red)
                            Text(Fmt.relative(last)).foregroundStyle(.secondary)
                        }
                    }
                    if s.lastStatus == "failed", let message = s.lastMessage, !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.red)
                    }
                }
                if let next = s.nextRun, enabled {
                    LabeledContent("Next Backup", value: Fmt.date(next))
                }
            }
            Button {
                Task { await runNow() }
            } label: {
                HStack {
                    Label(s?.isRunning == true ? "Backing Up…" : "Back Up Now", systemImage: "play.circle")
                    if s?.isRunning == true { Spacer(); ProgressView() }
                }
            }
            .disabled(s?.isRunning == true || runner.isRunning)
        } header: {
            Text("Scheduled Backups")
        } footer: {
            if let tz = s?.timezone, store.string("local_backup_schedule", default: "daily") != "hourly" {
                Text("Times use the server's time zone (\(tz)). Older backups beyond the number to keep are deleted automatically.")
            } else {
                Text("Older backups beyond the number to keep are deleted automatically.")
            }
        }
    }

    @ViewBuilder
    private func pathCheckRows(_ check: SettingsLocalBackupPathCheck) -> some View {
        if check.writable == false {
            VStack(alignment: .leading, spacing: 6) {
                Label("Backups can't be written to this folder", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                if let message = check.message { Text(message).font(.footnote) }
                if let remedy = check.remedy, !remedy.isEmpty {
                    Text("How to fix").font(.footnote.weight(.semibold))
                    Text(remedy).font(.caption.monospaced()).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 6))
                }
                if let detail = check.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } else if check.warning == "container_ephemeral" {
            VStack(alignment: .leading, spacing: 6) {
                Label("Backups are stored inside the container", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text("\(check.path ?? "This folder") isn't on a mounted volume, so backups are lost when the container is recreated. Choose a folder on a mounted volume.")
                    .font(.footnote)
                if let remedy = check.remedy, !remedy.isEmpty {
                    Text(remedy).font(.caption.monospaced()).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 6))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Self.date(fromTime: store.string("local_backup_time", default: "03:00")) },
            set: { store.stage("local_backup_time", .string(Self.time(from: $0))) }
        )
    }

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }

    static func date(fromTime raw: String) -> Date {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        let hour = parts.first.map { min(max($0, 0), 23) } ?? 3
        let minute = parts.count > 1 ? min(max(parts[1], 0), 59) : 0
        return utcCalendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)) ?? .now
    }

    static func time(from date: Date) -> String {
        let c = utcCalendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    // MARK: Saved backups

    @ViewBuilder
    private var savedBackupsSection: some View {
        Section {
            if let list = files.value {
                if list.isEmpty {
                    Text("No backups on the server yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(list) { file in fileRow(file) }
                }
            } else if let error = files.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Backups on Server")
        } footer: {
            if let list = files.value, !list.isEmpty {
                Text("Swipe or touch and hold a backup to download, restore or delete it.")
            }
        }
    }

    private func fileRow(_ file: SettingsLocalBackupFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.zipper").font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename).font(.subheadline).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.bytes(file.size)) · \(Fmt.date(file.createdAt))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                fileActions(file)
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .buttonStyle(.borderless)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = file } label: { Label("Delete", systemImage: "trash") }
            Button { Task { await download(file) } } label: { Label("Download", systemImage: "arrow.down.circle") }.tint(.blue)
        }
        .contextMenu { fileActions(file) }
    }

    @ViewBuilder
    private func fileActions(_ file: SettingsLocalBackupFile) -> some View {
        Button { Task { await download(file) } } label: { Label("Download", systemImage: "arrow.down.circle") }
        if canRestore {
            Button { pendingServerRestore = file } label: { Label("Restore…", systemImage: "arrow.counterclockwise") }
        }
        Button(role: .destructive) { pendingDelete = file } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Git

    private var gitSection: some View {
        Section {
            NavigationLink {
                SettingsGitHubBackupView()
            } label: {
                LabeledContent {
                    if let g = gitStatus {
                        if g.configured != true {
                            StatusBadge(text: "Not Set Up")
                        } else if g.enabled != true {
                            StatusBadge(text: "Off")
                        } else if g.isRunning == true || g.restoreRunning == true {
                            StatusBadge(text: "Running", color: .blue)
                        } else if g.lastBackupStatus == "failed" {
                            StatusBadge(text: "Failed", color: .red)
                        } else {
                            StatusBadge(text: "On", color: .green)
                        }
                    }
                } label: {
                    Label("Git Repository Backup", systemImage: "arrow.triangle.branch")
                }
            }
        } footer: {
            Text("Push profiles, settings, inventory and archive history to a private GitHub, GitLab, Gitea or Forgejo repository, and restore them from any commit.")
        }
    }

    // MARK: Loading

    private func reload(includeStore: Bool = false) async {
        if includeStore || (!store.hasLoaded && !store.isLoading && session.can("settings:read")) { await store.load() }
        if canBackup {
            await loadStatus()
            await loadPathCheck()
            await loadFiles()
        }
        if session.can("github:backup") {
            gitStatus = try? await session.client.get("github-backup/status")
        }
    }

    private func loadStatus() async {
        guard canBackup else { return }
        let client = session.client
        await status.load { try await client.get("local-backup/status") }
    }

    private func loadPathCheck() async {
        guard canBackup else { return }
        if let check: SettingsLocalBackupPathCheck = try? await session.client.get("local-backup/path-check") { pathCheck = check }
    }

    private func loadFiles() async {
        let client = session.client
        await files.load { try await client.get("local-backup/backups") }
    }

    // MARK: Actions

    private func downloadFullBackup() async {
        busyMessage = "Creating backup… This can take a while for large libraries."
        defer { busyMessage = nil }
        await runner.run {
            let url = try await session.client.download("settings/backup")
            sharedFile = SettingsBackupDownloadedFile(url: url)
        }
    }

    private func download(_ file: SettingsLocalBackupFile) async {
        busyMessage = "Downloading \(file.filename)…"
        defer { busyMessage = nil }
        await runner.run {
            let url = try await session.client.download("local-backup/backups/\(Self.pathComponent(file.filename))/download", suggestedName: file.filename)
            sharedFile = SettingsBackupDownloadedFile(url: url)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                confirmText = ""
                pendingUpload = SettingsBackupPendingUpload(name: url.lastPathComponent, data: data)
            } catch {
                runner.errorMessage = "Couldn't read the file: \(error.localizedDescription)"
            }
        case .failure(let error):
            runner.errorMessage = error.localizedDescription
        }
    }

    private func restoreUpload(_ upload: SettingsBackupPendingUpload) async {
        pendingUpload = nil
        confirmText = ""
        busyMessage = "Uploading and restoring \(upload.name)… Keep the app open."
        defer { busyMessage = nil }
        await runner.run {
            let file = UploadFile(fileName: upload.name, mimeType: "application/zip", data: upload.data)
            let result: SettingsBackupActionResult = try await session.client.upload("settings/restore", files: [file])
            try handleRestoreResult(result)
        }
        await afterRestore()
    }

    private func restoreServerFile(_ file: SettingsLocalBackupFile) async {
        busyMessage = "Restoring \(file.filename)… Keep the app open."
        defer { busyMessage = nil }
        await runner.run {
            let result: SettingsBackupActionResult = try await session.client.send(.post, "local-backup/backups/\(Self.pathComponent(file.filename))/restore")
            try handleRestoreResult(result)
        }
        await afterRestore()
    }

    private func handleRestoreResult(_ result: SettingsBackupActionResult) throws {
        guard result.success != false else {
            throw APIError(status: 200, message: result.message ?? "Restore failed.", code: nil, detail: nil)
        }
        restoreOutcome = result.message ?? "The backup was restored. Restart Bambuddy for all changes to take effect."
    }

    private func afterRestore() async {
        guard restoreOutcome != nil else { return }
        await reload(includeStore: session.can("settings:read"))
        await session.printers.refresh()
    }

    private func runNow() async {
        await runner.run {
            let result: SettingsBackupActionResult = try await session.client.send(.post, "local-backup/run")
            guard result.success != false else {
                throw APIError(status: 200, message: result.message ?? "Backup failed.", code: nil, detail: nil)
            }
            runner.successMessage = "Backup created"
        }
        await loadStatus()
        await loadFiles()
    }

    private func delete(_ file: SettingsLocalBackupFile) async {
        await runner.run("Backup deleted") {
            let result: SettingsBackupActionResult = try await session.client.send(.delete, "local-backup/backups/\(Self.pathComponent(file.filename))")
            guard result.success != false else {
                throw APIError(status: 200, message: result.message ?? "Couldn't delete the backup.", code: nil, detail: nil)
            }
        }
        await loadFiles()
    }

    static func pathComponent(_ name: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }
}

private struct SettingsBackupPendingUpload {
    let name: String
    let data: Data
}

// MARK: - Shared download presentation

/// A file downloaded to a temporary location, ready to share or save.
struct SettingsBackupDownloadedFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// Sheet that offers a downloaded file for sharing / saving to Files.
struct SettingsBackupFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: SettingsBackupDownloadedFile

    private var size: Int64? {
        (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                VStack(spacing: 4) {
                    Text(file.url.lastPathComponent).font(.headline).multilineTextAlignment(.center)
                    Text(Fmt.bytes(size)).font(.subheadline).foregroundStyle(.secondary)
                }
                ShareLink(item: file.url) {
                    Label("Share or Save to Files", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Store this file somewhere safe — it contains sensitive data.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 420)
            .navigationTitle("Download Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Blocking progress overlay for long-running server operations.
struct SettingsBackupBusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(message).font(.subheadline).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
        }
        .transition(.opacity)
    }
}
