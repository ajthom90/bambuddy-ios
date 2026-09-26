import SwiftUI
import Charts
import PhotosUI

// MARK: - Logs

struct SystemLogsView: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<SystemLogsResponse>()
    @State private var level = "ALL"
    @State private var search = ""
    @State private var limit = 200
    @State private var live = false
    @State private var expanded: Set<Int> = []
    @State private var confirmClear = false
    @State private var runner = ActionRunner()

    private static let levels = ["ALL", "DEBUG", "INFO", "WARNING", "ERROR"]

    var body: some View {
        LoadingContent(loader: loader, retry: load) { response in
            List {
                Section {
                    if response.entries.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "No Log Entries" : "No Matches", systemImage: "doc.text")
                    }
                    ForEach(Array(response.entries.enumerated()), id: \.offset) { index, entry in
                        SystemLogRow(entry: entry, expanded: expanded.contains(index))
                            .contentShape(.rect)
                            .onTapGesture {
                                if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
                            }
                            .contextMenu {
                                Button { UIPasteboard.general.string = "\(entry.timestamp) \(entry.level) \(entry.loggerName ?? "") \(entry.message)" } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                            }
                    }
                } footer: {
                    Text("Showing \(response.entries.count) of \(response.filteredCount ?? response.entries.count) matching · \(response.totalInFile ?? 0) lines in log file")
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Level", selection: $level) {
                        ForEach(Self.levels, id: \.self) { Text($0 == "ALL" ? "All Levels" : $0.capitalized).tag($0) }
                    }
                    Picker("Entries", selection: $limit) {
                        ForEach([100, 200, 500, 1000], id: \.self) { Text("\($0) entries").tag($0) }
                    }
                    Toggle(isOn: $live) { Label("Live Tail", systemImage: "dot.radiowaves.left.and.right") }
                    if let text = shareText {
                        ShareLink(item: text) { Label("Share Visible Logs", systemImage: "square.and.arrow.up") }
                    }
                    if session.can("settings:update") {
                        Divider()
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear Logs…", systemImage: "trash") }
                    }
                } label: {
                    Label("Options", systemImage: level == "ALL" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
            if live {
                ToolbarItem(placement: .status) {
                    Label("Live", systemImage: "circle.fill").labelStyle(.titleAndIcon).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .refreshable { await load() }
        .task(id: "\(level)|\(search)|\(limit)|\(live)") {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            await load()
            while live && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await load()
            }
        }
        .confirm("Clear the application log?", isPresented: $confirmClear, message: "This empties the server's log file.", action: "Clear") {
            Task {
                await runner.run("Logs cleared") {
                    try await session.client.call(.delete, "support/logs")
                    await load()
                }
            }
        }
        .actionAlerts(runner)
    }

    private var shareText: String? {
        guard let entries = loader.value?.entries, !entries.isEmpty else { return nil }
        return entries.reversed().map { "\($0.timestamp) [\($0.level)] \($0.loggerName ?? ""): \($0.message)" }.joined(separator: "\n")
    }

    private func load() async {
        let q: [String: QueryValue?] = [
            "limit": .int(limit),
            "level": level == "ALL" ? nil : .string(level),
            "search": search.isEmpty ? nil : .string(search),
        ]
        await loader.load { try await session.client.get("support/logs", query: q) }
    }
}

private struct SystemLogRow: View {
    let entry: SystemLogEntry
    let expanded: Bool

    private var color: Color {
        switch entry.level.uppercased() {
        case "ERROR", "CRITICAL": .red
        case "WARNING": .orange
        case "DEBUG": .secondary
        default: .blue
        }
    }

    private var icon: String {
        switch entry.level.uppercased() {
        case "ERROR", "CRITICAL": "xmark.octagon.fill"
        case "WARNING": "exclamationmark.triangle.fill"
        case "DEBUG": "ladybug.fill"
        default: "info.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color).font(.caption)
                Text(entry.timestamp).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let name = entry.loggerName {
                    Text(name.split(separator: ".").last.map(String.init) ?? name)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
            if expanded, let name = entry.loggerName {
                Text(name).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Health

struct SystemHealthView: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<SystemHealthScan>()

    var body: some View {
        LoadingContent(loader: loader, retry: load) { scan in
            List {
                if scan.logAvailable == false {
                    ContentUnavailableView("Log File Unavailable", systemImage: "doc.questionmark",
                                           description: Text("The server's log file couldn't be read, so no scan was possible."))
                } else if scan.findings.isEmpty {
                    ContentUnavailableView {
                        Label("No Known Issues", systemImage: "checkmark.seal")
                    } description: {
                        Text("Scanned \(scan.scannedEntries ?? 0) recent log entries and found nothing from the known-issue catalog.")
                    }
                } else {
                    if let summary = scan.summary {
                        Section {
                            HStack {
                                summaryTile("Setup", summary["layer8"] ?? 0, .orange)
                                summaryTile("Environment", summary["environment"] ?? 0, .blue)
                                summaryTile("Bug", summary["bug"] ?? 0, .red)
                            }
                        } footer: {
                            Text("Scanned \(scan.scannedEntries ?? 0) recent log entries.")
                        }
                    }
                    ForEach(scan.findings) { f in
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: f.severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                        .foregroundStyle(f.severity == "error" ? .red : .orange)
                                    Text(f.title).font(.headline)
                                    Spacer()
                                    if let c = f.category { StatusBadge(text: categoryLabel(c), color: categoryColor(c)) }
                                }
                                Text("Seen \(f.count ?? 0) time\((f.count ?? 0) == 1 ? "" : "s") · last \(f.lastSeen ?? "—")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let sample = f.sample, !sample.isEmpty {
                                    Text(sample).font(.caption.monospaced()).lineLimit(6).textSelection(.enabled)
                                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                                }
                                if let url = f.wikiURL {
                                    Link(destination: url) { Label("How to Fix", systemImage: "book") }.font(.subheadline)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle("Log Health")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(loader.isLoading)
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func summaryTile(_ title: String, _ count: Int, _ color: Color) -> some View {
        VStack {
            Text("\(count)").font(.title2.bold()).foregroundStyle(count > 0 ? color : .secondary)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func categoryLabel(_ c: String) -> String {
        switch c {
        case "layer8": "Setup"
        case "environment": "Environment"
        case "bug": "Bug"
        default: c.capitalized
        }
    }

    private func categoryColor(_ c: String) -> Color {
        switch c {
        case "layer8": .orange
        case "environment": .blue
        case "bug": .red
        default: .secondary
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("system/health") }
    }
}

// MARK: - Connection diagnostic

struct SystemDiagnosticView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    let printerId: Int
    @State private var loader = Loader<SystemPrinterDiagnostic>()

    var body: some View {
        LoadingContent(loader: loader, retry: load) { result in
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: overallIcon(result.overall)).font(.largeTitle).foregroundStyle(overallColor(result.overall))
                        VStack(alignment: .leading) {
                            Text(overallTitle(result.overall)).font(.headline)
                            if let ip = result.ipAddress { Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("Checks") {
                    ForEach(result.checks) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: statusIcon(check.status)).foregroundStyle(statusColor(check.status))
                                Text(check.title)
                                Spacer()
                                Text(check.status.capitalized).font(.caption).foregroundStyle(statusColor(check.status))
                            }
                            if let params = check.params, !params.isEmpty {
                                Text(params.keys.sorted().map { "\($0.replacingOccurrences(of: "_", with: " ")): \(params[$0]!.displayString)" }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(printers.printer(printerId)?.name ?? "Diagnostic")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: { Label("Run Again", systemImage: "arrow.clockwise") }.disabled(loader.isLoading)
            }
        }
        .task { await load() }
    }

    private func load() async {
        await loader.load { try await session.client.get("printers/\(printerId)/diagnostic") }
    }

    private func overallTitle(_ o: String?) -> String {
        switch o {
        case "ok": "All checks passed"
        case "warnings": "Passed with warnings"
        case "problems": "Problems found"
        default: o?.capitalized ?? "Unknown"
        }
    }
    private func overallIcon(_ o: String?) -> String {
        switch o {
        case "ok": "checkmark.circle.fill"
        case "warnings": "exclamationmark.triangle.fill"
        default: "xmark.octagon.fill"
        }
    }
    private func overallColor(_ o: String?) -> Color {
        switch o {
        case "ok": .green
        case "warnings": .orange
        default: .red
        }
    }
    private func statusIcon(_ s: String) -> String {
        switch s {
        case "pass": "checkmark.circle.fill"
        case "warn": "exclamationmark.triangle.fill"
        case "fail": "xmark.circle.fill"
        default: "minus.circle"
        }
    }
    private func statusColor(_ s: String) -> Color {
        switch s {
        case "pass": .green
        case "warn": .orange
        case "fail": .red
        default: .secondary
        }
    }
}

// MARK: - Storage breakdown

struct SystemStorageView: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<SystemStorageUsage>()

    var body: some View {
        LoadingContent(loader: loader, retry: { await load(refresh: false) }) { usage in
            List {
                let cats = (usage.categories ?? []).filter { ($0.bytes ?? 0) > 0 }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(usage.totalFormatted ?? Fmt.bytes(usage.totalBytes)).font(.largeTitle.bold())
                        Text("Used by Bambuddy data").font(.subheadline).foregroundStyle(.secondary)
                        if !cats.isEmpty {
                            Chart(cats) { c in
                                SectorMark(angle: .value("Size", c.bytes ?? 0), innerRadius: .ratio(0.6), angularInset: 1)
                                    .foregroundStyle(by: .value("Category", c.label ?? c.key ?? "Other"))
                            }
                            .frame(height: 200)
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Categories") {
                    ForEach(usage.categories ?? []) { c in
                        LabeledContent {
                            VStack(alignment: .trailing) {
                                Text(c.formatted ?? Fmt.bytes(c.bytes))
                                if let p = c.percentOfTotal { Text(Fmt.number(p, digits: 1) + "%").font(.caption).foregroundStyle(.secondary) }
                            }
                        } label: {
                            Text(c.label ?? c.key ?? "—")
                        }
                    }
                }
                if let other = usage.otherBreakdown, !other.isEmpty {
                    Section("Other") {
                        ForEach(other) { c in
                            LabeledContent(c.label ?? c.bucket ?? "—", value: c.formatted ?? Fmt.bytes(c.bytes))
                        }
                    }
                }
                Section {
                    ForEach(usage.roots ?? [], id: \.self) { Text($0).font(.caption.monospaced()) }
                } header: {
                    Text("Scanned Folders")
                } footer: {
                    VStack(alignment: .leading) {
                        if let g = usage.generatedAt { Text("Measured \(Fmt.relative(g))") }
                        if let e = usage.scanErrors, e > 0 { Text("\(e) items couldn't be read.") }
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load(refresh: true) } } label: { Label("Rescan", systemImage: "arrow.clockwise") }.disabled(loader.isLoading)
            }
        }
        .refreshable { await load(refresh: true) }
        .task { await load(refresh: false) }
    }

    private func load(refresh: Bool) async {
        await loader.load { try await session.client.get("system/storage-usage", query: ["refresh": refresh ? .bool(true) : nil]) }
    }
}

// MARK: - Release notes / update

struct SystemReleaseNotesView: View {
    @Environment(AppSession.self) private var session
    let update: SystemUpdateCheck?
    @State private var runner = ActionRunner()
    @State private var status: SystemUpdateStatus?
    @State private var confirm = false

    var body: some View {
        List {
            if let update {
                Section {
                    LabeledContent("Installed", value: update.currentVersion ?? "—")
                    LabeledContent("Latest", value: update.latestVersion ?? "—")
                    if let p = update.publishedAt { LabeledContent("Released", value: Fmt.date(p, style: .dateTime.month(.abbreviated).day().year())) }
                    if let method = update.updateMethod { LabeledContent("Install Method", value: method.capitalized) }
                    if let u = update.releaseUrl.flatMap(URL.init(string:)) {
                        Link(destination: u) { Label("View on GitHub", systemImage: "arrow.up.right.square") }
                    }
                }
                if update.updateAvailable == true, session.can("settings:update") {
                    Section {
                        Button { confirm = true } label: { Label("Install Update", systemImage: "arrow.down.circle") }
                            .disabled(runner.isRunning)
                        if let status {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(status.message ?? status.status?.capitalized ?? "").font(.subheadline)
                                if let p = status.progress, status.status != "idle" { ProgressView(value: p, total: 100) }
                                if let e = status.error { Text(e).font(.caption).foregroundStyle(.red) }
                            }
                        }
                    } footer: {
                        if update.isDocker == true || update.isHaAddon == true {
                            Text("This server runs in a container. The server will explain how to update if it can't update itself (for example, pull the new image and recreate the container).")
                        }
                    }
                }
                if let notes = update.releaseNotes, !notes.isEmpty {
                    Section("Release Notes") {
                        Text(Self.render(notes)).font(.callout).textSelection(.enabled)
                    }
                }
            } else {
                ContentUnavailableView("No Update Information", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle(update?.releaseName ?? "Update")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
        .confirm("Install \(update?.latestVersion ?? "the update")?", isPresented: $confirm, message: "Bambuddy restarts during the update; printing continues on the printers.", action: "Install", role: nil) {
            Task { await apply() }
        }
    }

    static func render(_ markdown: String) -> AttributedString {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: normalized, options: options)) ?? AttributedString(normalized)
    }

    private func apply() async {
        await runner.run {
            let r: SystemUpdateStatus = try await session.client.send(.post, "updates/apply")
            status = r
            if r.success == false, let m = r.message { runner.errorMessage = m; return }
            for _ in 0..<120 {
                try await Task.sleep(for: .seconds(2))
                guard let s: SystemUpdateStatus = try? await session.client.get("updates/status") else { continue }
                status = s
                if s.status == "complete" || s.status == "error" || s.status == "idle" { break }
            }
        }
    }
}

// MARK: - Bug report

struct SystemBugReportView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers

    private enum Phase: Equatable { case form, logging(Date), submitting, done(String?, Int?) }

    @State private var phase: Phase = .form
    @State private var description = ""
    @State private var email = ""
    @State private var includeSupport = true
    @State private var photo: PhotosPickerItem?
    @State private var screenshot: UIImage?
    @State private var wasDebug = false
    @State private var findings: [SystemHealthFinding] = []
    @State private var problems: [(String, String)] = []
    @State private var runner = ActionRunner()

    private static let maxLogSeconds: TimeInterval = 300

    var body: some View {
        Form {
            switch phase {
            case .form, .submitting: formContent
            case .logging(let start): loggingContent(start)
            case .done(let url, let number): doneContent(url, number)
            }
        }
        .navigationTitle("Report a Bug")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
        .task { await preflight() }
        .onChange(of: photo) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) { screenshot = UIImage(data: data) }
            }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        if !problems.isEmpty || !findings.isEmpty {
            Section {
                ForEach(problems, id: \.0) { p in
                    Label("\(p.0): \(p.1)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(findings) { f in
                    if let url = f.wikiURL {
                        Link(destination: url) { Label(f.title, systemImage: "book") }
                    } else {
                        Label(f.title, systemImage: "exclamationmark.triangle")
                    }
                }
            } header: {
                Text("Check These First")
            } footer: {
                Text("Most problems are setup issues. These were detected automatically and may already explain what you're seeing.")
            }
        }
        Section {
            TextField("What happened, and what did you expect?", text: $description, axis: .vertical)
                .lineLimit(5...12)
        } header: {
            Text("Description")
        }
        Section {
            TextField("Email (optional, for follow-up)", text: $email)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
            Toggle("Include System Information", isOn: $includeSupport)
            let pickerTitle = screenshot == nil ? "Attach Screenshot" : "Change Screenshot"
            PhotosPicker(selection: $photo, matching: .images) {
                Label(pickerTitle, systemImage: "photo")
            }
            if let screenshot {
                HStack {
                    Image(uiImage: screenshot).resizable().scaledToFit().frame(height: 120).clipShape(.rect(cornerRadius: 8))
                    Spacer()
                    Button("Remove", role: .destructive) { self.screenshot = nil; photo = nil }.buttonStyle(.borderless)
                }
            }
        } footer: {
            Text("The report is filed as a public GitHub issue. System information is sanitized and leaves out names, serials, addresses and credentials.")
        }
        Section {
            Button {
                Task { await startLogging() }
            } label: {
                Label("Capture Logs While I Reproduce It", systemImage: "record.circle")
            }
            .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .submitting || !session.can("settings:update"))
            Button {
                Task { await submit(logs: nil) }
            } label: {
                HStack {
                    Label("Submit Without Logs", systemImage: "paperplane")
                    if phase == .submitting { Spacer(); ProgressView() }
                }
            }
            .disabled(description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .submitting)
        } footer: {
            Text("Capturing turns on debug logging for up to 5 minutes while you reproduce the problem, then attaches those logs.")
        }
    }

    @ViewBuilder
    private func loggingContent(_ start: Date) -> some View {
        Section {
            TimelineView(.periodic(from: start, by: 1)) { ctx in
                let elapsed = ctx.date.timeIntervalSince(start)
                VStack(alignment: .leading, spacing: 8) {
                    Label("Recording debug logs", systemImage: "record.circle.fill").foregroundStyle(.red).font(.headline)
                    Text("Reproduce the problem now, then come back and tap Stop & Submit.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ProgressView(value: min(elapsed, Self.maxLogSeconds), total: Self.maxLogSeconds)
                    Text("\(Fmt.duration(seconds: elapsed)) of 5m").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .task(id: elapsed >= Self.maxLogSeconds) {
                    if elapsed >= Self.maxLogSeconds { await stopAndSubmit() }
                }
            }
            .padding(.vertical, 4)
        }
        Section {
            Button { Task { await stopAndSubmit() } } label: { Label("Stop & Submit", systemImage: "stop.circle") }
            Button("Cancel Recording", role: .destructive) { Task { await cancelLogging() } }
        }
    }

    @ViewBuilder
    private func doneContent(_ url: String?, _ number: Int?) -> some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(.green)
                Text("Thanks — your report was submitted.").font(.headline)
                if let number { Text("Issue #\(number)").foregroundStyle(.secondary) }
                if let url, let u = URL(string: url) {
                    Link(destination: u) { Label("View Issue", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical)
        }
        Section {
            Button("Report Another Problem") {
                description = ""; screenshot = nil; photo = nil; phase = .form
            }
        }
    }

    private func preflight() async {
        let client = session.client
        if email.isEmpty { email = session.user?.email ?? "" }
        if let scan: SystemHealthScan = try? await client.get("system/health") { findings = scan.findings }
        var found: [(String, String)] = []
        for p in printers.printers {
            if let d: SystemPrinterDiagnostic = try? await client.get("printers/\(p.id)/diagnostic"), d.overall == "problems" {
                let failing = d.checks.filter { $0.status == "fail" }.map(\.title).joined(separator: ", ")
                found.append((p.name, failing.isEmpty ? "connection problems" : failing))
            }
        }
        problems = found
    }

    private func startLogging() async {
        await runner.run {
            let r: SystemStartLogging = try await session.client.send(.post, "bug-report/start-logging")
            wasDebug = r.wasDebug ?? false
            phase = .logging(Date())
        }
    }

    private func cancelLogging() async {
        _ = try? await session.client.send(.post, "bug-report/stop-logging", query: ["was_debug": .bool(wasDebug)], as: SystemStopLogging.self)
        phase = .form
    }

    private func stopAndSubmit() async {
        guard case .logging = phase else { return }
        phase = .submitting
        let logs = try? await session.client.send(.post, "bug-report/stop-logging", query: ["was_debug": .bool(wasDebug)], as: SystemStopLogging.self)
        await submit(logs: logs?.logs)
    }

    private func submit(logs: String?) async {
        phase = .submitting
        let body = SystemBugReportRequest(
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.isEmpty ? nil : email,
            screenshotBase64: screenshot.flatMap(Self.encode),
            includeSupportInfo: includeSupport,
            debugLogs: logs
        )
        do {
            let r: SystemBugReportResponse = try await session.client.send(.post, "bug-report/submit", body: body)
            if r.success {
                phase = .done(r.issueUrl, r.issueNumber)
            } else {
                phase = .form
                runner.errorMessage = r.message ?? "The report couldn't be submitted."
            }
        } catch {
            phase = .form
            runner.errorMessage = error.localizedDescription
        }
    }

    /// Downscales to at most 1600 px and encodes as JPEG base64.
    private static func encode(_ image: UIImage) -> String? {
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.jpegData(compressionQuality: 0.7)?.base64EncodedString()
    }
}
