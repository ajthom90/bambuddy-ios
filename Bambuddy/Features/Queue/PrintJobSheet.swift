import SwiftUI

/// What is being printed. Shared entry point used by Archives, Files, Projects and Queue.
enum PrintSource: Hashable, Sendable {
    case archive(id: Int, name: String)
    case libraryFile(id: Int, name: String)

    var name: String {
        switch self {
        case .archive(_, let name), .libraryFile(_, let name): name
        }
    }
}

/// Sheet for sending a file to a printer now or adding it to the queue
/// (printer choice, plate, AMS mapping, print options, scheduling).
/// Owned by the Queue feature.
struct PrintJobSheet: View {
    enum Mode: Hashable, Sendable { case printNow, addToQueue }

    let source: PrintSource
    var mode: Mode = .printNow
    var onComplete: (() -> Void)? = nil

    var body: some View {
        OpenInWebView(title: "Print \(source.name)", webPath: "queue")
    }
}
