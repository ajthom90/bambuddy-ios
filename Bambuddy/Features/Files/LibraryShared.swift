import SwiftUI
import UIKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import UniformTypeIdentifiers

// MARK: Permissions

/// Ownership-aware permission checks for library files (mirrors the web's `canModify`).
@MainActor
enum LibraryAccess {
    static func canUpdate(_ session: AppSession, ownerId: Int?) -> Bool {
        owns(session, ownerId: ownerId, all: "library:update_all", own: "library:update_own")
    }

    static func canDelete(_ session: AppSession, ownerId: Int?) -> Bool {
        owns(session, ownerId: ownerId, all: "library:delete_all", own: "library:delete_own")
    }

    static func canUpdateAny(_ session: AppSession) -> Bool {
        session.can("library:update_all") || session.can("library:update_own")
    }

    static func canDeleteAny(_ session: AppSession) -> Bool {
        session.can("library:delete_all") || session.can("library:delete_own")
    }

    static func canRead(_ session: AppSession) -> Bool {
        session.can("library:read_all") || session.can("library:read_own") || session.can("library:read")
    }

    private static func owns(_ session: AppSession, ownerId: Int?, all: String, own: String) -> Bool {
        if session.can(all) { return true }
        guard session.can(own) else { return false }
        guard session.isAuthEnabled else { return true }
        return ownerId != nil && ownerId == session.user?.id
    }
}

// MARK: Shared API helpers

enum LibraryAPI {
    static func folders(_ client: APIClient) async throws -> [LibraryFolderNode] {
        try await client.get("library/folders")
    }

    static func settings(_ client: APIClient) async -> LibraryServerSettings? {
        try? await client.get("settings/")
    }

    static func tags(_ client: APIClient) async throws -> [LibraryTag] {
        try await client.get("library/tags")
    }

    static func thumbnailPath(fileId: Int) -> String { "library/files/\(fileId)/thumbnail" }
}

// MARK: Upload with progress

/// Streams a multipart upload from disk so large 3MF/ZIP files never sit in
/// memory, reporting progress as bytes are sent.
enum LibraryUploader {
    static func upload(
        client: APIClient,
        path: String,
        query: [String: QueryValue?],
        file: URL,
        fileName: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = try await Task.detached(priority: .utility) {
            try makeBody(file: file, fileName: fileName, boundary: boundary)
        }.value
        defer { try? FileManager.default.removeItem(at: body) }

        var request = client.makeRequest(.post, path, query: query)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60 * 30
        let delegate = LibraryUploadProgressDelegate(progress)
        let (data, response) = try await APIClient.session.upload(for: request, fromFile: body, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 401, client.token != nil {
                NotificationCenter.default.post(name: .bambuddyUnauthorized, object: nil)
            }
            throw APIError.from(status: http.statusCode, data: data)
        }
        progress(1)
        return data
    }

    /// Builds the multipart body (a single `file` part) in a temporary file.
    static func makeBody(file: URL, fileName: String, boundary: String) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let writer = try FileHandle(forWritingTo: out)
        defer { try? writer.close() }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimeType(for: fileName))\r\n\r\n"
        try writer.write(contentsOf: Data(header.utf8))
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
        try writer.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return out
    }

    static func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "zip": return "application/zip"
        case "3mf": return "model/3mf"
        case "stl": return "model/stl"
        case "gcode": return "text/x.gcode"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

private final class LibraryUploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

/// Copies picked / dropped files into the app's temp directory so the upload
/// no longer depends on security-scoped access.
enum LibraryImportStaging {
    static func stage(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    @MainActor
    static func stage(provider: NSItemProvider) async -> URL? {
        let suggested = provider.suggestedName
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("library-drop-\(UUID().uuidString)", isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let name = suggested.map { name in
                        name.contains(".") || url.pathExtension.isEmpty ? name : "\(name).\(url.pathExtension)"
                    } ?? url.lastPathComponent
                    let dest = dir.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: Views

/// Thumbnail for a library file, falling back to a type icon.
struct LibraryFileThumbnail: View {
    let fileId: Int
    let hasThumbnail: Bool
    let type: String
    var version: Int = 0

    var body: some View {
        RemoteImage(path: hasThumbnail ? LibraryAPI.thumbnailPath(fileId: fileId) : nil,
                    contentMode: .fit,
                    reloadKey: version == 0 ? nil : AnyHashable(version)) {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: LibraryFileKind.icon(for: type))
                    .font(.title2)
                    .foregroundStyle(LibraryFileKind.color(for: type).opacity(0.7))
            }
        }
        .background(Color(.secondarySystemBackground))
    }
}

struct LibraryTypeBadge: View {
    let type: String
    var body: some View {
        StatusBadge(text: type.uppercased(), color: LibraryFileKind.color(for: type))
    }
}

struct LibraryTagChips: View {
    let tags: [LibraryTagRef]
    var onTap: ((LibraryTagRef) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(tags) { tag in
                    Button { onTap?(tag) } label: {
                        Label(tag.name, systemImage: "tag")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14), in: .capsule)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(onTap == nil)
                }
            }
        }
    }
}

/// A downloaded file ready to hand to the share sheet.
struct LibrarySharedFile: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
}

/// `UIActivityViewController` wrapper (share / Save to Files / AirDrop / open in…).
struct LibraryActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Interactive 3D preview for mesh files (STL / OBJ) using SceneKit.
struct LibraryModelPreviewView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let fileId: Int
    let filename: String

    @State private var scene: SCNScene?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let scene {
                    SceneView(scene: scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                        .ignoresSafeArea(edges: .bottom)
                } else if let error {
                    ContentUnavailableView("Preview Unavailable", systemImage: "cube.transparent", description: Text(error))
                } else {
                    ProgressView("Loading model…")
                }
            }
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let url = try await session.client.download("library/files/\(fileId)/download", suggestedName: filename)
            let built = await Task.detached(priority: .userInitiated) { () -> LibrarySceneBox? in
                let asset = MDLAsset(url: url)
                guard asset.count > 0 else { return nil }
                asset.loadTextures()
                let scene = SCNScene(mdlAsset: asset)
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.systemTeal
                material.lightingModel = .blinn
                scene.rootNode.enumerateChildNodes { node, _ in
                    node.geometry?.materials = [material]
                }
                return LibrarySceneBox(scene: scene)
            }.value
            if let built { scene = built.scene } else { error = "This file format can't be previewed on this device." }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// SceneKit scenes are built off the main thread and then handed over once.
private struct LibrarySceneBox: @unchecked Sendable { let scene: SCNScene }


/// Small row used by folder pickers.
struct LibraryFolderLabel: View {
    let node: LibraryFolderNode
    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(node.name)
                if node.readOnly { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
            }
        } icon: {
            Image(systemName: node.external ? "externaldrive.connected.to.line.below" : (node.isLinked ? "folder.badge.gearshape" : "folder"))
                .foregroundStyle(node.external ? .purple : .blue)
        }
    }
}
