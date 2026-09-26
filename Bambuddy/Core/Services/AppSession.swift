import Foundation
import Observation

/// Root application state: which server we talk to, who is signed in, and the
/// shared services (live updates, printer store) for that connection.
@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case launching
        case needsServer
        case connecting
        case needsLogin
        case needsSetup
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    private(set) var client: APIClient
    private(set) var serverURL: URL?
    private(set) var authStatus: AuthStatus?
    private(set) var user: User?
    private(set) var serverVersion: String?

    let live = LiveUpdates()
    let printers: PrinterStore

    private static let serverKey = "serverURL"
    private static let recentServersKey = "recentServers"

    init() {
        let url = UserDefaults.standard.string(forKey: Self.serverKey).flatMap(URL.init(string:))
        serverURL = url
        client = APIClient(baseURL: url ?? URL(string: "http://localhost")!, token: url.flatMap { Keychain.get($0.absoluteString) })
        printers = PrinterStore()
        printers.attach(session: self)
        NotificationCenter.default.addObserver(forName: .bambuddyUnauthorized, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleUnauthorized() }
        }
    }

    var recentServers: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentServersKey) ?? []
    }

    var isAuthEnabled: Bool { authStatus?.authEnabled ?? false }

    /// Permission check mirroring the web UI: with auth disabled everything is allowed.
    func can(_ permission: String) -> Bool {
        guard isAuthEnabled else { return true }
        guard let user else { return false }
        if user.isAdmin { return true }
        return user.permissions?.contains(permission) ?? false
    }

    // MARK: Lifecycle

    func start() async {
        guard serverURL != nil else { phase = .needsServer; return }
        await connect()
    }

    /// Normalizes user input like `192.168.1.5:8000` into a base URL.
    nonisolated static func normalize(_ input: String) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), comps.host?.isEmpty == false else { return nil }
        var path = comps.path
        for suffix in ["/api/v1", "/api/v1/"] where path.hasSuffix(suffix) { path.removeLast(suffix.count) }
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    /// Probes a server before switching to it. Returns its auth status.
    nonisolated static func probe(_ url: URL) async throws -> AuthStatus {
        try await APIClient(baseURL: url).get("auth/status")
    }

    func useServer(_ url: URL) async {
        live.disconnect()
        serverURL = url
        UserDefaults.standard.set(url.absoluteString, forKey: Self.serverKey)
        var recents = recentServers.filter { $0 != url.absoluteString }
        recents.insert(url.absoluteString, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(8)), forKey: Self.recentServersKey)
        client = APIClient(baseURL: url, token: Keychain.get(url.absoluteString))
        await connect()
    }

    func forgetServer() {
        live.disconnect()
        printers.reset()
        if let serverURL { Keychain.set(nil, for: serverURL.absoluteString) }
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        serverURL = nil
        user = nil
        authStatus = nil
        phase = .needsServer
    }

    func connect() async {
        guard let serverURL else { phase = .needsServer; return }
        phase = .connecting
        do {
            let status: AuthStatus = try await client.get("auth/status")
            authStatus = status
            if status.requiresSetup {
                phase = .needsSetup
                return
            }
            if status.authEnabled {
                guard client.token != nil else { phase = .needsLogin; return }
                do {
                    user = try await client.get("auth/me")
                } catch let error as APIError where error.status == 401 {
                    setToken(nil)
                    phase = .needsLogin
                    return
                }
            } else {
                user = nil
            }
            serverVersion = try? await client.get("system/info", as: JSONValue.self)["app"]?["version"]?.stringValue
            phase = .ready
            live.connect(client: client)
            await printers.refresh()
        } catch {
            phase = .failed("Could not reach \(serverURL.host() ?? serverURL.absoluteString): \(error.localizedDescription)")
        }
    }

    // MARK: Auth

    func completeLogin(token: String, user: User?) async {
        setToken(token)
        self.user = user
        await connect()
    }

    func logout() async {
        if client.token != nil { try? await client.call(.post, "auth/logout") }
        live.disconnect()
        printers.reset()
        setToken(nil)
        user = nil
        phase = isAuthEnabled ? .needsLogin : .ready
        if phase == .ready { live.connect(client: client); await printers.refresh() }
    }

    func refreshUser() async {
        guard isAuthEnabled else { return }
        if let me: User = try? await client.get("auth/me") { user = me }
    }

    private func setToken(_ token: String?) {
        guard let serverURL else { return }
        Keychain.set(token, for: serverURL.absoluteString)
        client = client.withToken(token)
    }

    private func handleUnauthorized() {
        guard phase == .ready, isAuthEnabled else { return }
        live.disconnect()
        setToken(nil)
        user = nil
        phase = .needsLogin
    }
}
