import SwiftUI

/// Detail for one library file: metadata, plates, filaments, tags, notes,
/// duplicates, versions, and every file action.
struct LibraryFileDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(\.dismiss) private var dismiss
    let fileId: Int

    @State private var loader = Loader<LibraryFileDetail>()
    @State private var plates: LibraryPlatesResponse?
    @State private var summary: LibraryFileSummary?
    @State private var variantGroup: LibraryVariantGroup?
    @State private var settings: LibraryServerSettings?
    @State private var actions = LibraryFileActions()
    @State private var runner = ActionRunner()
    @State private var editingNotes = false
    @State private var showRawMetadata = false
    @State private var ungroupConfirm = false

    var body: some View {
        LoadingContent(loader: loader, retry: load) { file in
            let ref = LibraryFileRef(file, tags: summary?.tags ?? [], variantGroupId: variantGroup?.id ?? summary?.variantGroupId)
            List {
                headerSection(file, ref: ref)
                actionSection(ref)
                detailsSection(file)
                printSettingsSection(file)
                platesSection(file)
                tagsSection(ref)
                notesSection(file)
                locationSection(file)
                duplicatesSection(file)
                versionsSection(file)
                rawMetadataSection(file)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        LibraryFileMenuItems(file: ref, actions: actions, useSlicerApi: settings?.useSlicerApi ?? false, reload: load)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $editingNotes) {
                LibraryNotesSheet(initial: file.notes ?? "") { text in
                    let updated: LibraryFileDetail = try await session.client.send(.put, "library/files/\(file.id)", body: LibraryFileUpdateBody(notes: text))
                    loader.value = updated
                }
            }
        }
        .navigationTitle(loader.value?.displayName ?? "File")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: live.revision("print_complete", "archive_created")) { await load() }
        .modifier(LibraryFileActionsPresenter(actions: actions, reload: load, onDeleted: { ids in
            if ids.contains(fileId) { dismiss() }
        }))
        .confirm("Ungroup these versions?", isPresented: $ungroupConfirm, message: "The files stay in the library; they're just no longer treated as versions of the same job.", action: "Ungroup") {
            Task { await ungroup() }
        }
        .actionAlerts(runner)
    }

    // MARK: Sections

    private func headerSection(_ file: LibraryFileDetail, ref: LibraryFileRef) -> some View {
        Section {
            VStack(spacing: 12) {
                let platePics = (plates?.plates ?? []).filter { $0.hasThumbnail == true && $0.thumbnailUrl != nil }
                if platePics.count > 1 {
                    TabView {
                        ForEach(platePics) { plate in
                            RemoteImage(path: plate.thumbnailUrl, contentMode: .fit, systemImage: "cube")
                                .overlay(alignment: .bottomLeading) {
                                    Text("Plate \(plate.index)").font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.ultraThinMaterial, in: .capsule).padding(8)
                                }
                        }
                    }
                    .tabViewStyle(.page)
                    .frame(height: 260)
                } else {
                    LibraryFileThumbnail(fileId: file.id, hasThumbnail: file.thumbnailPath != nil, type: file.type,
                                         version: actions.thumbnailVersions[file.id] ?? 0)
                        .frame(maxWidth: 320, maxHeight: 260)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 14))
                }
                VStack(spacing: 4) {
                    Text(file.displayName).font(.title3.bold()).multilineTextAlignment(.center)
                    if file.displayName != file.filename {
                        Text(file.filename).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    HStack(spacing: 6) {
                        LibraryTypeBadge(type: file.type)
                        if file.isSliced { StatusBadge(text: "READY TO PRINT", color: .blue) }
                        if file.isExternal == true { StatusBadge(text: "EXTERNAL", color: .purple) }
                        if let n = file.printCount, n > 0 { StatusBadge(text: "PRINTED \(n)×", color: .green) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func actionSection(_ ref: LibraryFileRef) -> some View {
        let useApi = settings?.useSlicerApi ?? false
        Section {
            HStack(spacing: 10) {
                if ref.isSliced {
                    actionButton("Print", "printer.fill", prominent: true) { actions.sheet = .print(ref, .printNow) }
                        .disabled(!session.can("queue:create"))
                    actionButton("Queue", "text.badge.plus") { actions.sheet = .print(ref, .addToQueue) }
                        .disabled(!session.can("queue:create"))
                } else if useApi && ref.isSliceable {
                    actionButton("Slice", "gearshape.2.fill", prominent: true) { actions.sheet = .slice(ref) }
                        .disabled(!session.can("library:upload"))
                }
                if ref.isMesh {
                    actionButton("3D View", "cube.transparent") { actions.sheet = .preview3d(ref) }
                }
                actionButton(actions.downloadingId == ref.id ? "Loading…" : "Share", "square.and.arrow.up") {
                    Task { await actions.share(ref, client: session.client) }
                }
                .disabled(actions.downloadingId != nil || !LibraryAccess.canRead(session))
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private func actionButton(_ title: String, _ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? .accentColor : .secondary)
    }

    private func detailsSection(_ file: LibraryFileDetail) -> some View {
        Section("Details") {
            InfoRow("Size", Fmt.bytes(file.fileSize), systemImage: "internaldrive")
            if let t = file.printTimeSeconds, t > 0 {
                InfoRow("Print Time", Fmt.duration(seconds: t), systemImage: "clock")
            }
            if let g = file.filamentUsedGrams, g > 0 {
                InfoRow("Filament", Fmt.grams(g), systemImage: "scalemass")
            }
            if let model = file.slicedForModel, !model.isEmpty {
                InfoRow("Sliced For", model, systemImage: "printer")
            }
            InfoRow("Prints", "\(file.printCount ?? 0)", systemImage: "number")
            if let last = file.lastPrintedAt {
                InfoRow("Last Printed", Fmt.date(last), systemImage: "calendar.badge.clock")
            }
            if let owner = file.createdByUsername {
                InfoRow("Uploaded By", owner, systemImage: "person")
            }
            InfoRow("Added", Fmt.date(file.createdAt), systemImage: "calendar")
            if let updated = file.updatedAt, updated != file.createdAt {
                InfoRow("Updated", Fmt.date(updated), systemImage: "pencil")
            }
            if let hash = file.fileHash {
                InfoRow("Hash", String(hash.prefix(16)) + "…", systemImage: "number.square")
            }
        }
    }

    @ViewBuilder
    private func printSettingsSection(_ file: LibraryFileDetail) -> some View {
        let meta = file.metadata
        let rows = settingRows(meta)
        let colors = splitList(meta?["filament_color"]?.stringValue)
        if !rows.isEmpty || !colors.isEmpty {
            Section("Print Settings") {
                ForEach(rows, id: \.0) { row in
                    InfoRow(row.0, row.1)
                }
                if !colors.isEmpty {
                    LabeledContent("Colors") {
                        HStack(spacing: 4) {
                            ForEach(Array(colors.enumerated()), id: \.offset) { _, hex in ColorSwatch(hex: hex, size: 18) }
                        }
                    }
                }
                if let link = meta?["makerworld_url"]?.stringValue, let url = URL(string: link) {
                    Link(destination: url) { Label("View on MakerWorld", systemImage: "globe") }
                }
            }
        }
    }

    private func settingRows(_ meta: JSONValue?) -> [(String, String)] {
        guard let meta else { return [] }
        var rows: [(String, String)] = []
        func add(_ label: String, _ key: String, unit: String = "") {
            if let v = meta[key], !v.isNull, let s = v.stringValue, !s.isEmpty { rows.append((label, s + unit)) }
        }
        add("Filament Type", "filament_type")
        add("Layer Height", "layer_height", unit: " mm")
        add("Nozzle", "nozzle_diameter", unit: " mm")
        add("Nozzle Temperature", "nozzle_temperature", unit: " °C")
        add("Bed Temperature", "bed_temperature", unit: " °C")
        add("Build Plate", "bed_type")
        add("Layers", "total_layers")
        if let mm = meta["filament_used_mm"]?.doubleValue, mm > 0 {
            rows.append(("Filament Length", String(format: "%.2f m", mm / 1000)))
        }
        if let objects = meta["printable_objects"] {
            if let count = objects.arrayValue?.count ?? objects.objectValue?.count ?? objects.intValue, count > 0 {
                rows.append(("Objects", "\(count)"))
            }
        }
        add("Designer", "designer")
        return rows
    }

    private func splitList(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        return raw.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @ViewBuilder
    private func platesSection(_ file: LibraryFileDetail) -> some View {
        if let list = plates?.plates, !list.isEmpty {
            Section {
                ForEach(list) { plate in
                    LibraryPlateRow(plate: plate)
                }
            } header: {
                Text(list.count == 1 ? "Plate" : "\(list.count) Plates")
            } footer: {
                if let printer = plates?.embeddedPrinter {
                    Text("Prepared for \(printer)\(plates?.embeddedProcess.map { " · \($0)" } ?? "")")
                }
            }
        }
    }

    @ViewBuilder
    private func tagsSection(_ ref: LibraryFileRef) -> some View {
        let canEdit = LibraryAccess.canUpdate(session, ownerId: ref.ownerId)
        if !ref.tags.isEmpty || canEdit {
            Section("Tags") {
                if ref.tags.isEmpty {
                    Text("No tags").foregroundStyle(.secondary)
                } else {
                    LibraryTagChips(tags: ref.tags)
                }
                if canEdit {
                    Button("Edit Tags…", systemImage: "tag") { actions.sheet = .tags([ref]) }
                }
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ file: LibraryFileDetail) -> some View {
        let canEdit = LibraryAccess.canUpdate(session, ownerId: file.createdById)
        if (file.notes?.isEmpty == false) || canEdit {
            Section("Notes") {
                if let notes = file.notes, !notes.isEmpty {
                    Text(notes).textSelection(.enabled)
                }
                if canEdit {
                    Button(file.notes?.isEmpty == false ? "Edit Notes…" : "Add Notes…", systemImage: "note.text") { editingNotes = true }
                }
            }
        }
    }

    private func locationSection(_ file: LibraryFileDetail) -> some View {
        Section("Location") {
            if let folderId = file.folderId {
                NavigationLink(value: LibraryRoute.browse(.folder(folderId))) {
                    Label(file.folderName ?? "Folder", systemImage: file.isExternal == true ? "externaldrive.connected.to.line.below" : "folder")
                }
            } else {
                Label("Library (no folder)", systemImage: "tray.full")
            }
            if let project = file.projectName ?? file.projectId.map({ "Project #\($0)" }) {
                Label(project, systemImage: "briefcase")
            }
            if LibraryAccess.canUpdate(session, ownerId: file.createdById) {
                Button(file.projectId == nil ? "Add to Project…" : "Change Project…", systemImage: "briefcase") {
                    actions.sheet = .project([LibraryFileRef(file)])
                }
            }
        }
    }

    @ViewBuilder
    private func duplicatesSection(_ file: LibraryFileDetail) -> some View {
        if let dups = file.duplicates, !dups.isEmpty {
            Section {
                ForEach(dups) { dup in
                    NavigationLink(value: LibraryRoute.file(dup.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dup.filename ?? "File #\(dup.id)")
                            Text([dup.folderName ?? "No folder", Fmt.date(dup.createdAt)].joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Duplicates")
            } footer: {
                Text("Files with identical contents elsewhere in the library.")
            }
        }
    }

    @ViewBuilder
    private func versionsSection(_ file: LibraryFileDetail) -> some View {
        if let group = variantGroup, let members = group.members, !members.isEmpty {
            let canEdit = LibraryAccess.canUpdateAny(session)
            Section {
                ForEach(members.sorted { ($0.position ?? 0) < ($1.position ?? 0) }) { member in
                    Group {
                        if member.libraryFileId == file.id {
                            memberLabel(member, current: true)
                        } else {
                            NavigationLink(value: LibraryRoute.file(member.libraryFileId)) { memberLabel(member, current: false) }
                        }
                    }
                    .swipeActions {
                        if canEdit {
                            Button("Remove", role: .destructive) { Task { await removeMember(group: group, fileId: member.libraryFileId) } }
                        }
                    }
                }
                if canEdit {
                    Button("Ungroup Versions", systemImage: "square.stack.3d.up.slash", role: .destructive) { ungroupConfirm = true }
                }
            } header: {
                Text(group.name.map { "Versions · \($0)" } ?? "Versions")
            } footer: {
                Text("The same job sliced for different printers. Printing offers whichever version matches the printer.")
            }
        }
    }

    private func memberLabel(_ member: LibraryVariantMember, current: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.filename ?? "File #\(member.libraryFileId)")
                if let model = member.targetModel { Label(model, systemImage: "printer").font(.caption).foregroundStyle(.secondary) }
            }
            if current {
                Spacer()
                Text("This File").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func rawMetadataSection(_ file: LibraryFileDetail) -> some View {
        if let meta = file.metadata?.objectValue, !meta.isEmpty {
            Section {
                DisclosureGroup("All Metadata", isExpanded: $showRawMetadata) {
                    ForEach(meta.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(meta[key]?.displayString ?? "—").font(.callout).lineLimit(6).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    // MARK: Networking

    private func load() async {
        let client = session.client
        await loader.load { try await client.get("library/files/\(fileId)") }
        guard let file = loader.value else { return }
        if settings == nil { settings = await LibraryAPI.settings(client) }
        if file.filename.lowercased().hasSuffix(".3mf") {
            plates = try? await client.get("library/files/\(fileId)/plates")
        }
        // Tags and version info only come with list rows, so look the file up in its folder.
        var query: [String: QueryValue?] = [:]
        if let folder = file.folderId { query["folder_id"] = .int(folder); query["include_root"] = false } else { query["include_root"] = true }
        if let rows: [LibraryFileSummary] = try? await client.get("library/files", query: query) {
            summary = rows.first { $0.id == fileId }
        }
        variantGroup = try? await client.get("library/variant-groups/by-file/\(fileId)")
    }

    private func removeMember(group: LibraryVariantGroup, fileId member: Int) async {
        await runner.run("Removed from versions") {
            try await session.client.call(.delete, "library/variant-groups/\(group.id)/members/\(member)")
            await load()
        }
    }

    private func ungroup() async {
        guard let group = variantGroup else { return }
        await runner.run("Versions ungrouped") {
            try await session.client.call(.delete, "library/variant-groups/\(group.id)")
            variantGroup = nil
            await load()
        }
    }
}

/// One plate of a multi-plate 3MF.
private struct LibraryPlateRow: View {
    let plate: LibraryPlate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(path: plate.hasThumbnail == true ? plate.thumbnailUrl : nil, contentMode: .fit, systemImage: "square.grid.3x3")
                .frame(width: 72, height: 72)
                .background(Color(.secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("Plate \(plate.index)\(plate.name.map { " · \($0)" } ?? "")").font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 10) {
                    if let t = plate.printTimeSeconds, t > 0 { Label(Fmt.duration(seconds: t), systemImage: "clock") }
                    if let g = plate.filamentUsedGrams, g > 0 { Label(Fmt.grams(g), systemImage: "scalemass") }
                    if let n = plate.objectCount ?? plate.objects?.count, n > 0 { Label("\(n)", systemImage: "cube") }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let filaments = plate.filaments, !filaments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(filaments.enumerated()), id: \.offset) { _, f in
                                HStack(spacing: 4) {
                                    ColorSwatch(hex: f.color, size: 14)
                                    Text([f.type, f.usedGrams.map { Fmt.grams($0) }].compactMap { $0 }.joined(separator: " "))
                                }
                                .font(.caption2)
                            }
                        }
                    }
                }
                if let objects = plate.objects, !objects.isEmpty {
                    Text(objects.prefix(4).joined(separator: ", ") + (objects.count > 4 ? "…" : ""))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
