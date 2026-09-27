import SwiftUI
import UIKit

/// Bambuddy software updates and printer firmware availability.
struct SettingsUpdatesView: View {
    @Environment(ServerSettingsStore.self) private var store
    @Environment(AppSession.self) private var session

    @State private var version: SettingsUpdateVersion?
    @State private var check: SettingsUpdateCheck?
    @State private var checkError: String?
    @State private var isChecking = false
    @State private var status: SettingsUpdateStatus?
    @State private var pollToken = 0
    @State private var confirmInstall = false
    @State private var notes: UpdateNotesItem?
    @State private var runner = ActionRunner()
    @State private var firmware = Loader<SettingsFirmwareUpdates>()
    @State private var latestFirmware = Loader<[SettingsFirmwareLatest]>()

    private var canCheck: Bool { session.can("system:read") }
    private var canReadFirmware: Bool { session.can("firmware:read") }

    var body: some View {
        SettingsForm("Updates") {
            softwareSection
            if check != nil || checkError != nil || status?.isRunning == true {
                resultSection
            }
            firmwareSection
            if canReadFirmware { latestFirmwareSection }
        }
        .actionAlerts(runner)
        .confirm("Install Update?", isPresented: $confirmInstall,
                 message: "The server downloads and installs version \(check?.latestVersion ?? "") and must be restarted afterwards. Prints already running on your printers continue, but the server is unreachable while it restarts.",
                 action: "Install", role: nil) {
            Task { await install() }
        }
        .sheet(item: $notes) { item in
            UpdateNotesSheet(item: item)
        }
        .task { await initialLoad() }
        .task(id: pollToken) { await pollStatus() }
    }

    // MARK: Sections

    @ViewBuilder private var softwareSection: some View {
        let checksEnabled = store.bool("check_updates", default: true)
        Section {
            LabeledContent("Installed Version") {
                Text(version?.version ?? session.serverVersion ?? "—").monospacedDigit()
            }
            SettingsToggle("Check for Updates", key: "check_updates", help: "Look for new Bambuddy releases on GitHub.", default: true)
            SettingsToggle("Include Beta Releases", key: "include_beta_updates", help: "Also offer prerelease versions.")
                .disabled(!checksEnabled)
            if canCheck {
                Button {
                    Task { await runCheck() }
                } label: {
                    HStack {
                        Label("Check Now", systemImage: "arrow.clockwise")
                        if isChecking { Spacer(); ProgressView() }
                    }
                }
                .disabled(isChecking || !checksEnabled)
            }
        } header: {
            Text("Bambuddy")
        } footer: {
            if !checksEnabled { Text("Turn on update checks to look for new releases.") }
        }
    }

    @ViewBuilder private var resultSection: some View {
        Section {
            if let status, status.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.message ?? "Updating…").font(.subheadline)
                    ProgressView(value: min(max((status.progress ?? 0) / 100, 0), 1))
                }
                .padding(.vertical, 4)
            } else if let status, status.status == "complete" {
                Label(status.message ?? "Update installed. Restart the server to finish.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if let status, status.status == "error", pollToken > 0 {
                Label(status.error ?? status.message ?? "The update failed.", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            if let checkError {
                Label(checkError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let check {
                if let error = check.error {
                    Label(retryText(error, check.retryAfterSeconds), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if check.updateAvailable == true {
                    availableRows(check)
                } else if let message = check.message, check.latestVersion == nil {
                    Text(message).foregroundStyle(.secondary)
                } else {
                    Label("Bambuddy is up to date.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("Latest Release")
        } footer: {
            if check?.updateAvailable == true, status?.isRunning != true { installFooter }
        }
    }

    @ViewBuilder private func availableRows(_ check: SettingsUpdateCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Version \(check.latestVersion ?? "?") Available", systemImage: "arrow.down.circle.fill")
                .font(.headline)
                .foregroundStyle(.tint)
            if let name = check.releaseName, !name.isEmpty, name != check.latestVersion, name != "v\(check.latestVersion ?? "")" {
                Text(name).font(.subheadline).foregroundStyle(.secondary)
            }
            if let published = check.publishedAt {
                Text("Released \(Fmt.date(published, style: .dateTime.month(.abbreviated).day().year()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)

        if let releaseNotes = check.releaseNotes, !releaseNotes.isEmpty {
            Button {
                notes = UpdateNotesItem(title: "Version \(check.latestVersion ?? "")", markdown: releaseNotes,
                                        link: check.releaseUrl.flatMap(URL.init(string:)))
            } label: {
                Label("Release Notes", systemImage: "doc.text")
            }
        }
        if let link = check.releaseUrl.flatMap(URL.init(string:)) {
            Link(destination: link) { Label("View Release on GitHub", systemImage: "safari") }
        }

        if status?.isRunning != true {
            switch check.resolvedMethod {
            case "docker":
                dockerRows(check)
            case "windows_installer":
                if let url = (check.installerDownloadUrl ?? check.releaseUrl).flatMap(URL.init(string:)) {
                    Link(destination: url) { Label("Download Windows Installer", systemImage: "arrow.down.to.line") }
                }
            case "ha_addon":
                EmptyView()
            default:
                if session.can("settings:update") {
                    Button {
                        confirmInstall = true
                    } label: {
                        HStack {
                            Label("Install Update", systemImage: "square.and.arrow.down")
                            if runner.isRunning { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(runner.isRunning)
                }
            }
        }
    }

    @ViewBuilder private func dockerRows(_ check: SettingsUpdateCheck) -> some View {
        let command = SettingsUpdateInstructions.composeCommand(savedDirectory: store.string("docker_compose_dir"),
                                                                detectedDirectory: check.composeDirDetected)
        VStack(alignment: .leading, spacing: 8) {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.fill.tertiary, in: .rect(cornerRadius: 8))
            Button {
                UIPasteboard.general.string = command
                runner.successMessage = "Command copied"
            } label: {
                Label("Copy Command", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        SettingsTextField("Compose Directory", key: "docker_compose_dir",
                          prompt: check.composeDirDetected?.isEmpty == false ? check.composeDirDetected : "/opt/bambuddy",
                          help: "Folder on the host that contains docker-compose.yml. Leave empty to use the detected folder.")
    }

    @ViewBuilder private var installFooter: some View {
        switch check?.resolvedMethod {
        case "docker":
            Text("This server runs in Docker and can't update itself. Run the command above on the host to pull the new image and restart the container.")
        case "ha_addon":
            Text("This server runs as a Home Assistant add-on. Update it from Home Assistant's add-on page; the Supervisor handles the upgrade.")
        case "windows_installer":
            Text("This server was installed with the Windows installer. Download and run the new installer to upgrade; your data is kept.")
        default:
            if session.can("settings:update") {
                Text("The server installs the update itself. Restart it when the installation finishes.")
            } else {
                Text("Ask an administrator to install this update.")
            }
        }
    }

    @ViewBuilder private var firmwareSection: some View {
        Section {
            SettingsToggle("Check Printer Firmware", key: "check_printer_firmware",
                           help: "Compare each printer's firmware with the latest version published by Bambu Lab.", default: true)
            if canReadFirmware {
                if let updates = firmware.value?.updates {
                    if updates.isEmpty {
                        Text("No active printers.").foregroundStyle(.secondary)
                    }
                    ForEach(updates) { info in
                        NavigationLink {
                            UpdatesFirmwareDetail(info: info)
                        } label: {
                            UpdatesFirmwareRow(info: info)
                        }
                    }
                } else if let error = firmware.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if firmware.isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        } header: {
            Text("Printer Firmware")
        } footer: {
            if let count = firmware.value?.updatesAvailable, count > 0 {
                Text("\(count) printer\(count == 1 ? " has" : "s have") a firmware update available. Updates are installed from each printer's page.")
            }
        }
    }

    @ViewBuilder private var latestFirmwareSection: some View {
        if let latest = latestFirmware.value, !latest.isEmpty {
            Section("Latest Firmware by Model") {
                ForEach(latest) { item in
                    Button {
                        notes = UpdateNotesItem(title: "\(item.familyName) \(item.version ?? "")", markdown: item.releaseNotes ?? "",
                                                link: item.downloadUrl.flatMap(URL.init(string:)), linkTitle: "Download Firmware")
                    } label: {
                        LabeledContent(item.familyName) {
                            Text(item.version ?? "—").monospacedDigit()
                        }
                        .contentShape(.rect)
                    }
                    .tint(.primary)
                }
            }
        }
    }

    // MARK: Actions

    private func retryText(_ error: String, _ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return error }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        return "\(error) (try again in about \(minutes) minute\(minutes == 1 ? "" : "s"))"
    }

    private func initialLoad() async {
        let client = session.client
        if !store.hasLoaded { await store.load() }
        async let versionTask: SettingsUpdateVersion? = try? client.get("updates/version")
        if canCheck {
            status = try? await client.get("updates/status")
            if status?.isRunning == true { pollToken += 1 }
            if store.bool("check_updates", default: true), check == nil { await runCheck() }
        }
        version = await versionTask
        await loadFirmware()
    }

    private func loadFirmware() async {
        guard canReadFirmware else { return }
        let client = session.client
        await firmware.load { try await client.get("firmware/updates") }
        await latestFirmware.load { try await client.get("firmware/latest") }
    }

    private func runCheck() async {
        guard canCheck else { return }
        isChecking = true
        defer { isChecking = false }
        do {
            check = try await session.client.get("updates/check")
            checkError = nil
        } catch {
            checkError = error.localizedDescription
        }
    }

    private func install() async {
        await runner.run {
            let result: SettingsUpdateApplyResult = try await session.client.send(.post, "updates/apply")
            if let s = result.status { status = s }
            if result.success == true {
                pollToken += 1
            } else {
                throw UpdatesMessageError(message: result.message ?? "The server couldn't start the update.")
            }
        }
    }

    /// Polls the update status every second while an installation is running.
    private func pollStatus() async {
        guard pollToken > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if let next: SettingsUpdateStatus = try? await session.client.get("updates/status") {
                status = next
                if !next.isRunning { return }
            }
        }
    }
}

private struct UpdatesMessageError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Firmware rows

private struct UpdatesFirmwareRow: View {
    let info: SettingsFirmwareUpdateInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.printerName ?? "Printer \(info.printerId)")
                Text(versionLine).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if info.updateAvailable == true {
                StatusBadge(text: "Update", color: .orange)
            } else if info.currentVersion == nil {
                StatusBadge(text: "Unknown", color: .secondary)
            } else {
                StatusBadge(text: "Current", color: .green)
            }
        }
    }

    private var versionLine: String {
        let model = info.model.map { "\($0) · " } ?? ""
        let current = info.currentVersion ?? "offline"
        if info.updateAvailable == true, let latest = info.latestVersion { return "\(model)\(current) → \(latest)" }
        return model + current
    }
}

private struct UpdatesFirmwareDetail: View {
    let info: SettingsFirmwareUpdateInfo

    var body: some View {
        List {
            Section {
                InfoRow("Model", info.model)
                InfoRow("Installed", info.currentVersion ?? "Unknown (printer offline)")
                InfoRow("Latest", info.latestVersion)
                if let url = info.downloadUrl.flatMap(URL.init(string:)) {
                    Link(destination: url) { Label("Download Firmware File", systemImage: "arrow.down.to.line") }
                }
            } footer: {
                if info.updateAvailable == true {
                    Text("Install firmware from the printer's page, or from the printer itself.")
                }
            }

            if let notes = info.releaseNotes, !notes.isEmpty {
                Section("Release Notes") {
                    UpdatesMarkdownView(markdown: notes).padding(.vertical, 4)
                }
            }

            if let versions = info.availableVersions, versions.count > 1 {
                Section("Available Versions") {
                    ForEach(versions, id: \.version) { v in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(v.version).monospacedDigit()
                                Spacer()
                                if v.version == info.currentVersion { StatusBadge(text: "Installed", color: .green) }
                                if v.fileAvailable == false { StatusBadge(text: "No File", color: .secondary) }
                            }
                            if let time = v.releaseTime, !time.isEmpty {
                                Text(Fmt.date(time, style: .dateTime.month(.abbreviated).day().year())).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(info.printerName ?? "Firmware")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Release notes sheet

private struct UpdateNotesItem: Identifiable {
    let id = UUID()
    let title: String
    let markdown: String
    var link: URL?
    var linkTitle = "View on GitHub"
}

private struct UpdateNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: UpdateNotesItem

    var body: some View {
        NavigationStack {
            ScrollView {
                if item.markdown.isEmpty {
                    ContentUnavailableView("No Release Notes", systemImage: "doc.text")
                } else {
                    UpdatesMarkdownView(markdown: item.markdown)
                        .padding()
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let link = item.link {
                    ToolbarItem(placement: .bottomBar) {
                        Link(destination: link) { Label(item.linkTitle, systemImage: "safari").labelStyle(.titleAndIcon) }
                    }
                }
            }
        }
    }
}

/// Renders release-note Markdown as native text blocks.
private struct UpdatesMarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = SettingsUpdateMarkdown.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(SettingsUpdateMarkdown.inline(text))
                        .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                        .padding(.top, level <= 2 ? 6 : 2)
                case .bullet(let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(SettingsUpdateMarkdown.inline(text))
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .numbered(let marker, let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(SettingsUpdateMarkdown.inline(text))
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .paragraph(let text):
                    Text(SettingsUpdateMarkdown.inline(text))
                case .rule:
                    Divider()
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
