import SafariServices
import SwiftUI

struct AppExternalLink: Codable, Sendable, Identifiable, Hashable {
    var id: Int
    var name: String
    var url: String
    var icon: String?
    var openInNewTab: Bool?
    var customIcon: String?
    var sortOrder: Int?
}

/// Server-configured external links (the web UI shows these in its sidebar).
/// They open in an in-app Safari view, or in Safari when marked "open in new tab".
struct ExternalLinksView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.openURL) private var openURL
    @State private var loader = Loader<[AppExternalLink]>()
    @State private var presented: IdentifiableURL?

    var body: some View {
        NavigationStack {
            LoadingContent(loader: loader, retry: load) { links in
                if links.isEmpty {
                    ContentUnavailableView("No Links", systemImage: "link",
                                           description: Text("External links added in Bambuddy's settings appear here."))
                } else {
                    List(links.sorted { ($0.sortOrder ?? 0, $0.name) < ($1.sortOrder ?? 0, $1.name) }) { link in
                        Button {
                            guard let url = URL(string: link.url) else { return }
                            if link.openInNewTab == true || !["http", "https"].contains(url.scheme ?? "") {
                                openURL(url)
                            } else {
                                presented = IdentifiableURL(url: url)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if link.customIcon != nil {
                                    RemoteImage(path: "external-links/\(link.id)/icon", contentMode: .fit, systemImage: "link")
                                        .frame(width: 28, height: 28)
                                        .clipShape(.rect(cornerRadius: 6))
                                } else {
                                    Image(systemName: "link").frame(width: 28, height: 28).foregroundStyle(.tint)
                                }
                                VStack(alignment: .leading) {
                                    Text(link.name).foregroundStyle(.primary)
                                    Text(link.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: link.openInNewTab == true ? "arrow.up.forward.app" : "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Links")
            .refreshable { await load() }
            .task { await load() }
            .sheet(item: $presented) { item in
                SafariView(url: item.url).ignoresSafeArea()
            }
        }
    }

    private func load() async {
        await loader.load { try await session.client.get("external-links/") }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
