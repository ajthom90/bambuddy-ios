import SwiftUI

/// Per-printer external camera configuration plus the web interface's camera view default.
struct SettingsCamerasView: View {
    @Environment(ServerSettingsStore.self) private var store
    @Environment(PrinterStore.self) private var printers
    @Environment(AppSession.self) private var session
    @State private var ffmpeg: SettingsGeneralFfmpegStatus?

    var body: some View {
        List {
            Section {
                if printers.printers.isEmpty {
                    if printers.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("No printers have been added yet.").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("External Cameras")
            } footer: {
                Text("An external camera replaces a printer's built-in camera for live view, finish photos, timelapses and plate detection. MJPEG streams, RTSP, HTTP snapshots and USB cameras attached to the server are supported.")
            }

            ForEach(printers.printers) { printer in
                CameraPrinterSection(printer: printer)
            }

            Section {
                SettingsPicker("Web Camera View", key: "camera_view_mode", choices: [
                    ("window", "Separate Window"),
                    ("embedded", "Embedded Overlay"),
                ])
                if let ffmpeg {
                    LabeledContent {
                        if ffmpeg.installed == true {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("Not Found", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    } label: {
                        SettingsLabel("ffmpeg", help: ffmpeg.installed == true ? ffmpeg.path : "Needed on the server for RTSP cameras and camera snapshots.")
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("The camera view setting is the default for new browser sessions of the web interface.")
            }
        }
        .navigationTitle("Cameras")
        .refreshable { await reload() }
        .task { await reload() }
        .alert("Couldn't Save", isPresented: Binding(get: { store.saveError != nil }, set: { if !$0 { store.saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.saveError ?? "") }
    }

    private func reload() async {
        let client = session.client
        let printerStore = printers, settings = store
        async let status: SettingsGeneralFfmpegStatus? = try? client.get("settings/check-ffmpeg")
        await printerStore.refresh()
        if !settings.hasLoaded { await settings.load() }
        ffmpeg = await status
    }
}

/// Builds `PATCH /printers/{id}` bodies that touch only camera fields. Values are sent as
/// explicit JSON so cleared URLs/types become `null` (a Codable struct would omit them).
enum SettingsCameraPatch {
    static let types = ["mjpeg", "rtsp", "snapshot", "usb"]

    static func enabled(_ value: Bool) -> JSONValue { ["external_camera_enabled": .bool(value)] }
    static func type(_ value: String) -> JSONValue { ["external_camera_type": value.isEmpty ? .null : .string(value)] }
    static func rotation(_ value: Int) -> JSONValue { ["camera_rotation": .number(Double(value))] }
    static func url(_ value: String) -> JSONValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["external_camera_url": trimmed.isEmpty ? .null : .string(trimmed)]
    }
    static func snapshotURL(_ value: String) -> JSONValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["external_camera_snapshot_url": trimmed.isEmpty ? .null : .string(trimmed)]
    }

    /// Snapshot URLs are only meaningful for streaming camera types.
    static func supportsSnapshotURL(_ type: String) -> Bool { ["mjpeg", "rtsp", "usb"].contains(type) }
}

/// `POST /printers/{id}/camera/external/test`
struct SettingsCameraTestResult: Codable, Sendable, Hashable {
    var success: Bool?
    var error: String?
    var resolution: String?
    /// True when the frame came from a capture that was already running rather than a fresh connection.
    var coalesced: Bool?
}

private struct CameraPrinterSection: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printers
    let printer: Printer

    @State private var enabled = false
    @State private var type = "mjpeg"
    @State private var rotation = 0
    @State private var url = ""
    @State private var snapshotURL = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var testing: String?
    @State private var testResult: (kind: String, result: SettingsCameraTestResult)?
    @FocusState private var focus: Field?

    private enum Field: Hashable { case url, snapshot }

    private var canEdit: Bool { session.can("printers:update") }
    private var canTest: Bool { session.can("camera:view") }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { enabled }, set: { value in
                enabled = value
                patch(SettingsCameraPatch.enabled(value))
            })) {
                HStack {
                    Text("Use External Camera")
                    if saving { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(!canEdit)
            // Row-level (not Section-level) so these run once per printer.
            .onAppear(perform: sync)
            .onChange(of: printer) { _, _ in sync() }
            .onChange(of: focus) { old, new in
                if old == .url, new != .url { commitURL() }
                if old == .snapshot, new != .snapshot { commitSnapshot() }
            }

            if enabled {
                Picker("Type", selection: Binding(get: { type }, set: { value in
                    type = value
                    testResult = nil
                    patch(SettingsCameraPatch.type(value))
                })) {
                    Text("MJPEG Stream").tag("mjpeg")
                    Text("RTSP").tag("rtsp")
                    Text("HTTP Snapshot").tag("snapshot")
                    Text("USB (on Server)").tag("usb")
                    if !SettingsCameraPatch.types.contains(type) { Text(type).tag(type) }
                }
                .disabled(!canEdit)

                urlField(title: type == "usb" ? "Device" : "URL",
                         prompt: type == "usb" ? "/dev/video0" : placeholder(for: type),
                         text: $url, field: .url, kind: "stream")

                if SettingsCameraPatch.supportsSnapshotURL(type) {
                    urlField(title: "Snapshot URL", prompt: "Optional", text: $snapshotURL, field: .snapshot, kind: "snapshot")
                }

                Picker("Rotation", selection: Binding(get: { rotation }, set: { value in
                    rotation = value
                    patch(SettingsCameraPatch.rotation(value))
                })) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                .disabled(!canEdit)
            }

            if let errorMessage {
                SettingsTestResultLabel(success: false, message: errorMessage)
            }
        } header: {
            Text(printer.name)
        } footer: {
            if enabled && SettingsCameraPatch.supportsSnapshotURL(type) {
                Text("The snapshot URL, if set, provides single frames for notifications, finish photos, timelapses and plate detection instead of grabbing them from the stream (for example go2rtc's /api/frame.jpeg).")
            }
        }
    }

    @ViewBuilder
    private func urlField(title: String, prompt: String, text: Binding<String>, field: Field, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            HStack(spacing: 8) {
                TextField(prompt, text: text)
                    .keyboardType(field == .url && type == "usb" ? .default : .URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: field)
                    .submitLabel(.done)
                    .onSubmit { field == .url ? commitURL() : commitSnapshot() }
                    .padding(8)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 8))
                    .disabled(!canEdit)
                if canTest {
                    Button {
                        Task { await test(kind: kind) }
                    } label: {
                        if testing == kind { ProgressView().controlSize(.small) } else { Text("Test") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(testing != nil || text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let testResult, testResult.kind == kind {
                SettingsTestResultLabel(success: testResult.result.success == true, message: message(for: testResult.result))
            }
        }
        .padding(.vertical, 2)
    }

    private func placeholder(for type: String) -> String {
        switch type {
        case "rtsp": "rtsp://192.168.1.50:554/stream"
        case "snapshot": "http://192.168.1.50/snapshot.jpg"
        default: "http://192.168.1.50:8080/stream"
        }
    }

    private func message(for result: SettingsCameraTestResult) -> String {
        if result.success == true {
            var text = "Camera reachable"
            if let res = result.resolution, !res.isEmpty { text += " (\(res))" }
            if result.coalesced == true { text += " – frame taken from a capture already in progress" }
            return text
        }
        return result.error ?? "Couldn't reach the camera"
    }

    private func sync() {
        enabled = printer.externalCameraEnabled ?? false
        type = (printer.externalCameraType?.isEmpty == false ? printer.externalCameraType : nil) ?? "mjpeg"
        rotation = printer.cameraRotation ?? 0
        if focus != .url { url = printer.externalCameraUrl ?? "" }
        if focus != .snapshot { snapshotURL = printer.externalCameraSnapshotUrl ?? "" }
    }

    private func commitURL() {
        guard url.trimmingCharacters(in: .whitespacesAndNewlines) != (printer.externalCameraUrl ?? "") else { return }
        testResult = nil
        patch(SettingsCameraPatch.url(url))
    }

    private func commitSnapshot() {
        guard snapshotURL.trimmingCharacters(in: .whitespacesAndNewlines) != (printer.externalCameraSnapshotUrl ?? "") else { return }
        testResult = nil
        patch(SettingsCameraPatch.snapshotURL(snapshotURL))
    }

    private func patch(_ body: JSONValue) {
        guard canEdit else { return }
        Task {
            saving = true
            defer { saving = false }
            do {
                try await session.client.call(.patch, "printers/\(printer.id)", body: body)
                errorMessage = nil
                await printers.refresh()
            } catch {
                errorMessage = error.localizedDescription
                sync()
            }
        }
    }

    private func test(kind: String) async {
        let target = (kind == "snapshot" ? snapshotURL : url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }
        testing = kind
        defer { testing = nil }
        do {
            let result: SettingsCameraTestResult = try await session.client.send(
                .post, "printers/\(printer.id)/camera/external/test",
                query: ["url": .string(target), "camera_type": .string(kind == "snapshot" ? "snapshot" : type)])
            testResult = (kind, result)
        } catch {
            testResult = (kind, SettingsCameraTestResult(success: false, error: error.localizedDescription))
        }
    }
}
