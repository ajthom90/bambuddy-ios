import SwiftUI
import UniformTypeIdentifiers
import QuickLook

// MARK: - Files (library folders linked to the project)

struct ProjectFilesSection: View {
    @Environment(AppSession.self) private var session
    let store: ProjectDetailStore
    let projectId: Int
    @Binding var printRequest: ProjectPrintRequest?

    @State private var runner = ActionRunner()
    @State private var showFolderPicker = false

    private var canLink: Bool { session.can("library:update_all") }
    private var canPrint: Bool { session.can("queue:create") }

    var body: some View {
        Section {
            if store.folders.isEmpty {
                Text("Link a File Manager folder to keep this project's printable files one tap away.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(store.folders) { folder in
                let files = store.files.filter { $0.folderId == folder.id }
                DisclosureGroup {
                    if files.isEmpty {
                        Text("No files in this folder").font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(files) { file in fileRow(file) }
                } label: {
                    Label {
                        HStack {
                            Text(folder.name)
                            Spacer()
                            Text("\(folder.fileCount ?? files.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: { Image(systemName: "folder.fill").foregroundStyle(.blue) }
                }
                .contextMenu {
                    if canLink {
                        Button(role: .destructive) { Task { await unlink(folder) } } label: { Label("Unlink Folder", systemImage: "link.badge.plus") }
                    }
                }
                .swipeActions {
                    if canLink {
                        Button("Unlink") { Task { await unlink(folder) } }.tint(.orange)
                    }
                }
            }
            if canLink {
                Button { showFolderPicker = true } label: { Label("Link Folder…", systemImage: "folder.badge.plus") }
            }
        } header: {
            Text("Files")
        }
        .sheet(isPresented: $showFolderPicker) {
            ProjectFolderPicker(projectId: projectId, linkedIds: Set(store.folders.map(\.id))) {
                Task { await store.load(client: session.client, id: projectId) }
            }
        }
        .actionAlerts(runner)
    }

    private func fileRow(_ file: ProjectLibraryFile) -> some View {
        HStack(spacing: 10) {
            RemoteImage(path: file.thumbnailPath != nil ? "library/files/\(file.id)/thumbnail" : nil, systemImage: "doc")
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    if let type = file.fileType { StatusBadge(text: type.uppercased(), color: file.isPrintable ? .blue : .green) }
                    if let s = file.printTimeSeconds { Text(Fmt.duration(seconds: Double(s))) }
                    if let g = file.filamentUsedGrams { Text(Fmt.grams(g)) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if file.isPrintable {
                let done = store.fileProgress[file.id] ?? 0
                if let target = store.project?.targetSets, target > 0 {
                    Text("\(done)/\(target)")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(done >= target ? .green : .secondary)
                } else if done > 0 {
                    Text("\(done)×").font(.caption).foregroundStyle(.secondary)
                }
                if canPrint {
                    Button { printRequest = ProjectPrintRequest(source: .libraryFile(id: file.id, name: file.displayName)) } label: {
                        Image(systemName: "printer.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Print \(file.displayName)")
                }
            }
        }
        .contextMenu {
            if canPrint {
                Button { printRequest = ProjectPrintRequest(source: .libraryFile(id: file.id, name: file.displayName)) } label: {
                    Label("Print…", systemImage: "printer")
                }
                Button { printRequest = ProjectPrintRequest(source: .libraryFile(id: file.id, name: file.displayName), mode: .addToQueue) } label: {
                    Label("Add to Queue…", systemImage: "text.badge.plus")
                }
            }
        }
    }

    private func unlink(_ folder: ProjectLibraryFolder) async {
        await runner.run("Folder unlinked") {
            try await session.client.call(.put, "library/folders/\(folder.id)", body: ["project_id": JSONValue.number(0)])
        }
        await store.load(client: session.client, id: projectId)
    }
}

private struct ProjectFolderPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let projectId: Int
    let linkedIds: Set<Int>
    var onLinked: () -> Void

    @State private var loader = Loader<[ProjectLibraryFolderNode]>()
    @State private var runner = ActionRunner()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { tree in
                let rows = tree.flatMap { $0.flattened() }.filter {
                    search.isEmpty || $0.node.name.localizedCaseInsensitiveContains(search)
                }
                List {
                    if rows.isEmpty {
                        ContentUnavailableView("No Folders", systemImage: "folder", description: Text("Create folders in the File Manager first."))
                    }
                    ForEach(rows, id: \.node.id) { row in
                        Button { Task { await link(row.node) } } label: {
                            HStack {
                                Label(row.node.name, systemImage: "folder")
                                    .padding(.leading, search.isEmpty ? CGFloat(row.depth) * 16 : 0)
                                Spacer()
                                if linkedIds.contains(row.node.id) {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                } else if let other = row.node.projectName, row.node.projectId != nil {
                                    Text(other).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .disabled(linkedIds.contains(row.node.id) || runner.isRunning)
                        .foregroundStyle(.primary)
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Link Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await load() }
            .actionAlerts(runner)
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("library/folders/") }
    }

    private func link(_ folder: ProjectLibraryFolderNode) async {
        await runner.run(nil) {
            try await session.client.call(.put, "library/folders/\(folder.id)", body: ["project_id": JSONValue.number(Double(projectId))])
        }
        if runner.errorMessage == nil { onLinked(); dismiss() }
    }
}

// MARK: - Parts (bill of materials)

struct ProjectBOMSection: View {
    @Environment(AppSession.self) private var session
    let store: ProjectDetailStore
    let projectId: Int
    let currency: String
    let reload: () async -> Void

    @AppStorage("projects.hideAcquiredParts") private var hideDone = false
    @State private var runner = ActionRunner()
    @State private var editing: ProjectBOMEditTarget?
    @State private var pendingDelete: ProjectBOMItem?

    private var canEdit: Bool { session.can("projects:update") }

    var body: some View {
        let stats = store.project?.stats
        Section {
            let items = store.bom.filter { !hideDone || !$0.complete }
            if store.bom.isEmpty {
                Text("Track hardware and other parts you need to buy for this project.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                row(item)
                    .swipeActions(edge: .trailing) {
                        if canEdit {
                            Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                            Button { editing = .edit(item) } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if canEdit {
                            Button { Task { await toggle(item) } } label: {
                                Label(item.complete ? "Not Acquired" : "Acquired", systemImage: item.complete ? "circle" : "checkmark.circle")
                            }
                            .tint(.green)
                        }
                    }
                    .contextMenu {
                        if canEdit {
                            Button { editing = .edit(item) } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                        }
                        if let s = item.sourcingUrl, let url = URL(string: s) {
                            Link(destination: url) { Label("Open Link", systemImage: "safari") }
                        }
                    }
            }
            if let cost = stats?.bomCost, cost > 0 {
                LabeledContent("Parts Total", value: ProjectMoney.format(cost, code: currency)).font(.subheadline.weight(.semibold))
            }
            if canEdit {
                Button { editing = .create } label: { Label("Add Part", systemImage: "plus.circle") }
            }
        } header: {
            HStack {
                Text("Parts")
                if let s = stats, (s.bomTotalItems ?? 0) > 0 {
                    Text("\(s.bomCompletedItems ?? 0)/\(s.bomTotalItems ?? 0) acquired")
                }
                Spacer()
                if store.bom.contains(where: \.complete) {
                    Button(hideDone ? "Show All" : "Hide Acquired") { withAnimation { hideDone.toggle() } }
                        .font(.caption).textCase(nil)
                }
            }
        }
        .sheet(item: $editing) { target in
            ProjectBOMEditor(projectId: projectId, target: target, currency: currency) { Task { await reload() } }
        }
        .confirm("Delete Part?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                 message: pendingDelete.map { "“\($0.name)” will be removed from the parts list." }) {
            if let item = pendingDelete { Task { await delete(item) } }
        }
        .actionAlerts(runner)
    }

    private func row(_ item: ProjectBOMItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { Task { await toggle(item) } } label: {
                Image(systemName: item.complete ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(item.complete ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canEdit)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name).strikethrough(item.complete).foregroundStyle(item.complete ? .secondary : .primary)
                    Text("×\(item.quantityNeeded)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let price = item.unitPrice {
                        Text(ProjectMoney.format(price * Double(item.quantityNeeded), code: currency)).font(.subheadline).monospacedDigit()
                    }
                }
                if item.quantityAcquired > 0 && !item.complete {
                    Text("\(item.quantityAcquired) of \(item.quantityNeeded) acquired").font(.caption).foregroundStyle(.orange)
                }
                if let s = item.sourcingUrl, let url = URL(string: s) {
                    Link(destination: url) {
                        Label((url.host() ?? s).replacingOccurrences(of: "www.", with: ""), systemImage: "link").font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                if let r = item.remarks, !r.isEmpty { Text(r).font(.caption).foregroundStyle(.secondary) }
                if let a = item.archiveName ?? item.stlFilename { Label(a, systemImage: "cube").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func toggle(_ item: ProjectBOMItem) async {
        guard canEdit else { return }
        await runner.run(nil) {
            let qty = item.complete ? 0 : item.quantityNeeded
            try await session.client.call(.patch, "projects/\(projectId)/bom/\(item.id)", body: ["quantity_acquired": JSONValue.number(Double(qty))])
        }
        await reload()
    }

    private func delete(_ item: ProjectBOMItem) async {
        await runner.run("Part removed") {
            try await session.client.call(.delete, "projects/\(projectId)/bom/\(item.id)")
        }
        await reload()
    }
}

enum ProjectBOMEditTarget: Identifiable {
    case create
    case edit(ProjectBOMItem)
    var id: String {
        switch self {
        case .create: "new"
        case .edit(let item): "bom-\(item.id)"
        }
    }
}

private struct ProjectBOMEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let projectId: Int
    let target: ProjectBOMEditTarget
    let currency: String
    var onSaved: () -> Void

    @State private var form = ProjectBOMForm()
    @State private var acquired = 0
    @State private var runner = ActionRunner()

    private var editingItem: ProjectBOMItem? {
        if case .edit(let item) = target { return item }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Part name", text: $form.name)
                    Stepper("Quantity: \(form.quantity)", value: $form.quantity, in: 1...100_000)
                    if editingItem != nil {
                        Stepper("Acquired: \(acquired)", value: $acquired, in: 0...max(form.quantity, acquired))
                    }
                    LabeledContent("Unit Price (\(currency))") {
                        TextField("Optional", text: $form.unitPrice).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    TextField("Sourcing link", text: $form.sourcingURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Remarks", text: $form.remarks, axis: .vertical).lineLimit(1...4)
                }
            }
            .navigationTitle(editingItem == nil ? "Add Part" : "Edit Part")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingItem == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                }
            }
            .onAppear {
                if let item = editingItem, form == ProjectBOMForm() {
                    form = ProjectBOMForm(item: item)
                    acquired = item.quantityAcquired
                }
            }
            .actionAlerts(runner)
        }
    }

    private func save() async {
        await runner.run(nil) {
            if let item = editingItem {
                var body = form.body
                // The server clears a price sent as 0 and text sent as "".
                for key in ["unit_price", "sourcing_url", "remarks"] where body[key] == nil {
                    body[key] = key == "unit_price" ? .number(0) : .string("")
                }
                body["quantity_acquired"] = .number(Double(acquired))
                try await session.client.call(.patch, "projects/\(projectId)/bom/\(item.id)", body: body)
            } else {
                try await session.client.call(.post, "projects/\(projectId)/bom", body: form.body)
            }
        }
        if runner.errorMessage == nil { onSaved(); dismiss() }
    }
}

// MARK: - Linked prints (archives)

struct ProjectArchivesSection: View {
    @Environment(AppSession.self) private var session
    let store: ProjectDetailStore
    let projectId: Int
    @Binding var printRequest: ProjectPrintRequest?
    let reload: () async -> Void

    @State private var runner = ActionRunner()
    @State private var showPicker = false
    @State private var showAll = false

    private var canEdit: Bool { session.can("projects:update") }
    private var canReprint: Bool {
        session.can("queue:create") && (session.can("archives:reprint_all") || session.can("archives:reprint_own"))
    }

    var body: some View {
        Section {
            if store.archives.isEmpty {
                Text("No prints linked yet. Prints started from this project's files are added automatically.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            let shown = showAll ? store.archives : Array(store.archives.prefix(12))
            ForEach(shown) { archive in
                row(archive)
                    .swipeActions {
                        if canEdit {
                            Button("Remove") { Task { await remove([archive.id]) } }.tint(.orange)
                        }
                    }
                    .contextMenu {
                        if canReprint {
                            Button { printRequest = ProjectPrintRequest(source: .archive(id: archive.id, name: archive.displayName)) } label: {
                                Label("Reprint…", systemImage: "printer")
                            }
                            Button { printRequest = ProjectPrintRequest(source: .archive(id: archive.id, name: archive.displayName), mode: .addToQueue) } label: {
                                Label("Add to Queue…", systemImage: "text.badge.plus")
                            }
                        }
                        if canEdit {
                            Button(role: .destructive) { Task { await remove([archive.id]) } } label: {
                                Label("Remove from Project", systemImage: "minus.circle")
                            }
                        }
                    }
            }
            if store.archives.count > 12 {
                Button(showAll ? "Show Fewer" : "Show All \(store.archives.count)") { withAnimation { showAll.toggle() } }
            }
            if canEdit {
                Button { showPicker = true } label: { Label("Add Prints…", systemImage: "plus.circle") }
            }
        } header: {
            Text("Prints (\(store.archives.count))")
        }
        .sheet(isPresented: $showPicker) {
            ProjectArchivePicker(projectId: projectId, existing: Set(store.archives.map(\.id))) { Task { await reload() } }
        }
        .actionAlerts(runner)
    }

    private func row(_ a: ProjectArchiveEntry) -> some View {
        HStack(spacing: 10) {
            RemoteImage(path: a.thumbnailPath != nil ? "archives/\(a.id)/thumbnail" : nil, systemImage: "cube")
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(a.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    Text(Fmt.date(a.completedAt ?? a.createdAt, style: .dateTime.month(.abbreviated).day().year()))
                    if let s = a.printTimeSeconds { Text(Fmt.duration(seconds: Double(s))) }
                    if let g = a.filamentUsedGrams { Text(Fmt.grams(g)) }
                    if let q = a.quantity, q > 1 { Text("×\(q)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ProjectArchiveStatusIcon(status: a.status)
        }
    }

    private func remove(_ ids: [Int]) async {
        await runner.run("Removed from project") {
            try await session.client.call(.post, "projects/\(projectId)/remove-archives", body: ["archive_ids": ids])
        }
        await reload()
    }
}

struct ProjectArchiveStatusIcon: View {
    let status: String?
    var body: some View {
        switch status {
        case "completed": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case "cancelled", "stopped": Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        case "printing": Image(systemName: "printer.fill").foregroundStyle(.blue)
        default: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }
}

private struct ProjectArchivePicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let projectId: Int
    let existing: Set<Int>
    var onAdded: () -> Void

    @State private var loader = Loader<[ProjectArchiveEntry]>()
    @State private var runner = ActionRunner()
    @State private var selection: Set<Int> = []
    @State private var search = ""
    @State private var onlyUnassigned = true

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { archives in
                let rows = archives.filter { a in
                    !existing.contains(a.id)
                        && (!onlyUnassigned || a.projectId == nil)
                        && (search.isEmpty || a.displayName.localizedCaseInsensitiveContains(search))
                }
                List(selection: $selection) {
                    Toggle("Only prints without a project", isOn: $onlyUnassigned)
                    if rows.isEmpty {
                        ContentUnavailableView("No Prints", systemImage: "archivebox", description: Text("There are no other prints to add."))
                    }
                    ForEach(rows) { a in
                        HStack(spacing: 10) {
                            RemoteImage(path: a.thumbnailPath != nil ? "archives/\(a.id)/thumbnail" : nil, systemImage: "cube")
                                .frame(width: 40, height: 40)
                                .clipShape(.rect(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(a.displayName).lineLimit(1)
                                Text([Fmt.date(a.createdAt, style: .dateTime.month(.abbreviated).day().year()), a.projectName.map { "in \($0)" }]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProjectArchiveStatusIcon(status: a.status)
                        }
                        .tag(a.id)
                    }
                }
                .environment(\.editMode, .constant(.active))
            }
            .searchable(text: $search, prompt: "Search prints")
            .navigationTitle(selection.isEmpty ? "Add Prints" : "\(selection.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await add() } }.disabled(selection.isEmpty || runner.isRunning)
                }
            }
            .task { await load() }
            .actionAlerts(runner)
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("archives/", query: ["limit": 500]) }
    }

    private func add() async {
        let ids = Array(selection)
        await runner.run(nil) {
            try await session.client.call(.post, "projects/\(projectId)/add-archives", body: ["archive_ids": ids])
        }
        if runner.errorMessage == nil { onAdded(); dismiss() }
    }
}

// MARK: - Attachments

struct ProjectAttachmentsSection: View {
    @Environment(AppSession.self) private var session
    let store: ProjectDetailStore
    let projectId: Int
    let reload: () async -> Void

    @State private var runner = ActionRunner()
    @State private var showImporter = false
    @State private var previewURL: URL?
    @State private var shareFile: ProjectsSharedFile?
    @State private var busy: String?
    @State private var pendingDelete: ProjectAttachment?

    private var canEdit: Bool { session.can("projects:update") }

    var body: some View {
        let attachments = store.project?.attachments ?? []
        Section {
            if attachments.isEmpty {
                Text("Attach photos, PDFs, instructions or model files.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(attachments) { att in
                Button { Task { await open(att, share: false) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: att.displayName)).font(.title3).foregroundStyle(.tint).frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(att.displayName).foregroundStyle(.primary).lineLimit(1)
                            Text([att.size.map { Fmt.bytes($0) }, att.uploadedAt.map { Fmt.date($0, style: .dateTime.month(.abbreviated).day().year()) }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if busy == att.filename { ProgressView() }
                    }
                }
                .swipeActions {
                    if canEdit {
                        Button(role: .destructive) { pendingDelete = att } label: { Label("Delete", systemImage: "trash") }
                    }
                    Button { Task { await open(att, share: true) } } label: { Label("Share", systemImage: "square.and.arrow.up") }.tint(.blue)
                }
                .contextMenu {
                    Button { Task { await open(att, share: false) } } label: { Label("Open", systemImage: "eye") }
                    Button { Task { await open(att, share: true) } } label: { Label("Share…", systemImage: "square.and.arrow.up") }
                    if canEdit {
                        Button(role: .destructive) { pendingDelete = att } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            if canEdit {
                Button { showImporter = true } label: {
                    HStack {
                        Label("Add Attachment…", systemImage: "paperclip")
                        if busy == "upload" { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy == "upload")
            }
        } header: {
            Text("Attachments")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await upload(urls) } }
        }
        .quickLookPreview($previewURL)
        .sheet(item: $shareFile) { ProjectsActivitySheet(items: [$0.url]) }
        .confirm("Delete Attachment?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                 message: pendingDelete?.displayName) {
            if let att = pendingDelete { Task { await delete(att) } }
        }
        .actionAlerts(runner)
    }

    private func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "svg", "ico": "photo"
        case "pdf": "doc.richtext"
        case "stl", "3mf", "step", "stp", "obj": "cube"
        case "zip", "7z", "rar", "gz", "tar": "doc.zipper"
        case "txt", "md", "csv", "doc", "docx", "xls", "xlsx": "doc.text"
        default: "doc"
        }
    }

    private func open(_ att: ProjectAttachment, share: Bool) async {
        guard let filename = att.filename else { return }
        busy = filename
        defer { busy = nil }
        await runner.run(nil) {
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            let url = try await session.client.download("projects/\(projectId)/attachments/\(encoded)", suggestedName: att.displayName)
            if share { shareFile = ProjectsSharedFile(url: url) } else { previewURL = url }
        }
    }

    private func upload(_ urls: [URL]) async {
        busy = "upload"
        defer { busy = nil }
        await runner.run(urls.count == 1 ? "Attachment added" : "\(urls.count) attachments added") {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let _: ProjectUploadResult = try await session.client.upload("projects/\(projectId)/attachments", files: [
                    UploadFile(fileName: url.lastPathComponent, mimeType: mime, data: data),
                ])
            }
        }
        await reload()
    }

    private func delete(_ att: ProjectAttachment) async {
        guard let filename = att.filename else { return }
        await runner.run("Attachment deleted") {
            let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
            try await session.client.call(.delete, "projects/\(projectId)/attachments/\(encoded)")
        }
        await reload()
    }
}

// MARK: - Notes

struct ProjectNotesSection: View {
    @Environment(AppSession.self) private var session
    let store: ProjectDetailStore
    let projectId: Int
    let reload: () async -> Void
    @State private var editing = false

    var body: some View {
        Section {
            if let notes = store.notes {
                Text(notes).textSelection(.enabled)
            } else {
                Text("No notes yet.").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Notes")
                Spacer()
                if session.can("projects:update") {
                    Button("Edit") { editing = true }.font(.caption).textCase(nil)
                }
            }
        }
        .sheet(isPresented: $editing) {
            ProjectNotesEditor(projectId: projectId, html: store.project?.notes) { Task { await reload() } }
        }
    }
}

private struct ProjectNotesEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let projectId: Int
    let html: String?
    var onSaved: () -> Void

    @State private var text = ""
    @State private var runner = ActionRunner()
    @FocusState private var focused: Bool

    private var hadFormatting: Bool {
        guard let html else { return false }
        return html.range(of: "<(b|strong|i|em|u|h[1-6]|ul|ol|a|code|blockquote|s)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 260)
                        .focused($focused)
                } footer: {
                    if hadFormatting {
                        Text("These notes contain formatting from the web editor. Saving here stores them as plain paragraphs.")
                    }
                }
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }.disabled(runner.isRunning)
                }
            }
            .onAppear {
                text = ProjectDetailStore.plainNotes(html)
                focused = true
            }
            .actionAlerts(runner)
        }
    }

    private func save() async {
        await runner.run(nil) {
            try await session.client.call(.patch, "projects/\(projectId)", body: ["notes": JSONValue.string(ProjectDetailStore.notesHTML(text))])
        }
        if runner.errorMessage == nil { onSaved(); dismiss() }
    }
}

// MARK: - Timeline

struct ProjectTimelineSection: View {
    let events: [ProjectTimelineEvent]

    var body: some View {
        Section("Activity") {
            if events.isEmpty {
                Text("No activity yet.").foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(event.eventType))
                        .foregroundStyle(color(event.eventType))
                        .frame(width: 28, height: 28)
                        .background(color(event.eventType).opacity(0.15), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title).font(.subheadline)
                        if let d = event.description, !d.isEmpty {
                            Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Text(Fmt.date(event.timestamp)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func icon(_ type: String) -> String {
        switch type {
        case "print_completed": "checkmark"
        case "print_failed": "xmark"
        case "print_started": "printer"
        case "queued": "list.number"
        case "project_created": "plus"
        default: "clock"
        }
    }

    private func color(_ type: String) -> Color {
        switch type {
        case "print_completed": .green
        case "print_failed": .red
        case "print_started": .yellow
        case "queued": .blue
        default: .secondary
        }
    }
}
