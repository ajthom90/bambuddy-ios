import SwiftUI

struct FilesRootView: View {
    @State private var navigator = LibraryNavigator()

    var body: some View {
        NavigationStack(path: $navigator.path) {
            LibraryBrowserView(scope: .root)
                .modifier(LibraryNavigationDestinations())
        }
        .environment(navigator)
        #if DEBUG
        .onAppear {
            // Launch arguments for screenshots: `-libraryOpenFolder <id>`, `-libraryOpenFile <id>`, `-libraryOpenTrash YES`.
            guard navigator.path.isEmpty else { return }
            let defaults = UserDefaults.standard
            if defaults.integer(forKey: "libraryOpenFolder") > 0 {
                navigator.path.append(.browse(.folder(defaults.integer(forKey: "libraryOpenFolder"))))
            }
            if defaults.integer(forKey: "libraryOpenFile") > 0 {
                navigator.path.append(.file(defaults.integer(forKey: "libraryOpenFile")))
            }
            if defaults.bool(forKey: "libraryOpenTrash") { navigator.path.append(.trash) }
            if defaults.bool(forKey: "libraryOpenAll") { navigator.path.append(.browse(.allInternal)) }
        }
        #endif
    }
}
