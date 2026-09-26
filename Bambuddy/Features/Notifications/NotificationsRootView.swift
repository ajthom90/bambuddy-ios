import SwiftUI

struct NotificationsRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Notifications", webPath: "notifications")
                .navigationTitle("Notifications")
        }
    }
}
