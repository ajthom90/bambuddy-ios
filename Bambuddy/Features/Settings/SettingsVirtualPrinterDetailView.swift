import SwiftUI
import UIKit

/// Edit screen for one virtual printer. Every change is saved immediately with a
/// single-field `PUT /virtual-printers/{id}` and the server's response replaces the local copy
/// (the server may switch the printer off, or change its serial/model, as a side effect).
struct SettingsVirtualPrinterDetailView: View {
    let vpID: Int
    let model: SettingsVirtualPrinterModel

    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printerStore
    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()
    @State private var nameDraft = ""
    @State private var accessCodeDraft = ""
    @State private var revealCode = false
    @State private var confirmDelete = false
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    private var canEdit: Bool { session.can("settings:update") }
    private var vp: SettingsVirtualPrinter? { model.printer(vpID) }

    var body: some View {
        Group {
            if let vp {
                form(vp)
            } else {
                ContentUnavailableView("Virtual Printer Not Found", systemImage: "printer.dotmatrix",
                                       description: Text("It may have been deleted."))
            }
        }
        .navigationTitle(vp?.displayName ?? "Virtual Printer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if saving { ToolbarItem(placement: .topBarTrailing) { ProgressView() } }
        }
        .onAppear { nameDraft = vp?.name ?? "" }
        .onChange(of: vp?.name) { _, newValue in if !nameFocused { nameDraft = newValue ?? "" } }
        .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                if !saving { await model.refreshList(client: session.client) }
            }
        }
        .refreshable { await model.loadAll(client: session.client) }
        .confirm("Delete \(vp?.displayName ?? "Virtual Printer")?", isPresented: $confirmDelete,
                 message: "Its services stop immediately and any of its uploads still waiting for review are discarded.") {
            Task { await delete() }
        }
        .actionAlerts(runner)
    }

    // MARK: Form

    private func form(_ vp: SettingsVirtualPrinter) -> some View {
        Form {
            statusSection(vp)
            if let proxy = vp.status?.proxy { proxySection(proxy) }
            Section("Name") {
                TextField("Name", text: $nameDraft)
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .submitLabel(.done)
                    .disabled(!canEdit)
            }
            modeSection(vp)
            if vp.modeKind == .queue { queueSection(vp) }
            if vp.modeKind != .proxy { modelSection(vp) }
            accessCodeSection(vp)
            targetSection(vp)
            networkSection(vp)
            tailscaleSection(vp)
            Section {
                NavigationLink {
                    SettingsVirtualPrinterDiagnosticView(vpID: vp.id, name: vp.displayName)
                } label: { Label("Check Setup", systemImage: "stethoscope") }
            } footer: {
                Text("Probes this virtual printer's interface and ports to explain why a slicer can't find or connect to it.")
            }
            if canEdit {
                Section {
                    Button("Delete Virtual Printer", role: .destructive) { confirmDelete = true }
                }
            }
        }
    }

    private func statusSection(_ vp: SettingsVirtualPrinter) -> some View {
        Section {
            Toggle(isOn: Binding(get: { vp.isEnabled }, set: { setEnabled($0) })) {
                SettingsLabel("Enabled", help: vp.isEnabled ? nil : SettingsVPValidation.enableProblem(for: vp))
            }
            .disabled(!canEdit)
            LabeledContent("Status") {
                if vp.isRunning {
                    StatusBadge(text: "Running", color: .green)
                } else if vp.isEnabled {
                    StatusBadge(text: "Not Running", color: .orange)
                } else {
                    StatusBadge(text: "Off", color: .secondary)
                }
            }
            if let pending = vp.status?.pendingFiles, pending > 0 {
                LabeledContent("Files in Progress", value: "\(pending)")
            }
            if let serial = vp.serial, !serial.isEmpty {
                InfoRow("Serial Number", serial)
                    .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = serial } }
            }
        } footer: {
            Text("Enabling requires a bind interface, plus an access code (or a target printer) — or, in proxy mode, a target printer. If a later change breaks a requirement, Bambuddy switches the printer off.")
        }
    }

    private func proxySection(_ proxy: SettingsVirtualPrinterProxyStatus) -> some View {
        Section("Relay") {
            LabeledContent("Relay") {
                StatusBadge(text: proxy.running == true ? "Active" : "Stopped", color: proxy.running == true ? .green : .secondary)
            }
            if let host = proxy.targetHost, !host.isEmpty { InfoRow("Target Address", host) }
            if let port = proxy.ftpPort {
                LabeledContent("File Transfer", value: "Port \(port) · \(proxy.ftpConnections ?? 0) connected")
            }
            if let port = proxy.mqttPort {
                LabeledContent("Control", value: "Port \(port) · \(proxy.mqttConnections ?? 0) connected")
            }
            if let ports = proxy.bindPorts, !ports.isEmpty {
                LabeledContent("Discovery",
                               value: "Ports \(ports.map(String.init).joined(separator: ", ")) · \(proxy.bindConnections ?? 0) connected")
            }
        }
    }

    private func modeSection(_ vp: SettingsVirtualPrinter) -> some View {
        Section {
            ForEach(SettingsVPMode.allCases) { mode in
                Button {
                    guard mode != vp.modeKind else { return }
                    save(SettingsVirtualPrinterUpdate(mode: mode.rawValue), success: "Mode changed") { $0.mode = mode.rawValue }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode.systemImage).frame(width: 24).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).foregroundStyle(.primary)
                            Text(mode.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode == vp.modeKind {
                            Image(systemName: "checkmark").foregroundStyle(.tint).fontWeight(.semibold)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
            }
        } header: {
            Text("Mode")
        }
    }

    private func queueSection(_ vp: SettingsVirtualPrinter) -> some View {
        Section {
            boolToggle("Dispatch Automatically", help: "Start queued prints on a matching idle printer without waiting for you.",
                       value: vp.autoDispatch ?? true) { SettingsVirtualPrinterUpdate(autoDispatch: $0) } apply: { $0.autoDispatch = $1 }
            boolToggle("Require Exact Colors", help: "Only dispatch to printers whose loaded filament colors match the job.",
                       value: vp.queueForceColorMatch ?? false) { SettingsVirtualPrinterUpdate(queueForceColorMatch: $0) } apply: { $0.queueForceColorMatch = $1 }
            boolToggle("Keep Slicer AMS Mapping", help: "Store the slot mapping chosen in the slicer with the queued job.",
                       value: vp.saveAmsMapping ?? false) { SettingsVirtualPrinterUpdate(saveAmsMapping: $0) } apply: { $0.saveAmsMapping = $1 }
            boolToggle("Inject G-code Snippets", help: "Apply your configured start/end G-code snippets to jobs queued from this printer.",
                       value: vp.gcodeInjection ?? false) { SettingsVirtualPrinterUpdate(gcodeInjection: $0) } apply: { $0.gcodeInjection = $1 }
        } header: {
            Text("Queue Options")
        }
    }

    private func modelSection(_ vp: SettingsVirtualPrinter) -> some View {
        Section {
            Picker("Printer Model", selection: Binding(
                get: { vp.model ?? "" },
                set: { code in
                    guard code != vp.model, !code.isEmpty else { return }
                    save(SettingsVirtualPrinterUpdate(model: code), success: "Model changed") {
                        $0.model = code
                        $0.modelName = model.models[code]
                    }
                })) {
                ForEach(model.sortedModels, id: \.code) { entry in
                    Text("\(entry.name) (\(entry.code))").tag(entry.code)
                }
                if let current = vp.model, model.models[current] == nil {
                    Text(vp.modelName ?? current).tag(current)
                }
            }
            .disabled(!canEdit)
        } footer: {
            Text("The model the slicer sees. Pick the one your slicer profiles are made for.")
        }
    }

    @ViewBuilder
    private func accessCodeSection(_ vp: SettingsVirtualPrinter) -> some View {
        if vp.modeKind == .proxy {
            Section {
                Label("The slicer uses the target printer's own access code.", systemImage: "info.circle")
                    .font(.subheadline)
            } header: { Text("Access Code") }
        } else if let targetID = vp.targetPrinterId {
            Section {
                let code = printerStore.printer(targetID)?.accessCode
                LabeledContent("Access Code") {
                    HStack(spacing: 8) {
                        if let code, !code.isEmpty {
                            Text(revealCode ? code : String(repeating: "•", count: code.count))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                            Button { revealCode.toggle() } label: {
                                Image(systemName: revealCode ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(revealCode ? "Hide Access Code" : "Show Access Code")
                        } else {
                            Text("From target printer").foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Access Code")
            } footer: {
                Text("Uses the target printer's access code, because slicer connections are passed through to that printer. Enter this code in the slicer.")
            }
        } else {
            Section {
                LabeledContent("Status") {
                    if vp.accessCodeSet == true {
                        Label("Set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Not Set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                if canEdit {
                    HStack {
                        Group {
                            if revealCode {
                                TextField(vp.accessCodeSet == true ? "New access code" : "8 characters", text: $accessCodeDraft)
                            } else {
                                SecureField(vp.accessCodeSet == true ? "New access code" : "8 characters", text: $accessCodeDraft)
                            }
                        }
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: accessCodeDraft) { _, value in
                            if value.count > 8 { accessCodeDraft = String(value.prefix(8)) }
                        }
                        Button { revealCode.toggle() } label: { Image(systemName: revealCode ? "eye.slash" : "eye") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(revealCode ? "Hide Access Code" : "Show Access Code")
                        Button("Save") { saveAccessCode() }
                            .buttonStyle(.borderless)
                            .disabled(accessCodeDraft.count != 8)
                    }
                    if !accessCodeDraft.isEmpty {
                        Text("\(accessCodeDraft.count) of 8 characters")
                            .font(.caption)
                            .foregroundStyle(accessCodeDraft.count == 8 ? Color.green : Color.orange)
                    }
                }
            } header: {
                Text("Access Code")
            } footer: {
                Text("The slicer asks for this code when you add the printer. It must be exactly 8 characters.")
            }
        }
    }

    private func targetSection(_ vp: SettingsVirtualPrinter) -> some View {
        Section {
            Picker("Target Printer", selection: Binding<Int?>(
                get: { vp.targetPrinterId },
                set: { id in
                    guard let id, id != vp.targetPrinterId else { return }
                    changeTarget(to: id, from: vp.targetPrinterId)
                })) {
                if vp.targetPrinterId == nil { Text("None").tag(Int?.none) }
                ForEach(printerStore.printers) { printer in
                    Text("\(printer.name) (\(printer.ipAddress))").tag(Int?.some(printer.id))
                }
                if let id = vp.targetPrinterId, printerStore.printer(id) == nil {
                    Text("Printer #\(id)").tag(Int?.some(id))
                }
            }
            .disabled(!canEdit)
        } footer: {
            Text(vp.modeKind == .proxy
                 ? "Required in proxy mode: the real printer the slicer is relayed to. Its model is copied to this virtual printer."
                 : "Optional. When set, slicer connections are bridged to this printer and its access code is used. A target can be changed but not removed.")
        }
    }

    private func networkSection(_ vp: SettingsVirtualPrinter) -> some View {
        Section {
            Picker("Bind Interface", selection: Binding(
                get: { vp.bindIp ?? "" },
                set: { ip in
                    guard ip != (vp.bindIp ?? "") else { return }
                    save(SettingsVirtualPrinterUpdate(bindIp: ip), success: "Bind interface changed") { $0.bindIp = ip }
                })) {
                Text("Not Set").tag("")
                ForEach(model.interfaces) { iface in Text(iface.menuLabel).tag(iface.ip) }
                if let ip = vp.bindIp, !ip.isEmpty, !model.interfaces.contains(where: { $0.ip == ip }) {
                    Text("\(ip) (unavailable)").tag(ip)
                }
            }
            .disabled(!canEdit)
            Picker("Remote Interface", selection: Binding(
                get: { vp.remoteInterfaceIp ?? "" },
                set: { ip in
                    guard ip != (vp.remoteInterfaceIp ?? "") else { return }
                    save(SettingsVirtualPrinterUpdate(remoteInterfaceIp: ip), success: "Remote interface changed") { $0.remoteInterfaceIp = ip }
                })) {
                Text("None").tag("")
                ForEach(model.interfaces) { iface in Text(iface.menuLabel).tag(iface.ip) }
                if let ip = vp.remoteInterfaceIp, !ip.isEmpty, !model.interfaces.contains(where: { $0.ip == ip }) {
                    Text("\(ip) (unavailable)").tag(ip)
                }
            }
            .disabled(!canEdit)
        } header: {
            Text("Network")
        } footer: {
            Text("The bind interface is the address slicers connect to; every enabled virtual printer needs its own (add an alias IP to run several). Set a remote interface only when your slicer is on a different network than the printers — Bambuddy then announces the virtual printer there too.")
        }
    }

    private func tailscaleSection(_ vp: SettingsVirtualPrinter) -> some View {
        let exposed = !(vp.tailscaleDisabled ?? true)
        return Section {
            boolToggle("Expose over Tailscale", help: nil, value: exposed) {
                SettingsVirtualPrinterUpdate(tailscaleDisabled: !$0)
            } apply: { $0.tailscaleDisabled = !$1 }
            if exposed, let ts = model.tailscale {
                if ts.available == true, let fqdn = ts.fqdn, !fqdn.isEmpty {
                    let ip = ts.tailscaleIps?.first
                    LabeledContent("Tailnet Address") {
                        Text(ip.map { "\($0) (\(fqdn))" } ?? fqdn)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .contextMenu { Button("Copy Host Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = fqdn } }
                } else {
                    Label("Tailscale isn't running on the Bambuddy host.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Remote Access")
        } footer: {
            Text("Makes this virtual printer reachable from slicers on your tailnet, using the host's Tailscale address.")
        }
    }

    // MARK: Building blocks

    private func boolToggle(_ title: String, help: String?, value: Bool,
                            body: @escaping (Bool) -> SettingsVirtualPrinterUpdate,
                            apply: @escaping (inout SettingsVirtualPrinter, Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { newValue in
            save(body(newValue)) { apply(&$0, newValue) }
        })) { SettingsLabel(title, help: help) }
            .disabled(!canEdit)
    }

    // MARK: Saving

    /// Applies `change` optimistically, sends `body`, and replaces the local copy with the server's
    /// answer (or restores the original on failure).
    private func save(_ body: SettingsVirtualPrinterUpdate, success: String? = "Saved",
                      _ change: @escaping (inout SettingsVirtualPrinter) -> Void) {
        guard let original = vp else { return }
        var optimistic = original
        change(&optimistic)
        model.replace(optimistic)
        Task {
            saving = true
            defer { saving = false }
            await runner.run(success) {
                do {
                    let updated: SettingsVirtualPrinter = try await session.client.send(.put, "virtual-printers/\(vpID)", body: body)
                    model.replace(updated)
                } catch {
                    model.replace(original)
                    throw error
                }
            }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard let vp else { return }
        if enabled, let problem = SettingsVPValidation.enableProblem(for: vp) {
            runner.errorMessage = problem
            return
        }
        save(SettingsVirtualPrinterUpdate(enabled: enabled), success: enabled ? "Virtual printer enabled" : "Virtual printer disabled") {
            $0.enabled = enabled
        }
    }

    private func commitName() {
        guard let vp else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { nameDraft = vp.name ?? ""; return }
        guard trimmed != vp.name else { return }
        save(SettingsVirtualPrinterUpdate(name: trimmed), success: "Name saved") { $0.name = trimmed }
    }

    private func saveAccessCode() {
        let code = accessCodeDraft
        if let problem = SettingsVPValidation.accessCodeProblem(code) {
            runner.errorMessage = problem
            return
        }
        guard !code.isEmpty else { return }
        accessCodeDraft = ""
        save(SettingsVirtualPrinterUpdate(accessCode: code), success: "Access code saved") { $0.accessCodeSet = true }
    }

    private func changeTarget(to id: Int, from previous: Int?) {
        let oldCode = previous.flatMap { printerStore.printer($0)?.accessCode }
        let newCode = printerStore.printer(id)?.accessCode
        let codeChanged = oldCode != nil && newCode != nil && oldCode != newCode
        save(SettingsVirtualPrinterUpdate(targetPrinterId: id),
             success: codeChanged ? "Target changed — re-add the printer in your slicer with the new access code" : "Target printer changed") {
            $0.targetPrinterId = id
        }
    }

    private func delete() async {
        await runner.run {
            try await session.client.call(.delete, "virtual-printers/\(vpID)")
            model.remove(vpID)
            dismiss()
        }
    }
}

// MARK: - Diagnostics

/// Runs `GET /virtual-printers/{id}/diagnostic` and lists each check with an explanation.
struct SettingsVirtualPrinterDiagnosticView: View {
    let vpID: Int
    let name: String

    @Environment(AppSession.self) private var session
    @State private var loader = Loader<SettingsVPDiagnosticResult>()

    var body: some View {
        List {
            if loader.isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking setup…").foregroundStyle(.secondary)
                    }
                }
            }
            if let error = loader.error, loader.value == nil {
                Section {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            if let result = loader.value {
                Section {
                    let overall = SettingsVPDiagnosticText.overall(result.overall)
                    Label(overall.text, systemImage: overall.icon)
                        .foregroundStyle(overall.color)
                        .font(.subheadline.weight(.medium))
                }
                Section("Checks") {
                    ForEach(result.checks ?? [], id: \.self) { check in
                        SettingsVPDiagnosticRow(check: check)
                    }
                }
            }
        }
        .navigationTitle("Setup Check")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Run Again", systemImage: "arrow.clockwise") { Task { await run() } }
                    .disabled(loader.isLoading)
            }
        }
        .task { await run() }
        .refreshable { await run() }
    }

    private func run() async {
        await loader.load { try await session.client.get("virtual-printers/\(vpID)/diagnostic") }
    }
}

private struct SettingsVPDiagnosticRow: View {
    let check: SettingsVPDiagnosticCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(SettingsVPDiagnosticText.title(check))
                if let detail = SettingsVPDiagnosticText.detail(check) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(check.status == "skip" ? 0.6 : 1)
    }

    private var icon: String {
        switch check.status {
        case "pass": "checkmark.circle.fill"
        case "fail": "xmark.circle.fill"
        case "warn": "exclamationmark.triangle.fill"
        default: "minus.circle"
        }
    }

    private var color: Color {
        switch check.status {
        case "pass": .green
        case "fail": .red
        case "warn": .orange
        default: .secondary
        }
    }
}

/// Human-readable text for diagnostic checks (the server only sends ids + statuses).
enum SettingsVPDiagnosticText {
    static func title(_ check: SettingsVPDiagnosticCheck) -> String {
        let port = check.params?.port.map(String.init)
        switch check.id {
        case "enabled": return "Virtual printer switched on"
        case "running": return "Services running"
        case "bind_interface": return "Bind interface available"
        case "access_code": return "Access code configured"
        case "target_printer": return "Target printer reachable"
        case "port_ftps": return "File upload service" + (port.map { " (port \($0))" } ?? "")
        case "port_mqtt": return "Printer control service" + (port.map { " (port \($0))" } ?? "")
        case "port_bind":
            if let port, let plain = check.params?.portPlain { return "Discovery service (ports \(plain) and \(port))" }
            return "Discovery service" + (port.map { " (port \($0))" } ?? "")
        case "privileged_ports": return "Permission to use low ports"
        case "certificate": return "TLS certificate"
        default: return check.id.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func detail(_ check: SettingsVPDiagnosticCheck) -> String? {
        let port = check.params?.port.map(String.init) ?? "?"
        switch (check.id, check.status ?? "") {
        case (_, "skip"): return "Skipped — doesn't apply right now."
        case ("enabled", "fail"): return "Turn the virtual printer on so slicers can discover it."
        case ("running", "fail"): return "It's switched on but its services aren't running. The Bambuddy log usually shows why — often an IP already in use or missing permissions."
        case ("bind_interface", "fail"):
            if let ip = check.params?.bindIp { return "\(ip) no longer exists on the Bambuddy host. Choose a current bind interface." }
            return "No bind interface is selected. Choose one in the Network section."
        case ("access_code", "fail"): return "Set an 8-character access code; the slicer must use the same code."
        case ("target_printer", "fail"): return "Proxy mode needs a target printer to relay to."
        case ("target_printer", "warn"): return "The target printer is offline. Relaying resumes when it reconnects."
        case ("port_ftps", "fail"): return "Nothing answers on port \(port) at the bind address, so the slicer can't upload files. Another service using the port is the usual cause."
        case ("port_mqtt", "fail"): return "Nothing answers on port \(port) at the bind address, so the slicer can't connect or show status."
        case ("port_bind", "fail"): return "The discovery ports don't answer at the bind address, so the slicer's connection handshake fails."
        case ("privileged_ports", "fail"): return "Bambuddy isn't allowed to open ports below 1024 (port \(port)). Grant the CAP_NET_BIND_SERVICE capability (systemd AmbientCapabilities, or cap_add: NET_BIND_SERVICE in Docker) and restart."
        case ("certificate", "pass"): return "Ready. Make sure the Bambuddy certificate is imported into your slicer."
        case ("certificate", "fail"): return "The certificate for this virtual printer is missing. Check that Bambuddy's data folder is writable."
        default: return nil
        }
    }

    static func overall(_ value: String?) -> (text: String, icon: String, color: Color) {
        switch value {
        case "ok": ("Everything checks out — this virtual printer is set up correctly.", "checkmark.seal.fill", .green)
        case "warnings": ("It should work, but a few things need attention.", "exclamationmark.triangle.fill", .orange)
        default: ("Problems found that explain why slicers can't see or use this virtual printer.", "xmark.octagon.fill", .red)
        }
    }
}
