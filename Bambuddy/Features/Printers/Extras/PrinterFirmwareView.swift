import SwiftUI

// MARK: Models

struct PrinterFirmwareInfo: Codable, Sendable, Hashable {
    var printerId: Int
    var printerName: String
    var model: String?
    var currentVersion: String?
    var latestVersion: String?
    var updateAvailable: Bool
    var downloadUrl: String?
    var releaseNotes: String?
    var availableVersions: [PrinterFirmwareVersion]?
}

struct PrinterFirmwareVersion: Codable, Sendable, Hashable {
    var version: String
    var fileAvailable: Bool
    var downloadUrl: String?
    var releaseNotes: String?
    var releaseTime: String?
}

struct PrinterFirmwarePrepare: Codable, Sendable, Hashable {
    var canProceed: Bool
    var sdCardPresent: Bool
    var sdCardFreeSpace: Int?
    var firmwareSize: Int?
    var spaceSufficient: Bool
    var updateAvailable: Bool
    var currentVersion: String?
    var latestVersion: String?
    var targetVersion: String?
    var firmwareFilename: String?
    var errors: [String]?
}

struct PrinterFirmwareUploadStart: Codable, Sendable, Hashable {
    var started: Bool
    var message: String
}

struct PrinterFirmwareUploadStatus: Codable, Sendable, Hashable {
    var status: String
    var progress: Int?
    var message: String?
    var error: String?
    var firmwareFilename: String?
    var firmwareVersion: String?

    var isActive: Bool { ["preparing", "downloading", "uploading"].contains(status) }
}

// MARK: View

struct PrinterFirmwareView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    let printerId: Int

    @State private var loader = Loader<PrinterFirmwareInfo>()
    @State private var runner = ActionRunner()
    @State private var upload: PrinterFirmwareUploadStatus?
    @State private var prepare: PrinterFirmwarePrepare?
    @State private var pendingVersion: String?
    @State private var confirmUpload = false
    @State private var notesVersion: PrinterFirmwareVersion?

    private var client: APIClient { session.client }

    var body: some View {
        LoadingContent(loader: loader, retry: load) { info in
            List {
                Section {
                    InfoRow("Model", info.model)
                    InfoRow("Installed", info.currentVersion)
                    InfoRow("Latest", info.latestVersion)
                    HStack {
                        if info.updateAvailable {
                            Label("Update available", systemImage: "arrow.down.circle.fill").foregroundStyle(.orange)
                        } else if info.latestVersion != nil {
                            Label("Up to date", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        } else {
                            Label("Latest version unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                        }
                    }
                }
                if let upload, upload.status != "idle" {
                    Section("Upload to Printer") {
                        if upload.isActive {
                            ProgressView(value: Double(upload.progress ?? 0), total: 100) {
                                Text(upload.status.capitalized)
                            } currentValueLabel: {
                                Text(upload.message ?? "\(upload.progress ?? 0)%")
                            }
                        } else if upload.status == "complete" {
                            Label(upload.message ?? "Firmware uploaded. Start the update from the printer's screen.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if upload.status == "error" {
                            Label(upload.error ?? upload.message ?? "Upload failed", systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                if session.can("firmware:update") {
                    Section {
                        if info.updateAvailable {
                            Button {
                                Task { await startPrepare(nil) }
                            } label: {
                                Label("Upload \(info.latestVersion ?? "Latest") to SD Card…", systemImage: "square.and.arrow.up")
                            }
                            .disabled(upload?.isActive == true || runner.isRunning)
                        }
                    } footer: {
                        Text("Bambuddy downloads the firmware and copies it to the printer's SD card. Afterwards, start the update on the printer's screen (Settings › Firmware).")
                    }
                }
                if let notes = info.releaseNotes, !notes.isEmpty {
                    Section("Release Notes") {
                        Text(markdown(notes)).font(.callout)
                    }
                }
                if let versions = info.availableVersions, !versions.isEmpty {
                    Section("Available Versions") {
                        ForEach(versions, id: \.version) { v in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(v.version).font(.body.monospacedDigit())
                                    if let t = v.releaseTime { Text(Fmt.date(t, style: .dateTime.month().day().year())).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if v.version == info.currentVersion { StatusBadge(text: "Installed", color: .green) }
                                if !v.fileAvailable { StatusBadge(text: "No file", color: .secondary) }
                            }
                            .contentShape(.rect)
                            .contextMenu {
                                if v.releaseNotes?.isEmpty == false {
                                    Button { notesVersion = v } label: { Label("Release Notes", systemImage: "doc.text") }
                                }
                                if session.can("firmware:update"), v.fileAvailable, v.version != info.currentVersion {
                                    Button { Task { await startPrepare(v.version) } } label: { Label("Upload to SD Card…", systemImage: "square.and.arrow.up") }
                                }
                            }
                            .swipeActions {
                                if session.can("firmware:update"), v.fileAvailable, v.version != info.currentVersion {
                                    Button("Upload") { Task { await startPrepare(v.version) } }.tint(.accentColor)
                                }
                            }
                            .onTapGesture { if v.releaseNotes?.isEmpty == false { notesVersion = v } }
                        }
                    }
                }
            }
        }
        .navigationTitle("Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .task(id: live.revision("firmware_upload_progress")) { await refreshUploadStatus() }
        .task(id: upload?.isActive == true) {
            // Polling fallback while an upload runs.
            while upload?.isActive == true, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await refreshUploadStatus()
            }
        }
        .actionAlerts(runner)
        .alert("Upload Firmware?", isPresented: $confirmUpload, presenting: prepare) { p in
            Button("Upload") { Task { await startUpload() } }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(prepareMessage(p))
        }
        .sheet(item: $notesVersion) { v in
            NavigationStack {
                ScrollView { Text(markdown(v.releaseNotes ?? "")).padding().frame(maxWidth: .infinity, alignment: .leading) }
                    .navigationTitle(v.version)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { notesVersion = nil } } }
            }
        }
    }

    private func load() async {
        await loader.load { try await client.get("firmware/updates/\(printerId)") }
        await refreshUploadStatus()
    }

    private func refreshUploadStatus() async {
        if let s: PrinterFirmwareUploadStatus = try? await client.get("firmware/updates/\(printerId)/upload/status") { upload = s }
    }

    private func startPrepare(_ version: String?) async {
        await runner.run {
            let p: PrinterFirmwarePrepare = try await client.get("firmware/updates/\(printerId)/prepare", query: ["version": .of(version)])
            if !p.canProceed {
                throw APIError(status: 400, message: (p.errors ?? []).joined(separator: "\n").nilIfBlank ?? "The firmware cannot be uploaded right now.", code: nil, detail: nil)
            }
            pendingVersion = version
            prepare = p
            confirmUpload = true
        }
    }

    private func startUpload() async {
        await runner.run {
            let r: PrinterFirmwareUploadStart = try await client.send(.post, "firmware/updates/\(printerId)/upload", query: ["version": .of(pendingVersion)])
            runner.successMessage = r.started ? "Upload started" : r.message
            await refreshUploadStatus()
        }
    }

    private func prepareMessage(_ p: PrinterFirmwarePrepare) -> String {
        var lines = ["\(p.currentVersion ?? "?") → \(p.targetVersion ?? p.latestVersion ?? "?")"]
        if let size = p.firmwareSize, size > 0 { lines.append("Download size: \(Fmt.bytes(size))") }
        if let free = p.sdCardFreeSpace, free >= 0 { lines.append("SD card free: \(Fmt.bytes(free))") }
        lines.append("The file is copied to the SD card; the printer is not updated until you confirm on its screen.")
        return lines.joined(separator: "\n")
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

extension PrinterFirmwareVersion: Identifiable { var id: String { version } }

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
