import SwiftUI

struct MakerWorldRootView: View {
    var body: some View {
        NavigationStack {
            MakerWorldImportView()
                .modifier(LibraryNavigationDestinations())
        }
    }
}

/// Paste a MakerWorld link, review the model and its plates, and import them
/// into the library.
private struct MakerWorldImportView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL

    @State private var status: MakerWorldStatus?
    @State private var recent = Loader<[MakerWorldRecentImport]>()
    @State private var folders: [LibraryFolderNode] = []
    @State private var settings: LibraryServerSettings?
    @State private var urlText = ""
    @State private var resolvedFor = ""
    @State private var resolved: MakerWorldResolvedModel?
    @State private var summaryText: String?
    @State private var resolving = false
    @State private var resolveError: String?
    @State private var folderId: Int?
    @State private var importing: Set<Int> = []
    @State private var importStarted: Date?
    @State private var imports: [Int: MakerWorldImportResult] = [:]
    @State private var bulkProgress: (current: Int, total: Int)?
    @State private var gallery: MakerWorldGallery?
    @State private var pendingDelete: (instanceId: Int, result: MakerWorldImportResult)?
    @State private var actions = LibraryFileActions()
    @State private var runner = ActionRunner()
    @FocusState private var urlFocused: Bool

    private var canImport: Bool { session.can("makerworld:import") }
    private var canDownload: Bool { status?.canDownload ?? false }
    private var useSlicerApi: Bool { settings?.useSlicerApi ?? false }
    private var busy: Bool { !importing.isEmpty || bulkProgress != nil }

    var body: some View {
        List {
            if let status, status.canDownload != true {
                signInBanner(expired: status.signInExpired == true)
            }
            urlSection
            if let model = resolved {
                modelSection(model)
                platesSection(model)
            }
            recentSection
            Section {
            } footer: {
                Text("MakerWorld is a Bambu Lab service. Models are downloaded with the Bambu Cloud account signed in on the server and remain subject to their creators' licenses.")
            }
        }
        .navigationTitle("MakerWorld")
        .refreshable { await loadAll() }
        .task { await loadAll() }
        .onChange(of: urlText) { _, new in
            if resolved != nil && new.trimmingCharacters(in: .whitespacesAndNewlines) != resolvedFor {
                resolved = nil; summaryText = nil; imports = [:]
            }
        }
        .fullScreenCover(item: $gallery) { g in MakerWorldGalleryView(gallery: g) }
        .confirmationDialog("Delete imported file?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                if let pending = pendingDelete { Task { await deleteImport(instanceId: pending.instanceId, result: pending.result) } }
            }
        } message: {
            Text(pendingDelete?.result.filename ?? "")
        }
        .modifier(LibraryFileActionsPresenter(actions: actions, reload: { await loadRecent() }))
        .actionAlerts(runner)
        #if DEBUG
        .onAppear {
            if let url = UserDefaults.standard.string(forKey: "makerworldURL"), urlText.isEmpty { urlText = url }
        }
        #endif
    }

    // MARK: Sections

    private func signInBanner(expired: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(expired ? "Bambu Cloud Sign-In Expired" : "Bambu Cloud Sign-In Required", systemImage: "exclamationmark.icloud.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(expired
                     ? "The server's Bambu Cloud session was rejected. Sign in again (Profiles › Cloud) to download models."
                     : "You can browse models, but downloading 3MF files needs a Bambu Cloud account signed in on the server (Profiles › Cloud).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var urlSection: some View {
        Section {
            HStack {
                TextField("https://makerworld.com/en/models/…", text: $urlText)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($urlFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await resolve() } }
                if !urlText.isEmpty {
                    Button { urlText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    urlText = first
                    Task { await resolve() }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                Spacer()
                Button {
                    Task { await resolve() }
                } label: {
                    if resolving { ProgressView() } else { Label("Look Up", systemImage: "arrow.right.circle.fill") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || resolving)
            }
            if let resolveError {
                Label(resolveError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Model Link")
        } footer: {
            Text("Paste a MakerWorld model URL to see its plates and import them into your library.")
        }
    }

    @ViewBuilder
    private func modelSection(_ model: MakerWorldResolvedModel) -> some View {
        Section {
            if let cover = MakerWorldMedia.proxied(model.coverURL, client: session.client) {
                RemoteImage(path: cover, contentMode: .fit, systemImage: "photo")
                    .frame(maxWidth: .infinity, maxHeight: 280)
                    .clipShape(.rect(cornerRadius: 12))
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(model.title ?? "Untitled Model").font(.title3.bold())
                if let creator = model.creatorName {
                    Label("by \(creator)", systemImage: "person.crop.circle").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if let n = model.downloadCount { Label(n.formatted(), systemImage: "arrow.down.circle") }
                    if let n = model.likeCount { Label(n.formatted(), systemImage: "heart") }
                    if let n = model.printCount { Label(n.formatted(), systemImage: "printer") }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if let license = model.license { StatusBadge(text: license, color: .secondary) }
                    if !(model.alreadyImportedLibraryIds ?? []).isEmpty { StatusBadge(text: "ALREADY IMPORTED", color: .green) }
                }
            }
            if let summaryText, !summaryText.isEmpty {
                DisclosureGroup("Description") {
                    Text(summaryText).font(.callout).textSelection(.enabled)
                }
            }
            if !model.tags.isEmpty {
                Text(model.tags.prefix(12).map { "#\($0)" }.joined(separator: "  ")).font(.caption).foregroundStyle(.secondary)
            }
            if let ids = model.alreadyImportedLibraryIds, !ids.isEmpty {
                ForEach(ids, id: \.self) { id in
                    NavigationLink(value: LibraryRoute.file(id)) {
                        Label("Open Imported File #\(id)", systemImage: "doc.fill")
                    }
                }
            }
            if let url = model.webURL {
                Link(destination: url) { Label("Open on MakerWorld", systemImage: "safari") }
            }
        }
    }

    @ViewBuilder
    private func platesSection(_ model: MakerWorldResolvedModel) -> some View {
        let plates = model.plates
        Section {
            if plates.isEmpty {
                Text("This model has no downloadable plates.").foregroundStyle(.secondary)
            }
            Picker("Import To", selection: $folderId) {
                Text("MakerWorld (automatic)").tag(Int?.none)
                ForEach(LibraryFolderTree.flatten(folders).filter { !$0.node.readOnly }) { entry in
                    Text(String(repeating: "  ", count: entry.depth) + entry.node.name).tag(Int?.some(entry.id))
                }
            }
            .disabled(busy)
            if plates.count > 1 {
                Button {
                    Task { await importAll(model) }
                } label: {
                    if let bulkProgress {
                        HStack {
                            ProgressView()
                            Text("Importing \(bulkProgress.current) of \(bulkProgress.total)…")
                            elapsedText
                        }
                    } else {
                        Label("Import All Plates", systemImage: "square.and.arrow.down.on.square")
                    }
                }
                .disabled(!canImport || !canDownload || busy || plates.allSatisfy { imports[$0.id] != nil })
            }
            ForEach(Array(plates.enumerated()), id: \.element.id) { index, plate in
                plateRow(plate, index: index, model: model)
            }
        } header: {
            Text(plates.count == 1 ? "1 Plate" : "\(plates.count) Plates")
        }
    }

    private var elapsedText: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let start = importStarted {
                let secs = Int(context.date.timeIntervalSince(start))
                Text(secs < 1 ? "Resolving…" : "Downloading · \(secs)s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func plateRow(_ plate: MakerWorldInstance, index: Int, model: MakerWorldResolvedModel) -> some View {
        let result = imports[plate.id]
        let isImporting = importing.contains(plate.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if !plate.pictures.isEmpty { gallery = MakerWorldGallery(title: plate.title ?? "Plate \(index + 1)", pictures: plate.pictures) }
                } label: {
                    RemoteImage(path: MakerWorldMedia.proxied(plate.cover ?? plate.pictures.first?.url, client: session.client), contentMode: .fill, systemImage: "cube")
                        .frame(width: 76, height: 76)
                        .clipShape(.rect(cornerRadius: 8))
                        .overlay(alignment: .bottomTrailing) {
                            if plate.pictures.count > 1 {
                                Label("\(plate.pictures.count)", systemImage: "photo.on.rectangle")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.black.opacity(0.6), in: .capsule)
                                    .foregroundStyle(.white)
                                    .padding(3)
                            }
                        }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    Text(plate.title ?? "Plate \(index + 1)").font(.subheadline.weight(.semibold)).lineLimit(2)
                    if let printer = plate.primaryPrinter {
                        Label("Sliced for \(printer)", systemImage: "printer").font(.caption)
                    }
                    HStack(spacing: 8) {
                        if let n = plate.materialCount { Text(n == 1 ? "1 material" : "\(n) materials") }
                        if plate.needsAMS { Text("AMS required").foregroundStyle(.orange) }
                        if let d = plate.downloadCount { Label(d.formatted(), systemImage: "arrow.down.circle") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !plate.otherPrinters.isEmpty {
                        Text("Also compatible: " + plate.otherPrinters.prefix(6).joined(separator: ", ") + (plate.otherPrinters.count > 6 ? "…" : ""))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if let result {
                HStack(spacing: 8) {
                    Label(result.wasExisting == true ? "Already in library" : "Imported", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                    Spacer()
                    NavigationLink(value: LibraryRoute.file(result.libraryFileId)) { Text("View") }
                        .buttonStyle(.bordered).controlSize(.small).fixedSize()
                    if useSlicerApi {
                        Button("Slice") { actions.sheet = .slice(LibraryFileRef(id: result.libraryFileId, filename: result.filename)) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(!session.can("library:upload"))
                    }
                    Button(role: .destructive) { pendingDelete = (plate.id, result) } label: { Image(systemName: "trash") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!LibraryAccess.canDeleteAny(session))
                }
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    if isImporting {
                        ProgressView()
                        elapsedText
                    } else {
                        Button("Import", systemImage: "square.and.arrow.down") { Task { await importPlate(plate, model: model) } }
                            .buttonStyle(.bordered)
                        if useSlicerApi {
                            Button("Import & Slice", systemImage: "gearshape.2") { Task { await importPlate(plate, model: model, thenSlice: true) } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .controlSize(.small)
                .disabled(!canImport || !canDownload || busy)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var recentSection: some View {
        if let items = recent.value, !items.isEmpty {
            Section("Recent Imports") {
                ForEach(items) { item in
                    NavigationLink(value: LibraryRoute.file(item.libraryFileId)) {
                        HStack(spacing: 12) {
                            LibraryFileThumbnail(fileId: item.libraryFileId, hasThumbnail: item.thumbnailPath != nil, type: LibraryFileKind.type(of: item.filename))
                                .frame(width: 48, height: 48)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename).lineLimit(2)
                                if let created = item.createdAt {
                                    Text(Fmt.relative(created)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .contextMenu {
                        if let folder = item.folderId {
                            NavigationLink(value: LibraryRoute.browse(.folder(folder))) { Label("Show in Folder", systemImage: "folder") }
                        }
                        if useSlicerApi {
                            Button("Slice…", systemImage: "gearshape.2") { actions.sheet = .slice(LibraryFileRef(id: item.libraryFileId, filename: item.filename)) }
                        }
                        if let source = item.sourceUrl, let url = URL(string: source) {
                            Button("Open on MakerWorld", systemImage: "safari") { openURL(url) }
                            Button("Look Up Again", systemImage: "arrow.clockwise") { urlText = source; Task { await resolve() } }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        if let source = item.sourceUrl, let url = URL(string: source) {
                            Button("MakerWorld") { openURL(url) }.tint(.blue)
                        }
                    }
                }
            }
        }
    }

    // MARK: Networking

    private func loadAll() async {
        let client = session.client
        status = try? await client.get("makerworld/status")
        if settings == nil { settings = await LibraryAPI.settings(client) }
        folders = (try? await LibraryAPI.folders(client)) ?? folders
        await loadRecent()
    }

    private func loadRecent() async {
        await recent.load { try await session.client.get("makerworld/recent-imports", query: ["limit": 10]) }
    }

    private func resolve() async {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        urlFocused = false
        resolving = true
        resolveError = nil
        defer { resolving = false }
        do {
            let model: MakerWorldResolvedModel = try await session.client.send(.post, "makerworld/resolve", body: MakerWorldResolveBody(url: url))
            resolved = model
            resolvedFor = url
            imports = [:]
            summaryText = model.summaryHTML.map { MakerWorldMedia.plainText(fromHTML: $0) }
        } catch {
            resolveError = error.localizedDescription
        }
    }

    @discardableResult
    private func importPlate(_ plate: MakerWorldInstance, model: MakerWorldResolvedModel, thenSlice: Bool = false, quiet: Bool = false) async -> Bool {
        importing.insert(plate.id)
        if importStarted == nil { importStarted = .now }
        defer {
            importing.remove(plate.id)
            if importing.isEmpty && bulkProgress == nil { importStarted = nil }
        }
        do {
            let body = MakerWorldImportBody(modelId: model.modelId, profileId: plate.profileId, instanceId: plate.id, folderId: folderId)
            let result: MakerWorldImportResult = try await session.client.send(.post, "makerworld/import", body: body)
            imports[plate.id] = result
            if !quiet {
                runner.successMessage = result.wasExisting == true ? "Already in your library" : "Imported \(result.filename)"
            }
            if thenSlice {
                actions.sheet = .slice(LibraryFileRef(id: result.libraryFileId, filename: result.filename))
            }
            await loadRecent()
            return true
        } catch {
            runner.errorMessage = error.localizedDescription
            return false
        }
    }

    private func importAll(_ model: MakerWorldResolvedModel) async {
        let pending = model.plates.filter { imports[$0.id] == nil && $0.profileId != nil }
        guard !pending.isEmpty else { return }
        importStarted = .now
        var succeeded = 0
        for (i, plate) in pending.enumerated() {
            bulkProgress = (i + 1, pending.count)
            if await importPlate(plate, model: model, quiet: true) { succeeded += 1 }
        }
        bulkProgress = nil
        importStarted = nil
        runner.successMessage = "Imported \(succeeded) of \(pending.count) plates"
    }

    private func deleteImport(instanceId: Int, result: MakerWorldImportResult) async {
        await runner.run("Moved to Trash") {
            try await session.client.call(.delete, "library/files/\(result.libraryFileId)")
            imports[instanceId] = nil
            await loadRecent()
        }
    }
}

// MARK: - Gallery

private struct MakerWorldGallery: Identifiable {
    let id = UUID()
    let title: String
    let pictures: [MakerWorldPicture]
}

private struct MakerWorldGalleryView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let gallery: MakerWorldGallery
    @State private var index = 0

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(gallery.pictures.enumerated()), id: \.offset) { i, picture in
                    RemoteImage(path: MakerWorldMedia.proxied(picture.url, client: session.client), contentMode: .fit) {
                        ProgressView().tint(.white)
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: gallery.pictures.count > 1 ? .always : .never))
            .background(.black)
            .navigationTitle(gallery.pictures.count > 1 ? "\(gallery.title) · \(index + 1)/\(gallery.pictures.count)" : gallery.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
