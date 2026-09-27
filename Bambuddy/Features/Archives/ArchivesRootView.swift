import SwiftUI

/// Navigation value for an archive's detail screen.
struct ArchivesDetailRoute: Hashable {
    let id: Int
}

enum ArchivesViewMode: String, CaseIterable, Identifiable {
    case grid, list, calendar, log
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: "Grid"
        case .list: "List"
        case .calendar: "Calendar"
        case .log: "Print Log"
        }
    }
    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        case .calendar: "calendar"
        case .log: "list.clipboard"
        }
    }
}

struct ArchivesRootView: View {
    @State private var path = NavigationPath()
    @State private var lookups = ArchivesLookups()

    var body: some View {
        NavigationStack(path: $path) {
            ArchivesBrowserView()
                .navigationDestination(for: ArchivesDetailRoute.self) { route in
                    ArchivesDetailView(archiveId: route.id)
                }
        }
        .environment(lookups)
        #if DEBUG
        .onAppear {
            // Launch argument `-openArchive <id>` opens an archive's detail screen (for screenshots).
            let id = UserDefaults.standard.integer(forKey: "openArchive")
            if id > 0, path.isEmpty { path.append(ArchivesDetailRoute(id: id)) }
        }
        #endif
    }
}

/// The archive browser: grid/list/calendar views with filters, search,
/// selection and bulk actions, plus the print log.
struct ArchivesBrowserView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(PrinterStore.self) private var printers
    @Environment(ArchivesLookups.self) private var lookups
    @AppStorage("archivesViewMode") private var viewMode: ArchivesViewMode = .grid
    @AppStorage("archivesNo3mfDismissed") private var no3mfDismissed = false

    @State private var model = ArchivesBrowserModel()
    @State private var actions = ArchivesActions()
    @State private var search = ""
    @State private var displayLimit = 60

    @State private var selecting = false
    @State private var selection = Set<Int>()
    @State private var bulkRunner = ActionRunner()
    @State private var showBulkDelete = false
    @State private var showBatchTags = false
    @State private var showBatchProject = false
    @State private var showCompare = false

    @State private var showFilters = false
    @State private var showTagManager = false
    @State private var showPurge = false
    @State private var showUpload = false
    @State private var exportRunner = ActionRunner()
    @State private var exportFile: ArchivesSharedFile?

    private let gridColumns = [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 16)]

    var body: some View {
        let visible = model.visible(search: search)
        content(visible)
            .navigationTitle(viewMode == .log ? "Print Log" : "Archives")
            .searchable(text: $search, prompt: viewMode == .log ? "Search print log" : "Search archives")
            .toolbar { toolbar(visible) }
            .safeAreaInset(edge: .bottom) {
                if selecting && viewMode != .log { selectionBar(visible) }
            }
            .task(id: live.revision("archive_created", "archive_updated", "print_complete")) {
                await model.load(client: session.client)
            }
            .task { await lookups.refresh(client: session.client) }
            .onChange(of: search) { displayLimit = 60 }
            .onChange(of: model.filters) { displayLimit = 60 }
            .onChange(of: viewMode) { if viewMode == .log { endSelection() } }
            .onAppear {
                actions.onUpdated = { updated in
                    if let updated { model.replace(updated) }
                    Task {
                        await model.load(client: session.client)
                        await lookups.refreshTags(client: session.client)
                    }
                }
                actions.onDeleted = { ids in
                    model.remove(ids)
                    selection.subtract(ids)
                }
            }
            .archivesActionPresenters(actions)
            .actionAlerts(bulkRunner)
            .actionAlerts(exportRunner)
            .sheet(isPresented: $showFilters) {
                ArchivesFilterSheet(model: model)
            }
            .sheet(isPresented: $showTagManager, onDismiss: reload) { ArchivesTagManagerSheet() }
            .sheet(isPresented: $showPurge, onDismiss: reload) { ArchivesPurgeSheet() }
            .sheet(isPresented: $showUpload, onDismiss: reload) { ArchivesUploadSheet() }
            .sheet(isPresented: $showBatchTags, onDismiss: reload) {
                ArchivesBatchTagSheet(archiveIds: Array(selection), knownTags: model.tags)
            }
            .sheet(isPresented: $showBatchProject, onDismiss: reload) {
                ArchivesBatchProjectSheet(archiveIds: Array(selection))
            }
            .sheet(isPresented: $showCompare) {
                ArchivesCompareSheet(archiveIds: orderedSelection(visible))
            }
            .sheet(item: $exportFile) { file in
                ArchivesShareSheet(file: file).presentationDetents([.medium])
            }
            .confirmationDialog("Delete \(selection.count) archive\(selection.count == 1 ? "" : "s")?", isPresented: $showBulkDelete, titleVisibility: .visible) {
                Button("Delete \(selection.count)", role: .destructive) { Task { await bulkDelete() } }
            } message: {
                Text("Their files are removed from the server. This cannot be undone.")
            }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ visible: [ArchivesRecord]) -> some View {
        if viewMode == .log {
            ArchivesPrintLogView(search: search)
        } else if !model.hasLoaded && model.archives.isEmpty {
            if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn't Load Archives", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { reload() }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if visible.isEmpty {
            ScrollView {
                header(visible)
                emptyState
            }
            .refreshable { await model.load(client: session.client) }
        } else {
            switch viewMode {
            case .grid: grid(visible)
            case .list: list(visible)
            case .calendar: calendar(visible)
            case .log: EmptyView()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(model.archives.isEmpty ? "No Archives Yet" : "No Matching Archives", systemImage: "archivebox")
        } description: {
            Text(model.archives.isEmpty
                 ? "Archives are created automatically when prints finish, or upload a 3MF file."
                 : "Try a different search or clear some filters.")
        } actions: {
            if !model.archives.isEmpty && (model.filters.activeCount > 0 || model.filters.collection != .all) {
                Button("Clear Filters") {
                    model.filters.resetRefinements()
                    model.filters.collection = .all
                }
                .buttonStyle(.bordered)
            } else if model.archives.isEmpty && session.can("archives:create") {
                Button("Upload 3MF") { showUpload = true }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 40)
    }

    private func grid(_ visible: [ArchivesRecord]) -> some View {
        ScrollView {
            header(visible)
            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(visible.prefix(displayLimit)) { archive in
                    item(archive) {
                        ArchivesCard(archive: archive, actions: actions, selecting: selecting, isSelected: selection.contains(archive.id))
                    }
                    .onAppear { loadMoreIfNeeded(archive, visible) }
                }
            }
            .padding(.horizontal)
            footer(visible)
        }
        .refreshable { await model.load(client: session.client) }
    }

    private func list(_ visible: [ArchivesRecord]) -> some View {
        List {
            Section {
                ForEach(visible.prefix(displayLimit)) { archive in
                    item(archive) {
                        ArchivesRow(archive: archive, selecting: selecting, isSelected: selection.contains(archive.id))
                    }
                    .onAppear { loadMoreIfNeeded(archive, visible) }
                    .swipeActions(edge: .trailing) {
                        if ArchivesPermissions.canDelete(session, archive) {
                            Button(role: .destructive) { actions.deleting = archive } label: { Label("Delete", systemImage: "trash") }
                        }
                        if ArchivesPermissions.canUpdate(session, archive) {
                            Button { actions.editing = archive } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if ArchivesPermissions.canUpdate(session, archive) {
                            Button { Task { await actions.toggleFavorite(archive, client: session.client) } } label: {
                                Label(archive.favorite ? "Unfavorite" : "Favorite", systemImage: archive.favorite ? "star.slash" : "star")
                            }
                            .tint(.yellow)
                        }
                        if archive.isSliced && ArchivesPermissions.canReprint(session, archive) {
                            Button { actions.print(archive, mode: .printNow) } label: { Label("Print", systemImage: "printer") }.tint(.green)
                        }
                    }
                }
            } header: {
                header(visible).textCase(nil).listRowInsets(EdgeInsets())
            } footer: {
                footer(visible)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.load(client: session.client) }
    }

    private func calendar(_ visible: [ArchivesRecord]) -> some View {
        ScrollView {
            header(visible)
            ArchivesCalendarView(archives: visible)
                .padding(.horizontal)
        }
        .refreshable { await model.load(client: session.client) }
    }

    /// Wraps a card/row with navigation or selection behaviour and the context menu.
    @ViewBuilder
    private func item<Label: View>(_ archive: ArchivesRecord, @ViewBuilder label: () -> Label) -> some View {
        if selecting {
            Button { toggle(archive.id) } label: { label() }
                .buttonStyle(.plain)
                .contextMenu { ArchivesActionMenu(archive: archive, actions: actions, onSelect: { toggle(archive.id) }, isSelected: selection.contains(archive.id)) }
        } else {
            NavigationLink(value: ArchivesDetailRoute(id: archive.id)) { label() }
                .buttonStyle(.plain)
                .contextMenu {
                    ArchivesActionMenu(archive: archive, actions: actions, onSelect: {
                        selecting = true
                        toggle(archive.id)
                    })
                } preview: {
                    ArchivesCard(archive: archive, actions: actions)
                        .frame(width: 320)
                        .environment(session)
                        .environment(printers)
                        .environment(lookups)
                }
        }
    }

    // MARK: Header / footer

    @ViewBuilder
    private func header(_ visible: [ArchivesRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let warning = model.no3mfWarning, warning.hasFallback == true, !no3mfDismissed {
                no3mfBanner(warning)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Collection", selection: $model.filters.collection) {
                            ForEach(ArchivesCollection.allCases) { c in Label(c.title, systemImage: c.systemImage).tag(c) }
                        }
                    } label: {
                        chip(model.filters.collection.title, systemImage: model.filters.collection.systemImage, active: model.filters.collection != .all)
                    }
                    Button { model.filters.favoritesOnly.toggle() } label: {
                        chip("Favorites", systemImage: model.filters.favoritesOnly ? "star.fill" : "star", active: model.filters.favoritesOnly)
                    }
                    Button { model.filters.hideFailed.toggle() } label: {
                        chip("Hide Failed", systemImage: "exclamationmark.triangle", active: model.filters.hideFailed)
                    }
                    Button { model.filters.hideDuplicates.toggle() } label: {
                        chip("Hide Duplicates", systemImage: "square.on.square", active: model.filters.hideDuplicates)
                    }
                    Button { showFilters = true } label: {
                        chip(model.filters.activeCount > 0 ? "Filters (\(model.filters.activeCount))" : "Filters", systemImage: "line.3.horizontal.decrease.circle", active: model.filters.activeCount > 0)
                    }
                    if model.filters.activeCount > 0 {
                        Button { model.filters.resetRefinements() } label: { chip("Reset", systemImage: "xmark", active: false) }
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
            summary(visible)
                .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func summary(_ visible: [ArchivesRecord]) -> some View {
        let grams = visible.compactMap(\.filamentUsedGrams).reduce(0, +)
        let seconds = visible.compactMap { $0.actualTimeSeconds ?? $0.printTimeSeconds }.reduce(0, +)
        let cost = visible.compactMap(\.cost).reduce(0, +)
        return HStack(spacing: 12) {
            Text("\(visible.count) of \(model.archives.count) prints").fontWeight(.medium)
            if seconds > 0 { Label(Fmt.duration(seconds: Double(seconds)), systemImage: "clock") }
            if grams > 0 { Label(Fmt.grams(grams), systemImage: "scalemass") }
            if cost > 0 { Label(lookups.money(cost), systemImage: "dollarsign.circle") }
            if model.isLoadingMore || (model.isLoading && model.hasLoaded) { ProgressView().controlSize(.mini) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }

    private func chip(_ title: String, systemImage: String, active: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(active ? AnyShapeStyle(Color.accentColor.opacity(0.2)) : AnyShapeStyle(.quaternary), in: .capsule)
            .foregroundStyle(active ? Color.accentColor : .primary)
    }

    private func no3mfBanner(_ warning: ArchivesNo3mfWarning) -> some View {
        let (title, body): (String, String) = switch warning.reason {
        case "internal_storage":
            ("Some prints were archived without their 3MF", "The printer stores sent files on internal storage, which Bambuddy can't read back. Archives from those prints have only a name.")
        case "no_external_storage":
            ("Some prints were archived without their 3MF", "The printer has no SD card / USB storage inserted, so the print file couldn't be fetched. Insert storage to archive full files.")
        case "internal_history":
            ("Some prints were started from the printer itself", "Prints started from files already on the printer can't always be matched to a 3MF, so their archives have no thumbnail or settings.")
        default:
            ("Some prints were archived without their 3MF", "Enable “Store sent files on external storage” in your slicer so Bambuddy can archive the full print file.")
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { no3mfDismissed = true } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 12))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func footer(_ visible: [ArchivesRecord]) -> some View {
        if visible.count > displayLimit || model.isLoadingMore {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding()
            .onAppear { if visible.count > displayLimit { displayLimit += 60 } }
        } else if visible.count > 12 {
            Text("\(visible.count) archives")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    private func loadMoreIfNeeded(_ archive: ArchivesRecord, _ visible: [ArchivesRecord]) {
        guard visible.count > displayLimit else { return }
        let index = visible.prefix(displayLimit).firstIndex { $0.id == archive.id } ?? 0
        if index >= displayLimit - 8 { displayLimit += 60 }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ visible: [ArchivesRecord]) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("View", selection: $viewMode) {
                    ForEach(ArchivesViewMode.allCases) { mode in Label(mode.title, systemImage: mode.systemImage).tag(mode) }
                }
            } label: {
                Label("View", systemImage: viewMode.systemImage)
            }
        }
        if viewMode != .log {
            if selecting {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { endSelection() }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort", selection: $model.filters.sort) {
                            ForEach(ArchivesSort.allCases) { s in Text(s.title).tag(s) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { selecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                        if session.can("archives:create") {
                            Button { showUpload = true } label: { Label("Upload 3MF", systemImage: "square.and.arrow.up") }
                        }
                        Menu {
                            Button("CSV") { Task { await export("csv") } }
                            Button("Excel") { Task { await export("xlsx") } }
                        } label: {
                            Label("Export", systemImage: "tablecells")
                        }
                        Button { showTagManager = true } label: { Label("Manage Tags", systemImage: "tag") }
                        if session.can("archives:purge") {
                            Button(role: .destructive) { showPurge = true } label: { Label("Purge Old Archives", systemImage: "clock.badge.xmark") }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: Selection

    private func selectionBar(_ visible: [ArchivesRecord]) -> some View {
        let canUpdate = ArchivesPermissions.canUpdateAny(session)
        let count = selection.count
        return VStack(spacing: 8) {
            HStack {
                Text("\(count) selected").font(.subheadline.weight(.semibold))
                Spacer()
                Button(count == visible.count && count > 0 ? "Deselect All" : "Select All") {
                    if count == visible.count { selection.removeAll() } else { selection = Set(visible.map(\.id)) }
                }
            }
            HStack(spacing: 18) {
                barButton("Compare", "square.split.2x1", disabled: !(2...5).contains(count)) { showCompare = true }
                barButton("Tags", "tag", disabled: count == 0 || !canUpdate) { showBatchTags = true }
                barButton("Project", "folder.badge.plus", disabled: count == 0 || !canUpdate) { showBatchProject = true }
                barButton("Favorite", "star", disabled: count == 0 || !canUpdate) { Task { await bulkFavorite() } }
                barButton("Delete", "trash", role: .destructive, disabled: count == 0 || !ArchivesPermissions.canDeleteAny(session)) { showBulkDelete = true }
            }
            .overlay { if bulkRunner.isRunning { ProgressView() } }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private func barButton(_ title: String, _ image: String, role: ButtonRole? = nil, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            VStack(spacing: 3) {
                Image(systemName: image).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(disabled || bulkRunner.isRunning)
        .tint(role == .destructive ? .red : nil)
    }

    private func toggle(_ id: Int) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelection() {
        selecting = false
        selection.removeAll()
    }

    private func orderedSelection(_ visible: [ArchivesRecord]) -> [Int] {
        visible.map(\.id).filter(selection.contains)
    }

    private func reload() {
        Task {
            await model.load(client: session.client)
            await lookups.refreshTags(client: session.client)
        }
    }

    private func bulkFavorite() async {
        let ids = Array(selection)
        await bulkRunner.run("Toggled favorites for \(ids.count) archive\(ids.count == 1 ? "" : "s")") {
            for id in ids {
                let _: ArchivesRecord = try await session.client.send(.post, "archives/\(id)/favorite")
            }
        }
        await model.load(client: session.client)
    }

    private func bulkDelete() async {
        let ids = selection
        var deleted = Set<Int>()
        await bulkRunner.run {
            for id in ids {
                try await session.client.call(.delete, "archives/\(id)")
                deleted.insert(id)
            }
        }
        if !deleted.isEmpty {
            model.remove(deleted)
            selection.subtract(deleted)
            bulkRunner.successMessage = "\(deleted.count) archive\(deleted.count == 1 ? "" : "s") deleted"
        }
        if selection.isEmpty { selecting = false }
    }

    private func export(_ format: String) async {
        let f = model.filters
        await exportRunner.run {
            let url = try await session.client.download("archives/export", query: [
                "format": .string(format),
                "printer_id": .of(f.printerId),
                "status": f.collection == .failed ? "failed" : nil,
                "search": search.isEmpty ? nil : .string(search),
            ], suggestedName: "archives_export.\(format)")
            exportFile = ArchivesSharedFile(url: url)
        }
    }
}
