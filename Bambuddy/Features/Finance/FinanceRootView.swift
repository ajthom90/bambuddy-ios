import SwiftUI

struct FinanceRootView: View {
    var body: some View {
        NavigationStack {
            OpenInWebView(title: "Finance", webPath: "finance")
                .navigationTitle("Finance")
        }
    }
}
