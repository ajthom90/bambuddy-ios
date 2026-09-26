import SwiftUI
import UniformTypeIdentifiers

/// One file queued for upload.
@MainActor
@Observable
final class LibraryUploadItem: Identifiable {
    enum State: Equatable { case pending, uploading, done(String), failed(String) }
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64?
    var state: State = .pending
    var progress: Double = 0

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    var isZip: Bool { name.lowercased().hasSuffix(".zip") }
    var is3MF: Bool { name.lowercased().hasSuffix(".3mf") }
    var isSTL: Bool { name.lowercased().hasSuffix(".stl") }
}

/// Uploads files (3MF, STL, G-code, ZIP, …) into a library folder with
/// per-file progress. ZIPs are extracted server-side.
struct LibraryUploadSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let folderId: Int?
    let folderName: String
    let initialFiles: [URL]
    let onFinished: () -> Void

    @State private var items: [LibraryUploadItem] = []
    @State private var generateThumbnails = true
    @State private var preserveZipStructure = true
    @State private var createFolderFromZip = false
    @State private var isUploading = false
    @State private var showImporter = false
    @State private var finished = false

    private var pendingCount: Int { items.filter { $0.state == .pending }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Destination") {
                        Label(folderName, systemImage: folderId == nil ? "tray.full" : "folder")
                    }
                }
                Section {
                    ForEach(items) { item in
                        LibraryUploadRow(item: item)
                            .swipeActions {
                                if item.state == .pending && !isUploading {
                                    Button("Remove", role: .destructive) { items.removeAll { $0.id == item.id } }
                                }
                            }
                    }
                    if !isUploading {
                        Button("Add Files…", systemImage: "plus") { showImporter = true }
                    }
                } header: {
                    Text("Files")
                } footer: {
                    if items.contains(where: \.is3MF) {
                        Text("Print settings, plates and thumbnails are read from 3MF files automatically.")
                    }
                }
                if items.contains(where: \.isZip) {
                    Section {
                        Toggle("Keep Folder Structure", isOn: $preserveZipStructure)
                        Toggle("Create Folder from ZIP Name", isOn: $createFolderFromZip)
                    } header: {
                        Text("ZIP Archives")
                    } footer: {
                        Text("ZIP files are extracted on the server instead of being stored as archives.")
                    }
                    .disabled(isUploading)
                }
                if items.contains(where: { $0.isSTL || $0.isZip }) {
                    Section {
                        Toggle("Generate STL Thumbnails", isOn: $generateThumbnails)
                    } footer: {
                        Text("Renders a preview image for STL models after upload.")
                    }
                    .disabled(isUploading)
                }
            }
            .navigationTitle("Upload")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(finished ? "Done" : "Cancel") {
                        if finished { onFinished() }
                        dismiss()
                    }
                    .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isUploading { ProgressView() } else {
                        Button(pendingCount > 0 ? "Upload (\(pendingCount))" : "Upload") { Task { await uploadAll() } }
                            .disabled(pendingCount == 0)
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { add(urls) }
            }
        }
        .interactiveDismissDisabled(isUploading)
        .onAppear { if items.isEmpty { add(initialFiles, staged: true) } }
    }

    private func add(_ urls: [URL], staged: Bool = false) {
        for url in urls {
            let local = staged ? url : (try? LibraryImportStaging.stage(url))
            if let local { items.append(LibraryUploadItem(url: local)) }
        }
    }

    private func uploadAll() async {
        isUploading = true
        defer { isUploading = false; finished = true }
        let client = session.client
        for item in items where item.state == .pending {
            item.state = .uploading
            item.progress = 0
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor in item.progress = value }
            }
            do {
                if item.isZip {
                    let data = try await LibraryUploader.upload(
                        client: client, path: "library/files/extract-zip",
                        query: ["folder_id": .of(folderId), "preserve_structure": .bool(preserveZipStructure),
                                "create_folder_from_zip": .bool(createFolderFromZip), "generate_stl_thumbnails": .bool(generateThumbnails)],
                        file: item.url, fileName: item.name, progress: report)
                    let result = try APICoders.decoder.decode(LibraryZipResult.self, from: data)
                    let failures = result.errors?.count ?? 0
                    var summary = "\(result.extracted ?? 0) files extracted"
                    if let folders = result.foldersCreated, folders > 0 { summary += ", \(folders) folders" }
                    if failures > 0 { summary += ", \(failures) failed" }
                    item.state = .done(summary)
                } else {
                    let data = try await LibraryUploader.upload(
                        client: client, path: "library/files/",
                        query: ["folder_id": .of(folderId), "generate_stl_thumbnails": .bool(generateThumbnails)],
                        file: item.url, fileName: item.name, progress: report)
                    let result = try APICoders.decoder.decode(LibraryUploadResult.self, from: data)
                    item.state = .done(result.duplicateOf != nil ? "Uploaded (duplicate of an existing file)" : "Uploaded")
                }
                item.progress = 1
            } catch {
                item.state = .failed(error.localizedDescription)
            }
        }
        onFinished()
        if items.allSatisfy({ if case .done = $0.state { true } else { false } }) {
            try? await Task.sleep(for: .milliseconds(600))
            dismiss()
        }
    }
}

private struct LibraryUploadRow: View {
    let item: LibraryUploadItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: LibraryFileKind.icon(for: LibraryFileKind.type(of: item.name)))
                .font(.title3)
                .foregroundStyle(LibraryFileKind.color(for: LibraryFileKind.type(of: item.name)))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).lineLimit(2)
                switch item.state {
                case .pending:
                    Text(item.isZip ? "\(Fmt.bytes(item.size)) · will be extracted" : Fmt.bytes(item.size))
                        .font(.caption).foregroundStyle(.secondary)
                case .uploading:
                    ProgressView(value: item.progress)
                    Text(item.progress >= 0.99 ? "Processing…" : "\(Int(item.progress * 100))% of \(Fmt.bytes(item.size))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                case .done(let message):
                    Label(message, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                }
            }
        }
    }
}
