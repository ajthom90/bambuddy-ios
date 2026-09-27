import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Full detail for one archive: media, metadata, filament, cost, settings,
/// notes/tags, photos, timelapse, attached files, run history and actions.
struct ArchivesDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @Environment(PrinterStore.self) private var printers
    @Environment(ArchivesLookups.self) private var lookups
    @Environment(\.dismiss) private var dismiss
    let archiveId: Int

    @State private var loader = Loader<ArchivesRecord>()
    @State private var plates: ArchivesPlatesInfo?
    @State private var runs: ArchivesLogPage?
    @State private var similar: [ArchivesSimilar] = []
    @State private var actions = ArchivesActions()
    @State private var runner = ActionRunner()
    @State private var plateSelection = 0
    @State private var photoItem: PhotosPickerItem?
    @State private var viewingPhoto: ArchivesPhotoRef?
    @State private var importKind: ArchivesImportKind?
    @State private var showImporter = false
    @State private var timelapseChoices: [ArchivesTimelapseFile] = []
    @State private var showPrinterMedia = false
    @State private var confirmRemove: ArchivesImportKind?
    @State private var photoToDelete: String?

    var body: some View {
        LoadingContent(loader: loader, retry: load) { archive in
            content(archive)
        }
        .navigationTitle(loader.value?.displayName ?? "Archive")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: live.revision("archive_updated", "print_complete")) { await load() }
        .onAppear {
            actions.onUpdated = { updated in
                if let updated { loader.value = updated }
                Task { await load() }
            }
            actions.onDeleted = { _ in dismiss() }
        }
        .archivesActionPresenters(actions)
        .actionAlerts(runner)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await uploadPhoto(item) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importKind?.types ?? [.data]) { result in
            guard let kind = importKind, case .success(let url) = result else { return }
            Task { await upload(url, kind: kind) }
        }
        .sheet(item: $viewingPhoto) { ref in
            ArchivesPhotoViewer(archiveId: archiveId, photos: loader.value?.photoNames ?? [], start: ref.name)
        }
        .sheet(isPresented: Binding(get: { !timelapseChoices.isEmpty }, set: { if !$0 { timelapseChoices = [] } })) {
            ArchivesTimelapsePicker(files: timelapseChoices) { file in
                timelapseChoices = []
                Task { await selectTimelapse(file.name) }
            }
        }
        .sheet(isPresented: $showPrinterMedia) {
            if let archive = loader.value { ArchivesPrinterMediaSheet(archive: archive) }
        }
        .confirmationDialog(confirmRemove?.removeTitle ?? "", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let kind = confirmRemove { Task { await remove(kind) } }
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: Binding(get: { photoToDelete != nil }, set: { if !$0 { photoToDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) {
                if let name = photoToDelete { Task { await deletePhoto(name) } }
            }
        }
    }

    // MARK: Layout

    private func content(_ archive: ArchivesRecord) -> some View {
        List {
            Section {
                hero(archive)
                    .listRowInsets(EdgeInsets())
                titleBlock(archive)
                primaryActions(archive)
            }
            summarySection(archive)
            settingsSection(archive)
            filamentSection(archive)
            platesSection(archive)
            notesSection(archive)
            photosSection(archive)
            timelapseSection(archive)
            filesSection(archive)
            linksSection(archive)
            runsSection(archive)
            relatedSection(archive)
            infoSection(archive)
            if ArchivesPermissions.canDelete(session, archive) {
                Section {
                    Button(role: .destructive) { actions.deleting = archive } label: {
                        Label("Delete Archive", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await actions.toggleFavorite(archive, client: session.client) } } label: {
                    Label(archive.favorite ? "Unfavorite" : "Favorite", systemImage: archive.favorite ? "star.fill" : "star")
                }
                .tint(archive.favorite ? .yellow : nil)
                .disabled(!ArchivesPermissions.canUpdate(session, archive))
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { actions.editing = archive }
                    .disabled(!ArchivesPermissions.canUpdate(session, archive))
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ArchivesActionMenu(archive: archive, actions: actions)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func hero(_ archive: ArchivesRecord) -> some View {
        let plateList = (plates?.plates ?? []).filter { $0.hasThumbnail == true }
        if plateList.count > 1 {
            TabView(selection: $plateSelection) {
                ForEach(Array(plateList.enumerated()), id: \.element.index) { offset, plate in
                    ArchivesThumbnail(archive: archive, plateIndex: plate.index)
                        .overlay(alignment: .bottomLeading) {
                            Text(plate.name.map { "Plate \(plate.index): \($0)" } ?? "Plate \(plate.index)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: .capsule)
                                .padding(10)
                                .padding(.bottom, 20)
                        }
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(height: 280)
            .background(Color(.tertiarySystemFill))
        } else {
            ArchivesThumbnail(archive: archive)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .background(Color(.tertiarySystemFill))
        }
    }

    private func titleBlock(_ archive: ArchivesRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(archive.displayName).font(.title2.weight(.semibold))
                if let plate = archive.plateId, plate > 1 {
                    Text("Plate \(plate)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ArchivesFlowLayout(spacing: 6) {
                ArchivesStatusBadge(status: archive.status)
                StatusBadge(text: archive.isSliced ? "G-code" : "Source", color: archive.isSliced ? .green : .orange)
                if let project = archive.projectName {
                    StatusBadge(text: project, color: Color(hex: lookups.project(archive.projectId)?.color) ?? .gray)
                }
                if let runs = archive.runCount, runs > 0 {
                    StatusBadge(text: "\(runs) print\(runs == 1 ? "" : "s") · \(archive.successfulRunCount ?? 0) ok · \(archive.failedRunCount ?? 0) failed", color: .orange)
                }
                if archive.isDuplicate {
                    StatusBadge(text: (archive.duplicateSequence ?? 0) > 0 ? "Reprint #\(archive.duplicateSequence ?? 0)" : "\(archive.duplicateCount ?? 0) reprint(s)", color: .purple)
                }
                if let mapPrinter = archive.slicerAmsMappingPrinterId, let name = printers.printer(mapPrinter)?.name {
                    StatusBadge(text: "Saved AMS mapping · \(name)", color: .green)
                }
            }
            if let reason = ArchivesVocabulary.failureLabel(archive.failureReason), archive.isFailed {
                Label(reason, systemImage: "exclamationmark.triangle.fill").font(.subheadline).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func primaryActions(_ archive: ArchivesRecord) -> some View {
        let canReprint = ArchivesPermissions.canReprint(session, archive) && !(archive.filePath ?? "").isEmpty
        HStack(spacing: 10) {
            if archive.isSliced {
                Button { actions.print(archive, mode: .printNow) } label: {
                    Label("Print", systemImage: "printer.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canReprint)
                Button { actions.print(archive, mode: .addToQueue) } label: {
                    Label("Queue", systemImage: "text.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canReprint)
            }
            Button { Task { await actions.download3MF(archive, client: session.client) } } label: {
                if actions.downloadingId == archive.id {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Label("3MF", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .disabled(actions.downloadingId != nil)
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    private func summarySection(_ archive: ArchivesRecord) -> some View {
        Section("Summary") {
            if let actual = archive.actualTimeSeconds, actual > 0 {
                LabeledContent {
                    HStack(spacing: 6) {
                        Text(ArchivesStyle.duration(actual))
                        if let acc = archive.timeAccuracy {
                            let delta = Int((acc - 100).rounded())
                            StatusBadge(text: "\(delta > 0 ? "+" : "")\(delta)%", color: ArchivesStyle.accuracyColor(acc))
                        }
                    }
                } label: { Label("Print Time", systemImage: "clock") }
            }
            if let est = archive.printTimeSeconds, est > 0 {
                InfoRow("Estimated Time", ArchivesStyle.duration(est), systemImage: "clock.badge.questionmark")
            }
            if let acc = archive.timeAccuracy {
                InfoRow("Time Accuracy", Fmt.percent(acc), systemImage: "target")
            }
            InfoRow("Filament Used", archive.filamentUsedGrams.map(ArchivesStyle.gramsPrecise), systemImage: "scalemass")
            if let actual = archive.totalFilamentActualGrams, (archive.runCount ?? 0) > 1 {
                InfoRow("Filament (all runs)", ArchivesStyle.gramsPrecise(actual), systemImage: "sum")
            }
            InfoRow("Filament Cost", archive.cost.map(lookups.money), systemImage: "dollarsign.circle")
            if archive.energyKwh != nil || archive.energyCost != nil {
                InfoRow("Energy", ArchivesStyle.number(archive.energyKwh, suffix: "kWh", digits: 3), systemImage: "bolt")
                InfoRow("Energy Cost", archive.energyCost.map(lookups.money), systemImage: "bolt.circle")
            }
            if let q = archive.quantity, q > 1 { InfoRow("Items Printed", "\(q)", systemImage: "number") }
            if let n = archive.objectCount, n > 0 { InfoRow("Objects", "\(n)", systemImage: "cube") }
        }
    }

    @ViewBuilder
    private func settingsSection(_ archive: ArchivesRecord) -> some View {
        let rows: [(String, String?, String)] = [
            ("Layer Height", archive.layerHeight.map { "\(Fmt.number($0, digits: 2)) mm" }, "square.stack.3d.up"),
            ("Total Layers", archive.totalLayers.map(String.init), "square.3.layers.3d"),
            ("Nozzle Diameter", archive.nozzleDiameter.map { "\(Fmt.number($0, digits: 2)) mm" }, "circle.circle"),
            ("Nozzle Temperature", archive.nozzleTemperature.map { "\($0) °C" }, "flame"),
            ("Bed Temperature", archive.bedTemperature.map { "\($0) °C" }, "thermometer.medium"),
            ("Build Plate", ArchivesStyle.bedTypeName(archive.bedType), "rectangle.portrait.on.rectangle.portrait"),
            ("Sliced For", archive.slicedForModel, "printer"),
        ].filter { $0.1 != nil }
        if !rows.isEmpty {
            Section("Print Settings") {
                ForEach(rows, id: \.0) { row in InfoRow(row.0, row.1, systemImage: row.2) }
            }
        }
    }

    @ViewBuilder
    private func filamentSection(_ archive: ArchivesRecord) -> some View {
        let plateFilaments = plateFilamentsFor(archive)
        if !plateFilaments.isEmpty {
            Section("Filament Usage") {
                ForEach(Array(plateFilaments.enumerated()), id: \.offset) { _, f in
                    HStack(spacing: 10) {
                        ColorSwatch(hex: f.color, size: 20)
                        VStack(alignment: .leading) {
                            Text(f.type?.isEmpty == false ? f.type! : "Filament")
                            if let slot = f.slotId { Text("Slot \(slot)").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(ArchivesStyle.gramsPrecise(f.usedGrams))
                            if let m = f.usedMeters, m > 0 { Text("\(Fmt.number(m, digits: 2)) m").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        } else if !archive.materials.isEmpty || !archive.colors.isEmpty {
            Section("Filament") {
                InfoRow("Material", archive.materials.joined(separator: ", "), systemImage: "circle.hexagongrid")
                if !archive.colors.isEmpty {
                    LabeledContent { ArchivesColorDots(colors: archive.colors, size: 16) } label: { Label("Colors", systemImage: "paintpalette") }
                }
            }
        }
    }

    /// Filaments of the printed plate (or the only plate).
    private func plateFilamentsFor(_ archive: ArchivesRecord) -> [ArchivesPlateFilament] {
        guard let list = plates?.plates, !list.isEmpty else { return [] }
        let plate = list.first { $0.index == archive.plateId } ?? (list.count == 1 ? list[0] : nil)
        return (plate?.filaments ?? []).filter { $0.usedInPlate != false }
    }

    @ViewBuilder
    private func platesSection(_ archive: ArchivesRecord) -> some View {
        if let list = plates?.plates, list.count > 1 {
            Section("Plates (\(list.count))") {
                ForEach(list) { plate in
                    HStack(spacing: 12) {
                        Group {
                            if plate.hasThumbnail == true {
                                ArchivesThumbnail(archive: archive, plateIndex: plate.index)
                            } else {
                                ImagePlaceholder(systemImage: "square.dashed")
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(.rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Plate \(plate.index)").font(.subheadline.weight(.semibold))
                                if plate.index == archive.plateId { StatusBadge(text: "Printed", color: .green) }
                            }
                            if let name = plate.name { Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            HStack(spacing: 10) {
                                if let t = plate.printTimeSeconds { Label(Fmt.duration(seconds: t), systemImage: "clock") }
                                if let g = plate.filamentUsedGrams { Label(Fmt.grams(g), systemImage: "scalemass") }
                                if let n = plate.objectCount ?? plate.objects?.count, n > 0 { Label("\(n)", systemImage: "cube") }
                            }
                            .font(.caption2).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                        }
                        Spacer()
                        ArchivesColorDots(colors: (plate.filaments ?? []).compactMap(\.color), size: 10)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notesSection(_ archive: ArchivesRecord) -> some View {
        let notes = archive.notes ?? ""
        if !notes.isEmpty || !archive.tagList.isEmpty {
            Section("Notes & Tags") {
                if !notes.isEmpty {
                    Text(notes).textSelection(.enabled)
                }
                if !archive.tagList.isEmpty {
                    ArchivesTagChips(tags: archive.tagList).padding(.vertical, 2)
                }
            }
        }
    }

    private func photosSection(_ archive: ArchivesRecord) -> some View {
        Section {
            if !archive.photoNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(archive.photoNames, id: \.self) { name in
                            Button { viewingPhoto = ArchivesPhotoRef(name: name) } label: {
                                RemoteImage(path: "archives/\(archive.id)/photos/\(name)")
                                    .frame(width: 110, height: 110)
                                    .clipShape(.rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if ArchivesPermissions.canDelete(session, archive) {
                                    Button(role: .destructive) { photoToDelete = name } label: { Label("Delete Photo", systemImage: "trash") }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            if ArchivesPermissions.canUpdate(session, archive) {
                let uploading = runner.isRunning && photoItem != nil
                PhotosPicker(selection: $photoItem, matching: .images) {
                    HStack {
                        Label("Add Photo", systemImage: "camera.badge.ellipsis")
                        if uploading { Spacer(); ProgressView() }
                    }
                }
            }
        } header: {
            Text("Photos" + (archive.photoNames.isEmpty ? "" : " (\(archive.photoNames.count))"))
        } footer: {
            Text("Photos of the finished print.")
        }
    }

    private func timelapseSection(_ archive: ArchivesRecord) -> some View {
        let canAdmin = ArchivesPermissions.canAdminister(session)
        return Section("Timelapse") {
            if archive.timelapsePath != nil {
                Button { actions.timelapse = archive } label: { Label("Play Timelapse", systemImage: "play.rectangle.fill") }
                Button {
                    Task { await actions.share("archives/\(archive.id)/timelapse", id: archive.id, name: "\(archive.displayName)_timelapse.mp4", client: session.client) }
                } label: { Label("Save Timelapse", systemImage: "square.and.arrow.down") }
                if ArchivesPermissions.canDelete(session, archive) {
                    Button(role: .destructive) { confirmRemove = .timelapse } label: { Label("Remove Timelapse", systemImage: "trash") }
                }
            } else {
                if archive.printerId != nil {
                    Button { Task { await scanTimelapse() } } label: { Label("Find Timelapse on Printer", systemImage: "magnifyingglass") }
                        .disabled(!canAdmin)
                }
                Button { importKind = .timelapse; showImporter = true } label: { Label("Upload Timelapse…", systemImage: "square.and.arrow.up") }
                    .disabled(!canAdmin)
            }
            if archive.timelapsePath != nil || (archive.printerId != nil && archive.startedAt != nil) {
                Button { showPrinterMedia = true } label: { Label("Printer Media", systemImage: "externaldrive.connected.to.line.below") }
            }
        }
    }

    private func filesSection(_ archive: ArchivesRecord) -> some View {
        let canUpdate = ArchivesPermissions.canUpdate(session, archive)
        let canDelete = ArchivesPermissions.canDelete(session, archive)
        return Section {
            Button { Task { await actions.download3MF(archive, client: session.client) } } label: {
                LabeledContent { Text(Fmt.bytes(archive.fileSize)) } label: { Label("Download 3MF", systemImage: "arrow.down.doc") }
            }
            if archive.source3mfPath != nil {
                Button {
                    Task { await actions.share("archives/\(archive.id)/source", id: archive.id, name: "\(archive.displayName)_source.3mf", client: session.client) }
                } label: { Label("Download Source 3MF", systemImage: "doc.badge.gearshape") }
                Button { importKind = .source; showImporter = true } label: { Label("Replace Source 3MF…", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!canUpdate)
                if canDelete {
                    Button(role: .destructive) { confirmRemove = .source } label: { Label("Remove Source 3MF", systemImage: "trash") }
                }
            } else {
                Button { importKind = .source; showImporter = true } label: { Label("Attach Source 3MF…", systemImage: "doc.badge.plus") }
                    .disabled(!canUpdate)
            }
            if archive.f3dPath != nil {
                Button {
                    Task { await actions.share("archives/\(archive.id)/f3d", id: archive.id, name: "\(archive.displayName).f3d", client: session.client) }
                } label: { Label("Download Fusion 360 Design", systemImage: "cube.transparent") }
                Button { importKind = .f3d; showImporter = true } label: { Label("Replace F3D…", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(!canUpdate)
                if canDelete {
                    Button(role: .destructive) { confirmRemove = .f3d } label: { Label("Remove F3D", systemImage: "trash") }
                }
            } else {
                Button { importKind = .f3d; showImporter = true } label: { Label("Attach Fusion 360 Design…", systemImage: "cube.transparent") }
                    .disabled(!canUpdate)
            }
            Button { actions.qrFor = archive } label: { Label("QR Code", systemImage: "qrcode") }
            Button { actions.copyDownloadLink(archive, session: session) } label: { Label("Copy Download Link", systemImage: "link") }
        } header: {
            Text("Files")
        } footer: {
            Text("The source 3MF is the original slicer project; F3D is the Fusion 360 design.")
        }
    }

    @ViewBuilder
    private func linksSection(_ archive: ArchivesRecord) -> some View {
        Section("Model") {
            if let url = URL(string: archive.externalUrl ?? ""), !(archive.externalUrl ?? "").isEmpty {
                Link(destination: url) { Label("External Link", systemImage: "link") }
            }
            if let url = URL(string: archive.makerworldUrl ?? ""), !(archive.makerworldUrl ?? "").isEmpty {
                Link(destination: url) {
                    Label(archive.designer.map { "MakerWorld · \($0)" } ?? "View on MakerWorld", systemImage: "globe")
                }
            } else if let designer = archive.designer {
                InfoRow("Designer", designer, systemImage: "person.crop.square")
            }
            Button { actions.projectPageFor = archive } label: { Label("Project Page", systemImage: "doc.richtext") }
            if let project = archive.projectName {
                LabeledContent {
                    Text(project)
                } label: {
                    Label("Project", systemImage: "folder")
                }
            }
        }
    }

    @ViewBuilder
    private func runsSection(_ archive: ArchivesRecord) -> some View {
        if let items = runs?.items, !items.isEmpty {
            Section {
                ForEach(items.prefix(5)) { entry in ArchivesLogRow(entry: entry, showThumbnail: false) }
                if items.count > 5 {
                    Button("Show All \(runs?.total ?? items.count) Prints") { actions.runsFor = archive }
                }
            } header: {
                Text("Print History")
            }
        }
    }

    @ViewBuilder
    private func relatedSection(_ archive: ArchivesRecord) -> some View {
        let dups = (archive.duplicates ?? []).filter { $0.id != archive.id }
        if !dups.isEmpty || !similar.isEmpty || archive.originalArchiveId != nil {
            Section("Related Archives") {
                if let original = archive.originalArchiveId, original != archive.id {
                    NavigationLink(value: ArchivesDetailRoute(id: original)) {
                        Label("Original Print (#\(original))", systemImage: "arrow.uturn.backward")
                    }
                }
                ForEach(dups) { dup in
                    NavigationLink(value: ArchivesDetailRoute(id: dup.id)) {
                        VStack(alignment: .leading) {
                            Text(dup.printName ?? "Archive #\(dup.id)")
                            Text("\(dup.matchType == "exact" ? "Identical file" : "Same name") · \(Fmt.date(dup.createdAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(similar.filter { s in !dups.contains { $0.id == s.id } && s.id != archive.id }) { s in
                    NavigationLink(value: ArchivesDetailRoute(id: s.id)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(s.archive.printName ?? "Archive #\(s.id)")
                                Text(s.matchReason ?? "Similar").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ArchivesStatusBadge(status: s.archive.status)
                        }
                    }
                }
            }
        }
    }

    private func infoSection(_ archive: ArchivesRecord) -> some View {
        Section("Details") {
            InfoRow("Printer", archive.printerId.map { printers.printer($0)?.name ?? "Printer #\($0)" } ?? "None", systemImage: "printer")
            InfoRow("File", archive.filename, systemImage: "doc")
            InfoRow("Size", Fmt.bytes(archive.fileSize), systemImage: "internaldrive")
            InfoRow("Archived", Fmt.date(archive.createdAt), systemImage: "calendar")
            if archive.startedAt != nil { InfoRow("Started", Fmt.date(archive.startedAt), systemImage: "play.circle") }
            if archive.completedAt != nil { InfoRow("Finished", Fmt.date(archive.completedAt), systemImage: "flag.checkered") }
            if archive.lastRunAt != nil && (archive.runCount ?? 0) > 1 { InfoRow("Last Printed", Fmt.date(archive.lastRunAt), systemImage: "clock.arrow.circlepath") }
            if let user = archive.createdByUsername { InfoRow("Uploaded By", user, systemImage: "person") }
            if let hash = archive.contentHash { InfoRow("SHA-256", String(hash.prefix(16)).uppercased() + "…", systemImage: "number") }
            InfoRow("Archive ID", "#\(archive.id)", systemImage: "archivebox")
        }
    }

    // MARK: Loading

    private func load() async {
        let client = session.client
        await loader.load { try await client.get("archives/\(archiveId)") }
        guard loader.value != nil else { return }
        async let platesTask: ArchivesPlatesInfo? = try? client.get("archives/\(archiveId)/plates")
        async let runsTask: ArchivesLogPage? = try? client.get("archives/\(archiveId)/runs")
        async let similarTask: [ArchivesSimilar]? = try? client.get("archives/\(archiveId)/similar", query: ["limit": 5])
        plates = await platesTask
        runs = await runsTask
        similar = await similarTask ?? []
        if let archive = loader.value, let idx = plates?.plates?.filter({ $0.hasThumbnail == true }).firstIndex(where: { $0.index == archive.plateId }) {
            plateSelection = idx
        }
    }

    // MARK: Mutations

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        await runner.run("Photo added") {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            let file = UploadFile(fileName: "photo.jpg", mimeType: "image/jpeg", data: jpeg)
            let _: ArchivesPhotosResponse = try await session.client.upload("archives/\(archiveId)/photos", files: [file])
        }
        await load()
    }

    private func deletePhoto(_ name: String) async {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        await runner.run("Photo deleted") {
            let _: ArchivesPhotosResponse = try await session.client.send(.delete, "archives/\(archiveId)/photos/\(encoded)")
        }
        await load()
    }

    private func upload(_ url: URL, kind: ArchivesImportKind) async {
        await runner.run(kind.successMessage) {
            let data = try archivesReadPickedFile(url)
            let file = UploadFile(fileName: url.lastPathComponent, mimeType: archivesMimeType(for: url), data: data)
            let _: EmptyResponse = try await session.client.upload("archives/\(archiveId)/\(kind.pathComponent)", files: [file])
        }
        await load()
    }

    private func remove(_ kind: ArchivesImportKind) async {
        await runner.run(kind.removedMessage) {
            let path = kind == .timelapse ? "archives/\(archiveId)/timelapse" : "archives/\(archiveId)/\(kind.pathComponent)"
            try await session.client.call(.delete, path)
        }
        confirmRemove = nil
        await load()
    }

    private func scanTimelapse() async {
        await runner.run {
            let result: ArchivesTimelapseScanResult = try await session.client.send(.post, "archives/\(archiveId)/timelapse/scan")
            switch result.status {
            case "attached": runner.successMessage = "Timelapse attached"
            case "exists": runner.successMessage = "Timelapse already attached"
            default:
                if let files = result.availableFiles, !files.isEmpty {
                    timelapseChoices = files
                } else {
                    runner.errorMessage = result.message ?? "No matching timelapse found on the printer."
                }
            }
        }
        await load()
    }

    private func selectTimelapse(_ name: String) async {
        await runner.run("Timelapse attached") {
            let _: ArchivesStatusMessage = try await session.client.send(.post, "archives/\(archiveId)/timelapse/select", query: ["filename": .string(name)])
        }
        await load()
    }
}

/// Which attachment a file importer is picking.
enum ArchivesImportKind: Hashable {
    case timelapse, source, f3d

    var types: [UTType] {
        switch self {
        case .timelapse: ArchivesFileTypes.video
        case .source: [ArchivesFileTypes.threeMF]
        case .f3d: [ArchivesFileTypes.f3d, .data]
        }
    }
    var pathComponent: String {
        switch self {
        case .timelapse: "timelapse/upload"
        case .source: "source"
        case .f3d: "f3d"
        }
    }
    var successMessage: String {
        switch self {
        case .timelapse: "Timelapse uploaded"
        case .source: "Source 3MF attached"
        case .f3d: "F3D attached"
        }
    }
    var removedMessage: String {
        switch self {
        case .timelapse: "Timelapse removed"
        case .source: "Source 3MF removed"
        case .f3d: "F3D removed"
        }
    }
    var removeTitle: String {
        switch self {
        case .timelapse: "Remove the timelapse video?"
        case .source: "Remove the source 3MF?"
        case .f3d: "Remove the F3D design file?"
        }
    }
}

struct ArchivesPhotoRef: Identifiable, Hashable {
    let name: String
    var id: String { name }
}

/// A print's run history from the print log.
struct ArchivesRunsList: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let archive: ArchivesRecord
    @State private var loader = Loader<ArchivesLogPage>()

    var body: some View {
        LoadingContent(loader: loader, retry: load) { page in
            List {
                if page.items.isEmpty {
                    ContentUnavailableView("No Prints Logged", systemImage: "clock", description: Text("Runs of this archive appear here once printed."))
                }
                ForEach(page.items) { entry in ArchivesLogRow(entry: entry, showThumbnail: false) }
            }
        }
        .task { await load() }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func load() async {
        await loader.load { try await session.client.get("archives/\(archive.id)/runs") }
    }
}
