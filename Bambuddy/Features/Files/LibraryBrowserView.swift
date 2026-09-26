import SwiftUI
import UniformTypeIdentifiers

/// Which slice of the library a browser shows.
enum LibraryScope: Hashable, Sendable {
    /// Top level: folders plus files that live outside any folder.
    case root
    case folder(Int)
    /// Every file in managed storage, across folders.
    case allInternal
    /// Every file under linked external folders.
    case allExternal
}

enum LibraryRoute: Hashable, Sendable {
    case browse(LibraryScope)
    case file(Int)
    case trash
}

/// Owns the Files tab's navigation path so breadcrumbs can jump to ancestors.
@MainActor
@Observable
final class LibraryNavigator {
    var path: [LibraryRoute] = []
}

/// Registers destinations for `LibraryRoute` values (used by Files and MakerWorld).
struct LibraryNavigationDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .browse(let scope): LibraryBrowserView(scope: scope)
            case .file(let id): LibraryFileDetailView(fileId: id)
            case .trash: LibraryTrashView()
            }
        }
    }
}

private enum LibrarySortField: String, CaseIterable, Identifiable {
    case name, date, size, type, prints
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .date: "Date Modified"
        case .size: "Size"
        case .type: "Type"
        case .prints: "Print Count"
        }
    }
}

private enum LibraryFolderSheet: Identifiable {
    case create(parent: Int?)
    case rename(LibraryFolderNode)
    case link(LibraryFolderNode)
    case move(LibraryFolderNode)
    case external(parent: Int?)

    var id: String {
        switch self {
        case .create(let p): "create-\(p ?? 0)"
        case .rename(let f): "rename-\(f.id)"
        case .link(let f): "link-\(f.id)"
        case .move(let f): "move-\(f.id)"
        case .external(let p): "external-\(p ?? 0)"
        }
    }
}

private struct LibraryPendingUpload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Folder browser + file list/grid with search, filters, sorting, selection
/// and bulk actions. Mirrors the web File Manager.
struct LibraryBrowserView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(LibraryNavigator.self) private var navigator: LibraryNavigator?
    let scope: LibraryScope

    @State private var folders = Loader<[LibraryFolderNode]>()
    @State private var files = Loader<[LibraryFileSummary]>()
    @State private var stats: LibraryStats?
    @State private var settings: LibraryServerSettings?
    @State private var trashCount: Int?
    @State private var tagCatalog: [LibraryTag] = []
    @State private var readme: LibraryFolderReadme?
    @State private var actions = LibraryFileActions()
    @State private var runner = ActionRunner()

    @State private var search = ""
    @State private var typeFilter: String?
    @State private var ownerFilter: String?
    @State private var tagFilter: Set<Int> = []
    @AppStorage("library.sortField") private var sortRaw = LibrarySortField.name.rawValue
    @AppStorage("library.sortAscending") private var ascending = true
    @AppStorage("library.gridView") private var gridView = false
    @AppStorage("library.showModified") private var showModified = false
    @AppStorage("library.foldersByActivity") private var foldersByActivity = false

    @State private var selection: Set<Int> = []
    @State private var editMode: EditMode = .inactive
    @State private var folderSheet: LibraryFolderSheet?
    @State private var deletingFolder: LibraryFolderNode?
    @State private var showImporter = false
    @State private var pendingUpload: LibraryPendingUpload?
    @State private var showPurge = false
    @State private var showTagManager = false
    @State private var showTrash = false
    @State private var showReadme = true
    @State private var dropTargeted = false

    // MARK: Derived state

    private var folderTree: [LibraryFolderNode] { folders.value ?? [] }
    private var currentFolder: LibraryFolderNode? {
        if case .folder(let id) = scope { return LibraryFolderTree.find(id, in: folderTree) }
        return nil
    }
    private var currentFolderId: Int? {
        if case .folder(let id) = scope { return id }
        return nil
    }
    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !trimmedSearch.isEmpty }
    private var sortField: LibrarySortField { LibrarySortField(rawValue: sortRaw) ?? .name }
    private var useSlicerApi: Bool { settings?.useSlicerApi ?? false }
    private var isReadOnlyFolder: Bool { currentFolder?.readOnly ?? false }
    private var canUpload: Bool {
        session.can("library:upload") && !isReadOnlyFolder && scope != .allExternal
    }
    private var hasExternal: Bool { folderTree.contains { $0.external } }

    private var title: String {
        switch scope {
        case .root: "Files"
        case .folder(let id): currentFolder?.name ?? "Folder \(id)"
        case .allInternal: "All Files"
        case .allExternal: "External Files"
        }
    }

    private var subfolders: [LibraryFolderNode] {
        let list: [LibraryFolderNode]
        switch scope {
        case .root: list = folderTree
        case .folder: list = currentFolder?.subfolders ?? []
        case .allInternal, .allExternal: list = []
        }
        return list.sorted { a, b in
            if foldersByActivity {
                switch (a.latestActivityAt.flatMap(APICoders.parseDate), b.latestActivityAt.flatMap(APICoders.parseDate)) {
                case let (x?, y?): return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private var visibleFiles: [LibraryFileSummary] {
        var list = files.value ?? []
        if isSearching {
            list = list.filter { $0.filename.localizedCaseInsensitiveContains(trimmedSearch) || ($0.printName?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) }
        }
        if let typeFilter { list = list.filter { $0.type == typeFilter } }
        if let ownerFilter { list = list.filter { $0.createdByUsername == ownerFilter } }
        let field = sortField
        list.sort { a, b in
            let ordered: Bool
            switch field {
            case .name:
                ordered = a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
            case .date:
                ordered = (a.modifiedAt.flatMap(APICoders.parseDate) ?? .distantPast) < (b.modifiedAt.flatMap(APICoders.parseDate) ?? .distantPast)
            case .size:
                ordered = (a.fileSize ?? 0) < (b.fileSize ?? 0)
            case .type:
                ordered = a.type < b.type
            case .prints:
                ordered = (a.printCount ?? 0) < (b.printCount ?? 0)
            }
            return ascending ? ordered : !ordered
        }
        return list
    }

    private var fileTypes: [String] { Array(Set((files.value ?? []).map(\.type))).sorted() }
    private var owners: [String] { Array(Set((files.value ?? []).compactMap(\.createdByUsername))).sorted() }
    private var filtersActive: Bool { typeFilter != nil || ownerFilter != nil || !tagFilter.isEmpty }

    private var selectedRefs: [LibraryFileRef] {
        (files.value ?? []).filter { selection.contains($0.id) }.map(LibraryFileRef.init)
    }

    private var fileQuery: [String: QueryValue?] {
        var q: [String: QueryValue?] = [:]
        switch scope {
        case .root:
            if isSearching {
                q["include_root"] = false
            } else {
                q["include_root"] = true
                q["internal_only"] = true
            }
        case .folder(let id):
            q["folder_id"] = .int(id)
            q["include_root"] = false
            if isSearching { q["recursive"] = true }
        case .allInternal:
            q["include_root"] = false
            q["internal_only"] = true
        case .allExternal:
            q["include_root"] = false
            q["external_only"] = true
        }
        if !tagFilter.isEmpty { q["tag_ids"] = .list(tagFilter.sorted().map(String.init)) }
        return q
    }

    private struct LoadKey: Hashable { let searching: Bool; let tags: Set<Int>; let revision: Int }

    // MARK: Body

    var body: some View {
        content
            .navigationTitle(title)
            .toolbarTitleMenu { breadcrumbMenu }
            .searchable(text: $search, prompt: currentFolder != nil ? "Search this folder and subfolders" : "Search files")
            .refreshable { await reload() }
            .toolbar { toolbarContent }
            .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
            .task(id: LoadKey(searching: isSearching, tags: tagFilter, revision: live.revision("print_complete", "archive_created", "pipeline_run_updated"))) {
                await reload()
            }
            .navigationDestination(isPresented: $showTrash) { LibraryTrashView() }
            .modifier(LibraryFileActionsPresenter(actions: actions, reload: reload, onDeleted: { ids in selection.subtract(ids) }))
            .sheet(item: $folderSheet) { sheet in folderSheetContent(sheet) }
            .sheet(item: $pendingUpload) { upload in
                LibraryUploadSheet(folderId: currentFolderId, folderName: currentFolder?.name ?? "Library (no folder)", initialFiles: upload.urls) {
                    Task { await reload() }
                }
            }
            .sheet(isPresented: $showPurge) { LibraryPurgeSheet { Task { await reload() } } }
            .sheet(isPresented: $showTagManager) { LibraryTagManagerSheet { Task { await loadTags(); await reload() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    let staged = urls.compactMap { try? LibraryImportStaging.stage($0) }
                    if !staged.isEmpty { pendingUpload = LibraryPendingUpload(urls: staged) }
                case .failure(let error):
                    runner.errorMessage = error.localizedDescription
                }
            }
            .onDrop(of: [.item], isTargeted: $dropTargeted) { providers in
                guard canUpload else { return false }
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = await LibraryImportStaging.stage(provider: provider) { urls.append(url) }
                    }
                    if !urls.isEmpty { pendingUpload = LibraryPendingUpload(urls: urls) }
                }
                return true
            }
            .overlay {
                if dropTargeted && canUpload {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .background(Color.accentColor.opacity(0.08), in: .rect(cornerRadius: 16))
                        .overlay { Label("Drop to Upload", systemImage: "square.and.arrow.down").font(.title2.bold()) }
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .confirm("Delete folder “\(deletingFolder?.name ?? "")”?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
                     message: deletingFolder?.external == true
                        ? "The link to the external folder is removed. Files on the server's disk are not deleted."
                        : "The folder, its subfolders and all files inside are deleted.") {
                if let folder = deletingFolder { Task { await deleteFolder(folder) } }
            }
            .actionAlerts(runner)
            .onChange(of: editMode.isEditing) { _, editing in if !editing { selection = [] } }
    }

    @ViewBuilder
    private var content: some View {
        if files.value == nil && folders.value == nil, let error = files.error ?? folders.error {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Try Again") { Task { await reload() } }.buttonStyle(.bordered)
            }
        } else if files.value == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if gridView {
            gridContent
        } else {
            listContent
        }
    }

    // MARK: List

    private var listContent: some View {
        List(selection: $selection) {
            headerSections
            if !subfolders.isEmpty && !isSearching {
                Section {
                    ForEach(subfolders) { folder in
                        folderRow(folder)
                    }
                } header: {
                    Text("Folders")
                }
            }
            Section {
                ForEach(visibleFiles) { file in
                    fileListRow(file)
                        .tag(file.id)
                }
            } header: {
                if !visibleFiles.isEmpty { filesHeader }
            }
        }
        .environment(\.editMode, $editMode)
        .overlay { emptyState }
    }

    private var filesHeader: some View {
        let total = files.value?.count ?? 0
        let shown = visibleFiles.count
        return Text(shown == total ? "\(total) \(total == 1 ? "File" : "Files")" : "\(shown) of \(total) Files")
    }

    @ViewBuilder
    private var headerSections: some View {
        if scope == .root && !isSearching {
            Section {
                if let stats { LibraryStatsStrip(stats: stats, lowDisk: isLowDisk) }
                NavigationLink(value: LibraryRoute.browse(.allInternal)) {
                    Label("All Files", systemImage: "doc.on.doc")
                }
                if hasExternal {
                    NavigationLink(value: LibraryRoute.browse(.allExternal)) {
                        Label("External Files", systemImage: "externaldrive.connected.to.line.below")
                    }
                }
                if LibraryAccess.canDeleteAny(session) {
                    NavigationLink(value: LibraryRoute.trash) {
                        Label("Trash", systemImage: "trash")
                    }
                    .badge(trashCount ?? 0)
                }
            }
        }
        if let folder = currentFolder, folder.external || folder.isLinked {
            Section { folderInfoBanner(folder) }
        }
        if let readme, let text = readme.content, !text.isEmpty, !isSearching {
            Section {
                DisclosureGroup(isExpanded: $showReadme) {
                    Text(markdown(text)).font(.callout).textSelection(.enabled)
                    if readme.truncated == true {
                        Text("README truncated").font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Label(readme.filename ?? "README", systemImage: "doc.richtext")
                }
            }
        }
        if filtersActive {
            Section { activeFilterChips }
        }
    }

    private var isLowDisk: Bool {
        guard let free = stats?.diskFreeBytes, let total = stats?.diskTotalBytes, total > 0 else { return false }
        let threshold = (settings?.libraryDiskWarningGb ?? 5) * 1_073_741_824
        return Double(free) < threshold
    }

    @ViewBuilder
    private func folderInfoBanner(_ folder: LibraryFolderNode) -> some View {
        if folder.external {
            VStack(alignment: .leading, spacing: 6) {
                Label(folder.readOnly ? "External Folder · Read Only" : "External Folder", systemImage: "externaldrive.connected.to.line.below")
                    .foregroundStyle(.purple)
                if let path = folder.externalPath {
                    Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if session.can("library:upload") {
                    Button("Scan for Changes", systemImage: "arrow.clockwise") { Task { await scan(folder) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        if let link = folder.linkDescription {
            Label(link, systemImage: "link")
                .foregroundStyle(.secondary)
                .swipeActions {
                    if session.can("library:update_all") {
                        Button("Change") { folderSheet = .link(folder) }
                    }
                }
        }
    }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let typeFilter {
                    chip("Type: \(typeFilter.uppercased())") { self.typeFilter = nil }
                }
                if let ownerFilter {
                    chip("Owner: \(ownerFilter)") { self.ownerFilter = nil }
                }
                ForEach(tagCatalog.filter { tagFilter.contains($0.id) }) { tag in
                    chip("# \(tag.name)") { tagFilter.remove(tag.id) }
                }
                Button("Clear All") { typeFilter = nil; ownerFilter = nil; tagFilter = [] }
                    .font(.caption)
            }
        }
    }

    private func chip(_ text: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: "xmark.circle.fill")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.15), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var emptyState: some View {
        if files.value != nil && visibleFiles.isEmpty && (isSearching || filtersActive) && (subfolders.isEmpty || isSearching) {
            if isSearching {
                ContentUnavailableView.search(text: trimmedSearch)
            } else {
                ContentUnavailableView {
                    Label("No Matching Files", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No files match the current filters.")
                } actions: {
                    Button("Clear Filters") { typeFilter = nil; ownerFilter = nil; tagFilter = [] }
                }
            }
        } else if files.value?.isEmpty == true && subfolders.isEmpty && scope != .root {
            ContentUnavailableView {
                Label(scope == .allExternal ? "No External Files" : "Empty Folder", systemImage: "folder")
            } description: {
                Text(scope == .allExternal ? "Link an external folder to index files stored elsewhere on the server." : "Upload files or create a subfolder.")
            } actions: {
                if canUpload { Button("Upload Files") { showImporter = true }.buttonStyle(.borderedProminent) }
            }
        } else if scope == .root && files.value?.isEmpty == true && folderTree.isEmpty {
            ContentUnavailableView {
                Label("No Files Yet", systemImage: "folder")
            } description: {
                Text("Upload 3MF, STL or G-code files, or import models from MakerWorld.")
            } actions: {
                if canUpload { Button("Upload Files") { showImporter = true }.buttonStyle(.borderedProminent) }
            }
            .padding(.top, 180)
        }
    }

    // MARK: Rows

    private func folderRow(_ folder: LibraryFolderNode) -> some View {
        NavigationLink(value: LibraryRoute.browse(.folder(folder.id))) {
            HStack(spacing: 12) {
                Image(systemName: folder.external ? "externaldrive.connected.to.line.below.fill" : (folder.isLinked ? "folder.fill.badge.gearshape" : "folder.fill"))
                    .font(.title2)
                    .foregroundStyle(folder.external ? .purple : .blue)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(folder.name)
                        if folder.readOnly { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                    }
                    let subtitle = [folder.linkDescription, folder.latestActivityAt.map { "Active \(Fmt.relative($0))" }].compactMap { $0 }
                    if !subtitle.isEmpty {
                        Text(subtitle.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let count = folder.fileCount, count > 0 {
                    Text("\(count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .contextMenu { folderMenu(folder) }
        .swipeActions {
            if canDelete(folder) {
                Button("Delete", role: .destructive) { deletingFolder = folder }
            }
            if session.can("library:update_all") {
                Button("Rename") { folderSheet = .rename(folder) }.tint(.orange)
            }
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: LibraryFolderNode) -> some View {
        let canEdit = session.can("library:update_all")
        Button("Rename…", systemImage: "pencil") { folderSheet = .rename(folder) }.disabled(!canEdit)
        Button("Move…", systemImage: "folder") { folderSheet = .move(folder) }.disabled(!canEdit)
        Button(folder.isLinked ? "Change Link…" : "Link to Project or Archive…", systemImage: "link") { folderSheet = .link(folder) }
            .disabled(!canEdit)
        if !folder.readOnly && session.can("library:upload") {
            Button("New Subfolder…", systemImage: "folder.badge.plus") { folderSheet = .create(parent: folder.id) }
        }
        if folder.external && session.can("library:upload") {
            Button("Scan for Changes", systemImage: "arrow.clockwise") { Task { await scan(folder) } }
        }
        Button("Generate Missing Thumbnails", systemImage: "photo") { Task { await generateThumbnails(folderId: folder.id) } }
            .disabled(!LibraryAccess.canUpdateAny(session))
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { deletingFolder = folder }
            .disabled(!canDelete(folder))
    }

    private func canDelete(_ folder: LibraryFolderNode) -> Bool {
        if session.can("library:delete_all") { return true }
        return session.can("library:delete_own") && (folder.fileCount ?? 0) == 0 && folder.subfolders.isEmpty && !folder.external && !folder.isLinked
    }

    private func fileListRow(_ file: LibraryFileSummary) -> some View {
        let ref = LibraryFileRef(file)
        return NavigationLink(value: LibraryRoute.file(file.id)) {
            LibraryFileRowContent(file: file, showModified: showModified, showOwner: session.isAuthEnabled,
                                  thumbnailVersion: actions.thumbnailVersions[file.id] ?? 0) { tag in
                tagFilter.insert(tag.id)
            }
        }
        .contextMenu { LibraryFileMenuItems(file: ref, actions: actions, useSlicerApi: useSlicerApi, reload: reload) }
        .swipeActions(edge: .trailing) {
            if LibraryAccess.canDelete(session, ownerId: file.createdById) {
                Button("Delete", role: .destructive) { actions.pendingDelete = [ref] }
            }
            if LibraryAccess.canUpdate(session, ownerId: file.createdById) {
                Button("Move") { actions.sheet = .move([ref]) }.tint(.indigo)
            }
        }
        .swipeActions(edge: .leading) {
            if file.isSliced && session.can("queue:create") {
                Button("Print") { actions.sheet = .print(ref, .printNow) }.tint(.green)
            } else if useSlicerApi && ref.isSliceable && session.can("library:upload") {
                Button("Slice") { actions.sheet = .slice(ref) }.tint(.blue)
            }
        }
    }

    // MARK: Grid

    private var gridColumns: [GridItem] { [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)] }

    private var gridContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if scope == .root && !isSearching {
                    if let stats { LibraryStatsStrip(stats: stats, lowDisk: isLowDisk).padding(.horizontal) }
                    HStack(spacing: 10) {
                        NavigationLink(value: LibraryRoute.browse(.allInternal)) { Label("All Files", systemImage: "doc.on.doc") }
                        if hasExternal {
                            NavigationLink(value: LibraryRoute.browse(.allExternal)) { Label("External", systemImage: "externaldrive.connected.to.line.below") }
                        }
                        if LibraryAccess.canDeleteAny(session) {
                            NavigationLink(value: LibraryRoute.trash) {
                                Label(trashCount.map { $0 > 0 ? "Trash (\($0))" : "Trash" } ?? "Trash", systemImage: "trash")
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }
                if let folder = currentFolder, folder.external || folder.isLinked {
                    VStack(alignment: .leading) { folderInfoBanner(folder) }
                        .padding()
                        .background(.background.secondary, in: .rect(cornerRadius: 12))
                        .padding(.horizontal)
                }
                if let readme, let text = readme.content, !text.isEmpty, !isSearching {
                    DisclosureGroup(isExpanded: $showReadme) {
                        Text(markdown(text)).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(readme.filename ?? "README", systemImage: "doc.richtext")
                    }
                    .padding()
                    .background(.background.secondary, in: .rect(cornerRadius: 12))
                    .padding(.horizontal)
                }
                if filtersActive { activeFilterChips.padding(.horizontal) }
                if !subfolders.isEmpty && !isSearching {
                    Text("Folders").font(.headline).padding(.horizontal)
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(subfolders) { folder in
                            NavigationLink(value: LibraryRoute.browse(.folder(folder.id))) {
                                LibraryFolderTile(folder: folder)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { folderMenu(folder) }
                        }
                    }
                    .padding(.horizontal)
                }
                if !visibleFiles.isEmpty {
                    filesHeader.font(.headline).padding(.horizontal)
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(visibleFiles) { file in
                            gridCard(file)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .overlay { emptyState }
    }

    @ViewBuilder
    private func gridCard(_ file: LibraryFileSummary) -> some View {
        let ref = LibraryFileRef(file)
        let card = LibraryFileCard(file: file, selected: editMode.isEditing ? selection.contains(file.id) : nil,
                                   showModified: showModified, showOwner: session.isAuthEnabled,
                                   thumbnailVersion: actions.thumbnailVersions[file.id] ?? 0)
        Group {
            if editMode.isEditing {
                Button {
                    if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
                } label: { card }
            } else {
                NavigationLink(value: LibraryRoute.file(file.id)) { card }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { LibraryFileMenuItems(file: ref, actions: actions, useSlicerApi: useSlicerApi, reload: reload) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if editMode.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                let all = visibleFiles.map(\.id)
                Button(selection.count == all.count && !all.isEmpty ? "Deselect All" : "Select All") {
                    selection = selection.count == all.count ? [] : Set(all)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { withAnimation { editMode = .inactive } }.bold()
            }
            ToolbarItemGroup(placement: .bottomBar) { selectionBar }
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if canUpload || session.can("library:upload") {
                    Menu {
                        if canUpload {
                            Button("Upload Files…", systemImage: "square.and.arrow.up") { showImporter = true }
                        }
                        if session.can("library:upload") && !isReadOnlyFolder && scope != .allInternal && scope != .allExternal {
                            Button("New Folder…", systemImage: "folder.badge.plus") { folderSheet = .create(parent: currentFolderId) }
                        }
                        if session.can("library:upload") && (scope == .root || scope == .allExternal) {
                            Button("Link External Folder…", systemImage: "externaldrive.badge.plus") { folderSheet = .external(parent: nil) }
                        }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                filterMenu
                moreMenu
            }
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        let refs = selectedRefs
        let sliced = refs.filter(\.isSliced)
        Menu {
            if sliced.count == 1, let file = sliced.first {
                Button("Print…", systemImage: "printer") { actions.sheet = .print(file, .printNow) }
                    .disabled(!session.can("queue:create"))
            }
            if !sliced.isEmpty {
                Button(sliced.count == 1 ? "Add to Queue" : "Add \(sliced.count) to Queue", systemImage: "text.badge.plus") {
                    Task { await actions.addToQueue(sliced, client: session.client); editMode = .inactive }
                }
                .disabled(!session.can("queue:create"))
            }
            if sliced.count >= 2 && !sliced.contains(where: { $0.variantGroupId != nil }) {
                Button("Group as Versions", systemImage: "square.stack.3d.up") {
                    Task { await actions.groupAsVersions(sliced, client: session.client, reload: reload); editMode = .inactive }
                }
                .disabled(!LibraryAccess.canUpdateAny(session))
            }
            Section {
                Button("Move…", systemImage: "folder") { actions.sheet = .move(refs) }
                Button("Tags…", systemImage: "tag") { actions.sheet = .tags(refs) }
                Button("Add to Project…", systemImage: "briefcase") { actions.sheet = .project(refs) }
                if refs.contains(where: \.isSTL) {
                    Button("Generate Thumbnails", systemImage: "photo") {
                        Task { await actions.generateThumbnails(refs.filter(\.isSTL), client: session.client, reload: reload) }
                    }
                }
            }
            .disabled(!LibraryAccess.canUpdateAny(session))
            if refs.count == 1, let file = refs.first {
                Button("Share…", systemImage: "square.and.arrow.up") { Task { await actions.share(file, client: session.client) } }
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
        .disabled(refs.isEmpty)
        Spacer()
        Text(refs.isEmpty ? "Select Files" : "\(refs.count) Selected").font(.footnote).foregroundStyle(.secondary)
        Spacer()
        Button(role: .destructive) { actions.pendingDelete = refs } label: { Label("Delete", systemImage: "trash") }
            .disabled(refs.isEmpty || !LibraryAccess.canDeleteAny(session))
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $typeFilter) {
                Text("All Types").tag(String?.none)
                ForEach(fileTypes, id: \.self) { Text($0.uppercased()).tag(String?.some($0)) }
            }
            .pickerStyle(.menu)
            if !tagCatalog.isEmpty {
                Menu("Tags") {
                    ForEach(tagCatalog) { tag in
                        Toggle(isOn: Binding(get: { tagFilter.contains(tag.id) }, set: { on in if on { tagFilter.insert(tag.id) } else { tagFilter.remove(tag.id) } })) {
                            Text("\(tag.name) (\(tag.fileCount ?? 0))")
                        }
                    }
                }
            }
            if session.isAuthEnabled && !owners.isEmpty {
                Picker("Uploaded By", selection: $ownerFilter) {
                    Text("Anyone").tag(String?.none)
                    ForEach(owners, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
            }
            if filtersActive {
                Button("Clear Filters", systemImage: "xmark") { typeFilter = nil; ownerFilter = nil; tagFilter = [] }
            }
        } label: {
            Label("Filter", systemImage: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var moreMenu: some View {
        Menu {
            if !(files.value ?? []).isEmpty {
                Button("Select", systemImage: "checkmark.circle") { withAnimation { editMode = .active } }
            }
            Section {
                Picker("View", selection: $gridView) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Grid", systemImage: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.inline)
            }
            Section {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(LibrarySortField.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.menu)
                Picker("Order", selection: $ascending) {
                    Text("Ascending").tag(true)
                    Text("Descending").tag(false)
                }
                .pickerStyle(.menu)
                Toggle("Show Modified Dates", systemImage: "calendar", isOn: $showModified)
                Toggle("Folders by Recent Activity", systemImage: "clock", isOn: $foldersByActivity)
            }
            Section {
                Button("Manage Tags…", systemImage: "tag") { showTagManager = true }
                Button("Generate Missing Thumbnails", systemImage: "photo.on.rectangle") { Task { await generateThumbnails(folderId: nil) } }
                    .disabled(!LibraryAccess.canUpdateAny(session))
                if session.can("library:purge") {
                    Button("Purge Old Files…", systemImage: "clock.arrow.circlepath") { showPurge = true }
                }
                if LibraryAccess.canDeleteAny(session) {
                    Button(trashCount.map { $0 > 0 ? "Trash (\($0))" : "Trash" } ?? "Trash", systemImage: "trash") { showTrash = true }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private var breadcrumbMenu: some View {
        if case .folder(let id) = scope {
            let chain = LibraryFolderTree.path(to: id, in: folderTree)
            ForEach(chain.dropLast().reversed()) { ancestor in
                Button { go(to: ancestor.id, chain: chain) } label: { Label(ancestor.name, systemImage: "folder") }
            }
            Button { go(to: nil, chain: chain) } label: { Label("Files", systemImage: "tray.full") }
        }
    }

    /// Jumps to an ancestor folder (or the top level) like the Files app's title menu.
    private func go(to folderId: Int?, chain: [LibraryFolderNode]) {
        guard let navigator else { return }
        var newChain: [LibraryRoute] = []
        if let folderId, let index = chain.firstIndex(where: { $0.id == folderId }) {
            newChain = chain[...index].map { .browse(.folder($0.id)) }
        }
        // Keep whatever led into the library (e.g. a detail screen) out of the rebuilt path.
        navigator.path = newChain
    }

    // MARK: Folder sheets

    @ViewBuilder
    private func folderSheetContent(_ sheet: LibraryFolderSheet) -> some View {
        switch sheet {
        case .create(let parent):
            LibraryNameSheet(title: "New Folder", actionTitle: "Create", initial: "") { name in
                let _: LibraryFolderInfo = try await session.client.send(.post, "library/folders", body: LibraryFolderCreateBody(name: name, parentId: parent))
                await reload()
            }
        case .rename(let folder):
            LibraryNameSheet(title: "Rename Folder", actionTitle: "Rename", initial: folder.name) { name in
                let _: LibraryFolderInfo = try await session.client.send(.put, "library/folders/\(folder.id)", body: LibraryFolderUpdateBody(name: name))
                await reload()
            }
        case .link(let folder):
            LibraryFolderLinkSheet(folder: folder) { Task { await reload() } }
        case .move(let folder):
            LibraryFolderPickerSheet(title: "Move “\(folder.name)”", current: folder.parentId,
                                     excluded: LibraryFolderTree.descendantIds(of: folder.id, in: folderTree)) { target in
                let _: LibraryFolderInfo = try await session.client.send(.put, "library/folders/\(folder.id)", body: LibraryFolderUpdateBody(parentId: target ?? 0))
                await reload()
            }
        case .external(let parent):
            LibraryExternalFolderSheet(parentId: parent) { folder in
                runner.successMessage = "Linked “\(folder.name)”"
                Task { await reload() }
            }
        }
    }

    // MARK: Networking

    private func reload() async {
        let client = session.client
        let query = fileQuery
        async let treeLoad: Void = folders.load { try await LibraryAPI.folders(client) }
        async let filesLoad: Void = files.load { try await client.get("library/files", query: query) }
        _ = await (treeLoad, filesLoad)
        if settings == nil { settings = await LibraryAPI.settings(client) }
        if tagCatalog.isEmpty { await loadTags() }
        if scope == .root {
            stats = try? await client.get("library/stats")
            if LibraryAccess.canDeleteAny(session) {
                trashCount = (try? await client.get("library/trash", query: ["limit": 1, "offset": 0], as: LibraryTrashPage.self))?.total
            }
        }
        if let id = currentFolderId, readme == nil {
            readme = try? await client.get("library/folders/\(id)/readme")
        }
        // Drop selections that no longer exist.
        let ids = Set((files.value ?? []).map(\.id))
        selection.formIntersection(ids)
    }

    private func loadTags() async {
        tagCatalog = (try? await LibraryAPI.tags(session.client)) ?? tagCatalog
        let valid = Set(tagCatalog.map(\.id))
        if !tagCatalog.isEmpty { tagFilter.formIntersection(valid) }
    }

    private func scan(_ folder: LibraryFolderNode) async {
        await runner.run {
            let result: LibraryScanResult = try await session.client.send(.post, "library/folders/\(folder.id)/scan")
            runner.successMessage = "Scan complete: \(result.added ?? 0) added, \(result.removed ?? 0) removed"
            await reload()
        }
    }

    private func deleteFolder(_ folder: LibraryFolderNode) async {
        await runner.run("Folder deleted") {
            try await session.client.call(.delete, "library/folders/\(folder.id)")
            await reload()
        }
    }

    private func generateThumbnails(folderId: Int?) async {
        await runner.run {
            let body = folderId.map { LibraryThumbnailBatchBody(folderId: $0) } ?? LibraryThumbnailBatchBody(allMissing: true)
            let result: LibraryThumbnailBatchResult = try await session.client.send(.post, "library/generate-stl-thumbnails", body: body)
            let processed = result.processed ?? 0
            if processed == 0 {
                runner.successMessage = "No STL files need thumbnails"
            } else {
                runner.successMessage = "Generated \(result.succeeded ?? 0) of \(processed) thumbnails"
            }
            for entry in result.results ?? [] where entry.success == true {
                if let id = entry.fileId { actions.thumbnailVersions[id, default: 0] += 1 }
            }
            await reload()
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Row & card views

/// Content of a file row in list mode.
private struct LibraryFileRowContent: View {
    let file: LibraryFileSummary
    let showModified: Bool
    let showOwner: Bool
    let thumbnailVersion: Int
    let onTag: (LibraryTagRef) -> Void

    var body: some View {
        HStack(spacing: 12) {
            LibraryFileThumbnail(fileId: file.id, hasThumbnail: file.thumbnailPath != nil, type: file.type, version: thumbnailVersion)
                .frame(width: 56, height: 56)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName).lineLimit(2)
                if file.displayName != file.filename {
                    Text(file.filename).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    LibraryTypeBadge(type: file.type)
                    Text(Fmt.bytes(file.fileSize))
                    if let t = file.printTimeSeconds, t > 0 { Label(Fmt.duration(seconds: t), systemImage: "clock") }
                    if let g = file.filamentUsedGrams, g > 0 { Label(Fmt.grams(g), systemImage: "scalemass") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let extras = extraLine
                if !extras.isEmpty {
                    Text(extras).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let tags = file.tags, !tags.isEmpty {
                    LibraryTagChips(tags: tags, onTap: onTag)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var extraLine: String {
        var parts: [String] = []
        if let model = file.slicedForModel, !model.isEmpty { parts.append(model) }
        if let n = file.printCount, n > 0 { parts.append("Printed \(n)×") }
        if let v = file.variantCount, v > 1 { parts.append("\(v) versions") }
        if showOwner, let owner = file.createdByUsername { parts.append(owner) }
        if showModified { parts.append(Fmt.date(file.modifiedAt, style: .dateTime.month(.abbreviated).day().year())) }
        return parts.joined(separator: " · ")
    }
}

/// A file tile in grid mode.
private struct LibraryFileCard: View {
    let file: LibraryFileSummary
    /// `nil` when not selecting.
    let selected: Bool?
    let showModified: Bool
    let showOwner: Bool
    let thumbnailVersion: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LibraryFileThumbnail(fileId: file.id, hasThumbnail: file.thumbnailPath != nil, type: file.type, version: thumbnailVersion)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topTrailing) { LibraryTypeBadge(type: file.type).padding(6) }
                .overlay(alignment: .topLeading) {
                    if let selected {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.3))
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(Fmt.bytes(file.fileSize))
                    if let t = file.printTimeSeconds, t > 0 { Label(Fmt.duration(seconds: t), systemImage: "clock") }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let model = file.slicedForModel, !model.isEmpty {
                    Label(model, systemImage: "printer").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let v = file.variantCount, v > 1 {
                    Label("\(v) versions", systemImage: "square.stack.3d.up").font(.caption).foregroundStyle(.tint)
                }
                if let n = file.printCount, n > 0 {
                    Text("Printed \(n)×").font(.caption).foregroundStyle(.green)
                }
                if showOwner, let owner = file.createdByUsername {
                    Label(owner, systemImage: "person").font(.caption).foregroundStyle(.secondary)
                }
                if showModified {
                    Label(Fmt.date(file.modifiedAt, style: .dateTime.month(.abbreviated).day().year()), systemImage: "calendar")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let tags = file.tags, !tags.isEmpty { LibraryTagChips(tags: tags) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected == true ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected == true ? 2 : 1)
        }
        .contentShape(.rect(cornerRadius: 12))
    }
}

private struct LibraryFolderTile: View {
    let folder: LibraryFolderNode
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: folder.external ? "externaldrive.connected.to.line.below.fill" : "folder.fill")
                .font(.title2)
                .foregroundStyle(folder.external ? .purple : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.subheadline.weight(.medium)).lineLimit(1)
                Text("\(folder.fileCount ?? 0) files").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if folder.readOnly { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.background, in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
    }
}

/// Files / folders / size / free-space summary for the library.
struct LibraryStatsStrip: View {
    let stats: LibraryStats
    let lowDisk: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                stat("Files", "\(stats.totalFiles ?? 0)", "doc", .green)
                stat("Folders", "\(stats.totalFolders ?? 0)", "folder", .blue)
                stat("Size", Fmt.bytes(stats.totalSizeBytes), "internaldrive", .orange)
                stat("Free", Fmt.bytes(stats.diskFreeBytes), "externaldrive", lowDisk ? .red : .secondary)
            }
            if lowDisk {
                Label("Low disk space on the server: \(Fmt.bytes(stats.diskFreeBytes)) free of \(Fmt.bytes(stats.diskTotalBytes)).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
