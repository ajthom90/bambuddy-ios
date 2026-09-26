import SwiftUI

/// Library trash: restore or permanently delete files, empty the trash, and
/// (for admins) adjust retention and auto-purge.
struct LibraryTrashView: View {
    @Environment(AppSession.self) private var session
    @State private var loader = Loader<LibraryTrashPage>()
    @State private var settings: LibraryTrashSettings?
    @State private var runner = ActionRunner()
    @State private var selection: Set<Int> = []
    @State private var editMode: EditMode = .inactive
    @State private var confirm: Confirmation?
    @State private var showSettings = false

    private enum Confirmation: Identifiable {
        case purge(LibraryTrashItem), purgeSelected([Int]), empty(Int)
        var id: String {
            switch self {
            case .purge(let i): "p\(i.id)"
            case .purgeSelected(let ids): "s\(ids)"
            case .empty: "empty"
            }
        }
    }

    private var isAdmin: Bool { session.can("library:purge") }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { page in
            List(selection: $selection) {
                Section {
                    if page.items.isEmpty {
                        ContentUnavailableView("Trash Is Empty", systemImage: "trash", description: Text("Deleted library files appear here until they're purged."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(page.items) { item in
                        row(item)
                            .tag(item.id)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", role: .destructive) { confirm = .purge(item) }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Restore") { Task { await restore([item.id]) } }.tint(.green)
                            }
                            .contextMenu {
                                Button("Restore", systemImage: "arrow.uturn.backward") { Task { await restore([item.id]) } }
                                Button("Delete Permanently", systemImage: "trash", role: .destructive) { confirm = .purge(item) }
                            }
                    }
                } header: {
                    if !page.items.isEmpty {
                        let bytes = page.items.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
                        Text("\(page.total ?? page.items.count) files · \(Fmt.bytes(bytes))")
                    }
                } footer: {
                    let days = settings?.retentionDays ?? page.retentionDays ?? 30
                    Text("Files are permanently deleted \(days) days after being moved to the trash.")
                }
            }
            .environment(\.editMode, $editMode)
        }
        .navigationTitle("Trash")
        .refreshable { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if editMode.isEditing {
                    Button("Done") { withAnimation { editMode = .inactive; selection = [] } }
                } else {
                    Menu {
                        Button("Select", systemImage: "checkmark.circle") { withAnimation { editMode = .active } }
                            .disabled(loader.value?.items.isEmpty ?? true)
                        if isAdmin {
                            Button("Trash Settings…", systemImage: "gearshape") { showSettings = true }
                        }
                        Divider()
                        Button("Empty Trash", systemImage: "trash.slash", role: .destructive) {
                            confirm = .empty(loader.value?.total ?? loader.value?.items.count ?? 0)
                        }
                        .disabled(loader.value?.items.isEmpty ?? true)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Restore") { Task { await restore(Array(selection)) } }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Text("\(selection.count) selected").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete", role: .destructive) { confirm = .purgeSelected(Array(selection)) }
                        .disabled(selection.isEmpty)
                }
            }
        }
        .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible, presenting: confirm) { c in
            Button("Delete Permanently", role: .destructive) {
                Task {
                    switch c {
                    case .purge(let item): await purge([item.id])
                    case .purgeSelected(let ids): await purge(ids)
                    case .empty: await emptyTrash()
                    }
                }
            }
        } message: { _ in
            Text("This can't be undone.")
        }
        .sheet(isPresented: $showSettings) {
            if let settings {
                LibraryTrashSettingsSheet(initial: settings) { self.settings = $0 }
            }
        }
        .actionAlerts(runner)
        .task { await load() }
    }

    private var confirmTitle: String {
        switch confirm {
        case .purge(let item): "Permanently delete “\(item.filename)”?"
        case .purgeSelected(let ids): "Permanently delete \(ids.count) files?"
        case .empty(let count): "Empty trash (\(count) files)?"
        case nil: ""
        }
    }

    private func row(_ item: LibraryTrashItem) -> some View {
        HStack(spacing: 12) {
            LibraryFileThumbnail(fileId: item.id, hasThumbnail: item.thumbnailPath != nil, type: LibraryFileKind.type(of: item.filename))
                .frame(width: 48, height: 48)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.filename).lineLimit(2)
                HStack(spacing: 8) {
                    Text(Fmt.bytes(item.fileSize))
                    if let folder = item.folderName { Label(folder, systemImage: "folder").labelStyle(.titleAndIcon) }
                    if session.isAuthEnabled, let owner = item.createdByUsername { Label(owner, systemImage: "person") }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Deleted \(Fmt.relative(item.deletedAt))")
                    if let purge = item.autoPurgeAt { Text("· purged \(Fmt.relative(purge))").foregroundStyle(.orange) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        let client = session.client
        await loader.load { try await client.get("library/trash", query: ["limit": 500, "offset": 0]) }
        if isAdmin, settings == nil { settings = try? await client.get("library/trash/settings") }
    }

    private func restore(_ ids: [Int]) async {
        await runner.run(ids.count == 1 ? "File restored" : "Restored \(ids.count) files") {
            for id in ids { try await session.client.call(.post, "library/trash/\(id)/restore") }
        }
        selection = []
        editMode = .inactive
        await load()
    }

    private func purge(_ ids: [Int]) async {
        await runner.run(ids.count == 1 ? "File deleted" : "Deleted \(ids.count) files") {
            for id in ids { try await session.client.call(.delete, "library/trash/\(id)") }
        }
        selection = []
        editMode = .inactive
        await load()
    }

    private func emptyTrash() async {
        await runner.run {
            let result: LibraryEmptyTrashResult = try await session.client.send(.delete, "library/trash")
            runner.successMessage = "Deleted \(result.deleted ?? 0) files"
        }
        await load()
    }
}

/// Retention and auto-purge policy (requires `library:purge`).
struct LibraryTrashSettingsSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let initial: LibraryTrashSettings
    let onSaved: (LibraryTrashSettings) -> Void

    @State private var draft = LibraryTrashSettings(retentionDays: 30)
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Keep for \(draft.retentionDays) days", value: $draft.retentionDays, in: 1...365)
                } header: {
                    Text("Retention")
                } footer: {
                    Text("How long deleted files stay in the trash before they're permanently removed.")
                }
                Section {
                    Toggle("Auto-Purge Old Files", isOn: Binding(get: { draft.autoPurgeEnabled ?? false }, set: { draft.autoPurgeEnabled = $0 }))
                    if draft.autoPurgeEnabled == true {
                        Stepper("Older than \(draft.autoPurgeDays ?? 90) days",
                                value: Binding(get: { draft.autoPurgeDays ?? 90 }, set: { draft.autoPurgeDays = $0 }), in: 7...3650, step: 7)
                        Toggle("Include Never-Printed Files", isOn: Binding(get: { draft.autoPurgeIncludeNeverPrinted ?? true }, set: { draft.autoPurgeIncludeNeverPrinted = $0 }))
                    }
                } header: {
                    Text("Automatic Cleanup")
                } footer: {
                    Text("Periodically moves library files that haven't been printed recently into the trash.")
                }
            }
            .navigationTitle("Trash Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button("Save") {
                            Task {
                                await runner.run {
                                    var body = draft
                                    body.autoPurgeEnabled = body.autoPurgeEnabled ?? false
                                    body.autoPurgeDays = body.autoPurgeDays ?? 90
                                    body.autoPurgeIncludeNeverPrinted = body.autoPurgeIncludeNeverPrinted ?? true
                                    let saved: LibraryTrashSettings = try await session.client.send(.put, "library/trash/settings", body: body)
                                    onSaved(saved)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .actionAlerts(runner)
        }
        .onAppear { draft = initial }
    }
}

/// Moves files older than N days into the trash, with a live preview.
struct LibraryPurgeSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void

    @State private var days = 90
    @State private var includeNeverPrinted = true
    @State private var preview = Loader<LibraryPurgePreview>()
    @State private var runner = ActionRunner()
    @State private var confirming = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("Older than \(days) days", value: $days, in: 1...3650, step: days < 30 ? 1 : 30)
                    Toggle("Include Never-Printed Files", isOn: $includeNeverPrinted)
                } footer: {
                    Text("Files last printed before this period — and, if included, never-printed files uploaded before it — are moved to the trash. External folders are not affected.")
                }
                Section("Preview") {
                    if let p = preview.value {
                        LabeledContent("Files", value: "\(p.count)")
                        LabeledContent("Size", value: Fmt.bytes(p.totalBytes))
                        ForEach(p.sampleFilenames ?? [], id: \.self) { name in
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                        if let shown = p.sampleFilenames?.count, p.count > shown {
                            Text("…and \(p.count - shown) more").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let error = preview.error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                }
            }
            .navigationTitle("Purge Old Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button("Purge", role: .destructive) { confirming = true }
                            .disabled((preview.value?.count ?? 0) == 0)
                    }
                }
            }
            .confirm("Move \(preview.value?.count ?? 0) files to the trash?", isPresented: $confirming,
                     message: "They can be restored from the trash until the retention period ends.", action: "Move to Trash") {
                Task {
                    await runner.run {
                        let result: LibraryPurgeResult = try await session.client.send(.post, "library/purge", body: LibraryPurgeBody(olderThanDays: days, includeNeverPrinted: includeNeverPrinted))
                        runner.successMessage = "Moved \(result.movedToTrash ?? 0) files to the trash"
                        onDone()
                        try? await Task.sleep(for: .seconds(1))
                        dismiss()
                    }
                }
            }
            .actionAlerts(runner)
        }
        .task(id: "\(days)-\(includeNeverPrinted)") {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let d = days, inc = includeNeverPrinted
            await preview.load { try await session.client.get("library/purge/preview", query: ["older_than_days": .int(d), "include_never_printed": .bool(inc)]) }
        }
    }
}
