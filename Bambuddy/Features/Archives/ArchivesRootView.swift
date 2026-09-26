import SwiftUI

struct ArchivesRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Archives", webPath: "archives")
                .navigationTitle("Archives")
        }
    }
}
