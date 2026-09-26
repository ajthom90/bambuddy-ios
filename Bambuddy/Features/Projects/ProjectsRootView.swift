import SwiftUI

struct ProjectsRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Projects", webPath: "projects")
                .navigationTitle("Projects")
        }
    }
}
