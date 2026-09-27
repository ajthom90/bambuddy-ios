import SwiftUI
import AVKit

// MARK: Timelapse player

/// Plays an archive's timelapse with AVPlayer, with speed control, save/share
/// and a trim/speed editor.
struct ArchivesTimelapsePlayer: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let archive: ArchivesRecord
    var onEdited: () -> Void

    @State private var player: AVPlayer?
    @State private var rate: Float = 1
    @State private var runner = ActionRunner()
    @State private var shared: ArchivesSharedFile?
    @State private var showEditor = false
    @State private var reloadToken = 0

    private let rates: [Float] = [0.5, 1, 2, 4, 8]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let player {
                        VideoPlayer(player: player)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Picker("Speed", selection: $rate) {
                    ForEach(rates, id: \.self) { r in Text(r == 0.5 ? "0.5×" : "\(Int(r))×").tag(r) }
                }
                .pickerStyle(.segmented)
                .padding()
            }
            .navigationTitle(archive.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            Task {
                                await runner.run {
                                    let url = try await session.client.download("archives/\(archive.id)/timelapse", suggestedName: "\(archive.displayName)_timelapse.mp4")
                                    shared = ArchivesSharedFile(url: url)
                                }
                            }
                        } label: { Label("Save or Share", systemImage: "square.and.arrow.up") }
                        if ArchivesPermissions.canAdminister(session) {
                            Button { player?.pause(); showEditor = true } label: { Label("Trim & Speed…", systemImage: "scissors") }
                        }
                    } label: {
                        if runner.isRunning { ProgressView() } else { Label("More", systemImage: "ellipsis.circle") }
                    }
                }
            }
            .task(id: reloadToken) {
                let url = await session.mediaURL("archives/\(archive.id)/timelapse", query: ["v": .int(reloadToken)])
                let p = AVPlayer(url: url)
                player = p
                p.playImmediately(atRate: rate)
            }
            .onChange(of: rate) { _, r in
                if player?.timeControlStatus == .playing { player?.rate = r } else { player?.defaultRate = r }
            }
            .onDisappear { player?.pause() }
            .sheet(item: $shared) { file in ArchivesShareSheet(file: file).presentationDetents([.medium]) }
            .sheet(isPresented: $showEditor) {
                ArchivesTimelapseEditor(archive: archive) {
                    onEdited()
                    reloadToken += 1
                }
            }
            .actionAlerts(runner)
        }
    }
}

/// Trim and speed-change a timelapse on the server (ffmpeg).
struct ArchivesTimelapseEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let archive: ArchivesRecord
    var onDone: () -> Void

    @State private var info: ArchivesTimelapseInfo?
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var speed: Double = 1
    @State private var replace = true
    @State private var runner = ActionRunner()

    private var duration: Double { info?.duration ?? 0 }
    private var outputDuration: Double { max(0, trimEnd - trimStart) / max(speed, 0.01) }

    var body: some View {
        NavigationStack {
            Form {
                if let info {
                    Section("Video") {
                        InfoRow("Duration", Fmt.duration(seconds: info.duration))
                        if let w = info.width, let h = info.height { InfoRow("Resolution", "\(w)×\(h)") }
                        if let fps = info.fps { InfoRow("Frame Rate", "\(Fmt.number(fps, digits: 1)) fps") }
                        InfoRow("Size", Fmt.bytes(info.fileSize))
                    }
                    Section {
                        LabeledContent("Start", value: Fmt.duration(seconds: trimStart))
                        Slider(value: $trimStart, in: 0...max(duration, 0.1)) { Text("Start") }
                            .onChange(of: trimStart) { if trimStart > trimEnd - 0.5 { trimStart = max(0, trimEnd - 0.5) } }
                        LabeledContent("End", value: Fmt.duration(seconds: trimEnd))
                        Slider(value: $trimEnd, in: 0...max(duration, 0.1)) { Text("End") }
                            .onChange(of: trimEnd) { if trimEnd < trimStart + 0.5 { trimEnd = min(duration, trimStart + 0.5) } }
                    } header: { Text("Trim") }
                    Section {
                        Picker("Speed", selection: $speed) {
                            ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { s in Text("\(Fmt.number(s, digits: 2))×").tag(s) }
                        }
                        LabeledContent("Output Length", value: Fmt.duration(seconds: outputDuration))
                    } header: { Text("Speed") }
                    Section {
                        Picker("Save As", selection: $replace) {
                            Text("Replace Original").tag(true)
                            Text("New Copy").tag(false)
                        }
                    }
                } else {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                }
            }
            .navigationTitle("Edit Timelapse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning { ProgressView() } else {
                        Button("Process") { Task { await process() } }.disabled(info == nil)
                    }
                }
            }
            .task {
                await runner.run {
                    let i: ArchivesTimelapseInfo = try await session.client.get("archives/\(archive.id)/timelapse/info")
                    info = i
                    trimEnd = i.duration ?? 0
                }
            }
            .actionAlerts(runner)
        }
    }

    private func process() async {
        var fields = [
            "trim_start": String(trimStart),
            "speed": String(speed),
            "save_mode": replace ? "replace" : "new",
        ]
        if trimEnd < duration - 0.01 { fields["trim_end"] = String(trimEnd) }
        await runner.run {
            let _: EmptyResponse = try await session.client.upload("archives/\(archive.id)/timelapse/process", files: [], fields: fields)
            onDone()
            dismiss()
        }
    }
}

/// Lets the user choose among timelapse videos found on the printer.
struct ArchivesTimelapsePicker: View {
    @Environment(\.dismiss) private var dismiss
    let files: [ArchivesTimelapseFile]
    var onPick: (ArchivesTimelapseFile) -> Void

    var body: some View {
        NavigationStack {
            List(files) { file in
                Button { onPick(file) } label: {
                    HStack {
                        Image(systemName: "film").foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(file.name).lineLimit(1)
                            Text([Fmt.bytes(file.size), file.mtime.map { Fmt.date($0) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Select Timelapse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .top) {
                Text("No video matched this print automatically. Pick the right one to attach.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Timelapse / camera recordings for this print: the attached copy and files
/// still on the printer's storage.
struct ArchivesPrinterMediaSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let archive: ArchivesRecord
    @State private var loader = Loader<ArchivesPrinterMedia>()
    @State private var runner = ActionRunner()
    @State private var shared: ArchivesSharedFile?

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { media in
                List {
                    if let warnings = media.warnings, !warnings.isEmpty {
                        Section {
                            ForEach(warnings, id: \.self) { w in
                                Label(Self.describe(w), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                    if let local = media.localTimelapse {
                        Section("Attached Timelapse") {
                            Button {
                                Task {
                                    await runner.run {
                                        let url = try await session.client.download("archives/\(archive.id)/timelapse", suggestedName: local.name ?? "\(archive.displayName)_timelapse.mp4")
                                        shared = ArchivesSharedFile(url: url)
                                    }
                                }
                            } label: {
                                LabeledContent {
                                    Text(Fmt.bytes(local.size))
                                } label: {
                                    Label(local.name ?? "Timelapse", systemImage: "square.and.arrow.down")
                                }
                            }
                        }
                    }
                    let remote = media.remoteFiles ?? []
                    Section {
                        if remote.isEmpty {
                            Text("No matching recordings on the printer.").foregroundStyle(.secondary)
                        }
                        ForEach(remote) { file in
                            HStack {
                                Image(systemName: file.kind == "ipcam" ? "video" : "film")
                                VStack(alignment: .leading) {
                                    Text(file.name).lineLimit(1)
                                    Text([Fmt.bytes(file.size), file.mtime.map { Fmt.date($0) }].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("On the Printer")
                    } footer: {
                        if !remote.isEmpty { Text("Download these from the printer's file browser in the Printers section.") }
                    }
                }
            }
            .navigationTitle("Printer Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(item: $shared) { file in ArchivesShareSheet(file: file).presentationDetents([.medium]) }
            .actionAlerts(runner)
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("archives/\(archive.id)/printer-media") }
    }

    private static func describe(_ warning: String) -> String {
        switch warning {
        case "printer_missing": "The printer for this archive no longer exists."
        case "timelapse_unavailable": "Couldn't list timelapse videos on the printer."
        case "ipcam_unavailable": "Couldn't list camera recordings on the printer."
        case "printer_files_forbidden": "You don't have permission to browse printer files."
        default: warning
        }
    }
}

// MARK: Photos

/// Full-screen paging viewer for an archive's photos.
struct ArchivesPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let archiveId: Int
    let photos: [String]
    @State private var current: String

    init(archiveId: Int, photos: [String], start: String) {
        self.archiveId = archiveId
        self.photos = photos
        _current = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(photos, id: \.self) { name in
                    RemoteImage(path: "archives/\(archiveId)/photos/\(name)", contentMode: .fit)
                        .tag(name)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .background(.black)
            .navigationTitle(photos.count > 1 ? "\((photos.firstIndex(of: current) ?? 0) + 1) of \(photos.count)" : "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: QR code

struct ArchivesQRCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let archive: ArchivesRecord

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                RemoteImage(path: "archives/\(archive.id)/qrcode", contentMode: .fit, systemImage: "qrcode")
                    .frame(width: 240, height: 240)
                    .background(.white)
                    .clipShape(.rect(cornerRadius: 12))
                Text(archive.displayName).font(.headline)
                Text("Scan to open this archive in Bambuddy.").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: Project page

/// The 3MF's embedded project page (title, description, designer, license, images).
struct ArchivesProjectPageSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let archive: ArchivesRecord
    @State private var loader = Loader<ArchivesProjectPage>()
    @State private var editing = false
    @State private var draft = ArchivesProjectPageDraft()
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { page in
                if editing { editor } else { viewer(page) }
            }
            .navigationTitle("Project Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editing ? "Cancel" : "Done") { if editing { editing = false } else { dismiss() } }
                }
                if ArchivesPermissions.canUpdate(session, archive), loader.value != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if editing {
                            Button("Save") { Task { await save() } }.disabled(runner.isRunning)
                        } else {
                            Button("Edit") {
                                if let p = loader.value { draft = ArchivesProjectPageDraft(p) }
                                editing = true
                            }
                        }
                    }
                }
            }
            .task { await load() }
            .actionAlerts(runner)
        }
    }

    private func viewer(_ page: ArchivesProjectPage) -> some View {
        let images = (page.modelPictures ?? []) + (page.profilePictures ?? [])
        let hasText = [page.title, page.description, page.designer, page.license].contains { !($0 ?? "").isEmpty }
        return List {
            if !images.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(images) { img in
                                RemoteImage(path: img.url ?? "archives/\(archive.id)/project-image/\(img.path)", contentMode: .fill)
                                    .frame(width: 200, height: 150)
                                    .clipShape(.rect(cornerRadius: 10))
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
            if !hasText && images.isEmpty {
                ContentUnavailableView("No Project Page", systemImage: "doc.richtext", description: Text("This 3MF has no embedded project information."))
            }
            if let title = page.title, !title.isEmpty {
                Section { Text(title).font(.title3.weight(.semibold)) }
            }
            if let desc = page.description, !desc.isEmpty {
                Section("Description") { Text(Self.plainText(desc)).textSelection(.enabled) }
            }
            Section("Details") {
                if let v = page.designer, !v.isEmpty { InfoRow("Designer", v) }
                if let v = page.license, !v.isEmpty { InfoRow("License", v) }
                if let v = page.copyright, !v.isEmpty { InfoRow("Copyright", v) }
                if let v = page.origin, !v.isEmpty { InfoRow("Origin", v) }
                if let v = page.creationDate, !v.isEmpty { InfoRow("Created", v) }
                if let v = page.modificationDate, !v.isEmpty { InfoRow("Modified", v) }
                if let v = page.designModelId, !v.isEmpty { InfoRow("Model ID", v) }
            }
            if !(page.profileTitle ?? "").isEmpty || !(page.profileDescription ?? "").isEmpty {
                Section("Print Profile") {
                    if let v = page.profileTitle, !v.isEmpty { Text(v).font(.headline) }
                    if let v = page.profileDescription, !v.isEmpty { Text(Self.plainText(v)) }
                    if let v = page.profileUserName, !v.isEmpty { InfoRow("By", v) }
                }
            }
        }
    }

    private var editor: some View {
        Form {
            Section("Title") { TextField("Title", text: $draft.title) }
            Section("Description") { TextField("Description", text: $draft.description, axis: .vertical).lineLimit(4...12) }
            Section("Credits") {
                TextField("Designer", text: $draft.designer)
                TextField("License", text: $draft.license)
                TextField("Copyright", text: $draft.copyright)
            }
            Section("Print Profile") {
                TextField("Profile title", text: $draft.profileTitle)
                TextField("Profile description", text: $draft.profileDescription, axis: .vertical).lineLimit(3...8)
            }
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("archives/\(archive.id)/project-page") }
    }

    private func save() async {
        await runner.run("Project page saved") {
            try await session.client.call(.patch, "archives/\(archive.id)/project-page", body: draft.payload)
            editing = false
            await load()
        }
    }

    /// Project descriptions are HTML; show them as plain text.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "</p>", with: "\n\n")
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ArchivesProjectPageDraft {
    var title = ""
    var description = ""
    var designer = ""
    var license = ""
    var copyright = ""
    var profileTitle = ""
    var profileDescription = ""

    init() {}
    init(_ p: ArchivesProjectPage) {
        title = p.title ?? ""
        description = p.description ?? ""
        designer = p.designer ?? ""
        license = p.license ?? ""
        copyright = p.copyright ?? ""
        profileTitle = p.profileTitle ?? ""
        profileDescription = p.profileDescription ?? ""
    }

    var payload: [String: String] {
        [
            "title": title, "description": description, "designer": designer, "license": license,
            "copyright": copyright, "profile_title": profileTitle, "profile_description": profileDescription,
        ]
    }
}
