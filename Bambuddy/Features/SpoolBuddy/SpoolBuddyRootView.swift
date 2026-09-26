import SwiftUI

struct SpoolBuddyRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "SpoolBuddy", webPath: "spoolbuddy")
                .navigationTitle("SpoolBuddy")
        }
    }
}
