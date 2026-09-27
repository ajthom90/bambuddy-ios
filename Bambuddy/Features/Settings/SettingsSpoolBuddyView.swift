import SwiftUI
import UIKit

// MARK: - Models

/// A registered SpoolBuddy kiosk (`GET /spoolbuddy/devices`, schema `DeviceResponse`).
struct SettingsSpoolBuddyDevice: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var deviceId: String
    var hostname: String?
    var ipAddress: String?
    var firmwareVersion: String?
    var hasNfc: Bool?
    var hasScale: Bool?
    var tareOffset: Int?
    var calibrationFactor: Double?
    var nfcReaderType: String?
    var nfcConnection: String?
    var backendUrl: String?
    var displayBrightness: Int?
    var displayBlankTimeout: Int?
    var hasBacklight: Bool?
    var lastCalibratedAt: String?
    var lastSeen: String?
    var pendingCommand: String?
    var nfcOk: Bool?
    var scaleOk: Bool?
    var uptimeS: Int?
    /// `pending`, `updating`, `complete` or `error`.
    var updateStatus: String?
    var updateMessage: String?
    var systemStats: SettingsSpoolBuddySystemStats?
    var online: Bool?
    var sshPublicKey: String?
    var createdAt: String?
    var updatedAt: String?

    var displayName: String {
        let h = (hostname ?? "").trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? deviceId : h
    }
    var isOnline: Bool { online ?? false }
}

/// Host statistics reported by the device daemon. The payload is free-form, so every field is
/// decoded leniently (a malformed value is dropped rather than failing the whole device list).
struct SettingsSpoolBuddySystemStats: Codable, Sendable, Hashable {
    var os: SettingsSpoolBuddyOSInfo?
    var cpuTempC: Double?
    var cpuCount: Double?
    var loadAvg: [Double]?
    var memory: SettingsSpoolBuddyMemory?
    var disk: SettingsSpoolBuddyDisk?
    var systemUptimeS: Double?

    enum CodingKeys: String, CodingKey {
        case os, cpuTempC, cpuCount, loadAvg, memory, disk, systemUptimeS
    }

    init(os: SettingsSpoolBuddyOSInfo? = nil, cpuTempC: Double? = nil, cpuCount: Double? = nil, loadAvg: [Double]? = nil,
         memory: SettingsSpoolBuddyMemory? = nil, disk: SettingsSpoolBuddyDisk? = nil, systemUptimeS: Double? = nil) {
        self.os = os; self.cpuTempC = cpuTempC; self.cpuCount = cpuCount; self.loadAvg = loadAvg
        self.memory = memory; self.disk = disk; self.systemUptimeS = systemUptimeS
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        os = try? c.decodeIfPresent(SettingsSpoolBuddyOSInfo.self, forKey: .os)
        cpuTempC = try? c.decodeIfPresent(Double.self, forKey: .cpuTempC)
        cpuCount = try? c.decodeIfPresent(Double.self, forKey: .cpuCount)
        loadAvg = try? c.decodeIfPresent([Double].self, forKey: .loadAvg)
        memory = try? c.decodeIfPresent(SettingsSpoolBuddyMemory.self, forKey: .memory)
        disk = try? c.decodeIfPresent(SettingsSpoolBuddyDisk.self, forKey: .disk)
        systemUptimeS = try? c.decodeIfPresent(Double.self, forKey: .systemUptimeS)
    }
}

struct SettingsSpoolBuddyOSInfo: Codable, Sendable, Hashable {
    var os: String?
    var kernel: String?
    var arch: String?
    var python: String?
}

struct SettingsSpoolBuddyMemory: Codable, Sendable, Hashable {
    var totalMb: Double?
    var availableMb: Double?
    var usedMb: Double?
    var percent: Double?
}

struct SettingsSpoolBuddyDisk: Codable, Sendable, Hashable {
    var totalGb: Double?
    var usedGb: Double?
    var freeGb: Double?
    var percent: Double?
}

/// `GET /spoolbuddy/devices/{id}/update-check`.
struct SettingsSpoolBuddyUpdateCheck: Codable, Sendable {
    var currentVersion: String?
    var latestVersion: String?
    var updateAvailable: Bool?
}

/// Response of the update / system-command endpoints.
struct SettingsSpoolBuddyActionResponse: Codable, Sendable {
    var status: String?
    var message: String?
    var command: String?
}

/// `GET /spoolbuddy/ssh/public-key`.
struct SettingsSpoolBuddySSHKey: Codable, Sendable {
    var publicKey: String?
}

/// Body for `POST /spoolbuddy/devices/{id}/system/command`.
struct SettingsSpoolBuddyCommandRequest: Encodable, Sendable {
    var command: String
}

/// Remote actions offered for a device. All except `update` go through `system/command`.
enum SettingsSpoolBuddyCommand: String, CaseIterable, Identifiable, Sendable {
    case update
    case restartBrowser = "restart_browser"
    case restartDaemon = "restart_daemon"
    case reboot
    case shutdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .update: "Update Software"
        case .restartBrowser: "Restart Display"
        case .restartDaemon: "Restart Service"
        case .reboot: "Reboot"
        case .shutdown: "Shut Down"
        }
    }

    var systemImage: String {
        switch self {
        case .update: "arrow.down.circle"
        case .restartBrowser: "display"
        case .restartDaemon: "arrow.clockwise"
        case .reboot: "restart"
        case .shutdown: "power"
        }
    }

    var isDestructive: Bool { self == .reboot || self == .shutdown }

    func confirmation(for host: String) -> String {
        switch self {
        case .update: "Bambuddy connects to \(host) over SSH, installs the matching SpoolBuddy version and restarts its service."
        case .restartBrowser: "The kiosk browser on \(host) reloads. The screen goes blank for a few seconds."
        case .restartDaemon: "The SpoolBuddy service on \(host) restarts. NFC and scale readings pause briefly."
        case .reboot: "\(host) restarts and is offline for about a minute."
        case .shutdown: "\(host) powers off. You'll need physical access to turn it back on."
        }
    }
}

// MARK: - Shared state

@MainActor
@Observable
final class SettingsSpoolBuddyDeviceModel {
    var devices: [SettingsSpoolBuddyDevice] = []
    var hasLoaded = false
    var error: String?

    func device(_ deviceID: String) -> SettingsSpoolBuddyDevice? { devices.first { $0.deviceId == deviceID } }

    func load(client: APIClient) async {
        do {
            let list: [SettingsSpoolBuddyDevice] = try await client.get("spoolbuddy/devices")
            devices = list
            error = nil
            hasLoaded = true
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            if !hasLoaded { self.error = error.localizedDescription }
        }
    }

    func remove(_ deviceID: String) { devices.removeAll { $0.deviceId == deviceID } }
}

// MARK: - Page

struct SettingsSpoolBuddyView: View {
    @Environment(AppSession.self) private var session
    @Environment(LiveUpdates.self) private var live
    @State private var model = SettingsSpoolBuddyDeviceModel()
    @State private var runner = ActionRunner()
    @State private var pendingUnregister: SettingsSpoolBuddyDevice?
    @State private var sshKey: String?

    private static let liveEvents = ["spoolbuddy_online", "spoolbuddy_offline", "spoolbuddy_unregistered", "spoolbuddy_update"]

    var body: some View {
        Group {
            if !session.can("inventory:read") {
                ContentUnavailableView("No Access", systemImage: "lock",
                                       description: Text("Viewing SpoolBuddy devices requires inventory access."))
            } else if model.hasLoaded {
                list
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn't Load Devices", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Try Again") { Task { await model.load(client: session.client) } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("SpoolBuddy")
        .task(id: live.revision(Self.liveEvents)) {
            guard session.can("inventory:read") else { return }
            await model.load(client: session.client)
        }
        .task {
            guard session.can("inventory:read") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await model.load(client: session.client)
            }
        }
        .task {
            guard session.can("settings:read"), sshKey == nil else { return }
            if let key: SettingsSpoolBuddySSHKey = try? await session.client.get("spoolbuddy/ssh/public-key") {
                sshKey = key.publicKey
            }
        }
        .confirm("Unregister \(pendingUnregister?.displayName ?? "Device")?",
                 isPresented: Binding(get: { pendingUnregister != nil }, set: { if !$0 { pendingUnregister = nil } }),
                 message: "The device is removed from Bambuddy. If it's still running it registers itself again on its next heartbeat.",
                 action: "Unregister") {
            if let device = pendingUnregister { Task { await unregister(device) } }
        }
        .actionAlerts(runner)
    }

    private var list: some View {
        List {
            Section {
                Label {
                    Text("SpoolBuddy is a companion kiosk with an NFC reader and scale for identifying and weighing spools. Devices register automatically when their service connects to this server.")
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "info.circle").foregroundStyle(.blue)
                }
            }

            if model.devices.count > 1 {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(model.devices.count) devices registered").fontWeight(.semibold)
                            Text("If you only own one SpoolBuddy, the extra entries are probably left over from a reinstall or a hostname change. Unregister the ones that stay offline.")
                                .font(.footnote)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                }
            }

            Section("Devices") {
                if model.devices.isEmpty {
                    ContentUnavailableView("No Devices", systemImage: "scalemass",
                                           description: Text("No SpoolBuddy has connected to this server yet."))
                } else {
                    ForEach(model.devices) { device in
                        NavigationLink {
                            SettingsSpoolBuddyDeviceDetailView(deviceID: device.deviceId, model: model)
                        } label: {
                            SettingsSpoolBuddyDeviceRow(device: device)
                        }
                        .swipeActions(edge: .trailing) {
                            if session.can("inventory:delete") {
                                Button("Unregister", systemImage: "trash", role: .destructive) { pendingUnregister = device }
                            }
                        }
                        .contextMenu {
                            if let ip = device.ipAddress, !ip.isEmpty {
                                Button("Copy IP Address", systemImage: "doc.on.doc") { UIPasteboard.general.string = ip }
                            }
                            if session.can("inventory:delete") {
                                Button("Unregister", systemImage: "trash", role: .destructive) { pendingUnregister = device }
                            }
                        }
                    }
                }
            }

            if let sshKey, !sshKey.isEmpty {
                Section {
                    Text(sshKey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(4)
                    Button("Copy Public Key", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = sshKey
                        runner.successMessage = "Key copied"
                    }
                    ShareLink(item: sshKey) { Label("Share Public Key", systemImage: "square.and.arrow.up") }
                } header: {
                    Text("Update Key")
                } footer: {
                    Text("Bambuddy updates SpoolBuddy devices over SSH with this key. Devices receive it automatically when they check in; if an update fails to authenticate, add it to the device user's authorized_keys by hand.")
                }
            }
        }
        .refreshable { await model.load(client: session.client) }
    }

    private func unregister(_ device: SettingsSpoolBuddyDevice) async {
        await runner.run("Device unregistered") {
            try await session.client.call(.delete, "spoolbuddy/devices/\(device.deviceId)")
            model.remove(device.deviceId)
        }
    }
}

private struct SettingsSpoolBuddyDeviceRow: View {
    let device: SettingsSpoolBuddyDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isOnline ? "wifi" : "wifi.slash")
                .foregroundStyle(device.isOnline ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName).font(.body.weight(.medium)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusBadge(text: device.isOnline ? "Online" : "Offline", color: device.isOnline ? .green : .secondary)
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts: [String] = []
        if let ip = device.ipAddress, !ip.isEmpty { parts.append(ip) }
        if let fw = device.firmwareVersion, !fw.isEmpty { parts.append("v\(fw)") }
        parts.append(device.lastSeen == nil ? "Never seen" : "Seen \(Fmt.relative(device.lastSeen))")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Device detail

struct SettingsSpoolBuddyDeviceDetailView: View {
    let deviceID: String
    let model: SettingsSpoolBuddyDeviceModel

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var updateCheck: SettingsSpoolBuddyUpdateCheck?
    @State private var pendingCommand: SettingsSpoolBuddyCommand?
    @State private var confirmUnregister = false

    private var device: SettingsSpoolBuddyDevice? { model.device(deviceID) }

    var body: some View {
        Group {
            if let device {
                form(device)
            } else {
                ContentUnavailableView("Device Not Found", systemImage: "scalemass",
                                       description: Text("It may have been unregistered."))
            }
        }
        .navigationTitle(device?.displayName ?? "SpoolBuddy")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            updateCheck = try? await session.client.get("spoolbuddy/devices/\(deviceID)/update-check")
        }
        .refreshable {
            await model.load(client: session.client)
            updateCheck = try? await session.client.get("spoolbuddy/devices/\(deviceID)/update-check")
        }
        .confirmationDialog(pendingCommand.map { "\($0.title)?" } ?? "",
                            isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } }),
                            titleVisibility: .visible, presenting: pendingCommand) { command in
            Button(command.title, role: command.isDestructive ? .destructive : nil) {
                Task { await run(command) }
            }
        } message: { command in
            Text(command.confirmation(for: device?.displayName ?? "the device"))
        }
        .confirm("Unregister \(device?.displayName ?? "Device")?", isPresented: $confirmUnregister,
                 message: "The device is removed from Bambuddy. If it's still running it registers itself again on its next heartbeat.",
                 action: "Unregister") {
            Task { await unregister() }
        }
        .actionAlerts(runner)
    }

    private func form(_ device: SettingsSpoolBuddyDevice) -> some View {
        Form {
            Section {
                LabeledContent("Status") {
                    StatusBadge(text: device.isOnline ? "Online" : "Offline", color: device.isOnline ? .green : .secondary)
                }
                InfoRow("Device ID", device.deviceId)
                InfoRow("IP Address", device.ipAddress)
                InfoRow("Version", device.firmwareVersion)
                LabeledContent("Last Seen", value: device.lastSeen == nil ? "Never" : Fmt.relative(device.lastSeen))
                if let uptime = device.uptimeS { LabeledContent("Service Uptime", value: Fmt.duration(seconds: Double(uptime))) }
                if let url = device.backendUrl, !url.isEmpty { InfoRow("Server Address", url) }
                if let command = device.pendingCommand, !command.isEmpty {
                    LabeledContent("Queued Command", value: command.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }

            Section("Hardware") {
                hardwareRow("NFC Reader", ok: device.nfcOk, present: device.hasNfc,
                            detail: [device.nfcReaderType, device.nfcConnection].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                hardwareRow("Scale", ok: device.scaleOk, present: device.hasScale, detail: nil)
                if device.hasScale == true {
                    if let tare = device.tareOffset { LabeledContent("Tare Offset", value: "\(tare)") }
                    if let factor = device.calibrationFactor {
                        LabeledContent("Calibration Factor", value: factor.formatted(.number.precision(.fractionLength(0...4))))
                    }
                    if let calibrated = device.lastCalibratedAt { LabeledContent("Last Calibrated", value: Fmt.relative(calibrated)) }
                }
                if device.hasBacklight == true, let brightness = device.displayBrightness {
                    LabeledContent("Display Brightness", value: "\(brightness)%")
                }
                if let timeout = device.displayBlankTimeout {
                    LabeledContent("Screen Blanking", value: timeout == 0 ? "Never" : Fmt.duration(seconds: Double(timeout)))
                }
            }

            if let stats = device.systemStats { statsSection(stats) }

            updateSection(device)

            if session.can("inventory:update") {
                Section {
                    ForEach(SettingsSpoolBuddyCommand.allCases.filter { $0 != .update }) { command in
                        Button(role: command.isDestructive ? .destructive : nil) {
                            pendingCommand = command
                        } label: {
                            Label(command.title, systemImage: command.systemImage)
                        }
                        .disabled(!device.isOnline || runner.isRunning)
                    }
                } header: {
                    Text("Remote Control")
                } footer: {
                    Text(device.isOnline
                         ? "Commands are picked up by the device on its next heartbeat, within a few seconds."
                         : "The device is offline, so it can't receive commands.")
                }
            }

            if session.can("inventory:delete") {
                Section {
                    Button("Unregister Device", role: .destructive) { confirmUnregister = true }
                }
            }
        }
    }

    private func hardwareRow(_ title: String, ok: Bool?, present: Bool?, detail: String?) -> some View {
        LabeledContent {
            if present == false {
                Text("Not Installed").foregroundStyle(.secondary)
            } else if ok == true {
                Label("Working", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Not Responding", systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
        } label: {
            SettingsLabel(title, help: (detail ?? "").isEmpty ? nil : detail)
        }
    }

    private func statsSection(_ stats: SettingsSpoolBuddySystemStats) -> some View {
        Section {
            if let temp = stats.cpuTempC {
                LabeledContent("CPU Temperature", value: "\(temp.formatted(.number.precision(.fractionLength(1)))) °C")
            }
            if let load = stats.loadAvg?.first {
                let loadText = load.formatted(.number.precision(.fractionLength(2)))
                if let cores = stats.cpuCount, cores > 0 {
                    LabeledContent("CPU Load", value: "\(loadText) of \(Int(cores)) cores (\(Int((load / cores * 100).rounded()))%)")
                } else {
                    LabeledContent("CPU Load", value: loadText)
                }
            }
            if let mem = stats.memory, let percent = mem.percent {
                LabeledContent("Memory", value: "\(Int(percent.rounded()))% (\(megabytes(mem.usedMb)) of \(megabytes(mem.totalMb)))")
            }
            if let disk = stats.disk, let percent = disk.percent {
                LabeledContent("Storage", value: "\(Int(percent.rounded()))% (\(gigabytes(disk.usedGb)) of \(gigabytes(disk.totalGb)))")
            }
            if let uptime = stats.systemUptimeS {
                LabeledContent("System Uptime", value: Fmt.duration(seconds: uptime))
            }
            if let os = stats.os {
                let parts = [os.os, os.kernel, os.arch, os.python.map { "Python \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("System")
        }
    }

    private func updateSection(_ device: SettingsSpoolBuddyDevice) -> some View {
        Section {
            if let check = updateCheck {
                LabeledContent("Installed", value: check.currentVersion ?? "—")
                LabeledContent("Server Version", value: check.latestVersion ?? "—")
                if check.updateAvailable == true {
                    Label("An update is available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
                } else {
                    Label("Up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            if let status = device.updateStatus, !status.isEmpty {
                LabeledContent("Last Update") {
                    StatusBadge(text: status.capitalized, color: updateColor(status))
                }
                if let message = device.updateMessage, !message.isEmpty {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if session.can("inventory:update") {
                Button {
                    pendingCommand = .update
                } label: {
                    Label(SettingsSpoolBuddyCommand.update.title, systemImage: SettingsSpoolBuddyCommand.update.systemImage)
                }
                .disabled(!device.isOnline || runner.isRunning || device.updateStatus == "updating")
            }
        } header: {
            Text("Software")
        } footer: {
            Text("Updating installs the SpoolBuddy version that matches this Bambuddy server.")
        }
    }

    private func updateColor(_ status: String) -> Color {
        switch status {
        case "complete": .green
        case "error": .red
        case "updating", "pending": .blue
        default: .secondary
        }
    }

    private func megabytes(_ mb: Double?) -> String {
        guard let mb else { return "—" }
        return mb >= 1024 ? "\((mb / 1024).formatted(.number.precision(.fractionLength(1)))) GB" : "\(Int(mb.rounded())) MB"
    }

    private func gigabytes(_ gb: Double?) -> String {
        guard let gb else { return "—" }
        return "\(gb.formatted(.number.precision(.fractionLength(1)))) GB"
    }

    // MARK: Actions

    private func run(_ command: SettingsSpoolBuddyCommand) async {
        await runner.run {
            let response: SettingsSpoolBuddyActionResponse
            if command == .update {
                response = try await session.client.send(.post, "spoolbuddy/devices/\(deviceID)/update",
                                                         body: JSONValue.object([:]))
            } else {
                response = try await session.client.send(.post, "spoolbuddy/devices/\(deviceID)/system/command",
                                                         body: SettingsSpoolBuddyCommandRequest(command: command.rawValue))
            }
            runner.successMessage = response.status == "already_updating"
                ? "An update is already running"
                : (command == .update ? "Update started" : "Command sent")
            await model.load(client: session.client)
        }
    }

    private func unregister() async {
        await runner.run("Device unregistered") {
            try await session.client.call(.delete, "spoolbuddy/devices/\(deviceID)")
            model.remove(deviceID)
            dismiss()
        }
    }
}
