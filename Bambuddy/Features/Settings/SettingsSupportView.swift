import SwiftUI

/// Debug logging, support bundle and the application log viewer.
struct SettingsSupportView: View {
    @Environment(AppSession.self) private var session

    @State private var debug = Loader<SettingsSupportDebugState>()
    @State private var runner = ActionRunner()
    @State private var busyMessage: String?
    @State private var sharedFile: SettingsBackupDownloadedFile?

    private var canUpdate: Bool { session.can("settings:update") }
    private var debugEnabled: Bool { debug.value?.enabled == true }

    var body: some View {
        List {
            debugSection
            bundleSection
            Section {
                NavigationLink {
                    SettingsSupportLogsView()
                } label: {
                    Label("Application Logs", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                Text("Browse, search and filter the server log.")
            }
        }
        .navigationTitle("Support & Logs")
        .disabled(busyMessage != nil)
        .overlay {
            if let busyMessage { SettingsBackupBusyOverlay(message: busyMessage) }
        }
        .task { await load() }
        .refreshable { await load() }
        .actionAlerts(runner)
        .sheet(item: $sharedFile) { SettingsBackupFileSheet(file: $0) }
    }

    private var debugSection: some View {
        Section {
            Toggle(isOn: Binding(get: { debugEnabled }, set: { on in Task { await setDebug(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug Logging")
                    if let state = debug.value, state.enabled {
                        SettingsSupportDurationText(state: state)
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Normal log level").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!canUpdate || debug.value == nil || runner.isRunning)
            if let error = debug.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Debug logging records much more detail, including printer communication. Turn it on, reproduce the problem, download a support bundle, then turn it off again.")
        }
    }

    private var bundleSection: some View {
        Section {
            Button {
                Task { await downloadBundle() }
            } label: {
                Label("Download Support Bundle", systemImage: "shippingbox")
            }
            .disabled(!debugEnabled)
        } footer: {
            Text(debugEnabled
                 ? "A ZIP with recent logs and system details for bug reports. Passwords, tokens and other known secrets are redacted, but review it before sharing publicly."
                 : "Turn on debug logging first so the bundle contains useful detail.")
        }
    }

    private func load() async {
        let client = session.client
        await debug.load { try await client.get("support/debug-logging") }
    }

    private func setDebug(_ on: Bool) async {
        await runner.run(on ? "Debug logging turned on" : "Debug logging turned off") {
            debug.value = try await session.client.send(.post, "support/debug-logging", body: SettingsSupportDebugToggle(enabled: on))
        }
    }

    private func downloadBundle() async {
        busyMessage = "Collecting diagnostics… This can take up to a minute."
        defer { busyMessage = nil }
        await runner.run {
            let url = try await session.client.download("support/bundle")
            sharedFile = SettingsBackupDownloadedFile(url: url)
        }
    }
}

/// "On for 12m 5s", ticking every second.
private struct SettingsSupportDurationText: View {
    let state: SettingsSupportDebugState
    @State private var loadedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("On for \(Fmt.duration(seconds: seconds(at: context.date)))")
        }
    }

    private func seconds(at now: Date) -> Double? {
        if let raw = state.enabledAt, let start = APICoders.parseDate(raw) {
            return max(0, now.timeIntervalSince(start))
        }
        return state.durationSeconds.map { Double($0) + now.timeIntervalSince(loadedAt) }
    }
}

// MARK: - Log viewer

struct SettingsSupportLogsView: View {
    @Environment(AppSession.self) private var session

    @State private var logs = Loader<SettingsSupportLogsResponse>()
    @State private var runner = ActionRunner()
    @State private var search = ""
    @State private var level = "ALL"
    @State private var limit = 200
    @State private var live = false
    @State private var expanded: Set<Int> = []
    @State private var confirmClear = false

    static let levels = ["ALL", "DEBUG", "INFO", "WARNING", "ERROR"]

    private struct Query: Hashable { var search: String; var level: String; var limit: Int; var live: Bool }

    var body: some View {
        List {
            if let response = logs.value {
                let entries = response.entries ?? []
                Section {
                    if entries.isEmpty {
                        ContentUnavailableView(search.isEmpty && level == "ALL" ? "No Log Entries" : "No Matching Entries",
                                               systemImage: "doc.text",
                                               description: Text(search.isEmpty && level == "ALL" ? "The log file is empty." : "Try a different search or level."))
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            SettingsSupportLogRow(entry: entry, expanded: expanded.contains(index))
                                .contentShape(.rect)
                                .onTapGesture {
                                    if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
                                }
                                .contextMenu {
                                    Button { UIPasteboard.general.string = Self.text(for: entry) } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("Newest First")
                        Spacer()
                        Text("\(response.filteredCount ?? entries.count) of \(response.totalInFile ?? 0) lines").monospacedDigit()
                    }
                }
            } else if let error = logs.error {
                ContentUnavailableView {
                    Label("Couldn't Load Logs", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Logs")
        .searchable(text: $search, prompt: "Message or logger")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    live.toggle()
                } label: {
                    Label(live ? "Stop Live Updates" : "Live Updates", systemImage: live ? "pause.circle.fill" : "play.circle")
                }
                .tint(live ? .green : nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Level", selection: $level) {
                        ForEach(Self.levels, id: \.self) { Text($0 == "ALL" ? "All Levels" : $0.capitalized).tag($0) }
                    }
                    Picker("Show", selection: $limit) {
                        ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0) Entries").tag($0) }
                    }
                    if session.can("settings:update") {
                        Divider()
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear Log…", systemImage: "trash") }
                    }
                } label: {
                    Label("Options", systemImage: level == "ALL" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .task(id: Query(search: search, level: level, limit: limit, live: live)) {
            // Debounce typing, then load; keep polling while live.
            if logs.value != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
            while live && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
        .refreshable { await load() }
        .actionAlerts(runner)
        .confirm("Clear the Log File?", isPresented: $confirmClear, message: "All entries in the server's application log are deleted.", action: "Clear") {
            Task { await clear() }
        }
    }

    private func load() async {
        let client = session.client
        let query: [String: QueryValue?] = [
            "limit": .int(limit),
            "level": level == "ALL" ? nil : .string(level),
            "search": search.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .string(search.trimmingCharacters(in: .whitespaces)),
        ]
        let previous = logs.value?.entries
        await logs.load { try await client.get("support/logs", query: query) }
        if logs.value?.entries != previous { expanded = [] }
    }

    private func clear() async {
        await runner.run("Log cleared") {
            try await session.client.call(.delete, "support/logs")
        }
        await load()
    }

    private static func text(for entry: SettingsSupportLogEntry) -> String {
        "\(entry.timestamp ?? "") \(entry.level ?? "") [\(entry.loggerName ?? "")] \(entry.message ?? "")"
    }
}

private struct SettingsSupportLogRow: View {
    let entry: SettingsSupportLogEntry
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color).font(.caption)
                Text(entry.level ?? "").font(.caption2.weight(.bold).monospaced()).foregroundStyle(color)
                Text(entry.timeText).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if entry.isMultiline {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Text(entry.loggerName ?? "")
                .font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            Text(entry.message ?? "")
                .font(.caption.monospaced())
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.level?.uppercased() {
        case "DEBUG": "ladybug"
        case "WARNING": "exclamationmark.triangle.fill"
        case "ERROR", "CRITICAL": "xmark.octagon.fill"
        default: "info.circle"
        }
    }

    private var color: Color {
        switch entry.level?.uppercased() {
        case "DEBUG": .gray
        case "WARNING": .orange
        case "ERROR", "CRITICAL": .red
        default: .blue
        }
    }
}
