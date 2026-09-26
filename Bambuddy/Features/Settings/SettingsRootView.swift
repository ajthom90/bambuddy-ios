import SwiftUI

struct SettingsRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Settings", webPath: "settings")
                .navigationTitle("Settings")
        }
    }
}
