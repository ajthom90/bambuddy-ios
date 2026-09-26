import SwiftUI
import UniformTypeIdentifiers

/// Navigation targets inside the Projects section.
enum ProjectsRoute: Hashable {
    case project(Int)
    case templates
}

struct ProjectsRootView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live

    @State private var path = NavigationPath()
    @State private var loader = Loader<[ProjectListEntry]>()
    @State private var templateIds: Set<Int> = []
    @State private var runner = ActionRunner()
    @State private var currency = "USD"

    @AppStorage("projects.statusFilter") private var statusFilter = "active"
    @AppStorage("projects.sort") private var sortOrder = ProjectSortOrder.updated.rawValue
    @State private var search = ""

    @State private var editor: ProjectEditorTarget?
    @State private var pendingDelete: ProjectListEntry?
    @State private var showImporter = false
    @State private var exportFile: ProjectsSharedFile?

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 480), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            LoadingContent(loader: loader, retry: load) { all in
                content(all)
            }
            .navigationTitle("Projects")
            .searchable(text: $search, prompt: "Search projects")
            .refreshable { await load() }
            .toolbar { toolbar }
            .navigationDestination(for: ProjectsRoute.self) { route in
                switch route {
                case .project(let id): ProjectDetailView(projectId: id)
                case .templates: ProjectTemplatesView()
                }
            }
            .task(id: live.revision("archive_created", "archive_updated", "print_complete", "print_start")) { await load() }
            .task { await loadCurrency() }
            .sheet(item: $editor) { target in
                ProjectEditorSheet(target: target, allProjects: loader.value ?? [], currency: currency) { saved in
                    Task {
                        await load()
                        if case .create = target, let saved { path.append(ProjectsRoute.project(saved.id)) }
                    }
                }
            }
            .sheet(item: $exportFile) { file in
                ProjectsActivitySheet(items: [file.url])
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .zip], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { Task { await importFile(url) } }
            }
            .confirm("Delete Project?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                     message: "Prints and queue items stay in Bambuddy but are unlinked from “\(pendingDelete?.name ?? "")”. Sub-projects move up one level.") {
                if let p = pendingDelete { Task { await delete(p) } }
            }
            .actionAlerts(runner)
            #if DEBUG
            .onAppear {
                let id = UserDefaults.standard.integer(forKey: "openProject")
                if id > 0, path.isEmpty { path.append(ProjectsRoute.project(id)) }
                if UserDefaults.standard.bool(forKey: "openProjectEditor"), editor == nil { editor = .create }
            }
            #endif
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ all: [ProjectListEntry]) -> some View {
        let projects = all.filter { !templateIds.contains($0.id) }
        let names = Dictionary(all.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let shown = visible(projects)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Status", selection: $statusFilter) {
                    ForEach(ProjectStatusFilter.allCases) { f in
                        Text(label(for: f, in: projects)).tag(f.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                if shown.isEmpty {
                    emptyState(hasAny: !projects.isEmpty)
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(shown) { project in
                            NavigationLink(value: ProjectsRoute.project(project.id)) {
                                ProjectCardView(project: project, parentName: project.parentId.flatMap { names[$0] })
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: project) }
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func label(for filter: ProjectStatusFilter, in projects: [ProjectListEntry]) -> String {
        let count = filter == .all ? projects.count : projects.filter { $0.status == filter.rawValue }.count
        return count > 0 ? "\(filter.title) (\(count))" : filter.title
    }

    private func visible(_ projects: [ProjectListEntry]) -> [ProjectListEntry] {
        var list = projects
        if statusFilter != ProjectStatusFilter.all.rawValue { list = list.filter { $0.status == statusFilter } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || ($0.description ?? "").localizedCaseInsensitiveContains(q)
                    || ($0.tags ?? "").localizedCaseInsensitiveContains(q)
            }
        }
        switch ProjectSortOrder(rawValue: sortOrder) ?? .updated {
        case .updated: break // server order: most recently updated first
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .created: list.sort { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        case .dueDate:
            list.sort { a, b in
                switch (ProjectDates.calendarDate(a.dueDate), ProjectDates.calendarDate(b.dueDate)) {
                case let (x?, y?): x < y
                case (_?, nil): true
                default: false
                }
            }
        case .priority:
            let rank = ["urgent": 0, "high": 1, "normal": 2, "low": 3]
            list.sort { (rank[$0.priority ?? "normal"] ?? 2) < (rank[$1.priority ?? "normal"] ?? 2) }
        case .progress: list.sort { ProjectCardView.progress($0) > ProjectCardView.progress($1) }
        }
        return list
    }

    @ViewBuilder
    private func emptyState(hasAny: Bool) -> some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if hasAny {
            ContentUnavailableView("No \(ProjectStatusFilter(rawValue: statusFilter)?.title ?? "") Projects", systemImage: "folder",
                                   description: Text("Projects with this status will appear here."))
        } else {
            ContentUnavailableView {
                Label("No Projects", systemImage: "folder.badge.gearshape")
            } description: {
                Text("Group related prints, files and parts into a project to track progress and cost.")
            } actions: {
                if session.can("projects:create") {
                    Button("New Project") { editor = .create }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for project: ProjectListEntry) -> some View {
        if session.can("projects:update") {
            Button { editor = .edit(ProjectEditForm(entry: project), id: project.id, coverFilename: project.coverImageFilename) } label: {
                Label("Edit", systemImage: "pencil")
            }
            if project.status != "completed" {
                Button { Task { await setStatus(project, "completed") } } label: { Label("Mark Completed", systemImage: "checkmark.circle") }
            }
            if project.status != "archived" {
                Button { Task { await setStatus(project, "archived") } } label: { Label("Archive", systemImage: "archivebox") }
            }
            if project.status != "active" {
                Button { Task { await setStatus(project, "active") } } label: { Label("Mark Active", systemImage: "arrow.uturn.backward.circle") }
            }
        }
        if let urlString = project.url, let url = URL(string: urlString) {
            Link(destination: url) { Label("Open Link", systemImage: "safari") }
        }
        if session.can("projects:delete") {
            Divider()
            Button(role: .destructive) { pendingDelete = project } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if session.can("projects:create") {
                Button { editor = .create } label: { Label("New Project", systemImage: "plus") }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Picker("Sort By", selection: $sortOrder) {
                    ForEach(ProjectSortOrder.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Divider()
                Button { path.append(ProjectsRoute.templates) } label: {
                    Label(templateIds.isEmpty ? "Templates" : "Templates (\(templateIds.count))", systemImage: "doc.on.doc")
                }
                if session.can("projects:create") {
                    Button { showImporter = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                }
                Button { Task { await exportAll() } } label: { Label("Export All as JSON", systemImage: "square.and.arrow.up") }
                    .disabled((loader.value ?? []).isEmpty)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Actions

    private func load() async {
        let client = session.client
        await loader.load {
            async let projects: [ProjectListEntry] = client.get("projects/")
            async let templates: [ProjectListEntry]? = try? client.get("projects/templates")
            let (p, t) = try await (projects, templates)
            templateIds = Set((t ?? []).map(\.id))
            return p
        }
    }

    private func loadCurrency() async {
        if let code = (try? await session.client.get("settings/", as: JSONValue.self))?["currency"]?.stringValue, !code.isEmpty {
            currency = code
        }
    }

    private func setStatus(_ project: ProjectListEntry, _ status: String) async {
        await runner.run("Project updated") {
            try await session.client.call(.patch, "projects/\(project.id)", body: ["status": JSONValue.string(status)])
        }
        await load()
    }

    private func delete(_ project: ProjectListEntry) async {
        await runner.run("Project deleted") {
            try await session.client.call(.delete, "projects/\(project.id)")
        }
        await load()
    }

    private func importFile(_ url: URL) async {
        let client = session.client
        await runner.run(nil) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "zip" {
                let _: ProjectDetail = try await client.upload("projects/import/file", files: [
                    UploadFile(fileName: url.lastPathComponent, mimeType: "application/zip", data: data),
                ])
                runner.successMessage = "Project imported"
            } else {
                let json = try JSONDecoder().decode(JSONValue.self, from: data)
                let items = json.arrayValue ?? [json]
                for item in items {
                    let _: ProjectDetail = try await client.send(.post, "projects/import", body: item)
                }
                runner.successMessage = items.count == 1 ? "Project imported" : "\(items.count) projects imported"
            }
        }
        await load()
    }

    private func exportAll() async {
        let client = session.client
        let ids = (loader.value ?? []).map(\.id)
        await runner.run(nil) {
            var exports: [JSONValue] = []
            for id in ids {
                exports.append(try await client.get("projects/\(id)/export", query: ["format": "json"], as: JSONValue.self))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(JSONValue.array(exports))
            let day = Date().formatted(.iso8601.year().month().day())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("bambuddy_projects_\(day).json")
            try data.write(to: url, options: .atomic)
            exportFile = ProjectsSharedFile(url: url)
        }
    }
}

// MARK: - Filters

enum ProjectStatusFilter: String, CaseIterable, Identifiable {
    case active, completed, archived, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .active: "Active"
        case .completed: "Completed"
        case .archived: "Archived"
        case .all: "All"
        }
    }
}

enum ProjectSortOrder: String, CaseIterable, Identifiable {
    case updated, name, created, dueDate, priority, progress
    var id: String { rawValue }
    var title: String {
        switch self {
        case .updated: "Recently Updated"
        case .name: "Name"
        case .created: "Newest"
        case .dueDate: "Due Date"
        case .priority: "Priority"
        case .progress: "Progress"
        }
    }
}

// MARK: - Card

struct ProjectCardView: View {
    let project: ProjectListEntry
    var parentName: String?

    static func progress(_ p: ProjectListEntry) -> Double {
        if let t = p.targetPartsCount, t > 0 { return Double(p.completedCount ?? 0) / Double(t) }
        if let t = p.targetCount, t > 0 { return Double(p.archiveCount ?? 0) / Double(t) }
        return -1
    }

    private var tint: Color { ProjectPalette.color(project.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                leadingImage
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(project.name).font(.headline).lineLimit(1)
                        if project.url != nil {
                            Image(systemName: "link").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let parentName {
                        Label("Part of \(parentName)", systemImage: "square.stack.3d.up")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let d = project.description, !d.isEmpty {
                        Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    badges
                }
                Spacer(minLength: 0)
            }

            progressSection
            materials

            if let archives = project.archives, !archives.isEmpty {
                HStack(spacing: 6) {
                    ForEach(archives.prefix(4)) { a in
                        RemoteImage(path: a.thumbnailPath != nil ? "archives/\(a.id)/thumbnail" : nil, systemImage: "cube")
                            .aspectRatio(1, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay(alignment: .topTrailing) {
                                if a.status == "failed" {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                                        .foregroundStyle(.white).padding(3).background(.red, in: .circle).padding(3)
                                }
                            }
                    }
                    ForEach(0..<max(0, 4 - archives.count), id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                }
                if (project.archiveCount ?? 0) > 4 {
                    Text("+\((project.archiveCount ?? 0) - 4) more").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            footer
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .overlay(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 18, topTrailingRadius: 18).fill(tint).frame(height: 4)
        }
        .contentShape(.rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var leadingImage: some View {
        if project.coverImageFilename != nil {
            RemoteImage(path: "projects/\(project.id)/cover-image", reloadKey: project.coverImageFilename, systemImage: "photo")
                .frame(width: 52, height: 52)
                .clipShape(.rect(cornerRadius: 10))
        } else {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundStyle(project.status == "completed" ? .green : tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.15), in: .rect(cornerRadius: 10))
        }
    }

    private var statusIcon: String {
        switch project.status {
        case "completed": "checkmark.circle.fill"
        case "archived": "archivebox"
        default: (project.queueCount ?? 0) > 0 ? "clock" : "folder"
        }
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if let t = project.targetPartsCount, t > 0 {
                StatusBadge(text: "\(project.completedCount ?? 0)/\(t) parts", color: (project.completedCount ?? 0) >= t ? .green : .secondary)
            } else if let t = project.targetCount, t > 0 {
                StatusBadge(text: "\(project.archiveCount ?? 0)/\(t) plates", color: (project.archiveCount ?? 0) >= t ? .green : .secondary)
            } else if (project.completedCount ?? 0) > 0 {
                StatusBadge(text: "\(project.completedCount ?? 0) parts")
            }
            if project.status == "completed" { StatusBadge(text: "Done", color: .green) }
            if project.status == "archived" { StatusBadge(text: "Archived") }
            if let p = project.priority, p != "normal" { StatusBadge(text: ProjectPalette.priorityLabel(p), color: ProjectPalette.priorityColor(p)) }
            if let days = ProjectDates.daysUntil(project.dueDate), project.status == "active" {
                StatusBadge(text: days < 0 ? "Overdue" : days == 0 ? "Due today" : "\(days)d left",
                            color: days < 0 ? .red : days <= 3 ? .orange : .secondary)
            }
            if let c = project.childCount, c > 0 {
                Label("\(c)", systemImage: "folder.fill.badge.plus").font(.caption2.weight(.semibold)).foregroundStyle(.purple)
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        let hasTargets = (project.targetCount ?? 0) > 0 || (project.targetPartsCount ?? 0) > 0
        if hasTargets {
            VStack(spacing: 6) {
                if let t = project.targetCount, t > 0 {
                    ProjectProgressRow(title: "Plates", done: project.archiveCount ?? 0, target: t, tint: tint)
                }
                if let t = project.targetPartsCount, t > 0 {
                    ProjectProgressRow(title: "Parts", done: project.completedCount ?? 0, target: t, tint: tint)
                }
                if let f = project.failedCount, f > 0 {
                    Label("\(f) failed", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if (project.completedCount ?? 0) == 0 && (project.failedCount ?? 0) == 0 && (project.queueCount ?? 0) == 0 {
            Text("No prints yet").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var materials: some View {
        let archives = project.archives ?? []
        let mats = ProjectPalette.unique(archives.flatMap { ProjectPalette.splitList($0.filamentType) })
        let colors = ProjectPalette.unique(archives.flatMap { ProjectPalette.splitList($0.filamentColor) })
            .filter { Color(hex: $0) != nil }
        if !mats.isEmpty || !colors.isEmpty {
            HStack(spacing: 6) {
                ForEach(mats.prefix(3), id: \.self) { StatusBadge(text: $0, color: .secondary) }
                ForEach(colors.prefix(5), id: \.self) { ColorSwatch(hex: $0, size: 14) }
                if colors.count > 5 { Text("+\(colors.count - 5)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Label("\(project.archiveCount ?? 0)", systemImage: "square.stack.3d.up").foregroundStyle(.blue)
            Label("\(project.completedCount ?? 0)", systemImage: "shippingbox").foregroundStyle(.green)
            if let f = project.failedCount, f > 0 { Label("\(f)", systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if let q = project.queueCount, q > 0 { Label("\(q)", systemImage: "list.number").foregroundStyle(.orange) }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.medium))
        .labelStyle(.titleAndIcon)
    }
}

struct ProjectProgressRow: View {
    let title: String
    let done: Int
    let target: Int
    let tint: Color
    var body: some View {
        let fraction = target > 0 ? min(1, Double(done) / Double(target)) : 0
        VStack(spacing: 3) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                Text("\(done) / \(target)").monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: fraction).tint(fraction >= 1 ? .green : tint)
        }
    }
}

// MARK: - Sharing

struct ProjectsSharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ProjectsActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
