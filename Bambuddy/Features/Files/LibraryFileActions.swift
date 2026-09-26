import SwiftUI

/// The facts a file action needs, built from either a list row or a detail.
struct LibraryFileRef: Identifiable, Hashable, Sendable {
    let id: Int
    var filename: String
    var displayName: String
    var fileType: String
    var ownerId: Int?
    var folderId: Int?
    var projectId: Int?
    var tags: [LibraryTagRef]
    var hasThumbnail: Bool
    var variantGroupId: Int?
    var isExternal: Bool

    var isSliced: Bool { LibraryFileKind.isSliced(filename: filename, fileType: fileType) }
    var isSliceable: Bool { LibraryFileKind.isSliceable(filename: filename, fileType: fileType) }
    var isMesh: Bool { LibraryFileKind.isMesh(filename: filename) }
    var isSTL: Bool { fileType.lowercased() == "stl" || filename.lowercased().hasSuffix(".stl") }

    init(_ s: LibraryFileSummary) {
        id = s.id; filename = s.filename; displayName = s.displayName; fileType = s.type
        ownerId = s.createdById; folderId = s.folderId; projectId = nil
        tags = s.tags ?? []; hasThumbnail = s.thumbnailPath != nil
        variantGroupId = s.variantGroupId; isExternal = s.isExternal ?? false
    }

    init(_ d: LibraryFileDetail, tags: [LibraryTagRef] = [], variantGroupId: Int? = nil) {
        id = d.id; filename = d.filename; displayName = d.displayName; fileType = d.type
        ownerId = d.createdById; folderId = d.folderId; projectId = d.projectId
        self.tags = tags; hasThumbnail = d.thumbnailPath != nil
        self.variantGroupId = variantGroupId; isExternal = d.isExternal ?? false
    }

    init(id: Int, filename: String) {
        self.id = id; self.filename = filename; displayName = filename
        fileType = LibraryFileKind.type(of: filename)
        tags = []; hasThumbnail = true; isExternal = false
    }
}

enum LibraryFileSheet: Identifiable {
    case print(LibraryFileRef, PrintJobSheet.Mode)
    case slice(LibraryFileRef)
    case rename(LibraryFileRef)
    case move([LibraryFileRef])
    case tags([LibraryFileRef])
    case project([LibraryFileRef])
    case share(LibrarySharedFile)
    case preview3d(LibraryFileRef)

    var id: String {
        switch self {
        case .print(let f, let mode): "print-\(f.id)-\(mode)"
        case .slice(let f): "slice-\(f.id)"
        case .rename(let f): "rename-\(f.id)"
        case .move(let fs): "move-\(fs.map(\.id))"
        case .tags(let fs): "tags-\(fs.map(\.id))"
        case .project(let fs): "project-\(fs.map(\.id))"
        case .share(let f): "share-\(f.url.path)"
        case .preview3d(let f): "3d-\(f.id)"
        }
    }
}

/// Shared state + operations for acting on library files (browser, detail,
/// MakerWorld). Attach the presenter with `.modifier(LibraryFileActionsPresenter(...))`.
@MainActor
@Observable
final class LibraryFileActions {
    var sheet: LibraryFileSheet?
    var pendingDelete: [LibraryFileRef] = []
    var downloadingId: Int?
    /// Bumped per file after a thumbnail regeneration so images reload.
    var thumbnailVersions: [Int: Int] = [:]
    let runner = ActionRunner()

    func share(_ file: LibraryFileRef, client: APIClient) async {
        downloadingId = file.id
        defer { downloadingId = nil }
        await runner.run {
            let url = try await client.download("library/files/\(file.id)/download", suggestedName: file.filename)
            sheet = .share(LibrarySharedFile(url: url))
        }
    }

    func addToQueue(_ files: [LibraryFileRef], client: APIClient) async {
        let sliced = files.filter(\.isSliced)
        guard !sliced.isEmpty else {
            runner.errorMessage = "Only sliced files (G-code) can be queued."
            return
        }
        await runner.run {
            let result: LibraryQueueAddResult = try await client.send(.post, "library/files/add-to-queue", body: LibraryFileIdsBody(fileIds: sliced.map(\.id)))
            let added = result.added?.count ?? 0
            if let errors = result.errors, !errors.isEmpty {
                let detail = errors.map { "\($0.filename ?? "#\($0.fileId ?? 0)"): \($0.error ?? "failed")" }.joined(separator: "\n")
                if added == 0 { throw APIError(status: 400, message: detail, code: nil, detail: nil) }
                runner.errorMessage = "Added \(added) to the queue. Some files failed:\n\(detail)"
            } else {
                runner.successMessage = added == 1 ? "Added to queue" : "Added \(added) files to queue"
            }
        }
    }

    func generateThumbnails(_ files: [LibraryFileRef], client: APIClient, reload: () async -> Void) async {
        await runner.run {
            let result: LibraryThumbnailBatchResult = try await client.send(.post, "library/generate-stl-thumbnails", body: LibraryThumbnailBatchBody(fileIds: files.map(\.id)))
            for entry in result.results ?? [] where entry.success == true {
                if let id = entry.fileId { thumbnailVersions[id, default: 0] += 1 }
            }
            if (result.succeeded ?? 0) == 0, let failure = result.results?.first(where: { $0.success != true }) {
                throw APIError(status: 400, message: failure.error ?? "Thumbnail generation failed", code: nil, detail: nil)
            }
            runner.successMessage = "Thumbnail generated"
            await reload()
        }
    }

    func groupAsVersions(_ files: [LibraryFileRef], client: APIClient, reload: () async -> Void) async {
        await runner.run {
            let body = LibraryVariantGroupCreateBody(members: files.map { .init(libraryFileId: $0.id) })
            let group: LibraryVariantGroup = try await client.send(.post, "library/variant-groups", body: body)
            runner.successMessage = "Grouped \(group.members?.count ?? files.count) files as versions"
            await reload()
        }
    }

    func delete(_ files: [LibraryFileRef], client: APIClient) async -> Bool {
        var ok = false
        await runner.run {
            if files.count == 1, let file = files.first {
                let result: LibraryDeleteFileResult = try await client.send(.delete, "library/files/\(file.id)")
                runner.successMessage = result.trashed == false ? "File deleted" : "Moved to Trash"
            } else {
                let result: LibraryBulkDeleteResult = try await client.send(.post, "library/bulk-delete", body: LibraryBulkDeleteBody(fileIds: files.map(\.id), folderIds: []))
                runner.successMessage = "Deleted \(result.deletedFiles ?? files.count) files"
            }
            ok = true
        }
        return ok
    }
}

/// Presents the sheets and confirmations driven by `LibraryFileActions`.
struct LibraryFileActionsPresenter: ViewModifier {
    @Environment(AppSession.self) private var session
    @Bindable var actions: LibraryFileActions
    let reload: () async -> Void
    var onDeleted: ([Int]) -> Void = { _ in }

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.sheet) { sheet in
                sheetContent(sheet)
            }
            .confirmationDialog(deleteTitle, isPresented: Binding(get: { !actions.pendingDelete.isEmpty }, set: { if !$0 { actions.pendingDelete = [] } }), titleVisibility: .visible) {
                Button(actions.pendingDelete.count == 1 ? "Move to Trash" : "Delete \(actions.pendingDelete.count) Files", role: .destructive) {
                    let files = actions.pendingDelete
                    Task {
                        if await actions.delete(files, client: session.client) {
                            onDeleted(files.map(\.id))
                            await reload()
                        }
                    }
                }
            } message: {
                Text("Deleted files go to the library trash and can be restored until they are purged.")
            }
            .actionAlerts(actions.runner)
    }

    private var deleteTitle: String {
        actions.pendingDelete.count == 1 ? "Delete “\(actions.pendingDelete[0].displayName)”?" : "Delete \(actions.pendingDelete.count) files?"
    }

    @ViewBuilder
    private func sheetContent(_ sheet: LibraryFileSheet) -> some View {
        switch sheet {
        case .print(let file, let mode):
            PrintJobSheet(source: .libraryFile(id: file.id, name: file.displayName), mode: mode) {
                Task { await reload() }
            }
        case .slice(let file):
            LibrarySliceSheet(file: file) { Task { await reload() } }
        case .rename(let file):
            let parts = LibraryFileKind.splitExtension(file.filename)
            LibraryNameSheet(title: "Rename File", actionTitle: "Rename", initial: parts.base, suffix: parts.ext, validateFilename: true) { newBase in
                let _: LibraryFileDetail = try await session.client.send(.put, "library/files/\(file.id)", body: LibraryFileUpdateBody(filename: newBase + parts.ext))
                await reload()
            }
        case .move(let files):
            let current = Set(files.map(\.folderId)).count == 1 ? files.first?.folderId : -1
            LibraryFolderPickerSheet(title: files.count == 1 ? "Move File" : "Move \(files.count) Files", current: current) { target in
                let result: LibraryMoveResult = try await session.client.send(.post, "library/files/move", body: LibraryFileMoveBody(fileIds: files.map(\.id), folderId: target))
                if let moved = result.moved, moved < files.count {
                    actions.runner.errorMessage = "Moved \(moved) of \(files.count) files. Some files couldn't be moved (for example into a read-only folder)."
                } else {
                    actions.runner.successMessage = files.count == 1 ? "File moved" : "Moved \(files.count) files"
                }
                await reload()
            }
        case .tags(let files):
            LibraryTagAssignSheet(fileIds: files.map(\.id), currentTags: files.count == 1 ? files[0].tags : []) {
                Task { await reload() }
            }
        case .project(let files):
            LibraryProjectPickerSheet(fileIds: files.map(\.id), currentProjectId: files.count == 1 ? files[0].projectId : nil) {
                actions.runner.successMessage = "Project updated"
                Task { await reload() }
            }
        case .share(let file):
            LibraryActivitySheet(items: [file.url])
                .presentationDetents([.medium, .large])
        case .preview3d(let file):
            LibraryModelPreviewView(fileId: file.id, filename: file.filename)
        }
    }
}

/// Context-menu / toolbar-menu entries for a single file.
struct LibraryFileMenuItems: View {
    @Environment(AppSession.self) private var session
    let file: LibraryFileRef
    let actions: LibraryFileActions
    let useSlicerApi: Bool
    var reload: () async -> Void = {}
    var showOpen: (() -> Void)? = nil

    var body: some View {
        if let showOpen {
            Button("Details", systemImage: "info.circle", action: showOpen)
        }
        if file.isSliced {
            Section {
                Button("Print…", systemImage: "printer") { actions.sheet = .print(file, .printNow) }
                    .disabled(!session.can("queue:create"))
                Button("Add to Queue…", systemImage: "text.badge.plus") { actions.sheet = .print(file, .addToQueue) }
                    .disabled(!session.can("queue:create"))
            }
        }
        if useSlicerApi && file.isSliceable {
            Button("Slice…", systemImage: "gearshape.2") { actions.sheet = .slice(file) }
                .disabled(!session.can("library:upload"))
        }
        Section {
            if file.isMesh {
                Button("3D Preview", systemImage: "cube.transparent") { actions.sheet = .preview3d(file) }
            }
            Button("Share…", systemImage: "square.and.arrow.up") {
                Task { await actions.share(file, client: session.client) }
            }
            .disabled(!LibraryAccess.canRead(session))
        }
        let canEdit = LibraryAccess.canUpdate(session, ownerId: file.ownerId)
        Section {
            Button("Rename…", systemImage: "pencil") { actions.sheet = .rename(file) }
            Button("Move…", systemImage: "folder") { actions.sheet = .move([file]) }
            Button("Tags…", systemImage: "tag") { actions.sheet = .tags([file]) }
            Button("Add to Project…", systemImage: "briefcase") { actions.sheet = .project([file]) }
            if file.isSTL {
                Button("Generate Thumbnail", systemImage: "photo") {
                    Task { await actions.generateThumbnails([file], client: session.client, reload: reload) }
                }
            }
        }
        .disabled(!canEdit)
        Button("Delete", systemImage: "trash", role: .destructive) { actions.pendingDelete = [file] }
            .disabled(!LibraryAccess.canDelete(session, ownerId: file.ownerId))
    }
}
