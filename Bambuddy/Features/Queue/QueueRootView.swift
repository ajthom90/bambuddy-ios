import SwiftUI

struct QueueRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Queue", webPath: "queue")
                .navigationTitle("Queue")
        }
    }
}
