import SwiftUI

// MARK: - Scale calibration

/// Two-step scale calibration: zero with an empty scale, then measure a known weight.
struct SpoolBuddyCalibrationView: View {
    @Environment(AppSession.self) private var session
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store
    let deviceId: String

    private enum Step { case idle, empty, weight, done }

    @State private var step: Step = .idle
    @State private var knownWeight: Double = 500
    @State private var tareRaw: Int?
    @State private var result: SpoolBuddyCalibration?
    @State private var runner = ActionRunner()

    private var device: SpoolBuddyDevice? { store.devices.value?.first { $0.deviceId == deviceId } }
    private var reading: SpoolBuddyLiveState.Reading? { liveState.readings[deviceId] }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    SpoolBuddyWeightText(reading: reading, font: .system(size: 44, weight: .semibold, design: .rounded))
                    if let raw = reading?.rawAdc {
                        Text("Raw reading \(raw)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                if let device {
                    LabeledContent("Tare Offset", value: "\(result?.tareOffset ?? device.tareOffset)")
                    LabeledContent("Calibration Factor", value: String(format: "%.6f", result?.calibrationFactor ?? device.calibrationFactor))
                    LabeledContent("Last Calibrated", value: device.lastCalibratedAt.map { Fmt.date($0) } ?? "Never")
                }
            } header: {
                Text("Live Reading")
            } footer: {
                if reading == nil { Text("Waiting for readings from the station…") }
            }

            switch step {
            case .idle, .done:
                Section {
                    Button { Task { await tare() } } label: { Label("Tare (Set Zero)", systemImage: "scalemass") }
                    Button { step = .empty } label: { Label("Calibrate with a Known Weight", systemImage: "dial.medium") }
                } footer: {
                    if step == .done {
                        Text("Calibration saved. Check the reading with your reference weight.").foregroundStyle(.green)
                    } else {
                        Text("Tare zeroes the scale. Calibrate if readings are off, using something whose weight you know precisely.")
                    }
                }
            case .empty:
                Section {
                    Label("Remove everything from the scale.", systemImage: "1.circle.fill")
                    Button { Task { await captureZero() } } label: { Label("Scale Is Empty — Set Zero", systemImage: "checkmark.circle") }
                        .disabled(reading?.rawAdc == nil || runner.isRunning)
                    Button("Cancel", role: .cancel) { step = .idle }
                } header: {
                    Text("Step 1 of 2")
                } footer: {
                    if reading?.stable == false { Text("Waiting for the reading to settle…") }
                }
            case .weight:
                Section {
                    Label("Place a known weight on the scale.", systemImage: "2.circle.fill")
                    HStack {
                        Text("Known Weight")
                        Spacer()
                        TextField("Grams", value: $knownWeight, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                        Text("g").foregroundStyle(.secondary)
                    }
                    Button { Task { await finish() } } label: { Label("Save Calibration", systemImage: "checkmark.circle") }
                        .disabled(reading?.rawAdc == nil || knownWeight <= 0 || runner.isRunning)
                    Button("Cancel", role: .cancel) { step = .idle }
                } header: {
                    Text("Step 2 of 2")
                } footer: {
                    if reading?.stable == false { Text("Waiting for the reading to settle…") }
                    else { Text("Uses the station's current raw reading.") }
                }
            }
        }
        .navigationTitle("Scale Calibration")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
    }

    private func tare() async {
        await runner.run("Tare sent to station") {
            let _: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/devices/\(deviceId)/calibration/tare")
        }
    }

    private func captureZero() async {
        tareRaw = reading?.rawAdc
        await runner.run {
            let _: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/devices/\(deviceId)/calibration/tare")
            step = .weight
        }
    }

    private func finish() async {
        struct Body: Encodable { var knownWeightGrams: Double; var rawAdc: Int; var tareRawAdc: Int? }
        guard let raw = reading?.rawAdc else { return }
        await runner.run("Calibration saved") {
            result = try await session.client.send(.post, "spoolbuddy/devices/\(deviceId)/calibration/set-factor",
                                                   body: Body(knownWeightGrams: knownWeight, rawAdc: raw, tareRawAdc: tareRaw))
            step = .done
            await store.loadDevices(session)
        }
    }
}

// MARK: - Station settings

struct SpoolBuddyDeviceSettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(SpoolBuddyLiveState.self) private var liveState
    @Environment(SpoolBuddyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deviceId: String

    @State private var brightness: Double = 100
    @State private var blankTimeout = 0
    @State private var displayLoaded = false
    @State private var backendURL = ""
    @State private var apiKey = ""
    @State private var update: SpoolBuddyUpdateCheck?
    @State private var checkingUpdate = false
    @State private var sshKey: String?
    @State private var command: SpoolBuddySystemCommand?
    @State private var diagnostic: SpoolBuddyDiagnosticKind?
    @State private var confirmRemove = false
    @State private var runner = ActionRunner()

    private var device: SpoolBuddyDevice? { store.devices.value?.first { $0.deviceId == deviceId } }
    private var canUpdate: Bool { session.can("inventory:update") }

    private static let timeouts: [(Int, String)] = [(0, "Never"), (60, "1 minute"), (300, "5 minutes"), (600, "10 minutes"),
                                                     (1800, "30 minutes"), (3600, "1 hour")]

    var body: some View {
        Group {
            if let device { form(device) } else { ProgressView() }
        }
        .navigationTitle("Station Settings")
        .navigationBarTitleDisplayMode(.inline)
        .actionAlerts(runner)
        .confirm(command?.confirmTitle ?? "", isPresented: Binding(get: { command != nil }, set: { if !$0 { command = nil } }),
                 message: command?.confirmMessage, action: command?.title ?? "OK", role: command == .shutdown ? .destructive : nil) {
            if let c = command { Task { await send(c) } }
        }
        .confirm("Remove this station?", isPresented: $confirmRemove,
                 message: "It disappears from Bambuddy until its daemon registers again.", action: "Remove") {
            Task { await remove() }
        }
        .sheet(item: $diagnostic) { kind in
            SpoolBuddyDiagnosticSheet(deviceId: deviceId, kind: kind)
        }
        .task { await loadExtras() }
    }

    @ViewBuilder
    private func form(_ device: SpoolBuddyDevice) -> some View {
        let online = liveState.isOnline(device)
        Form {
            Section("Display") {
                VStack(alignment: .leading) {
                    HStack { Text("Brightness"); Spacer(); Text("\(Int(brightness))%").foregroundStyle(.secondary).monospacedDigit() }
                    Slider(value: $brightness, in: 10...100, step: 5) { editing in
                        if !editing { Task { await saveDisplay() } }
                    }
                    .disabled(!canUpdate)
                }
                Picker("Screen Off After", selection: $blankTimeout) {
                    ForEach(Self.timeouts + (Self.timeouts.contains { $0.0 == blankTimeout } ? [] : [(blankTimeout, "\(blankTimeout) s")]), id: \.0) {
                        Text($0.1).tag($0.0)
                    }
                }
                .disabled(!canUpdate)
                .onChange(of: blankTimeout) { old, _ in if displayLoaded && old != blankTimeout { Task { await saveDisplay() } } }
                if device.hasBacklight == false {
                    Text("No hardware backlight detected; brightness is applied as a software dimmer.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if canUpdate {
                Section {
                    TextField("Server URL", text: $backendURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API key (leave blank to keep)", text: $apiKey)
                    Button("Send to Station") { Task { await saveConfig() } }
                        .disabled(backendURL.trimmingCharacters(in: .whitespaces).isEmpty || runner.isRunning)
                } header: {
                    Text("Server Connection")
                } footer: {
                    Text("The station applies this on its next check-in and reconnects. Use a full URL, e.g. http://192.168.1.10:8000.")
                }
            }

            Section {
                LabeledContent("Installed", value: update?.currentVersion ?? device.firmwareVersion ?? "—")
                if let latest = update?.latestVersion { LabeledContent("Latest", value: latest) }
                if let status = device.updateStatus, !status.isEmpty {
                    LabeledContent("Status", value: device.updateMessage ?? status.capitalized)
                }
                Button {
                    Task { await checkUpdate() }
                } label: {
                    HStack { Text("Check for Updates"); if checkingUpdate { Spacer(); ProgressView() } }
                }
                if canUpdate {
                    Button(update?.updateAvailable == true ? "Install Update" : "Reinstall Current Version") { Task { await applyUpdate() } }
                        .disabled(!online || device.updateStatus == "updating")
                }
            } header: {
                Text("Daemon Updates")
            } footer: {
                if update?.updateAvailable == true { Text("An update is available. The station restarts its daemon after installing.") }
            }

            Section("Diagnostics") {
                ForEach(SpoolBuddyDiagnosticKind.allCases) { kind in
                    Button { diagnostic = kind } label: { Label(kind.title, systemImage: kind.systemImage) }
                        .disabled(!online || (kind == .scale && !device.hasScale) || (kind != .scale && !device.hasNfc))
                }
            }

            if canUpdate {
                Section {
                    ForEach(SpoolBuddySystemCommand.allCases) { c in
                        Button(role: c == .shutdown ? .destructive : nil) { command = c } label: { Label(c.title, systemImage: c.systemImage) }
                            .disabled(!online)
                    }
                } header: {
                    Text("System")
                } footer: {
                    if !online { Text("Commands need the station to be online.") }
                }
            }

            Section("Hardware") {
                LabeledContent("NFC Reader", value: device.hasNfc ? (device.nfcOk ? "Ready" : "Not responding") : "Not installed")
                if let t = device.nfcReaderType { LabeledContent("Reader Type", value: t) }
                if let c = device.nfcConnection { LabeledContent("Connection", value: c) }
                LabeledContent("Scale", value: device.hasScale ? (device.scaleOk ? "Ready" : "Not responding") : "Not installed")
                InfoRow("Hostname", device.hostname)
                InfoRow("Address", device.ipAddress)
                InfoRow("Device ID", device.deviceId)
                InfoRow("Daemon Uptime", Fmt.duration(seconds: Double(device.uptimeS)))
            }

            if let stats = device.systemStats, stats.objectValue?.isEmpty == false {
                SpoolBuddySystemStatsSection(stats: stats)
            }

            if let sshKey, !sshKey.isEmpty {
                Section {
                    AdminSecretField(title: "Public Key", value: sshKey)
                } header: {
                    Text("SSH Access")
                } footer: {
                    Text("Deployed automatically for updates. For manual setup, add it to ~/.ssh/authorized_keys on the station.")
                }
            }

            if session.can("inventory:delete") {
                Section {
                    Button("Remove Station", role: .destructive) { confirmRemove = true }
                }
            }
        }
        .onAppear {
            guard !displayLoaded else { return }
            brightness = Double(device.displayBrightness ?? 100)
            blankTimeout = device.displayBlankTimeout ?? 0
            backendURL = device.backendUrl ?? session.serverURL?.absoluteString ?? ""
            Task { @MainActor in displayLoaded = true }
        }
    }

    // MARK: Actions

    private func loadExtras() async {
        update = try? await session.client.get("spoolbuddy/devices/\(deviceId)/update-check")
        if session.can("settings:read") {
            let key: JSONValue? = try? await session.client.get("spoolbuddy/ssh/public-key")
            sshKey = key?["public_key"]?.stringValue
        }
    }

    private func saveDisplay() async {
        struct Body: Encodable { var brightness: Int; var blankTimeout: Int }
        await runner.run {
            let _: SpoolBuddyAck = try await session.client.send(.put, "spoolbuddy/devices/\(deviceId)/display",
                                                                 body: Body(brightness: Int(brightness), blankTimeout: blankTimeout))
        }
    }

    private func saveConfig() async {
        struct Body: Encodable { var backendUrl: String; var apiKey: String? }
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        await runner.run("Settings queued for the station") {
            let _: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/devices/\(deviceId)/system/config",
                                                                 body: Body(backendUrl: backendURL.trimmingCharacters(in: .whitespaces), apiKey: key.isEmpty ? nil : key))
            apiKey = ""
        }
    }

    private func checkUpdate() async {
        checkingUpdate = true
        defer { checkingUpdate = false }
        await runner.run {
            update = try await session.client.get("spoolbuddy/devices/\(deviceId)/update-check")
            if update?.updateAvailable != true { runner.successMessage = "Station is up to date" }
        }
    }

    private func applyUpdate() async {
        await runner.run {
            let r: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/devices/\(deviceId)/update", body: [String: String]())
            runner.successMessage = r.message ?? "Update started"
            await store.loadDevices(session)
        }
    }

    private func send(_ c: SpoolBuddySystemCommand) async {
        struct Body: Encodable { var command: String }
        await runner.run("\(c.title) sent") {
            let _: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/devices/\(deviceId)/system/command", body: Body(command: c.rawValue))
        }
    }

    private func remove() async {
        await runner.run {
            try await session.client.call(.delete, "spoolbuddy/devices/\(deviceId)")
            await store.loadDevices(session)
            dismiss()
        }
    }
}

enum SpoolBuddySystemCommand: String, CaseIterable, Identifiable {
    case restartDaemon = "restart_daemon"
    case restartBrowser = "restart_browser"
    case reboot
    case shutdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restartDaemon: "Restart Daemon"
        case .restartBrowser: "Restart Display Browser"
        case .reboot: "Reboot"
        case .shutdown: "Shut Down"
        }
    }

    var systemImage: String {
        switch self {
        case .restartDaemon: "arrow.clockwise"
        case .restartBrowser: "safari"
        case .reboot: "restart"
        case .shutdown: "power"
        }
    }

    var confirmTitle: String { "\(title)?" }

    var confirmMessage: String {
        switch self {
        case .restartDaemon: "NFC and scale are unavailable for a few seconds."
        case .restartBrowser: "The station's screen goes blank briefly."
        case .reboot: "The station is unavailable until it finishes restarting."
        case .shutdown: "You'll need physical access to turn the station back on."
        }
    }
}

enum SpoolBuddyDiagnosticKind: String, CaseIterable, Identifiable {
    case scale, nfc
    case readTag = "read_tag"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scale: "Scale Diagnostic"
        case .nfc: "NFC Reader Diagnostic"
        case .readTag: "Read Tag"
        }
    }

    var systemImage: String {
        switch self {
        case .scale: "scalemass"
        case .nfc: "wave.3.right"
        case .readTag: "tag"
        }
    }
}

private struct SpoolBuddyDiagnosticSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let deviceId: String
    let kind: SpoolBuddyDiagnosticKind

    @State private var output = ""
    @State private var result: SpoolBuddyDiagnosticResult?
    @State private var running = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let result {
                        Label(result.success == true ? "Completed successfully" : "Finished with errors (exit \(result.exitCode ?? -1))",
                              systemImage: result.success == true ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.success == true ? .green : .red)
                    } else if running {
                        HStack { ProgressView(); Text("Running on the station…").foregroundStyle(.secondary) }
                    } else {
                        Text(kind == .readTag ? "Place a tag on the reader, then run." : "Runs a hardware check on the station and shows its output.")
                            .foregroundStyle(.secondary)
                    }
                    if !output.isEmpty {
                        Text(output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
                    }
                }
                .padding()
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(result == nil ? "Run" : "Run Again") { Task { await run() } }.disabled(running)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func run() async {
        running = true
        result = nil
        output = ""
        defer { running = false }
        do {
            let ack: SpoolBuddyAck = try await session.client.send(.post, "spoolbuddy/diagnostics/\(deviceId)/run",
                                                                   query: ["diagnostic": .string(kind.rawValue)], body: [String: String]())
            output = ack.message ?? "Queued"
            // The station picks the job up on its next heartbeat; poll for the result.
            for _ in 0..<45 {
                try await Task.sleep(for: .seconds(2))
                if let r: SpoolBuddyDiagnosticResult = try? await session.client.get("spoolbuddy/diagnostics/\(deviceId)/result",
                                                                                     query: ["diagnostic": .string(kind.rawValue)]) {
                    result = r
                    output = r.output ?? ""
                    return
                }
            }
            output += "\nNo result yet — is the station online?"
        } catch is CancellationError {
        } catch {
            output = error.localizedDescription
        }
    }
}

private struct SpoolBuddySystemStatsSection: View {
    let stats: JSONValue

    var body: some View {
        Section("Station System") {
            if let os = stats["os"] {
                InfoRow("OS", os["os"]?.stringValue)
                InfoRow("Kernel", os["kernel"]?.stringValue)
                InfoRow("Architecture", os["arch"]?.stringValue)
                InfoRow("Python", os["python"]?.stringValue)
            }
            if let t = stats["cpu_temp_c"]?.doubleValue { InfoRow("CPU Temperature", "\(Fmt.number(t)) °C") }
            if let load = stats["load_avg"]?.arrayValue, !load.isEmpty {
                InfoRow("Load Average", load.compactMap(\.doubleValue).map { Fmt.number($0, digits: 2) }.joined(separator: " / "))
            }
            if let mem = stats["memory"], let pct = mem["percent"]?.doubleValue {
                usage("Memory", pct, "\(Fmt.number(mem["used_mb"]?.doubleValue, digits: 0)) of \(Fmt.number(mem["total_mb"]?.doubleValue, digits: 0)) MB")
            }
            if let disk = stats["disk"], let pct = disk["percent"]?.doubleValue {
                usage("Disk", pct, "\(Fmt.number(disk["used_gb"]?.doubleValue)) of \(Fmt.number(disk["total_gb"]?.doubleValue)) GB")
            }
            if let up = stats["system_uptime_s"]?.doubleValue { InfoRow("System Uptime", Fmt.duration(seconds: up)) }
        }
    }

    private func usage(_ title: String, _ pct: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(Fmt.percent(pct)).foregroundStyle(.secondary) }
            ProgressView(value: min(1, pct / 100)).tint(pct > 90 ? .red : pct > 75 ? .orange : .accentColor)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
