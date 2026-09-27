import SwiftUI
import UIKit

// MARK: - Models

/// A virtual printer as returned by `GET /virtual-printers` (built by the route's `_vp_to_dict`).
struct SettingsVirtualPrinter: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String?
    var enabled: Bool?
    /// `archive`, `review`, `queue` or `proxy` (legacy `immediate` / `print_queue` may still appear).
    var mode: String?
    /// SSDP model code, e.g. `BL-P001`.
    var model: String?
    var modelName: String?
    var accessCodeSet: Bool?
    var serial: String?
    var targetPrinterId: Int?
    var autoDispatch: Bool?
    var queueForceColorMatch: Bool?
    var saveAmsMapping: Bool?
    var gcodeInjection: Bool?
    var bindIp: String?
    var remoteInterfaceIp: String?
    var tailscaleDisabled: Bool?
    var position: Int?
    var status: SettingsVirtualPrinterStatus?

    var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Virtual Printer \(id)" : trimmed
    }
    var isEnabled: Bool { enabled ?? false }
    var isRunning: Bool { status?.running ?? false }
    var modeKind: SettingsVPMode { SettingsVPMode.normalized(mode) }
}

struct SettingsVirtualPrinterStatus: Codable, Sendable, Hashable {
    var running: Bool?
    var pendingFiles: Int?
    var proxy: SettingsVirtualPrinterProxyStatus?
}

/// Live relay status of a proxy-mode virtual printer.
struct SettingsVirtualPrinterProxyStatus: Codable, Sendable, Hashable {
    var running: Bool?
    var targetHost: String?
    var ftpPort: Int?
    var mqttPort: Int?
    var bindPorts: [Int]?
    var ftpConnections: Int?
    var mqttConnections: Int?
    var bindConnections: Int?
}

/// `GET /virtual-printers` response.
struct SettingsVirtualPrinterList: Codable, Sendable {
    var printers: [SettingsVirtualPrinter]?
    /// SSDP model code → display name.
    var models: [String: String]?
}

/// One entry of `GET /settings/network-interfaces`.
struct SettingsVPNetworkInterface: Codable, Sendable, Hashable, Identifiable {
    var name: String?
    var ip: String
    var netmask: String?
    var subnet: String?
    var isAlias: Bool?
    var label: String?

    var id: String { ip }

    var menuLabel: String {
        var text = "\(name ?? "Interface") — \(ip)"
        if isAlias == true { text += " (alias)" }
        if let subnet, !subnet.isEmpty { text += " · \(subnet)" }
        return text
    }
}

struct SettingsVPNetworkInterfaces: Codable, Sendable {
    var interfaces: [SettingsVPNetworkInterface]?
}

/// `GET /virtual-printers/tailscale-status`.
struct SettingsVPTailscaleStatus: Codable, Sendable, Hashable {
    var available: Bool?
    var fqdn: String?
    var hostname: String?
    var tailnetName: String?
    var tailscaleIps: [String]?
    var error: String?
}

/// `GET /virtual-printers/ca-certificate` — the public CA every virtual printer's TLS chain uses.
struct SettingsVPCACertificate: Codable, Sendable, Hashable {
    var pem: String?
    var fingerprintSha256: String?
    var notValidAfter: String?
}

/// `GET /virtual-printers/{id}/diagnostic`.
struct SettingsVPDiagnosticResult: Codable, Sendable {
    var vpId: Int?
    var vpName: String?
    var mode: String?
    /// `ok`, `warnings` or `problems`.
    var overall: String?
    var checks: [SettingsVPDiagnosticCheck]?
}

struct SettingsVPDiagnosticCheck: Codable, Sendable, Hashable {
    /// enabled, running, bind_interface, access_code, target_printer, port_ftps, port_mqtt, port_bind,
    /// privileged_ports, certificate (others tolerated).
    var id: String
    /// `pass`, `fail`, `warn` or `skip`.
    var status: String?
    var params: SettingsVPDiagnosticParams?
}

/// Interpolation values the backend attaches to a check (`port`, `port_plain`, `bind_ip`).
struct SettingsVPDiagnosticParams: Codable, Sendable, Hashable {
    var port: Int?
    var portPlain: Int?
    var bindIp: String?
}

/// Body for `POST /virtual-printers` (omitted fields take the backend defaults).
struct SettingsVirtualPrinterCreate: Encodable, Sendable {
    var name: String?
    var enabled: Bool?
    var mode: String?
    var model: String?
    var accessCode: String?
    var targetPrinterId: Int?
    var autoDispatch: Bool?
    var queueForceColorMatch: Bool?
    var saveAmsMapping: Bool?
    var gcodeInjection: Bool?
    var bindIp: String?
    var remoteInterfaceIp: String?
}

/// Body for `PUT /virtual-printers/{id}`. `nil` fields are omitted and left unchanged by the server;
/// an empty string clears `bind_ip`, `remote_interface_ip` and `access_code`.
struct SettingsVirtualPrinterUpdate: Encodable, Sendable {
    var name: String?
    var enabled: Bool?
    var mode: String?
    var model: String?
    var accessCode: String?
    var targetPrinterId: Int?
    var autoDispatch: Bool?
    var queueForceColorMatch: Bool?
    var saveAmsMapping: Bool?
    var gcodeInjection: Bool?
    var bindIp: String?
    var remoteInterfaceIp: String?
    var tailscaleDisabled: Bool?
}

// MARK: - Mode & validation helpers

enum SettingsVPMode: String, CaseIterable, Identifiable, Sendable {
    case archive, review, queue, proxy

    var id: String { rawValue }

    /// Maps legacy wire values (`immediate`, `print_queue`) and unknown values onto the four modes.
    static func normalized(_ raw: String?) -> SettingsVPMode {
        switch raw?.lowercased() {
        case "immediate", "archive": .archive
        case "print_queue", "queue": .queue
        case "review": .review
        case "proxy": .proxy
        default: .archive
        }
    }

    var title: String {
        switch self {
        case .archive: "Archive"
        case .review: "Review"
        case .queue: "Queue"
        case .proxy: "Proxy"
        }
    }

    var summary: String {
        switch self {
        case .archive: "Files sent from the slicer are archived right away."
        case .review: "Uploads wait in Pending Uploads until you archive or discard them."
        case .queue: "Uploads are added to the print queue, ready to be dispatched to a real printer."
        case .proxy: "Relays the slicer straight through to a real printer, e.g. across networks or VPNs."
        }
    }

    var systemImage: String {
        switch self {
        case .archive: "archivebox"
        case .review: "tray.full"
        case .queue: "list.number"
        case .proxy: "arrow.left.arrow.right"
        }
    }
}

enum SettingsVPValidation {
    /// Access codes must be exactly 8 characters (Bambu Studio's requirement). Empty means "unchanged/none".
    static func accessCodeProblem(_ code: String) -> String? {
        guard !code.isEmpty else { return nil }
        return code.count == 8 ? nil : "The access code must be exactly 8 characters (currently \(code.count))."
    }

    /// Mirrors the server's checks when a virtual printer is switched on.
    static func enableProblem(mode: SettingsVPMode, bindIp: String?, targetPrinterId: Int?, hasAccessCode: Bool) -> String? {
        if (bindIp ?? "").isEmpty { return "Choose a bind interface before enabling this virtual printer." }
        if mode == .proxy {
            if targetPrinterId == nil { return "Proxy mode needs a target printer." }
        } else if !hasAccessCode && targetPrinterId == nil {
            return "Set an 8-character access code (or pick a target printer) before enabling."
        }
        return nil
    }

    static func enableProblem(for vp: SettingsVirtualPrinter) -> String? {
        enableProblem(mode: vp.modeKind, bindIp: vp.bindIp, targetPrinterId: vp.targetPrinterId,
                      hasAccessCode: vp.accessCodeSet ?? false)
    }
}

// MARK: - Shared page state

/// Virtual printers plus the lookup data (models, interfaces, Tailscale, CA) shared by the list,
/// detail and add screens.
@MainActor
@Observable
final class SettingsVirtualPrinterModel {
    var printers: [SettingsVirtualPrinter] = []
    var models: [String: String] = [:]
    var interfaces: [SettingsVPNetworkInterface] = []
    var tailscale: SettingsVPTailscaleStatus?
    var certificate: SettingsVPCACertificate?
    var certificateFile: URL?
    var certificateError: String?
    var hasLoaded = false
    var loadError: String?

    /// Model codes sorted by display name, for pickers.
    var sortedModels: [(code: String, name: String)] {
        models.map { (code: $0.key, name: $0.value) }
            .sorted { ($0.name, $0.code) < ($1.name, $1.code) }
    }

    func printer(_ id: Int) -> SettingsVirtualPrinter? { printers.first { $0.id == id } }

    func replace(_ vp: SettingsVirtualPrinter) {
        if let i = printers.firstIndex(where: { $0.id == vp.id }) { printers[i] = vp } else { printers.append(vp) }
    }

    func remove(_ id: Int) { printers.removeAll { $0.id == id } }

    func loadAll(client: APIClient) async {
        async let list: Void = refreshList(client: client)
        async let ifaces: Void = refreshInterfaces(client: client)
        async let ts: Void = refreshTailscale(client: client)
        async let cert: Void = loadCertificateIfNeeded(client: client)
        _ = await (list, ifaces, ts, cert)
    }

    func refreshList(client: APIClient) async {
        do {
            let response: SettingsVirtualPrinterList = try await client.get("virtual-printers")
            printers = (response.printers ?? []).sorted { ($0.position ?? 0, $0.id) < ($1.position ?? 0, $1.id) }
            if let m = response.models, !m.isEmpty { models = m }
            loadError = nil
            hasLoaded = true
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            if !hasLoaded { loadError = error.localizedDescription }
        }
    }

    func refreshInterfaces(client: APIClient) async {
        if let response: SettingsVPNetworkInterfaces = try? await client.get("settings/network-interfaces") {
            interfaces = response.interfaces ?? []
        }
    }

    func refreshTailscale(client: APIClient) async {
        if let status: SettingsVPTailscaleStatus = try? await client.get("virtual-printers/tailscale-status") {
            tailscale = status
        }
    }

    func loadCertificateIfNeeded(client: APIClient) async {
        guard certificate == nil else { return }
        do {
            let cert: SettingsVPCACertificate = try await client.get("virtual-printers/ca-certificate")
            certificate = cert
            certificateError = nil
            if let pem = cert.pem, !pem.isEmpty {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vp-ca", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("bambuddy-virtual-printer-ca.crt")
                try? pem.write(to: file, atomically: true, encoding: .utf8)
                certificateFile = FileManager.default.fileExists(atPath: file.path) ? file : nil
            }
        } catch is CancellationError {
        } catch {
            certificateError = error.localizedDescription
        }
    }
}

// MARK: - List page

struct SettingsVirtualPrintersView: View {
    @Environment(AppSession.self) private var session
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printerStore
    @State private var model = SettingsVirtualPrinterModel()
    @State private var runner = ActionRunner()
    @State private var showAdd = false
    @State private var pendingDelete: SettingsVirtualPrinter?
    @State private var diagnosing: SettingsVirtualPrinter?

    private var canEdit: Bool { session.can("settings:update") }

    var body: some View {
        content
            .navigationTitle("Virtual Printers")
            .toolbar {
                if canEdit {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showAdd = true } label: { Label("Add Virtual Printer", systemImage: "plus") }
                    }
                }
            }
            .task {
                if !store.hasLoaded, !store.isLoading { await store.load() }
                if printerStore.printers.isEmpty { await printerStore.refresh() }
            }
            .task {
                // No WebSocket events exist for virtual printers; poll like the web UI does.
                await model.loadAll(client: session.client)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if Task.isCancelled { break }
                    await model.refreshList(client: session.client)
                }
            }
            .sheet(isPresented: $showAdd) {
                SettingsVirtualPrinterAddSheet(model: model)
            }
            .sheet(item: $diagnosing) { vp in
                NavigationStack {
                    SettingsVirtualPrinterDiagnosticView(vpID: vp.id, name: vp.displayName)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Done") { diagnosing = nil } }
                        }
                }
            }
            .confirm("Delete \(pendingDelete?.displayName ?? "Virtual Printer")?",
                     isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                     message: "Its services stop immediately and any of its uploads still waiting for review are discarded.") {
                if let vp = pendingDelete { Task { await delete(vp) } }
            }
            .actionAlerts(runner)
            .alert("Couldn't Save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(store.saveError ?? "") }
    }

    @ViewBuilder private var content: some View {
        if model.hasLoaded {
            list
        } else if let error = model.loadError {
            ContentUnavailableView {
                Label("Couldn't Load Virtual Printers", systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button("Try Again") { Task { await model.loadAll(client: session.client) } }.buttonStyle(.bordered)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        List {
            printersSection
            certificateSection
            if store.hasLoaded {
                Section {
                    SettingsPicker("Archive Name", key: "virtual_printer_archive_name_source",
                                   choices: [("metadata", "Print Name in File"), ("filename", "File Name from Slicer")])
                } header: {
                    Text("Archive Naming")
                } footer: {
                    Text("Choose what names archives created from virtual printer uploads. The file name option lets you rename a print in the slicer's send dialog; the print name comes from the 3MF metadata, like a real printer.")
                }
            }
            tailscaleSection
            Section {
                Link(destination: URL(string: "https://wiki.bambuddy.cool/features/virtual-printer/")!) {
                    Label("Virtual Printer Setup Guide", systemImage: "book")
                }
            } footer: {
                Text("Virtual printers need a dedicated IP address on the Bambuddy host and the ports a real Bambu printer uses (990, 8883, 3000 and 3002). The guide covers Docker, alias IPs and firewall setup.")
            }
        }
        .refreshable { await model.loadAll(client: session.client) }
    }

    // MARK: Sections

    private var printersSection: some View {
        Section {
            if model.printers.isEmpty {
                ContentUnavailableView {
                    Label("No Virtual Printers", systemImage: "printer.dotmatrix")
                } description: {
                    Text("Add one to send prints from your slicer straight to Bambuddy.")
                } actions: {
                    if canEdit {
                        Button("Add Virtual Printer") { showAdd = true }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                ForEach(model.printers) { vp in
                    NavigationLink {
                        SettingsVirtualPrinterDetailView(vpID: vp.id, model: model)
                    } label: {
                        SettingsVPRow(vp: vp, targetName: vp.targetPrinterId.flatMap { printerStore.printer($0)?.name })
                    }
                    .swipeActions(edge: .trailing) {
                        if canEdit {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = vp }
                        }
                        Button("Check Setup", systemImage: "stethoscope") { diagnosing = vp }.tint(.indigo)
                    }
                    .swipeActions(edge: .leading) {
                        if canEdit {
                            Button(vp.isEnabled ? "Disable" : "Enable",
                                   systemImage: vp.isEnabled ? "stop.circle" : "play.circle") {
                                Task { await setEnabled(vp, !vp.isEnabled) }
                            }
                            .tint(vp.isEnabled ? .orange : .green)
                        }
                    }
                    .contextMenu {
                        if canEdit {
                            Button(vp.isEnabled ? "Disable" : "Enable",
                                   systemImage: vp.isEnabled ? "stop.circle" : "play.circle") {
                                Task { await setEnabled(vp, !vp.isEnabled) }
                            }
                        }
                        Button("Check Setup", systemImage: "stethoscope") { diagnosing = vp }
                        if let serial = vp.serial, !serial.isEmpty {
                            Button("Copy Serial Number", systemImage: "doc.on.doc") { UIPasteboard.general.string = serial }
                        }
                        if canEdit {
                            Divider()
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = vp }
                        }
                    }
                }
            }
        } header: {
            Text("Virtual Printers")
        } footer: {
            Text("Each virtual printer shows up in Bambu Studio and OrcaSlicer like a real printer on your network. In the slicer, add it by its bind IP address and access code (proxy mode uses the real printer's code), and import the certificate below once so the slicer trusts the connection.")
        }
    }

    private var certificateSection: some View {
        Section {
            if let cert = model.certificate {
                if let fingerprint = cert.fingerprintSha256 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SHA-256 Fingerprint")
                        Text(fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
                if let expiry = cert.notValidAfter {
                    LabeledContent("Valid Until", value: Fmt.date(expiry, style: .dateTime.month(.abbreviated).day().year()))
                }
                if let file = model.certificateFile {
                    ShareLink(item: file) { Label("Share Certificate File", systemImage: "square.and.arrow.up") }
                }
                if let pem = cert.pem, !pem.isEmpty {
                    Button {
                        UIPasteboard.general.string = pem
                        runner.successMessage = "Certificate copied"
                    } label: { Label("Copy Certificate (PEM)", systemImage: "doc.on.doc") }
                }
            } else if let error = model.certificateError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView()
            }
        } header: {
            Text("Slicer Certificate")
        } footer: {
            Text("Every virtual printer presents a TLS certificate signed by this Bambuddy authority. Import it once into your slicer's trusted certificates (or the OS trust store) and all virtual printers will be accepted. Only the public certificate is shared.")
        }
    }

    private var tailscaleSection: some View {
        Section {
            if let ts = model.tailscale {
                if ts.available == true {
                    LabeledContent("Status") { StatusBadge(text: "Connected", color: .green) }
                    if let host = ts.hostname, !host.isEmpty { InfoRow("Host Name", host) }
                    if let fqdn = ts.fqdn, !fqdn.isEmpty {
                        InfoRow("Address", fqdn)
                            .contextMenu { Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = fqdn } }
                    }
                    if let ips = ts.tailscaleIps, !ips.isEmpty { InfoRow("Tailscale IPs", ips.joined(separator: ", ")) }
                    if let tailnet = ts.tailnetName, !tailnet.isEmpty { InfoRow("Tailnet", tailnet) }
                } else {
                    LabeledContent("Status") { StatusBadge(text: "Not Available", color: .secondary) }
                    if let error = ts.error, !error.isEmpty {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Tailscale")
        } footer: {
            Text("When Bambuddy runs on a Tailscale node, a virtual printer can also be reached from slicers on your tailnet. Turn on Tailscale for each printer that should be exposed.")
        }
    }

    // MARK: Actions

    private func setEnabled(_ vp: SettingsVirtualPrinter, _ enabled: Bool) async {
        if enabled, let problem = SettingsVPValidation.enableProblem(for: vp) {
            runner.errorMessage = problem
            return
        }
        await runner.run(enabled ? "Virtual printer enabled" : "Virtual printer disabled") {
            let updated: SettingsVirtualPrinter = try await session.client.send(
                .put, "virtual-printers/\(vp.id)", body: SettingsVirtualPrinterUpdate(enabled: enabled))
            model.replace(updated)
        }
    }

    private func delete(_ vp: SettingsVirtualPrinter) async {
        await runner.run("Virtual printer deleted") {
            try await session.client.call(.delete, "virtual-printers/\(vp.id)")
            model.remove(vp.id)
        }
    }
}

// MARK: - Row

private struct SettingsVPRow: View {
    let vp: SettingsVirtualPrinter
    let targetName: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: vp.modeKind.systemImage)
                .font(.title3)
                .foregroundStyle(vp.isRunning ? Color.green : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(vp.displayName).font(.body.weight(.medium)).lineLimit(1)
                Text(detailLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            statusBadge
        }
        .padding(.vertical, 2)
    }

    private var detailLine: String {
        var parts = [vp.modeKind.title]
        if vp.modeKind != .proxy, let model = vp.modelName ?? vp.model { parts.append(model) }
        if let targetName { parts.append("→ \(targetName)") }
        if let ip = vp.bindIp, !ip.isEmpty { parts.append(ip) }
        if let pending = vp.status?.pendingFiles, pending > 0 { parts.append("\(pending) pending") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var statusBadge: some View {
        if vp.isRunning {
            StatusBadge(text: "Running", color: .green)
        } else if vp.isEnabled {
            StatusBadge(text: "Not Running", color: .orange)
        } else {
            StatusBadge(text: "Off", color: .secondary)
        }
    }
}
