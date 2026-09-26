import Foundation
import Observation

/// A message pushed by the server over `/api/v1/ws`.
struct LiveEvent: Sendable {
    let type: String
    let printerId: Int?
    let data: JSONValue?
    let raw: JSONValue
}

/// Maintains the WebSocket connection to `/api/v1/ws` and fans events out.
///
/// Views that only need "something changed, reload" observe `revision(_:)`;
/// services that need payloads register a handler with `subscribe`.
@MainActor
@Observable
final class LiveUpdates {
    private(set) var isConnected = false
    private(set) var revisions: [String: Int] = [:]
    /// The most recent event that is worth surfacing to the user as a toast.
    private(set) var latestNotice: LiveEvent?

    @ObservationIgnored private var handlers: [UUID: @MainActor (LiveEvent) -> Void] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?

    /// Event types that bump `revisions` (high-frequency printer status does not).
    private static let quietTypes: Set<String> = ["printer_status", "pong", "spoolbuddy_weight"]
    static let noticeTypes: Set<String> = [
        "print_start", "print_complete", "plate_not_empty", "missing_spool_assignment",
        "kill_switch_triggered", "billing_charge_failed", "unknown_tag", "queue_item_failed",
    ]

    /// Sum of revisions for the given event types; use with `.onChange` / `.task(id:)`.
    func revision(_ types: String...) -> Int {
        types.reduce(0) { $0 + (revisions[$1] ?? 0) }
    }

    func revision(_ types: [String]) -> Int {
        types.reduce(0) { $0 + (revisions[$1] ?? 0) }
    }

    @discardableResult
    func subscribe(_ handler: @escaping @MainActor (LiveEvent) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unsubscribe(_ id: UUID) { handlers[id] = nil }

    func connect(client: APIClient) {
        disconnect()
        loop = Task { [weak self] in await self?.run(client: client) }
    }

    func disconnect() {
        loop?.cancel()
        loop = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isConnected = false
    }

    private func run(client: APIClient) async {
        while !Task.isCancelled {
            var token: String?
            do {
                token = try await client.send(.post, "auth/ws-token", as: TokenResponse.self).token
            } catch let error as APIError where error.status == 401 || error.status == 403 {
                return // Auth decision, not a transient failure.
            } catch {
                // Network error: fall through; the socket attempt decides.
            }
            guard !Task.isCancelled else { return }

            var comps = URLComponents(url: client.url("ws"), resolvingAgainstBaseURL: false)!
            comps.scheme = comps.scheme == "https" ? "wss" : "ws"
            if let token { comps.queryItems = [URLQueryItem(name: "token", value: token)] }
            let task = APIClient.session.webSocketTask(with: comps.url!)
            socket = task
            task.resume()

            let pinger = Task { [weak task] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    try? await task?.send(.string(#"{"type":"ping"}"#))
                }
            }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    isConnected = true
                    switch message {
                    case .string(let text): dispatch(Data(text.utf8))
                    case .data(let data): dispatch(data)
                    @unknown default: break
                    }
                }
            } catch {
                // Connection dropped.
            }
            pinger.cancel()
            isConnected = false
            if task.closeCode.rawValue == 4401 { return }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    private func dispatch(_ data: Data) {
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
              let type = raw["type"]?.stringValue else { return }
        let event = LiveEvent(type: type, printerId: raw["printer_id"]?.intValue, data: raw["data"], raw: raw)
        if !Self.quietTypes.contains(type) {
            revisions[type, default: 0] += 1
        }
        if Self.noticeTypes.contains(type) { latestNotice = event }
        for handler in handlers.values { handler(event) }
    }
}
