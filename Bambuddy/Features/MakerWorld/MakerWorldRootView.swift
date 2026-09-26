import SwiftUI

struct MakerWorldRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "MakerWorld", webPath: "makerworld")
                .navigationTitle("MakerWorld")
        }
    }
}
