import SwiftUI

struct ProfilesRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Profiles", webPath: "profiles")
                .navigationTitle("Profiles")
        }
    }
}
