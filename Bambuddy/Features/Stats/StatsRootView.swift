import SwiftUI

struct StatsRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Stats", webPath: "stats")
                .navigationTitle("Stats")
        }
    }
}
