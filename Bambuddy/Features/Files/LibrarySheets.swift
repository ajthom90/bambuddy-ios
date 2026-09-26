import SwiftUI

// Small editing sheets used by the file manager: names, folder pickers,
// links, external folders, projects, tags and notes.

// MARK: Name editing

/// Edits a name. For files the extension is shown but not editable.
struct LibraryNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let actionTitle: String
    var fieldLabel: String = "Name"
    let initial: String
    var suffix: String = ""
    var validateFilename = false
    let onSave: (String) async throws -> Void

    @State private var name = ""
    @State private var error: String?
    @State private var saving = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var invalidChar: Character? { validateFilename ? LibraryFileKind.invalidCharacter(in: trimmed) : nil }
    private var canSave: Bool { !trimmed.isEmpty && invalidChar == nil && trimmed != initial && !saving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 4) {
                        TextField(fieldLabel, text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit { if canSave { Task { await save() } } }
                        if !suffix.isEmpty {
                            Text(suffix).foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if let invalidChar {
                        Text("File names can't contain “\(String(invalidChar))”.").foregroundStyle(.red)
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button(actionTitle) { Task { await save() } }.disabled(!canSave)
                    }
                }
            }
        }
        .onAppear { name = initial }
        .presentationDetents([.medium])
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            try await onSave(trimmed)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Folder picker

/// Picks a destination folder (or the root). Used for moving files and folders
/// and for choosing an import target.
struct LibraryFolderPickerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let title: String
    var actionTitle: String = "Move"
    var current: Int?
    var excluded: Set<Int> = []
    var rootLabel: String = "Library (no folder)"
    let onPick: (Int?) async throws -> Void

    @State private var loader = Loader<[LibraryFolderNode]>()
    @State private var selection: Int? = nil
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { folders in
                List {
                    if let error {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                    Section {
                        row(id: nil) {
                            Label(rootLabel, systemImage: "tray.full")
                        }
                    }
                    let flat = LibraryFolderTree.flatten(folders)
                    if !flat.isEmpty {
                        Section("Folders") {
                            ForEach(flat) { entry in
                                row(id: entry.id, disabled: excluded.contains(entry.id) || entry.node.readOnly) {
                                    LibraryFolderLabel(node: entry.node)
                                        .padding(.leading, CGFloat(entry.depth) * 16)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button(actionTitle) { Task { await pick() } }.disabled(selection == current)
                    }
                }
            }
        }
        .task { selection = current; await load() }
    }

    @ViewBuilder
    private func row<L: View>(id: Int?, disabled: Bool = false, @ViewBuilder label: () -> L) -> some View {
        Button { selection = id } label: {
            HStack {
                label()
                Spacer()
                if id == current {
                    Text("Current").font(.caption).foregroundStyle(.secondary)
                }
                if selection == id {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private func load() async {
        await loader.load { try await LibraryAPI.folders(session.client) }
    }

    private func pick() async {
        saving = true
        defer { saving = false }
        do {
            try await onPick(selection)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: Link folder to project / archive

struct LibraryFolderLinkSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let folder: LibraryFolderNode
    let onDone: () -> Void

    private enum Kind: String, CaseIterable, Identifiable { case project = "Project", archive = "Archive"; var id: String { rawValue } }

    @State private var kind: Kind = .project
    @State private var selected: Int?
    @State private var projects = Loader<[LibraryProjectOption]>()
    @State private var archives = Loader<[LibraryArchiveOption]>()
    @State private var runner = ActionRunner()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Link to", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                switch kind {
                case .project:
                    LoadingContent(loader: projects) { rows in
                        let visible = rows
                            .filter { $0.status != "archived" || $0.id == folder.projectId }
                            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        if visible.isEmpty {
                            Text("No projects found").foregroundStyle(.secondary)
                        }
                        ForEach(visible) { p in
                            choice(id: p.id) {
                                HStack {
                                    Circle().fill(Color(hex: p.color) ?? .accentColor).frame(width: 10, height: 10)
                                    Text(p.name)
                                }
                            }
                        }
                    }
                case .archive:
                    LoadingContent(loader: archives) { rows in
                        let visible = rows.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
                        if visible.isEmpty {
                            Text("No archives found").foregroundStyle(.secondary)
                        }
                        ForEach(visible) { a in
                            choice(id: a.id) { Text(a.displayName) }
                        }
                    }
                }
                if folder.isLinked {
                    Section {
                        Button("Remove Link", role: .destructive) {
                            Task { await save(projectId: 0, archiveId: 0) }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Link “\(folder.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button("Link") {
                            Task {
                                if kind == .project { await save(projectId: selected, archiveId: 0) }
                                else { await save(projectId: 0, archiveId: selected) }
                            }
                        }
                        .disabled(selected == nil)
                    }
                }
            }
            .actionAlerts(runner)
        }
        .onChange(of: kind) { _, _ in selected = nil }
        .task {
            if folder.archiveId != nil { kind = .archive; selected = folder.archiveId } else { selected = folder.projectId }
            async let p: Void = projects.load { try await session.client.get("projects/") }
            async let a: Void = archives.load { try await session.client.get("archives/", query: ["limit": 100]) }
            _ = await (p, a)
        }
    }

    private func choice<L: View>(id: Int, @ViewBuilder label: () -> L) -> some View {
        Button { selected = id } label: {
            HStack {
                label()
                Spacer()
                if selected == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func save(projectId: Int?, archiveId: Int?) async {
        await runner.run {
            let body = LibraryFolderUpdateBody(projectId: projectId, archiveId: archiveId)
            let _: LibraryFolderInfo = try await session.client.send(.put, "library/folders/\(folder.id)", body: body)
            onDone()
            dismiss()
        }
    }
}

// MARK: External folder

struct LibraryExternalFolderSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var parentId: Int?
    let onCreated: (LibraryFolderInfo) -> Void

    @State private var name = ""
    @State private var path = ""
    @State private var readOnly = true
    @State private var showHidden = false
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("/mnt/nas/3d-prints", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    Text("An absolute path on the Bambuddy server (for example a mounted NAS share). Files there are indexed in place, not copied.")
                }
                Section {
                    Toggle("Read Only", isOn: $readOnly)
                    Toggle("Show Hidden Files", isOn: $showHidden)
                } footer: {
                    Text("Read-only folders can't receive uploads, renames or deletions.")
                }
            }
            .navigationTitle("Link External Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button("Link") { Task { await save() } }
                            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || path.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .actionAlerts(runner)
        }
    }

    private func save() async {
        await runner.run {
            let body = LibraryExternalFolderBody(
                name: name.trimmingCharacters(in: .whitespaces),
                externalPath: path.trimmingCharacters(in: .whitespaces),
                readonly: readOnly, showHidden: showHidden, parentId: parentId)
            let folder: LibraryFolderInfo = try await session.client.send(.post, "library/folders/external", body: body)
            // Index the new folder right away so its files show up.
            _ = try? await session.client.send(.post, "library/folders/\(folder.id)/scan", as: LibraryScanResult.self)
            onCreated(folder)
            dismiss()
        }
    }
}

// MARK: Project picker

/// Assigns one or more files to a project (or removes the assignment).
struct LibraryProjectPickerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let fileIds: [Int]
    var currentProjectId: Int?
    let onDone: () -> Void

    @State private var loader = Loader<[LibraryProjectOption]>()
    @State private var runner = ActionRunner()
    @State private var search = ""

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { rows in
                let visible = rows
                    .filter { $0.status != "archived" || $0.id == currentProjectId }
                    .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                List {
                    if currentProjectId != nil {
                        Section {
                            Button("Remove from Project", role: .destructive) { Task { await assign(0) } }
                        }
                    }
                    Section {
                        if visible.isEmpty {
                            Text("No projects").foregroundStyle(.secondary)
                        }
                        ForEach(visible) { p in
                            Button { Task { await assign(p.id) } } label: {
                                HStack {
                                    Circle().fill(Color(hex: p.color) ?? .accentColor).frame(width: 10, height: 10)
                                    Text(p.name).foregroundStyle(.primary)
                                    Spacer()
                                    if p.id == currentProjectId { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    }
                }
                .searchable(text: $search)
            }
            .disabled(runner.isRunning)
            .overlay { if runner.isRunning { ProgressView() } }
            .navigationTitle(fileIds.count == 1 ? "Add to Project" : "Add \(fileIds.count) Files to Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .actionAlerts(runner)
        }
        .task { await load() }
    }

    private func load() async {
        await loader.load { try await session.client.get("projects/") }
    }

    private func assign(_ projectId: Int) async {
        await runner.run {
            for id in fileIds {
                let _: LibraryFileDetail = try await session.client.send(.put, "library/files/\(id)", body: LibraryFileUpdateBody(projectId: projectId))
            }
            onDone()
            dismiss()
        }
    }
}

// MARK: Tags

/// Adds, removes or replaces tags on one or more files.
struct LibraryTagAssignSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let fileIds: [Int]
    var currentTags: [LibraryTagRef] = []
    let onDone: () -> Void

    private enum Mode: String, CaseIterable, Identifiable { case add = "Add", remove = "Remove", replace = "Replace"; var id: String { rawValue } }

    @State private var catalog = Loader<[LibraryTag]>()
    @State private var chosen: Set<Int> = []
    @State private var mode: Mode = .replace
    @State private var newTag = ""
    @State private var runner = ActionRunner()

    private var isSingle: Bool { fileIds.count == 1 }

    var body: some View {
        NavigationStack {
            LoadingContent(loader: catalog, retry: load) { tags in
                Form {
                    if !isSingle {
                        Section {
                            Picker("Action", selection: $mode) {
                                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        } footer: {
                            switch mode {
                            case .add: Text("Selected tags are added to all \(fileIds.count) files.")
                            case .remove: Text("Selected tags are removed from all \(fileIds.count) files.")
                            case .replace: Text("All \(fileIds.count) files end up with exactly the selected tags.")
                            }
                        }
                    }
                    Section("Tags") {
                        if tags.isEmpty {
                            Text("No tags yet. Create one below.").foregroundStyle(.secondary)
                        }
                        ForEach(tags) { tag in
                            Button {
                                if chosen.contains(tag.id) { chosen.remove(tag.id) } else { chosen.insert(tag.id) }
                            } label: {
                                HStack {
                                    Label(tag.name, systemImage: "tag").foregroundStyle(.primary)
                                    Spacer()
                                    if chosen.contains(tag.id) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                        }
                    }
                    Section {
                        HStack {
                            TextField("New tag", text: $newTag).onSubmit { Task { await create() } }
                            Button("Create") { Task { await create() } }
                                .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .navigationTitle(isSingle ? "Tags" : "Tag \(fileIds.count) Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button("Save") { Task { await save() } }
                            .disabled(!isSingle && mode != .replace && chosen.isEmpty)
                    }
                }
            }
            .actionAlerts(runner)
        }
        .task {
            if isSingle { chosen = Set(currentTags.map(\.id)) }
            await load()
        }
    }

    private func load() async {
        await catalog.load { try await LibraryAPI.tags(session.client) }
    }

    private func create() async {
        let name = newTag.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await runner.run {
            let tag: LibraryTag = try await session.client.send(.post, "library/tags", body: LibraryTagNameBody(name: name))
            newTag = ""
            chosen.insert(tag.id)
            await load()
        }
    }

    private func save() async {
        await runner.run {
            let body = LibraryTagAssignBody(fileIds: fileIds, tagIds: Array(chosen), action: isSingle ? "replace" : mode.rawValue.lowercased())
            let _: LibraryTagAssignResult = try await session.client.send(.post, "library/tags/bulk-assign", body: body)
            onDone()
            dismiss()
        }
    }
}

/// Manages the tag catalog: create, rename, delete.
struct LibraryTagManagerSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void

    @State private var loader = Loader<[LibraryTag]>()
    @State private var runner = ActionRunner()
    @State private var newTag = ""
    @State private var renaming: LibraryTag?
    @State private var renameText = ""
    @State private var deleting: LibraryTag?

    private var canEdit: Bool { LibraryAccess.canUpdateAny(session) }

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { tags in
                List {
                    if canEdit {
                        Section {
                            HStack {
                                TextField("New tag", text: $newTag).onSubmit { Task { await create() } }
                                Button("Add") { Task { await create() } }
                                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    }
                    Section {
                        if tags.isEmpty {
                            Text("No tags").foregroundStyle(.secondary)
                        }
                        ForEach(tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { tag in
                            HStack {
                                Label(tag.name, systemImage: "tag")
                                Spacer()
                                Text("\(tag.fileCount ?? 0) files").font(.caption).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                if canEdit {
                                    Button("Delete", role: .destructive) { deleting = tag }
                                    Button("Rename") { renameText = tag.name; renaming = tag }.tint(.orange)
                                }
                            }
                            .contextMenu {
                                if canEdit {
                                    Button("Rename", systemImage: "pencil") { renameText = tag.name; renaming = tag }
                                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = tag }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename Tag", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    if let tag = renaming { Task { await rename(tag) } }
                }
            }
            .confirm("Delete tag “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                     message: "The tag is removed from every file that carries it.") {
                if let tag = deleting { Task { await delete(tag) } }
            }
            .actionAlerts(runner)
        }
        .task { await load() }
    }

    private func load() async {
        await loader.load { try await LibraryAPI.tags(session.client) }
    }

    private func create() async {
        let name = newTag.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        await runner.run {
            let _: LibraryTag = try await session.client.send(.post, "library/tags", body: LibraryTagNameBody(name: name))
            newTag = ""
            await load(); onChange()
        }
    }

    private func rename(_ tag: LibraryTag) async {
        let name = renameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != tag.name else { return }
        await runner.run {
            let _: LibraryTag = try await session.client.send(.patch, "library/tags/\(tag.id)", body: LibraryTagNameBody(name: name))
            await load(); onChange()
        }
    }

    private func delete(_ tag: LibraryTag) async {
        await runner.run {
            try await session.client.call(.delete, "library/tags/\(tag.id)")
            await load(); onChange()
        }
    }
}

// MARK: Notes

struct LibraryNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let initial: String
    let onSave: (String) async throws -> Void

    @State private var text = ""
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal)
                .navigationTitle("Notes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if runner.isRunning { ProgressView() } else {
                            Button("Save") {
                                Task { await runner.run { try await onSave(text); dismiss() } }
                            }
                        }
                    }
                }
                .actionAlerts(runner)
        }
        .onAppear { text = initial }
    }
}
