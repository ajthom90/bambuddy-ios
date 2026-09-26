import SwiftUI

struct SystemRootView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(PrinterStore.self) private var printers

    @State private var info = Loader<SystemInfo>()
    @State private var update: SystemUpdateCheck?
    @State private var debug: SystemDebugLogging?
    @State private var health: SystemHealthScan?
    @State private var runner = ActionRunner()
    @State private var bundleURL: URL?
    @State private var bundleBusy = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if session.can("system:read") {
                    LoadingContent(loader: info, retry: load) { info in content(info) }
                } else {
                    ContentUnavailableView("No Access", systemImage: "lock", description: Text("You don't have permission to view system information."))
                }
            }
            .navigationTitle("System")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(info.isLoading)
                }
            }
            .refreshable { await load() }
            .task(id: live.revision("printer_added", "printer_removed", "archive_created")) { await load() }
            .actionAlerts(runner)
            .navigationDestination(for: SystemRoute.self) { route in
                switch route {
                case .logs: SystemLogsView()
                case .health: SystemHealthView()
                case .diagnostic(let id): SystemDiagnosticView(printerId: id)
                case .bugReport: SystemBugReportView()
                case .storage: SystemStorageView()
                case .releaseNotes: SystemReleaseNotesView(update: update)
                case .adminUsers: UsersAndGroupsView()
                case .adminKeys: APIKeysView()
                case .adminSecurity: AccountSecurityView()
                }
            }
            .sheet(item: Binding(get: { bundleURL.map(SystemSharedFile.init) }, set: { if $0 == nil { bundleURL = nil } })) { file in
                SystemShareSheet(url: file.url)
            }
            #if DEBUG
            .onAppear {
                // `-openSystem logs|health|bug|storage|users|apikeys|security` opens a deeper screen (screenshots).
                guard path.isEmpty, let target = UserDefaults.standard.string(forKey: "openSystem") else { return }
                let map: [String: SystemRoute] = ["logs": .logs, "health": .health, "bug": .bugReport, "storage": .storage,
                                                  "users": .adminUsers, "apikeys": .adminKeys, "security": .adminSecurity, "notes": .releaseNotes]
                if let r = map[target] { path.append(r) }
            }
            #endif
        }
    }

    @ViewBuilder
    private func content(_ info: SystemInfo) -> some View {
        List {
            if let update, update.updateAvailable == true {
                Section {
                    NavigationLink(value: SystemRoute.releaseNotes) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle.fill").font(.title).foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bambuddy \(update.latestVersion ?? "") Available").font(.headline)
                                Text("You have \(update.currentVersion ?? info.app?.version ?? "an older version"). View release notes and update.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Application") {
                InfoRow("Version", info.app?.version, systemImage: "shippingbox")
                InfoRow("Uptime", info.system?.uptimeFormatted ?? Fmt.duration(seconds: info.system?.uptimeSeconds), systemImage: "clock")
                InfoRow("Hostname", info.system?.hostname, systemImage: "network")
                if let update, update.updateAvailable != true, update.latestVersion != nil {
                    Label("Up to date", systemImage: "checkmark.seal").foregroundStyle(.green)
                }
            }

            Section("Resources") {
                SystemUsageRow(title: "CPU", systemImage: "cpu", percent: info.cpu?.percent,
                               detail: info.cpu.map { "\($0.countLogical ?? $0.count ?? 0) cores" })
                SystemUsageRow(title: "Memory", systemImage: "memorychip", percent: info.memory?.percentUsed,
                               detail: info.memory.map { "\($0.usedFormatted ?? "—") of \($0.totalFormatted ?? "—") · \($0.availableFormatted ?? "—") available" })
                SystemUsageRow(title: "Disk", systemImage: "internaldrive", percent: info.storage?.diskPercentUsed,
                               detail: info.storage.map { "\($0.diskUsedFormatted ?? "—") of \($0.diskTotalFormatted ?? "—") · \($0.diskFreeFormatted ?? "—") free" })
            }

            Section {
                InfoRow("Archives", info.storage?.archiveSizeFormatted, systemImage: "archivebox")
                InfoRow("Database", info.storage?.databaseSizeFormatted, systemImage: "cylinder")
                NavigationLink(value: SystemRoute.storage) { Label("Storage Breakdown", systemImage: "chart.pie") }
            } header: {
                Text("Storage")
            }

            if let db = info.database {
                Section("Database") {
                    InfoRow("Engine", [db.engine, db.version].compactMap { $0 }.joined(separator: " · "))
                    LabeledContent("Archives") {
                        Text("\(db.archives ?? 0)  ·  \(db.archivesCompleted ?? 0) done, \(db.archivesFailed ?? 0) failed, \(db.archivesPrinting ?? 0) printing")
                            .multilineTextAlignment(.trailing)
                    }
                    InfoRow("Printers", db.printers.map(String.init))
                    InfoRow("Filaments", db.filaments.map(String.init))
                    InfoRow("Projects", db.projects.map(String.init))
                    InfoRow("Smart Plugs", db.smartPlugs.map(String.init))
                    InfoRow("Total Print Time", db.totalPrintTimeFormatted ?? Fmt.duration(seconds: db.totalPrintTimeSeconds))
                    InfoRow("Total Filament", Fmt.grams(db.totalFilamentGrams))
                }
            }

            Section {
                let list = info.printers?.connectedList ?? []
                if list.isEmpty {
                    Text("No printers connected").foregroundStyle(.secondary)
                }
                ForEach(list) { p in
                    HStack {
                        Image(systemName: "printer.fill").foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text(p.name ?? "Printer \(p.id)")
                            if let m = p.model { Text(m).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let s = p.state { StatusBadge(text: s.capitalized, color: s == "RUNNING" ? .blue : .secondary) }
                    }
                }
            } header: {
                Text("Connected Printers")
            } footer: {
                Text("\(info.printers?.connected ?? 0) of \(info.printers?.total ?? 0) printers connected")
            }

            supportSection

            if !printers.printers.isEmpty {
                Section {
                    ForEach(printers.printers) { p in
                        NavigationLink(value: SystemRoute.diagnostic(p.id)) {
                            Label(p.name, systemImage: "stethoscope")
                        }
                    }
                } header: {
                    Text("Connection Diagnostic")
                } footer: {
                    Text("Checks ports, LAN mode, network and access code for a printer.")
                }
            }

            Section("System Details") {
                InfoRow("Operating System", [info.system?.platform, info.system?.platformRelease].compactMap { $0 }.joined(separator: " "))
                InfoRow("Architecture", info.system?.architecture)
                InfoRow("Python", info.system?.pythonVersion)
                InfoRow("Boot Time", info.system?.bootTime.map { Fmt.date($0) })
                InfoRow("Data Directory", info.app?.baseDir)
            }

        }
    }

    @ViewBuilder
    private var supportSection: some View {
        Section {
            NavigationLink(value: SystemRoute.health) {
                HStack {
                    Label("Log Health Check", systemImage: "heart.text.square")
                    Spacer()
                    if let health {
                        if health.findings.isEmpty {
                            StatusBadge(text: "No issues", color: .green)
                        } else {
                            StatusBadge(text: "\(health.findings.count) found", color: .orange)
                        }
                    }
                }
            }
            if session.can("settings:read") {
                NavigationLink(value: SystemRoute.logs) { Label("Application Logs", systemImage: "doc.text.magnifyingglass") }
            }
            if session.can("settings:update") {
                Toggle(isOn: Binding(get: { debug?.enabled ?? false }, set: { v in Task { await setDebug(v) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Debug Logging", systemImage: "ladybug")
                        if let d = debug, d.enabled {
                            Text("Capturing detailed logs" + (d.durationSeconds.map { " · \(Fmt.duration(seconds: Double($0)))" } ?? ""))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .disabled(debug == nil)
            }
            if session.can("settings:read") {
                Button {
                    Task { await downloadBundle() }
                } label: {
                    HStack {
                        Label("Download Support Bundle", systemImage: "doc.zipper")
                        Spacer()
                        if bundleBusy { ProgressView() }
                    }
                }
                .disabled(bundleBusy || debug?.enabled != true)
                NavigationLink(value: SystemRoute.bugReport) { Label("Report a Bug", systemImage: "exclamationmark.bubble") }
            }
        } header: {
            Text("Support & Troubleshooting")
        } footer: {
            if debug?.enabled != true, session.can("settings:read") {
                Text("To report a problem: turn on debug logging, reproduce the issue, then download the support bundle and attach it to your report. The bundle leaves out printer names, serial numbers, access codes, passwords, emails, API keys and IP addresses.")
            } else {
                Text("The support bundle contains system details and sanitized debug logs. Remember to turn debug logging off afterwards.")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        guard session.can("system:read") else { return }
        let client = session.client
        async let u = try? client.get("updates/check", as: SystemUpdateCheck.self)
        async let d = session.can("settings:read") ? try? client.get("support/debug-logging", as: SystemDebugLogging.self) : nil
        async let h = try? client.get("system/health", as: SystemHealthScan.self)
        await info.load { try await client.get("system/info") }
        update = await u
        debug = await d
        health = await h
    }

    private func setDebug(_ enabled: Bool) async {
        struct Body: Encodable { var enabled: Bool }
        await runner.run(enabled ? "Debug logging on" : "Debug logging off") {
            debug = try await session.client.send(.post, "support/debug-logging", body: Body(enabled: enabled))
        }
    }

    private func downloadBundle() async {
        bundleBusy = true
        defer { bundleBusy = false }
        await runner.run {
            bundleURL = try await session.client.download("support/bundle", suggestedName: nil)
        }
    }
}

enum SystemRoute: Hashable {
    case logs, health, bugReport, storage, releaseNotes
    case diagnostic(Int)
    case adminUsers, adminKeys, adminSecurity
}

private struct SystemUsageRow: View {
    let title: String
    let systemImage: String
    let percent: Double?
    let detail: String?

    private var color: Color {
        guard let percent else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(Fmt.percent(percent)).monospacedDigit().foregroundStyle(color)
            }
            ProgressView(value: min(max((percent ?? 0) / 100, 0), 1)).tint(color)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }
}

struct SystemSharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Wraps `UIActivityViewController` so a downloaded file can be saved or shared.
struct SystemShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
