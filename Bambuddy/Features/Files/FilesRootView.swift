import SwiftUI

struct FilesRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Files", webPath: "files")
                .navigationTitle("Files")
        }
    }
}
