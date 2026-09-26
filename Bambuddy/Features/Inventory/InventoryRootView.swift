import SwiftUI

struct InventoryRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Inventory", webPath: "inventory")
                .navigationTitle("Inventory")
        }
    }
}
