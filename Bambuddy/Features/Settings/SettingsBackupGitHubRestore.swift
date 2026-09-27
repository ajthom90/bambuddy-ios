import SwiftUI

/// Restore selected categories from one commit of the Git backup repository.
struct SettingsGitHubRestoreSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var commits: SettingsGitHubCommitList?
    @State private var commitsError: String?
    @State private var selectedRef = "HEAD"
    @State private var preview: SettingsGitHubRestorePreview?
    @State private var previewError: String?
    @State private var loadingPreview = false
    @State private var selected: Set<String> = []
    @State private var overwrite = false
    @State private var confirm = false
    @State private var runner = ActionRunner()
    @State private var result: SettingsGitHubRestoreResult?
    @State private var failure: String?

    /// Categories in the order the server applies them, with the permission that owns their rows.
    static let categories: [(id: String, title: String, symbol: String, permission: String)] = [
        ("settings", "App Settings", "gearshape", "settings:update"),
        ("spools", "Spool Inventory", "circle.circle", "inventory:update"),
        ("archives", "Print Archive History", "archivebox", "archives:update_all"),
        ("kprofiles", "K-Profiles", "thermometer.medium", "kprofiles:update"),
    ]

    static func title(for category: String) -> String {
        categories.first { $0.id == category }?.title ?? category.capitalized
    }

    private var availability: [String: SettingsGitHubRestorePreviewCategory] {
        guard preview?.success != false else { return [:] }
        return Dictionary((preview?.categories ?? []).map { ($0.category, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// What a restore would actually send: only categories the loaded preview offers.
    private var effectiveSelection: [String] {
        Self.categories.map(\.id).filter { selected.contains($0) && availability[$0]?.available == true && !loadingPreview }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    resultView(result)
                } else {
                    form
                }
            }
            .navigationTitle("Restore from Git")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }.disabled(runner.isRunning)
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if runner.isRunning {
                            ProgressView()
                        } else {
                            Button("Restore") { confirm = true }.disabled(effectiveSelection.isEmpty)
                        }
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
            .actionAlerts(runner)
            .confirmationDialog("Restore \(effectiveSelection.count == 1 ? "1 Category" : "\(effectiveSelection.count) Categories")?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Restore", role: .destructive) { Task { await restore() } }
            } message: {
                Text(overwrite
                     ? "Existing entries will be overwritten with the versions from this backup."
                     : "Only entries missing on the server will be added; existing ones stay as they are.")
            }
            .task { await loadCommits() }
            .task(id: selectedRef) { await loadPreview() }
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                Picker("Backup", selection: $selectedRef) {
                    Text("Latest Backup").tag("HEAD")
                    ForEach(commits?.commits ?? []) { commit in
                        Text("\(commit.shortSha) · \(Fmt.date(commit.date, style: .dateTime.month(.abbreviated).day().hour().minute()))")
                            .tag(commit.sha)
                    }
                }
                .pickerStyle(.navigationLink)
                if let commit = preview?.commit {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(commit.title.isEmpty ? commit.shortSha : commit.title).font(.subheadline)
                        Text("\(commit.shortSha) · \(commit.author ?? "") · \(Fmt.date(commit.date))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let version = preview?.metadataVersion {
                    LabeledContent("Created by Bambuddy", value: version)
                }
                if let commitsError {
                    Label(commitsError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Commit")
            } footer: {
                if let branch = commits?.branch { Text("Branch \(branch)") }
            }

            Section {
                if loadingPreview {
                    HStack { ProgressView(); Text("Inspecting backup…").foregroundStyle(.secondary) }
                } else if let previewError {
                    Label(previewError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again") { Task { await loadPreview() } }
                } else {
                    ForEach(Self.categories, id: \.id) { category in
                        categoryRow(category)
                    }
                }
            } header: {
                Text("What to Restore")
            } footer: {
                Text("Cloud presets can't be restored here — they live in your Bambu or Orca Cloud account.")
            }

            Section {
                Toggle(isOn: $overwrite) {
                    SettingsLabel("Overwrite Existing Entries", help: "Replace entries that already exist on the server. When off, only missing entries are added.")
                }
                if !overwrite && effectiveSelection.contains("kprofiles") {
                    Label("K-profiles always overwrite the matching calibration slot on the printer, even with this turned off.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let failure {
                    Label(failure, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Printers must be connected for K-profiles to be written.")
            }
        }
        .disabled(runner.isRunning)
    }

    private func categoryRow(_ category: (id: String, title: String, symbol: String, permission: String)) -> some View {
        let info = availability[category.id]
        let available = info?.available == true
        let permitted = session.can(category.permission)
        return Toggle(isOn: Binding(
            get: { selected.contains(category.id) && available },
            set: { on in if on { selected.insert(category.id) } else { selected.remove(category.id) } }
        )) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                    Group {
                        if !permitted {
                            Text("You don't have permission to restore this.")
                        } else if available {
                            Text(info?.itemCount == 1 ? "1 item" : "\(info?.itemCount ?? 0) items")
                        } else {
                            Text(info?.detail ?? "Not in this backup")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if available, let detail = info?.detail, !detail.isEmpty, permitted {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: category.symbol)
            }
        }
        .disabled(!available || !permitted)
    }

    // MARK: Result

    private func resultView(_ result: SettingsGitHubRestoreResult) -> some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.success == true ? "Restore Complete" : "Restore Incomplete").font(.headline)
                        if let message = result.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                    }
                } icon: {
                    Image(systemName: result.success == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(result.success == true ? .green : .orange)
                }
                if let ref = result.ref {
                    LabeledContent("Commit") { Text(String(ref.prefix(7))).font(.body.monospaced()) }
                }
            } footer: {
                if result.success != true {
                    Text("The categories below were written before the restore stopped.")
                }
            }
            let entries = (result.results ?? [:]).sorted { a, b in
                (Self.categories.firstIndex { $0.id == a.key } ?? 99) < (Self.categories.firstIndex { $0.id == b.key } ?? 99)
            }
            ForEach(entries, id: \.key) { name, tally in
                Section(Self.title(for: name)) {
                    HStack(spacing: 16) {
                        tallyValue("Restored", tally.restored, .green)
                        tallyValue("Skipped", tally.skipped, .secondary)
                        tallyValue("Failed", tally.failed, (tally.failed ?? 0) > 0 ? .red : .secondary)
                    }
                    ForEach(Array((tally.notes ?? []).enumerated()), id: \.offset) { _, note in
                        Label(note.message ?? note.code ?? "", systemImage: "info.circle").font(.footnote)
                    }
                }
            }
            if result.results?["settings"] != nil {
                Section {
                    Text("Settings were restored. Some changes take effect after you reopen the affected screens.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tallyValue(_ title: String, _ value: Int?, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value ?? 0)").font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Loading

    private func loadCommits() async {
        do {
            let list: SettingsGitHubCommitList = try await session.client.get("github-backup/commits", query: ["limit": 20])
            commits = list
            commitsError = list.success == false ? (list.message ?? "Couldn't list backups.") : nil
        } catch is CancellationError {
        } catch {
            commitsError = error.localizedDescription
        }
    }

    private func loadPreview() async {
        loadingPreview = true
        defer { loadingPreview = false }
        do {
            let p: SettingsGitHubRestorePreview = try await session.client.get("github-backup/restore/preview", query: ["ref": .string(selectedRef)])
            preview = p
            previewError = p.success == false ? (p.message ?? "Couldn't read this backup.") : nil
            // Drop selections the new commit can't satisfy.
            let offered = Set((p.categories ?? []).filter { $0.available == true }.map(\.category))
            selected = selected.intersection(offered)
        } catch is CancellationError {
        } catch {
            preview = nil
            previewError = error.localizedDescription
        }
    }

    private func restore() async {
        failure = nil
        // Restore the exact commit that was previewed, not a moving "HEAD".
        let ref = (preview?.success == true ? preview?.ref : nil) ?? selectedRef
        let request = SettingsGitHubRestoreRequest(ref: ref, categories: effectiveSelection, overwriteExisting: overwrite)
        await runner.run {
            let response: SettingsGitHubRestoreResult = try await session.client.send(.post, "github-backup/restore", body: request)
            let wroteSomething = !(response.results ?? [:]).isEmpty
            if response.success == true || wroteSomething {
                result = response
            } else {
                failure = response.message ?? "Nothing was restored."
            }
        }
        if result?.results?["settings"] != nil { await store.load() }
    }
}
