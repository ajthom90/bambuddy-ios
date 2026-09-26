import SwiftUI

struct SystemRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "System", webPath: "system")
                .navigationTitle("System")
        }
    }
}
