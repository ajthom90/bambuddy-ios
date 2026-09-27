import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Create/edit sheet for an external link, including its icon.
struct SettingsExternalLinkEditor: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let link: SettingsExternalLink?
    var onSave: (SettingsExternalLink) -> Void

    @State private var name = ""
    @State private var url = "https://"
    @State private var icon = "link"
    @State private var openInNewTab = false
    /// Replacement icon chosen in this session (uploaded on save).
    @State private var pendingIcon: SettingsExternalLinkUpload?
    /// True when the existing uploaded icon should be removed on save.
    @State private var removeCustomIcon = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var runner = ActionRunner()
    @State private var didPopulate = false

    private var hasExistingCustomIcon: Bool { link?.customIconPath != nil && !removeCustomIcon }
    private var isValid: Bool { SettingsExternalLinkIcons.isValidName(name) && SettingsExternalLinkIcons.isValidURL(url) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        preview.frame(width: 64, height: 64)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > 50 { name = String(v.prefix(50)) } }
                    TextField("https://example.com", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    if !url.isEmpty && url != "https://" && !SettingsExternalLinkIcons.isValidURL(url) {
                        Text("The address must start with http:// or https://.").foregroundStyle(.red)
                    }
                }

                Section {
                    Toggle("Open in New Browser Tab", isOn: $openInNewTab)
                } footer: {
                    Text("Controls how the web interface opens the link. In this app, links always open in your browser.")
                }

                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                        ForEach(SettingsExternalLinkIcons.all, id: \.name) { item in
                            Button {
                                icon = item.name
                            } label: {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 18))
                                    .frame(width: 44, height: 44)
                                    .background(icon == item.name ? Color.accentColor.opacity(0.2) : Color.clear, in: .rect(cornerRadius: 8))
                                    .overlay {
                                        if icon == item.name {
                                            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 1.5)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.name.replacingOccurrences(of: "-", with: " "))
                            .accessibilityAddTraits(icon == item.name ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Icon")
                } footer: {
                    if pendingIcon != nil || hasExistingCustomIcon {
                        Text("The uploaded image is shown instead; this icon is the fallback.")
                    }
                }

                Section {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { showFileImporter = true } label: {
                        Label("Choose File…", systemImage: "folder")
                    }
                    if pendingIcon != nil || hasExistingCustomIcon {
                        Button(role: .destructive) {
                            pendingIcon = nil
                            photoItem = nil
                            if link?.customIconPath != nil { removeCustomIcon = true }
                        } label: {
                            Label("Remove Custom Image", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Custom Image")
                } footer: {
                    Text("PNG, JPEG, GIF, SVG, WebP or ICO, up to 1 MB. Large photos are scaled down automatically.")
                }
            }
            .navigationTitle(link == nil ? "New Link" : "Edit Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }.disabled(!isValid)
                    }
                }
            }
            .interactiveDismissDisabled(runner.isRunning)
            .actionAlerts(runner)
            .onAppear(perform: populate)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: SettingsExternalLinkIcons.importableTypes) { result in
                loadFile(result)
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let pendingIcon {
            if let image = UIImage(data: pendingIcon.data) {
                Image(uiImage: image).resizable().scaledToFit().clipShape(.rect(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    .overlay { Image(systemName: "photo.badge.checkmark").font(.title2).foregroundStyle(.secondary) }
            }
        } else if let link, hasExistingCustomIcon {
            SettingsExternalLinkIconView(link: link)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.15))
                .overlay {
                    Image(systemName: SettingsExternalLinkIcons.symbol(for: icon)).font(.system(size: 28, weight: .medium)).foregroundStyle(.tint)
                }
        }
    }

    private func populate() {
        guard !didPopulate else { return }
        didPopulate = true
        guard let link else { return }
        name = link.name
        url = link.url
        icon = link.icon ?? "link"
        openInNewTab = link.openInNewTab ?? false
    }

    // MARK: Icon selection

    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension?.lowercased()
            pendingIcon = try SettingsExternalLinkUpload.make(data: data, fileExtension: ext)
            removeCustomIcon = false
        } catch {
            runner.errorMessage = error.localizedDescription
        }
    }

    private func loadFile(_ result: Result<URL, Error>) {
        do {
            let fileURL = try result.get()
            let scoped = fileURL.startAccessingSecurityScopedResource()
            defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: fileURL)
            pendingIcon = try SettingsExternalLinkUpload.make(data: data, fileExtension: fileURL.pathExtension.lowercased())
            removeCustomIcon = false
        } catch {
            runner.errorMessage = error.localizedDescription
        }
    }

    // MARK: Save

    private func save() async {
        let body = SettingsExternalLinkBody(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                            url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                                            icon: icon, openInNewTab: openInNewTab)
        let client = session.client
        await runner.run {
            var saved: SettingsExternalLink
            if let link {
                saved = try await client.send(.patch, "external-links/\(link.id)", body: body)
            } else {
                saved = try await client.send(.post, "external-links/", body: body)
                // The create endpoint ignores `open_in_new_tab`; apply it with a follow-up update.
                if openInNewTab && saved.openInNewTab != true {
                    saved = try await client.send(.patch, "external-links/\(saved.id)", body: ["open_in_new_tab": JSONValue.bool(true)])
                }
            }
            if let pendingIcon {
                saved = try await client.upload("external-links/\(saved.id)/icon", files: [
                    UploadFile(fieldName: "file", fileName: pendingIcon.fileName, mimeType: pendingIcon.mimeType, data: pendingIcon.data),
                ])
            } else if removeCustomIcon, link?.customIconPath != nil {
                saved = try await client.send(.delete, "external-links/\(saved.id)/icon")
            }
            if pendingIcon != nil || removeCustomIcon {
                await ImageLoader.shared.evict(client.url("external-links/\(saved.id)/icon"))
            }
            onSave(saved)
            dismiss()
        }
    }
}

/// An icon file ready to upload (name, type and bytes).
struct SettingsExternalLinkUpload: Sendable, Hashable {
    var fileName: String
    var mimeType: String
    var data: Data

    struct TooLarge: LocalizedError {
        var errorDescription: String? { "The image must be smaller than 1 MB." }
    }

    struct Unsupported: LocalizedError {
        var errorDescription: String? { "Choose a PNG, JPEG, GIF, SVG, WebP or ICO image." }
    }

    /// Accepts files the server allows as-is; bitmap formats it doesn't (HEIC, TIFF, …) and
    /// oversized bitmaps are converted to a PNG no larger than 256 pixels.
    static func make(data: Data, fileExtension: String?) throws -> SettingsExternalLinkUpload {
        var ext = (fileExtension ?? "").lowercased()
        if ext == "jpeg" { ext = "jpg" }
        if SettingsExternalLinkIcons.allowedExtensions.contains(ext), data.count <= SettingsExternalLinkIcons.maxUploadBytes {
            return SettingsExternalLinkUpload(fileName: "icon.\(ext)", mimeType: mimeType(for: ext), data: data)
        }
        if ext == "svg" || ext == "ico" || ext == "gif" { throw TooLarge() }
        guard let image = UIImage(data: data), let png = downscaledPNG(image, maxDimension: 256) else { throw Unsupported() }
        guard png.count <= SettingsExternalLinkIcons.maxUploadBytes else { throw TooLarge() }
        return SettingsExternalLinkUpload(fileName: "icon.png", mimeType: "image/png", data: png)
    }

    static func mimeType(for ext: String) -> String {
        switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "ico": "image/x-icon"
        default: "application/octet-stream"
        }
    }

    private static func downscaledPNG(_ image: UIImage, maxDimension: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
