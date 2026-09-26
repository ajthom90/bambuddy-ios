import SwiftUI

struct MaintenanceRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Maintenance", webPath: "maintenance")
                .navigationTitle("Maintenance")
        }
    }
}
