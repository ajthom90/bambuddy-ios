import SwiftUI
import UIKit

/// Everything the project screen shows, loaded together.
@MainActor
@Observable
final class ProjectDetailStore {
    var project: ProjectDetail?
    var error: String?
    var archives: [ProjectArchiveEntry] = []
    var bom: [ProjectBOMItem] = []
    var timeline: [ProjectTimelineEvent] = []
    var folders: [ProjectLibraryFolder] = []
    var files: [ProjectLibraryFile] = []
    var fileProgress: [Int: Int] = [:]
    var notes: AttributedString?

    func load(client: APIClient, id: Int) async {
        async let projectReq: ProjectDetail = client.get("projects/\(id)")
        async let archivesReq: [ProjectArchiveEntry]? = try? client.get("projects/\(id)/archives", query: ["limit": 500])
        async let bomReq: [ProjectBOMItem]? = try? client.get("projects/\(id)/bom")
        async let timelineReq: [ProjectTimelineEvent]? = try? client.get("projects/\(id)/timeline", query: ["limit": 30])
        async let foldersReq: [ProjectLibraryFolder]? = try? client.get("library/folders/by-project/\(id)")
        async let filesReq: [ProjectLibraryFile]? = try? client.get("library/files/", query: ["project_id": .int(id), "include_root": false])
        async let progressReq: [ProjectFileProgressEntry]? = try? client.get("projects/\(id)/file-progress")
        do {
            let p = try await projectReq
            if p.notes != project?.notes { notes = Self.renderNotes(p.notes) }
            project = p
            error = nil
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
        if let v = await archivesReq { archives = v }
        if let v = await bomReq { bom = v }
        if let v = await timelineReq { timeline = v }
        if let v = await foldersReq { folders = v }
        if let v = await filesReq { files = v }
        if let v = await progressReq { fileProgress = Dictionary(v.map { ($0.fileId, $0.completedCount) }, uniquingKeysWith: { a, _ in a }) }
    }

    /// Complete sets: the fewest finished copies across the printable files, capped at the target.
    var completeSets: Int? {
        guard let target = project?.targetSets, target > 0 else { return nil }
        let printable = files.filter(\.isPrintable)
        guard !printable.isEmpty else { return nil }
        return printable.map { min(fileProgress[$0.id] ?? 0, target) }.min()
    }

    // MARK: Notes (stored as HTML by the web editor)

    static func renderNotes(_ html: String?) -> AttributedString? {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let styled = "<style>body{font-family:-apple-system;font-size:17px;}</style>" + html
        guard let data = styled.data(using: .utf8),
              let ns = try? NSMutableAttributedString(data: data, options: [
                  .documentType: NSAttributedString.DocumentType.html,
                  .characterEncoding: String.Encoding.utf8.rawValue,
              ], documentAttributes: nil) else {
            return AttributedString(plainNotes(html))
        }
        ns.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: ns.length))
        while ns.string.hasSuffix("\n") { ns.deleteCharacters(in: NSRange(location: ns.length - 1, length: 1)) }
        return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(ns.string)
    }

    static func plainNotes(_ html: String?) -> String {
        guard let html, !html.isEmpty else { return "" }
        var s = html
        for tag in ["</p>", "<br>", "<br/>", "<br />", "</li>", "</h1>", "</h2>", "</h3>", "</div>"] {
            s = s.replacingOccurrences(of: tag, with: tag + "\n", options: .caseInsensitive)
        }
        s = s.replacingOccurrences(of: "<li>", with: "• ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain text → simple paragraphs the web editor understands.
    static func notesHTML(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.components(separatedBy: "\n").map { line in
            let escaped = line.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return escaped.isEmpty ? "<p></p>" : "<p>\(escaped)</p>"
        }.joined()
    }
}

struct ProjectPrintRequest: Identifiable {
    let id = UUID()
    let source: PrintSource
    var mode: PrintJobSheet.Mode = .printNow
}

struct ProjectDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(\.dismiss) private var dismiss

    let projectId: Int

    @State private var currency = "USD"
    @State private var store = ProjectDetailStore()
    @State private var runner = ActionRunner()
    @State private var editor: ProjectEditorTarget?
    @State private var confirmDelete = false
    @State private var shareFile: ProjectsSharedFile?
    @State private var printRequest: ProjectPrintRequest?
    @State private var templateName = ""
    @State private var askTemplateName = false

    var body: some View {
        Group {
            if let project = store.project {
                content(project)
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Couldn't Load Project", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await reload() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(store.project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if let project = store.project { toolbar(project) } }
        .task(id: live.revision("archive_created", "archive_updated", "print_complete", "print_start")) { await reload() }
        .task {
            if let code = (try? await session.client.get("settings/", as: JSONValue.self))?["currency"]?.stringValue, !code.isEmpty {
                currency = code
            }
        }
        .refreshable { await reload() }
        .sheet(item: $editor) { target in
            ProjectEditorSheet(target: target, allProjects: [], currency: currency) { _ in Task { await reload() } }
        }
        .sheet(item: $shareFile) { ProjectsActivitySheet(items: [$0.url]) }
        .sheet(item: $printRequest) { req in
            PrintJobSheet(source: req.source, mode: req.mode) { Task { await reload() } }
        }
        .confirm("Delete Project?", isPresented: $confirmDelete,
                 message: "Prints and queue items are kept but unlinked from this project. Sub-projects move up one level.") {
            Task { await delete() }
        }
        .alert("New Project from Template", isPresented: $askTemplateName) {
            TextField("Project name", text: $templateName)
            Button("Create") { Task { await createFromTemplate() } }
            Button("Cancel", role: .cancel) {}
        }
        .actionAlerts(runner)
    }

    private func reload() async { await store.load(client: session.client, id: projectId) }

    // MARK: Layout

    private func content(_ project: ProjectDetail) -> some View {
        List {
            ProjectHeaderSection(project: project)
            if hasTargets(project) { progressSection(project) }
            if let stats = project.stats { statsSection(stats) }
            costSection(project)
            if let rollup = project.rollupStats { rollupSection(rollup, project: project) }
            if let children = project.children, !children.isEmpty { childrenSection(children) }
            ProjectFilesSection(store: store, projectId: projectId, printRequest: $printRequest)
            ProjectBOMSection(store: store, projectId: projectId, currency: currency, reload: reload)
            ProjectArchivesSection(store: store, projectId: projectId, printRequest: $printRequest, reload: reload)
            ProjectAttachmentsSection(store: store, projectId: projectId, reload: reload)
            ProjectNotesSection(store: store, projectId: projectId, reload: reload)
            ProjectTimelineSection(events: store.timeline)
        }
        .listStyle(.insetGrouped)
    }

    private func hasTargets(_ p: ProjectDetail) -> Bool {
        (p.targetCount ?? 0) > 0 || (p.targetPartsCount ?? 0) > 0 || (p.targetSets ?? 0) > 0
    }

    private func progressSection(_ project: ProjectDetail) -> some View {
        let tint = ProjectPalette.color(project.color)
        let stats = project.stats
        return Section("Progress") {
            if let t = project.targetCount, t > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProjectProgressRow(title: "Print jobs", done: stats?.totalArchives ?? 0, target: t, tint: tint)
                    if let r = stats?.remainingPrints, r > 0 { Text("\(r) remaining").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let t = project.targetPartsCount, t > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProjectProgressRow(title: "Parts", done: stats?.completedPrints ?? 0, target: t, tint: tint)
                    if let r = stats?.remainingParts, r > 0 { Text("\(r) remaining").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let t = project.targetSets, t > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    ProjectProgressRow(title: "Complete sets", done: store.completeSets ?? 0, target: t, tint: tint)
                    Text("A set is complete when every printable file in the linked folders has been printed that many times.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func statsSection(_ stats: ProjectStatsInfo) -> some View {
        Section("Statistics") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ProjectStatTile(title: "Print Jobs", value: "\(stats.totalArchives ?? 0)", systemImage: "square.stack.3d.up", tint: .blue,
                                detail: (stats.failedPrints ?? 0) > 0 ? "\(stats.failedPrints ?? 0) failed" : nil)
                ProjectStatTile(title: "Parts Printed", value: "\(stats.completedPrints ?? 0)", systemImage: "shippingbox", tint: .green)
                ProjectStatTile(title: "Print Time", value: Fmt.duration(seconds: (stats.totalPrintTimeHours ?? 0) * 3600), systemImage: "clock", tint: .yellow)
                ProjectStatTile(title: "Filament", value: Fmt.grams(stats.totalFilamentGrams ?? 0), systemImage: "scalemass", tint: .purple)
            }
            .padding(.vertical, 4)
            if (stats.inProgressPrints ?? 0) > 0 || (stats.queuedPrints ?? 0) > 0 {
                HStack {
                    if let n = stats.inProgressPrints, n > 0 { Label("\(n) printing", systemImage: "printer.fill").foregroundStyle(.orange) }
                    if let n = stats.queuedPrints, n > 0 { Label("\(n) queued", systemImage: "list.number").foregroundStyle(.blue) }
                }
                .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func costSection(_ project: ProjectDetail) -> some View {
        if let stats = project.stats, (stats.estimatedCost ?? 0) > 0 || stats.totalCost > 0 || project.budget != nil {
            Section("Cost") {
                InfoRow("Filament", ProjectMoney.format(stats.estimatedCost ?? 0, code: currency), systemImage: "circle.circle")
                if let kwh = stats.totalEnergyKwh, kwh > 0 {
                    let cost = (stats.totalEnergyCost ?? 0) > 0 ? " (\(ProjectMoney.format(stats.totalEnergyCost, code: currency)))" : ""
                    InfoRow("Energy", String(format: "%.3f kWh", kwh) + cost, systemImage: "bolt")
                }
                if let bom = stats.bomCost, bom > 0 {
                    InfoRow("Parts", ProjectMoney.format(bom, code: currency), systemImage: "cart")
                }
                if stats.totalCost > 0 {
                    LabeledContent {
                        Text(ProjectMoney.format(stats.totalCost, code: currency)).font(.headline).foregroundStyle(.green)
                    } label: { Label("Total", systemImage: "sum") }
                }
                if let budget = project.budget {
                    let remaining = budget - stats.totalCost
                    InfoRow("Budget", ProjectMoney.format(budget, code: currency), systemImage: "banknote")
                    LabeledContent {
                        Text(ProjectMoney.format(remaining, code: currency)).foregroundStyle(remaining < 0 ? .red : .green)
                    } label: { Label(remaining < 0 ? "Over Budget" : "Remaining", systemImage: remaining < 0 ? "exclamationmark.triangle" : "checkmark.circle") }
                    if budget > 0 {
                        ProgressView(value: min(1, stats.totalCost / budget)).tint(remaining < 0 ? .red : .green)
                    }
                }
            }
        }
    }

    private func rollupSection(_ rollup: ProjectStatsInfo, project: ProjectDetail) -> some View {
        Section {
            InfoRow("Print Jobs", "\(rollup.totalArchives ?? 0) · \(rollup.completedPrints ?? 0) parts")
            InfoRow("Print Time", Fmt.duration(seconds: (rollup.totalPrintTimeHours ?? 0) * 3600))
            InfoRow("Filament", Fmt.grams(rollup.totalFilamentGrams ?? 0))
            if rollup.totalCost > 0 { InfoRow("Total Cost", ProjectMoney.format(rollup.totalCost, code: currency)) }
            if let p = rollup.progressPercent {
                ProjectProgressRow(title: "Overall progress", done: Int(p.rounded()), target: 100, tint: ProjectPalette.color(project.color))
            }
        } header: {
            Text("Including \(project.descendantCount ?? 0) Sub-project\((project.descendantCount ?? 0) == 1 ? "" : "s")")
        }
    }

    private func childrenSection(_ children: [ProjectChildSummary]) -> some View {
        Section("Sub-projects (\(children.count))") {
            ForEach(children) { child in
                NavigationLink(value: ProjectsRoute.project(child.id)) {
                    HStack(spacing: 10) {
                        Circle().fill(ProjectPalette.color(child.color)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(child.name).lineLimit(1)
                            let parts = [
                                (child.totalArchives ?? 0) > 0 ? "\(child.totalArchives ?? 0) jobs" : nil,
                                (child.totalFilamentGrams ?? 0) > 0 ? Fmt.grams(child.totalFilamentGrams) : nil,
                                (child.totalCost ?? 0) > 0 ? ProjectMoney.format(child.totalCost, code: currency) : nil,
                                (child.descendantCount ?? 0) > 0 ? "\(child.descendantCount ?? 0) nested" : nil,
                            ].compactMap { $0 }
                            if !parts.isEmpty { Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if let p = child.progressPercent { Text(Fmt.percent(p)).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                        StatusBadge(text: ProjectPalette.statusLabel(child.status ?? "active"), color: ProjectPalette.statusColor(child.status ?? "active"))
                    }
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ project: ProjectDetail) -> some ToolbarContent {
        if session.can("projects:update") {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { editor = .edit(ProjectEditForm(project: project), id: project.id, coverFilename: project.coverImageFilename) }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                if session.can("projects:update") {
                    if project.status != "completed" {
                        Button { Task { await setStatus("completed") } } label: { Label("Mark Completed", systemImage: "checkmark.circle") }
                    }
                    if project.status != "archived" {
                        Button { Task { await setStatus("archived") } } label: { Label("Archive", systemImage: "archivebox") }
                    }
                    if project.status != "active" {
                        Button { Task { await setStatus("active") } } label: { Label("Mark Active", systemImage: "arrow.uturn.backward.circle") }
                    }
                }
                if session.can("projects:create") {
                    if project.isTemplate == true {
                        Button {
                            templateName = project.name
                            askTemplateName = true
                        } label: { Label("New Project from Template", systemImage: "plus.square.on.square") }
                    } else {
                        Button { Task { await saveAsTemplate() } } label: { Label("Save as Template", systemImage: "doc.on.doc") }
                    }
                }
                Divider()
                Button { Task { await export(zip: true) } } label: { Label("Export with Files (ZIP)", systemImage: "doc.zipper") }
                Button { Task { await export(zip: false) } } label: { Label("Export as JSON", systemImage: "curlybraces") }
                if session.can("projects:delete") {
                    Divider()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Project", systemImage: "trash") }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: Actions

    private func setStatus(_ status: String) async {
        await runner.run("Project updated") {
            try await session.client.call(.patch, "projects/\(projectId)", body: ["status": JSONValue.string(status)])
        }
        await reload()
    }

    private func saveAsTemplate() async {
        await runner.run("Template saved") {
            let _: ProjectDetail = try await session.client.send(.post, "projects/\(projectId)/create-template")
        }
    }

    private func createFromTemplate() async {
        let name = templateName.trimmingCharacters(in: .whitespaces)
        await runner.run("Project created") {
            let _: ProjectDetail = try await session.client.send(.post, "projects/from-template/\(projectId)", query: ["name": .of(name.isEmpty ? nil : name)])
        }
    }

    private func export(zip: Bool) async {
        let client = session.client
        let name = store.project?.name ?? "project"
        await runner.run(nil) {
            if zip {
                let url = try await client.download("projects/\(projectId)/export", query: ["format": "zip"])
                shareFile = ProjectsSharedFile(url: url)
            } else {
                let json: JSONValue = try await client.get("projects/\(projectId)/export", query: ["format": "json"])
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let safe = name.replacingOccurrences(of: "/", with: "-")
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).json")
                try encoder.encode(json).write(to: url, options: .atomic)
                shareFile = ProjectsSharedFile(url: url)
            }
        }
    }

    private func delete() async {
        await runner.run(nil) {
            try await session.client.call(.delete, "projects/\(projectId)")
        }
        if runner.errorMessage == nil { dismiss() }
    }
}

// MARK: - Header

private struct ProjectHeaderSection: View {
    let project: ProjectDetail

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                if project.coverImageFilename != nil {
                    RemoteImage(path: "projects/\(project.id)/cover-image", reloadKey: project.coverImageFilename)
                        .frame(width: 88, height: 88)
                        .clipShape(.rect(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(ProjectPalette.color(project.color).gradient)
                        .frame(width: 56, height: 56)
                        .overlay { Image(systemName: "folder.fill").font(.title2).foregroundStyle(.white) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name).font(.title2.bold())
                    if let d = project.description, !d.isEmpty {
                        Text(d).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        StatusBadge(text: ProjectPalette.statusLabel(project.status), color: ProjectPalette.statusColor(project.status))
                        if project.isTemplate == true { StatusBadge(text: "Template", color: .purple) }
                        if let p = project.priority, p != "normal" {
                            StatusBadge(text: ProjectPalette.priorityLabel(p), color: ProjectPalette.priorityColor(p))
                        }
                    }
                }
            }
            .padding(.vertical, 4)

            if let due = ProjectDates.calendarDate(project.dueDate) {
                let days = ProjectDates.daysUntil(project.dueDate) ?? 0
                LabeledContent {
                    VStack(alignment: .trailing) {
                        Text(due.formatted(date: .abbreviated, time: .omitted))
                        Text(days < 0 ? "Overdue by \(-days) day\(days == -1 ? "" : "s")" : days == 0 ? "Due today" : "\(days) day\(days == 1 ? "" : "s") left")
                            .font(.caption)
                            .foregroundStyle(days < 0 ? .red : days == 0 ? .orange : days <= 3 ? .yellow : .secondary)
                    }
                } label: { Label("Due", systemImage: "calendar") }
            }
            let tags = ProjectPalette.tagList(project.tags)
            if !tags.isEmpty {
                LabeledContent {
                    Text(tags.joined(separator: ", ")).multilineTextAlignment(.trailing)
                } label: { Label("Tags", systemImage: "tag") }
            }
            if let urlString = project.url, let url = URL(string: urlString) {
                Link(destination: url) {
                    Label(url.host() ?? urlString, systemImage: "link")
                }
            }
            if let parentId = project.parentId {
                NavigationLink(value: ProjectsRoute.project(parentId)) {
                    Label("Part of \(project.parentName ?? "project #\(parentId)")", systemImage: "square.stack.3d.up")
                }
            }
        }
    }
}

struct ProjectStatTile: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage).font(.caption).foregroundStyle(tint)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if let detail { Text(detail).font(.caption2).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.08), in: .rect(cornerRadius: 12))
    }
}
