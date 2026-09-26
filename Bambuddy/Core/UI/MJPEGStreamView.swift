import SwiftUI
import UIKit

/// Parses a `multipart/x-mixed-replace` MJPEG stream by scanning for JPEG
/// start/end markers, which is robust to boundary formatting differences.
final class MJPEGStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let onFrame: @Sendable (UIImage) -> Void
    private let onError: @Sendable (String) -> Void

    init(onFrame: @escaping @Sendable (UIImage) -> Void, onError: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onError = onError
    }

    func start(_ request: URLRequest) {
        stop()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }

    func stop() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        lock.withLock { buffer.removeAll() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onError("Camera unavailable (HTTP \(http.statusCode))")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var frames: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let start = buffer.firstRange(of: Data([0xFF, 0xD8])),
                  let end = buffer[start.upperBound...].firstRange(of: Data([0xFF, 0xD9])) {
                frames.append(buffer.subdata(in: start.lowerBound..<end.upperBound))
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            }
            if buffer.count > 8_000_000 { buffer.removeAll() }
        }
        // Only the newest frame matters.
        if let last = frames.last, let image = UIImage(data: last) { onFrame(image) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        } else {
            // The server closed the stream cleanly; fall back to snapshots instead of freezing.
            onError("Camera stream ended")
        }
    }
}

@MainActor
@Observable
final class CameraFeed {
    var frame: UIImage?
    var error: String?
    var isRunning = false
    @ObservationIgnored private var stream: MJPEGStream?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?

    /// Starts the MJPEG stream for a printer; falls back to polling snapshots on failure.
    func start(printerId: Int, client: APIClient, fps: Int = 10) {
        stop()
        isRunning = true
        error = nil
        Task {
            let token = try? await client.send(.post, "printers/camera/stream-token", as: TokenResponse.self).token
            var query: [String: QueryValue?] = ["fps": .int(fps)]
            if let token { query["token"] = .string(token) }
            let req = client.makeRequest(.get, "printers/\(printerId)/camera/stream", query: query)
            let stream = MJPEGStream(
                onFrame: { [weak self] image in Task { @MainActor in self?.frame = image; self?.error = nil } },
                onError: { [weak self] message in Task { @MainActor in self?.fallBackToSnapshots(printerId: printerId, client: client, token: token, reason: message) } }
            )
            self.stream = stream
            stream.start(req)
        }
    }

    private func fallBackToSnapshots(printerId: Int, client: APIClient, token: String?, reason: String) {
        guard isRunning, snapshotTask == nil else { return }
        stream?.stop()
        snapshotTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                var query: [String: QueryValue?] = ["t": .int(Int(Date().timeIntervalSince1970))]
                if let token { query["token"] = .string(token) }
                if let data = try? await client.data("printers/\(printerId)/camera/snapshot", query: query), let img = UIImage(data: data) {
                    self?.frame = img
                    self?.error = nil
                    failures = 0
                } else {
                    failures += 1
                    if failures >= 3 { self?.error = reason }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        stream?.stop()
        stream = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        isRunning = false
    }
}

/// Live camera view for a printer.
struct PrinterCameraView: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    var rotation: Int = 0
    var fps: Int = 10
    @State private var feed = CameraFeed()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black
            if let frame = feed.frame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .rotationEffect(.degrees(Double(rotation)))
            } else if let error = feed.error {
                ContentUnavailableView("Camera Unavailable", systemImage: "video.slash", description: Text(error))
                    .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .onAppear { feed.start(printerId: printerId, client: session.client, fps: fps) }
        .onDisappear {
            feed.stop()
            let client = session.client
            Task { try? await client.call(.post, "printers/\(printerId)/camera/stop") }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !feed.isRunning { feed.start(printerId: printerId, client: session.client, fps: fps) }
            if phase == .background { feed.stop() }
        }
    }

    var currentFrame: UIImage? { feed.frame }
}
