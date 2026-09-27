import SwiftUI

/// Shared presentation state and mutations for archive actions, used by the
/// browser (cards, rows, context menus, bulk bar) and the detail screen.
@MainActor
@Observable
final class ArchivesActions {
    var editing: ArchivesRecord?
    var deleting: ArchivesRecord?
    var printRequest: ArchivesPrintRequest?
    var timelapse: ArchivesRecord?
    var sharedFile: ArchivesSharedFile?
    var runsFor: ArchivesRecord?
    var qrFor: ArchivesRecord?
    var projectPageFor: ArchivesRecord?
    var downloadingId: Int?

    let runner = ActionRunner()

    /// Called with the updated archive after a successful change (nil = reload everything).
    @ObservationIgnored var onUpdated: ((ArchivesRecord?) -> Void)?
    /// Called with ids removed by a delete.
    @ObservationIgnored var onDeleted: ((Set<Int>) -> Void)?

    func toggleFavorite(_ archive: ArchivesRecord, client: APIClient) async {
        await runner.run {
            let updated: ArchivesRecord = try await client.send(.post, "archives/\(archive.id)/favorite")
            onUpdated?(updated)
            runner.successMessage = updated.favorite ? "Added to favorites" : "Removed from favorites"
        }
    }

    func assignProject(_ archive: ArchivesRecord, projectId: Int?, client: APIClient) async {
        var body = ArchivesUpdate()
        body.set("project_id", projectId)
        await runner.run(projectId == nil ? "Removed from project" : "Project updated") {
            let updated: ArchivesRecord = try await client.send(.patch, "archives/\(archive.id)", body: body)
            onUpdated?(updated)
        }
    }

    func print(_ archive: ArchivesRecord, mode: PrintJobSheet.Mode) {
        printRequest = ArchivesPrintRequest(archiveId: archive.id, name: archive.displayName, mode: mode)
    }

    /// Downloads a server file to a temp location and opens the share sheet.
    func share(_ path: String, id: Int, name: String?, client: APIClient) async {
        downloadingId = id
        defer { downloadingId = nil }
        await runner.run {
            let url = try await client.download(path, suggestedName: name)
            sharedFile = ArchivesSharedFile(url: url)
        }
    }

    func download3MF(_ archive: ArchivesRecord, client: APIClient) async {
        let base = archive.displayName.replacingOccurrences(of: "/", with: "_")
        let name = (archive.filename?.lowercased().hasSuffix(".3mf") ?? true) ? (base.hasSuffix(".3mf") ? base : base + ".3mf") : (archive.filename ?? base)
        await share("archives/\(archive.id)/download", id: archive.id, name: name, client: client)
    }

    func copyDownloadLink(_ archive: ArchivesRecord, session: AppSession) {
        UIPasteboard.general.url = session.client.url("archives/\(archive.id)/download")
        runner.successMessage = "Link copied"
    }
}

// MARK: Context menu

/// The per-archive action menu (context menu, "…" buttons, detail toolbar).
struct ArchivesActionMenu: View {
    @Environment(AppSession.self) private var session
    @Environment(ArchivesLookups.self) private var lookups
    let archive: ArchivesRecord
    let actions: ArchivesActions
    var includeOpen: Bool = true
    var onSelect: (() -> Void)? = nil
    var isSelected = false

    var body: some View {
        let canUpdate = ArchivesPermissions.canUpdate(session, archive)
        let canReprint = ArchivesPermissions.canReprint(session, archive)
        Section {
            if archive.isSliced {
                Button { actions.print(archive, mode: .printNow) } label: { Label("Print", systemImage: "printer") }
                    .disabled(!canReprint || (archive.filePath ?? "").isEmpty)
                Button { actions.print(archive, mode: .addToQueue) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                    .disabled(!canReprint || (archive.filePath ?? "").isEmpty)
            }
            if let link = archive.externalLink {
                Link(destination: link) {
                    Label(archive.externalUrl?.isEmpty == false ? "Open External Link" : "View on MakerWorld", systemImage: "globe")
                }
            }
        }
        Section {
            if archive.timelapsePath != nil {
                Button { actions.timelapse = archive } label: { Label("Play Timelapse", systemImage: "film") }
            }
            Button { actions.runsFor = archive } label: { Label("Print History", systemImage: "clock.arrow.circlepath") }
            Button { actions.projectPageFor = archive } label: { Label("Project Page", systemImage: "doc.richtext") }
            Button { actions.qrFor = archive } label: { Label("QR Code", systemImage: "qrcode") }
        }
        Section {
            Button { Task { await actions.download3MF(archive, client: session.client) } } label: {
                Label("Download 3MF", systemImage: "arrow.down.circle")
            }
            .disabled(!session.can("archives:read"))
            Button { actions.copyDownloadLink(archive, session: session) } label: { Label("Copy Download Link", systemImage: "link") }
        }
        Section {
            Button { Task { await actions.toggleFavorite(archive, client: session.client) } } label: {
                Label(archive.favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: archive.favorite ? "star.slash" : "star")
            }
            .disabled(!canUpdate)
            Button { actions.editing = archive } label: { Label("Edit", systemImage: "pencil") }
                .disabled(!canUpdate)
            Menu {
                if archive.projectId != nil {
                    Button(role: .destructive) { Task { await actions.assignProject(archive, projectId: nil, client: session.client) } } label: {
                        Label("Remove from Project", systemImage: "xmark")
                    }
                }
                let options = lookups.assignableProjects(keeping: archive.projectId)
                if options.isEmpty {
                    Text("No projects available")
                }
                ForEach(options) { project in
                    Button {
                        Task { await actions.assignProject(archive, projectId: project.id, client: session.client) }
                    } label: {
                        if project.id == archive.projectId { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                    }
                    .disabled(project.id == archive.projectId)
                }
            } label: {
                Label("Add to Project", systemImage: "folder.badge.plus")
            }
            .disabled(!canUpdate)
            if let onSelect {
                Button(action: onSelect) {
                    Label(isSelected ? "Deselect" : "Select", systemImage: isSelected ? "checkmark.circle.fill" : "checkmark.circle")
                }
            }
        }
        Section {
            Button(role: .destructive) { actions.deleting = archive } label: { Label("Delete", systemImage: "trash") }
                .disabled(!ArchivesPermissions.canDelete(session, archive))
        }
    }
}

// MARK: Presenters

extension View {
    /// Attaches the sheets/dialogs driven by an `ArchivesActions` hub.
    func archivesActionPresenters(_ actions: ArchivesActions) -> some View {
        modifier(ArchivesActionPresenters(actions: actions))
    }
}

private struct ArchivesActionPresenters: ViewModifier {
    @Bindable var actions: ArchivesActions

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.editing) { archive in
                ArchivesEditSheet(archive: archive) { updated in actions.onUpdated?(updated) }
            }
            .sheet(item: $actions.deleting) { archive in
                ArchivesDeleteSheet(archive: archive) { actions.onDeleted?([archive.id]) }
                    .presentationDetents([.medium])
            }
            .sheet(item: $actions.printRequest) { request in
                PrintJobSheet(source: .archive(id: request.archiveId, name: request.name), mode: request.mode) {
                    actions.onUpdated?(nil)
                }
            }
            .sheet(item: $actions.timelapse) { archive in
                ArchivesTimelapsePlayer(archive: archive) { actions.onUpdated?(nil) }
            }
            .sheet(item: $actions.sharedFile) { file in
                ArchivesShareSheet(file: file)
                    .presentationDetents([.medium])
            }
            .sheet(item: $actions.runsFor) { archive in
                NavigationStack { ArchivesRunsList(archive: archive).navigationTitle("Print History") }
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $actions.qrFor) { archive in
                ArchivesQRCodeSheet(archive: archive)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $actions.projectPageFor) { archive in
                ArchivesProjectPageSheet(archive: archive)
            }
            .actionAlerts(actions.runner)
    }
}

/// Share sheet wrapper for a downloaded file.
struct ArchivesShareSheet: View {
    let file: ArchivesSharedFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.fill").font(.system(size: 48)).foregroundStyle(.tint)
                VStack(spacing: 4) {
                    Text(file.url.lastPathComponent).font(.headline).multilineTextAlignment(.center)
                    if let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        Text(Fmt.bytes(size)).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                ShareLink(item: file.url) {
                    Label("Share or Save", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Download Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// Delete confirmation with queue-impact preflight and the "also remove from
/// statistics" option.
struct ArchivesDeleteSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let archive: ArchivesRecord
    var onDeleted: () -> Void

    @State private var impact: ArchivesDeleteImpact?
    @State private var purgeStats = false
    @State private var runner = ActionRunner()

    private var blocked: Bool { (impact?.currentlyPrinting ?? 0) > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Delete “\(archive.displayName)”? Its files are removed from the server.")
                    if let impact, (impact.relatedQueueItems ?? 0) > 0 {
                        if blocked {
                            Label("\(impact.currentlyPrinting ?? 0) related queue item(s) are printing right now. Stop the print before deleting.", systemImage: "exclamationmark.octagon.fill")
                                .foregroundStyle(.red)
                        } else {
                            Label("\(impact.relatedQueueItems ?? 0) related queue item(s) will also be removed.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Toggle("Also remove from statistics", isOn: $purgeStats)
                } footer: {
                    Text("By default the print still counts toward filament, time and cost totals.")
                }
                Section {
                    Button(role: .destructive) {
                        Task {
                            await runner.run {
                                try await session.client.call(.delete, "archives/\(archive.id)", query: ["purge_stats": purgeStats ? true : nil])
                                onDeleted()
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Text("Delete Archive")
                            Spacer()
                            if runner.isRunning { ProgressView() }
                        }
                    }
                    .disabled(blocked || runner.isRunning)
                }
            }
            .navigationTitle("Delete Archive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { impact = try? await session.client.get("archives/\(archive.id)/delete-impact") }
            .actionAlerts(runner)
        }
    }
}
