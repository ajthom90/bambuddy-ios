import SwiftUI

@main
struct BambuddyApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(session.printers)
                .environment(session.live)
        }
    }
}
