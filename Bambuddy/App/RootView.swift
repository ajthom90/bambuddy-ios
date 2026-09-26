import SwiftUI

struct RootView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.phase {
            case .launching, .connecting:
                ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsServer:
                ServerSetupView()
            case .needsLogin:
                LoginView()
            case .needsSetup:
                FirstRunSetupView()
            case .failed(let message):
                ConnectionFailedView(message: message)
            case .ready:
                MainView()
            }
        }
        .task { await session.start() }
        .onChange(of: scenePhase) { _, phase in
            guard session.phase == .ready else { return }
            switch phase {
            case .active:
                if !session.live.isConnected { session.live.connect(client: session.client) }
                Task { await session.printers.refresh() }
            case .background:
                session.live.disconnect()
            default: break
            }
        }
    }
}

struct ConnectionFailedView: View {
    @Environment(AppSession.self) private var session
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label("Can't Connect", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await session.connect() } }.buttonStyle(.borderedProminent)
            Button("Change Server") { session.forgetServer() }
        }
    }
}
