import SwiftUI

struct DiscoveredPrinter: Codable, Sendable, Identifiable, Hashable {
    var serial: String
    var name: String?
    var ipAddress: String
    var model: String?
    var discoveredAt: String?
    var id: String { serial }
    var serialNumber: String? { serial }
}

/// Finds printers via the server's SSDP listener, or a subnet scan when running in Docker.
struct DiscoveryView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onPick: (DiscoveredPrinter) -> Void

    struct Info: Decodable { var isDocker: Bool; var ssdpRunning: Bool; var scanRunning: Bool; var subnets: [String]? }
    struct ScanStatus: Decodable { var running: Bool; var scanned: Int?; var total: Int? }

    @State private var info: Info?
    @State private var found: [DiscoveredPrinter] = []
    @State private var subnet = ""
    @State private var scan: ScanStatus?
    @State private var error: String?
    @State private var polling: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if let info, info.isDocker {
                    Section {
                        TextField("Subnet (e.g. 192.168.1.0/24)", text: $subnet).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                        Button(scan?.running == true ? "Scanning… \(scan?.scanned ?? 0)/\(scan?.total ?? 0)" : "Scan Subnet") { Task { await startScan() } }
                            .disabled(subnet.isEmpty || scan?.running == true)
                    } footer: { Text("The server runs in Docker, so multicast discovery may not work. Scan your printer's subnet instead.") }
                }
                Section("Found Printers") {
                    if found.isEmpty {
                        HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                    }
                    ForEach(found) { printer in
                        let known = store.printers.contains { $0.serialNumber == printer.serial }
                        Button {
                            onPick(printer)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(printer.name ?? printer.serial).font(.headline)
                                Text("\(printer.model ?? "Unknown model") · \(printer.ipAddress) · \(printer.serial)").font(.caption).foregroundStyle(.secondary)
                                if known { Text("Already added").font(.caption2).foregroundStyle(.orange) }
                            }
                        }
                        .disabled(known)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Discover Printers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task { await start() }
            .onDisappear {
                polling?.cancel()
                let client = session.client
                Task { try? await client.call(.post, "discovery/stop") }
            }
        }
    }

    private func start() async {
        let client = session.client
        do {
            info = try await client.get("discovery/info")
            subnet = info?.subnets?.first ?? ""
            if info?.isDocker != true { try await client.call(.post, "discovery/start", query: ["duration": 30]) }
        } catch { self.error = error.localizedDescription }
        polling = Task {
            while !Task.isCancelled {
                if let list: [DiscoveredPrinter] = try? await client.get("discovery/printers") { found = list }
                if scan?.running == true { scan = try? await client.get("discovery/scan/status") }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func startScan() async {
        do {
            struct Req: Encodable { var subnet: String }
            scan = try await session.client.send(.post, "discovery/scan", body: Req(subnet: subnet))
        } catch { self.error = error.localizedDescription }
    }
}
