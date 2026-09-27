import SwiftUI
import QuickLook

// MARK: Models

struct PrinterFileListing: Codable, Sendable, Hashable {
    var path: String?
    var files: [PrinterFileEntry]
    var warnings: [String]?

    var printerUnavailable: Bool { warnings?.contains("printer_unavailable") ?? false }
}

struct PrinterFileEntry: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var path: String
    var mtime: String?

    var id: String { path }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var is3MF: Bool { name.lowercased().hasSuffix(".3mf") }
    var date: Date? { mtime.flatMap(APICoders.parseDate) }

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        switch ext {
        case "3mf": return "cube"
        case "gcode": return "doc.text"
        case "mp4", "avi": return "film"
        case "png", "jpg", "jpeg": return "photo"
        default: return "doc"
        }
    }
}

struct PrinterStorageInfo: Codable, Sendable, Hashable {
    var usedBytes: Int64?
    var freeBytes: Int64?
}

struct PrinterFilePlates: Codable, Sendable, Hashable {
    var printerId: Int?
    var path: String?
    var filename: String?
    var plates: [PrinterFilePlate]
    var isMultiPlate: Bool?
}

struct PrinterFilePlate: Codable, Sendable, Hashable, Identifiable {
    var index: Int
    var name: String?
    var objects: [String]?
    var objectCount: Int?
    var hasThumbnail: Bool?
    var thumbnailUrl: String?
    var printTimeSeconds: Int?
    var filamentUsedGrams: Double?
    var filaments: [PrinterFilePlateFilament]?

    var id: Int { index }
}

struct PrinterFilePlateFilament: Codable, Sendable, Hashable {
    var slotId: Int?
    var type: String?
    var color: String?
    var usedGrams: Double?
    var usedMeters: Double?
}

struct PrinterFilesJobRequest: Codable, Sendable {
    var paths: [String]
    var sizes: [String: Int64]
    var filename: String
    var asZip: Bool
}

struct PrinterFilesJob: Codable, Sendable, Hashable {
    var jobId: String
    var printerId: Int?
    var state: String
    var requested: Int?
    var successful: Int?
    var failed: Int?
    var token: String?
    var filename: String?
    var message: String?

    var isPending: Bool { state == "queued" || state == "preparing" }
    var fraction: Double {
        guard let requested, requested > 0 else { return 0 }
        return Double((successful ?? 0) + (failed ?? 0)) / Double(requested)
    }
}

enum PrinterFileSort: String, CaseIterable, Identifiable {
    case nameAsc, nameDesc, sizeDesc, sizeAsc, dateDesc, dateAsc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nameAsc: return "Name (A–Z)"
        case .nameDesc: return "Name (Z–A)"
        case .sizeDesc: return "Largest First"
        case .sizeAsc: return "Smallest First"
        case .dateDesc: return "Newest First"
        case .dateAsc: return "Oldest First"
        }
    }

    /// Folders always come first; missing dates sort as oldest.
    func sorted(_ files: [PrinterFileEntry]) -> [PrinterFileEntry] {
        files.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            switch self {
            case .nameAsc: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .nameDesc: return a.name.localizedStandardCompare(b.name) == .orderedDescending
            case .sizeAsc: return (a.size ?? 0) < (b.size ?? 0)
            case .sizeDesc: return (a.size ?? 0) > (b.size ?? 0)
            case .dateAsc: return (a.date ?? .distantPast) < (b.date ?? .distantPast)
            case .dateDesc: return (a.date ?? .distantPast) > (b.date ?? .distantPast)
            }
        }
    }
}

extension PrinterFileEntry {
    /// Parent directory of an SD card path (`/cache/a.3mf` → `/cache`).
    static func parent(of path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        guard let slash = p.lastIndex(of: "/"), slash != p.startIndex else { return "/" }
        return String(p[..<slash])
    }
}

// MARK: View

struct PrinterFilesView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int

    @State private var path = "/"
    @State private var loader = Loader<PrinterFileListing>()
    @State private var storage: PrinterStorageInfo?
    @State private var runner = ActionRunner()
    @State private var search = ""
    @AppStorage("printerFiles.sort") private var sort: PrinterFileSort = .nameAsc
    @State private var editMode: EditMode = .inactive
    @State private var selection: Set<String> = []
    @State private var pendingDelete: [PrinterFileEntry] = []
    @State private var job: PrinterFilesJob?
    @State private var jobTask: Task<Void, Never>?
    @State private var downloaded: PrinterDownloadedFile?
    @State private var platesFor: PrinterFileEntry?

    private var client: APIClient { session.client }
    private var canManage: Bool { session.can("printers:files") }

    private static let quickPaths: [(String, String, String)] = [
        ("Root", "/", "externaldrive"), ("Cache", "/cache", "tray.full"),
        ("Models", "/model", "cube"), ("Timelapse", "/timelapse", "film"),
    ]

    var body: some View {
        LoadingContent(loader: loader, retry: load) { listing in
            list(listing)
        }
        .navigationTitle(path == "/" ? "Printer Files" : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Filter by name")
        .environment(\.editMode, $editMode)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { jobBanner }
        .task(id: path) {
            selection = []
            await load()
        }
        .task { await loadStorage() }
        .onDisappear { cancelJob() }
        .actionAlerts(runner)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete(pendingDelete) } }
        } message: {
            Text("Files are permanently removed from the printer's storage.")
        }
        .sheet(item: $downloaded) { file in
            PrinterDownloadedFileSheet(file: file)
        }
        .sheet(item: $platesFor) { file in
            PrinterFilePlatesSheet(printerId: printerId, file: file)
        }
    }

    // MARK: List

    @ViewBuilder
    private func list(_ listing: PrinterFileListing) -> some View {
        let entries = visible(listing)
        List(selection: $selection) {
            Section {
                storageRow
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.quickPaths, id: \.1) { item in
                            Button { search = ""; path = item.1 } label: {
                                Label(item.0, systemImage: item.2).font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                            .tint(path == item.1 ? .accentColor : .secondary)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                if path != "/" {
                    Button { path = PrinterFileEntry.parent(of: path) } label: {
                        Label(PrinterFileEntry.parent(of: path) == "/" ? "Back to Root" : "Up to \((PrinterFileEntry.parent(of: path) as NSString).lastPathComponent)", systemImage: "arrow.turn.left.up")
                    }
                }
            } footer: {
                Text(path).font(.caption.monospaced())
            }
            .selectionDisabled()

            Section {
                if listing.printerUnavailable {
                    ContentUnavailableView("Printer Unavailable", systemImage: "wifi.exclamationmark", description: Text("The printer's storage could not be reached. Check that it is online and try again."))
                        .selectionDisabled()
                } else if entries.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No Files" : "No Matches", systemImage: search.isEmpty ? "folder" : "magnifyingglass",
                                           description: Text(search.isEmpty ? "This folder is empty." : "No files match “\(search)”."))
                        .selectionDisabled()
                }
                ForEach(entries) { entry in
                    row(entry)
                        .tag(entry.path)
                        .selectionDisabled(entry.isDirectory)
                }
            } footer: {
                if !entries.isEmpty {
                    Text(footerText(entries: entries, total: listing.files.count))
                }
            }
        }
        .refreshable {
            await load()
            await loadStorage()
        }
    }

    @ViewBuilder
    private var storageRow: some View {
        if let storage, storage.usedBytes != nil || storage.freeBytes != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let used = storage.usedBytes, let free = storage.freeBytes, used + free > 0 {
                    ProgressView(value: Double(used), total: Double(used + free))
                }
                HStack {
                    Label("Storage", systemImage: "sdcard")
                    Spacer()
                    if let used = storage.usedBytes { Text("Used \(Fmt.bytes(used))") }
                    if let free = storage.freeBytes { Text("· Free \(Fmt.bytes(free))") }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: PrinterFileEntry) -> some View {
        if entry.isDirectory {
            Button { search = ""; path = entry.path } label: {
                HStack {
                    Label(entry.name, systemImage: entry.systemImage).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 12) {
                Image(systemName: entry.systemImage)
                    .font(.title3)
                    .foregroundStyle(entry.is3MF ? Color.accentColor : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(Fmt.bytes(entry.size))
                        if let d = entry.date { Text("·"); Text(d.formatted(date: .abbreviated, time: .omitted)) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
            .contextMenu { fileActions(entry) }
            .swipeActions(edge: .trailing) {
                if canManage {
                    Button(role: .destructive) { pendingDelete = [entry] } label: { Label("Delete", systemImage: "trash") }
                    Button { Task { await downloadSingle(entry) } } label: { Label("Download", systemImage: "square.and.arrow.down") }
                        .tint(.accentColor)
                }
            }
            .onTapGesture {
                guard editMode == .inactive else { return }
                if entry.is3MF { platesFor = entry } else { Task { await downloadSingle(entry) } }
            }
        }
    }

    @ViewBuilder
    private func fileActions(_ entry: PrinterFileEntry) -> some View {
        if canManage {
            Button { Task { await downloadSingle(entry) } } label: { Label("Download", systemImage: "square.and.arrow.down") }
        }
        if entry.is3MF {
            Button { platesFor = entry } label: { Label("Plates & Details", systemImage: "square.grid.2x2") }
        }
        if canManage {
            Divider()
            Button(role: .destructive) { pendingDelete = [entry] } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if editMode == .active {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { editMode = .inactive; selection = [] }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button(allVisibleSelected ? "Deselect All" : "Select All") { toggleSelectAll() }
                Spacer()
                Text("\(selection.count) selected").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await downloadSelection() } } label: { Image(systemName: "square.and.arrow.down") }
                    .disabled(selection.isEmpty || job != nil)
                    .accessibilityLabel("Download Selected")
                Button(role: .destructive) { pendingDelete = selectedEntries } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty)
                    .accessibilityLabel("Delete Selected")
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if canManage {
                        Button { editMode = .active } label: { Label("Select Files", systemImage: "checkmark.circle") }
                    }
                    Picker(selection: $sort) {
                        ForEach(PrinterFileSort.allCases) { s in Text(s.label).tag(s) }
                    } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                    .pickerStyle(.menu)
                    Button { Task { await load(); await loadStorage() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                } label: { Image(systemName: "ellipsis") }
            }
        }
    }

    @ViewBuilder
    private var jobBanner: some View {
        if let job {
            HStack(spacing: 12) {
                ProgressView(value: job.fraction)
                    .frame(maxWidth: 160)
                Text(job.state == "queued" ? "Queued…" : "Preparing \((job.successful ?? 0) + (job.failed ?? 0))/\(job.requested ?? 0)")
                    .font(.subheadline).monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { cancelJob() }
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    // MARK: Helpers

    private func visible(_ listing: PrinterFileListing) -> [PrinterFileEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? listing.files : listing.files.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return sort.sorted(filtered)
    }

    private var selectedEntries: [PrinterFileEntry] {
        (loader.value?.files ?? []).filter { selection.contains($0.path) && !$0.isDirectory }
    }

    private var allVisibleSelected: Bool {
        guard let listing = loader.value else { return false }
        let files = visible(listing).filter { !$0.isDirectory }.map(\.path)
        return !files.isEmpty && Set(files).isSubset(of: selection)
    }

    private func toggleSelectAll() {
        guard let listing = loader.value else { return }
        let files = Set(visible(listing).filter { !$0.isDirectory }.map(\.path))
        if allVisibleSelected { selection.subtract(files) } else { selection.formUnion(files) }
    }

    private func footerText(entries: [PrinterFileEntry], total: Int) -> String {
        if !search.isEmpty { return "\(entries.count) of \(total) items" }
        return "\(total) item\(total == 1 ? "" : "s")"
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete “\(pendingDelete[0].name)”?" : "Delete \(pendingDelete.count) files?"
    }

    // MARK: Networking

    private func load() async {
        let requested = path
        await loader.load { try await client.get("printers/\(printerId)/files", query: ["path": .string(requested)]) }
        if let listing = loader.value, !listing.printerUnavailable {
            selection.formIntersection(Set(listing.files.map(\.path)))
        }
    }

    private func loadStorage() async {
        storage = try? await client.get("printers/\(printerId)/storage")
    }

    private func delete(_ entries: [PrinterFileEntry]) async {
        pendingDelete = []
        await runner.run(entries.count == 1 ? "File deleted" : "\(entries.count) files deleted") {
            for entry in entries {
                try await client.call(.delete, "printers/\(printerId)/files", query: ["path": .string(entry.path)])
                selection.remove(entry.path)
            }
        }
        if selection.isEmpty { editMode = .inactive }
        await load()
        await loadStorage()
    }

    private func downloadSingle(_ entry: PrinterFileEntry) async {
        guard canManage else { return }
        await runner.run {
            let url = try await client.download("printers/\(printerId)/files/download", query: ["path": .string(entry.path)], suggestedName: entry.name)
            downloaded = PrinterDownloadedFile(url: url)
        }
    }

    private func downloadSelection() async {
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        if entries.count == 1 { await downloadSingle(entries[0]); return }
        let printerName = store.printer(printerId)?.name ?? "printer"
        let safe = String(printerName.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let body = PrinterFilesJobRequest(
            paths: entries.map(\.path),
            sizes: Dictionary(uniqueKeysWithValues: entries.map { ($0.path, max(0, $0.size ?? 0)) }),
            filename: "\(safe)-files.zip",
            asZip: true
        )
        jobTask?.cancel()
        jobTask = Task { await runJob(body) }
    }

    private func runJob(_ body: PrinterFilesJobRequest) async {
        var jobId: String?
        await runner.run {
            var current: PrinterFilesJob = try await client.send(.post, "printers/\(printerId)/files/download-job", body: body)
            jobId = current.jobId
            job = current
            var polls = 0
            while current.isPending {
                try await Task.sleep(for: .milliseconds(polls < 10 ? 500 : 2000))
                polls += 1
                current = try await client.get("printers/\(printerId)/files/download-jobs/\(current.jobId)")
                job = current
            }
            guard current.state == "ready", let token = current.token else {
                throw APIError(status: 0, message: current.message ?? "The download could not be prepared (\(current.state)).", code: nil, detail: nil)
            }
            let name = body.filename
            let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? token
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? name
            let url = try await client.download("printers/\(printerId)/files/dl/\(encodedToken)/\(encodedName)", suggestedName: name)
            job = nil
            jobId = nil
            if (current.failed ?? 0) > 0 {
                runner.successMessage = "\(current.failed ?? 0) of \(current.requested ?? 0) files could not be downloaded"
            }
            downloaded = PrinterDownloadedFile(url: url)
            editMode = .inactive
            selection = []
        }
        job = nil
        if let jobId, Task.isCancelled || runner.errorMessage != nil {
            try? await client.call(.delete, "printers/\(printerId)/files/download-jobs/\(jobId)")
        }
    }

    private func cancelJob() {
        guard let current = job else { return }
        jobTask?.cancel()
        jobTask = nil
        job = nil
        let client = client, printerId = printerId
        Task { try? await client.call(.delete, "printers/\(printerId)/files/download-jobs/\(current.jobId)") }
    }
}

// MARK: Downloaded file

struct PrinterDownloadedFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

private struct PrinterDownloadedFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: PrinterDownloadedFile
    @State private var preview: URL?

    private var size: Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.int64Value
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "doc.fill").font(.system(size: 54)).foregroundStyle(.tint)
                VStack(spacing: 4) {
                    Text(file.url.lastPathComponent).font(.headline).multilineTextAlignment(.center)
                    Text(Fmt.bytes(size)).foregroundStyle(.secondary)
                }
                ShareLink(item: file.url) {
                    Label("Share or Save…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                if QLPreviewController.canPreview(file.url as NSURL) {
                    Button { preview = file.url } label: {
                        Label("Preview", systemImage: "eye").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Download Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .quickLookPreview($preview)
        }
        .presentationDetents([.medium])
    }
}

// MARK: Plates

private struct PrinterFilePlatesSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    let file: PrinterFileEntry
    @State private var loader = Loader<PrinterFilePlates>()

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { info in
                if info.plates.isEmpty {
                    ContentUnavailableView("No Plate Details", systemImage: "square.grid.2x2", description: Text("This file has no readable plate metadata."))
                } else {
                    List {
                        Section {
                            InfoRow("File", file.name)
                            InfoRow("Size", Fmt.bytes(file.size))
                            if let d = file.date { InfoRow("Modified", d.formatted(date: .abbreviated, time: .shortened)) }
                            InfoRow("Plates", "\(info.plates.count)")
                        }
                        ForEach(info.plates) { plate in
                            Section(plate.name.map { "Plate \(plate.index) · \($0)" } ?? "Plate \(plate.index)") {
                                HStack(alignment: .top, spacing: 12) {
                                    if plate.hasThumbnail ?? false {
                                        RemoteImage(path: session.client.url("printers/\(printerId)/files/plate-thumbnail/\(plate.index)", query: ["path": .string(file.path)]).absoluteString,
                                                    contentMode: .fit, systemImage: "cube")
                                            .frame(width: 96, height: 96)
                                            .clipShape(.rect(cornerRadius: 10))
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let t = plate.printTimeSeconds { Label(Fmt.duration(seconds: Double(t)), systemImage: "clock") }
                                        if let g = plate.filamentUsedGrams { Label(Fmt.grams(g), systemImage: "scalemass") }
                                        if let n = plate.objectCount { Label("\(n) object\(n == 1 ? "" : "s")", systemImage: "cube.transparent") }
                                    }
                                    .font(.subheadline)
                                }
                                ForEach(Array((plate.filaments ?? []).enumerated()), id: \.offset) { _, f in
                                    HStack {
                                        ColorSwatch(hex: f.color, size: 18)
                                        Text(f.type ?? "Filament")
                                        if let slot = f.slotId { Text("Slot \(slot)").foregroundStyle(.secondary) }
                                        Spacer()
                                        Text([f.usedGrams.map { Fmt.grams($0) }, f.usedMeters.map { String(format: "%.2f m", $0) }].compactMap { $0 }.joined(separator: " · "))
                                            .foregroundStyle(.secondary).monospacedDigit()
                                    }
                                    .font(.subheadline)
                                }
                                if let objects = plate.objects, !objects.isEmpty {
                                    DisclosureGroup("Objects") {
                                        ForEach(Array(objects.enumerated()), id: \.offset) { _, name in Text(name).font(.subheadline) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("printers/\(printerId)/files/plates", query: ["path": .string(file.path)]) }
    }
}
