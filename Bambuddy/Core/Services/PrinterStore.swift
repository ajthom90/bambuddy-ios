import Foundation
import Observation

/// Printers and their live status, kept current by the WebSocket feed.
@MainActor
@Observable
final class PrinterStore {
    private(set) var printers: [Printer] = []
    private(set) var statuses: [Int: PrinterStatus] = [:]
    private(set) var isLoading = false
    private(set) var error: String?

    @ObservationIgnored private weak var session: AppSession?
    @ObservationIgnored private var raw: [Int: JSONValue] = [:]
    @ObservationIgnored private var pending: [Int: JSONValue] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    func attach(session: AppSession) {
        self.session = session
        session.live.subscribe { [weak self] event in self?.handle(event) }
    }

    private var client: APIClient? { session?.client }

    func reset() {
        printers = []
        statuses = [:]
        raw = [:]
        pending = [:]
    }

    func printer(_ id: Int) -> Printer? { printers.first { $0.id == id } }

    func refresh() async {
        guard let client else { return }
        isLoading = printers.isEmpty
        defer { isLoading = false }
        do {
            printers = try await client.get("printers/")
            error = nil
            await withTaskGroup(of: Void.self) { group in
                for p in printers { group.addTask { await self.refreshStatus(p.id) } }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshStatus(_ id: Int) async {
        guard let client else { return }
        guard let value: JSONValue = try? await client.get("printers/\(id)/status") else { return }
        raw[id] = value
        if let status = try? value.decode(PrinterStatus.self) { statuses[id] = status }
    }

    private func handle(_ event: LiveEvent) {
        switch event.type {
        case "printer_status":
            guard let id = event.printerId, let data = event.data else { return }
            pending[id] = (pending[id] ?? .object([:])).merging(data)
            scheduleFlush()
        case "print_start", "print_complete":
            if let id = event.printerId { Task { await refreshStatus(id) } }
        default:
            break
        }
    }

    /// Coalesces bursts of status deltas into at most ~3 UI updates per second.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        for (id, delta) in pending {
            var merged = (raw[id] ?? .object([:])).merging(delta)
            // The server sometimes omits wifi_signal; keep the last known value.
            if case .object(var o) = merged, (o["wifi_signal"] ?? .null).isNull, let old = raw[id]?["wifi_signal"], !old.isNull {
                o["wifi_signal"] = old
                merged = .object(o)
            }
            raw[id] = merged
            if let status = try? merged.decode(PrinterStatus.self) { statuses[id] = status }
        }
        pending = [:]
    }
}
