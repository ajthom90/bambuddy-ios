import SwiftUI
import UIKit

/// Loads images through the API client so the bearer token is attached.
actor ImageLoader {
    static let shared = ImageLoader()
    private let cache = NSCache<NSURL, UIImage>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    init() { cache.countLimit = 300 }

    func image(for url: URL, client: APIClient, reload: Bool = false) async -> UIImage? {
        if !reload, let hit = cache.object(forKey: url as NSURL) { return hit }
        if let task = inflight[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            var req = client.makeRequest(.get, url.absoluteString)
            req.setValue("image/*,*/*", forHTTPHeaderField: "Accept")
            guard let data = try? await client.rawData(req) else { return nil }
            return await Task.detached(priority: .utility) { UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) }.value
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }

    func evict(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}

/// An `AsyncImage` replacement that authenticates against the Bambuddy server.
/// `path` may be relative to `/api/v1`, server-absolute (`/api/v1/...`) or a full URL.
struct RemoteImage<Placeholder: View>: View {
    @Environment(AppSession.self) private var session
    let path: String?
    var contentMode: ContentMode = .fill
    var reloadKey: AnyHashable? = nil
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: TaskKey(path: path, reload: reloadKey)) {
            guard let path, !path.isEmpty else { image = nil; return }
            let url = session.client.url(path)
            let loaded = await ImageLoader.shared.image(for: url, client: session.client, reload: reloadKey != nil && image != nil)
            if let loaded { image = loaded } else if image == nil { failed = true }
        }
    }

    private struct TaskKey: Hashable { let path: String?; let reload: AnyHashable? }
}

extension RemoteImage where Placeholder == ImagePlaceholder {
    init(path: String?, contentMode: ContentMode = .fill, reloadKey: AnyHashable? = nil, systemImage: String = "photo") {
        self.init(path: path, contentMode: contentMode, reloadKey: reloadKey) { ImagePlaceholder(systemImage: systemImage) }
    }
}

struct ImagePlaceholder: View {
    var systemImage: String = "photo"
    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay { Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary) }
    }
}
