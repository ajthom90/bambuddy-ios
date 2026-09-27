import SwiftUI

// MARK: Models

struct PrinterPlateROI: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let `default` = PrinterPlateROI(x: 0.15, y: 0.35, w: 0.70, h: 0.55)
}

struct PrinterPlateCheck: Codable, Sendable, Hashable {
    var isEmpty: Bool
    var confidence: Double?
    var differencePercent: Double?
    var message: String?
    var hasDebugImage: Bool?
    var needsCalibration: Bool?
    var lightWarning: Bool?
    var referenceCount: Int?
    var maxReferences: Int?
    var roi: PrinterPlateROI?
    var debugImageUrl: String?

    var debugImage: UIImage? {
        guard let s = debugImageUrl, let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else { return nil }
        return UIImage(data: data)
    }
}

struct PrinterPlateStatus: Codable, Sendable, Hashable {
    var available: Bool?
    var calibrated: Bool?
    var referenceCount: Int?
    var maxReferences: Int?
    var message: String?
    var chamberLight: Bool?
}

struct PrinterPlateReferences: Codable, Sendable, Hashable {
    var references: [PrinterPlateReference]
    var maxReferences: Int?
}

struct PrinterPlateReference: Codable, Sendable, Hashable, Identifiable {
    var index: Int
    var label: String?
    var timestamp: String?
    var hasImage: Bool?
    var thumbnailUrl: String?

    var id: Int { index }
}

struct PrinterPlateCalibrateResult: Codable, Sendable, Hashable {
    var success: Bool
    var message: String?
    var index: Int?
}

// MARK: View

/// Camera-based "is the build plate empty?" detection: status, references and region of interest.
struct PrinterPlateDetectionView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    let printerId: Int

    @State private var status: PrinterPlateStatus?
    @State private var references: PrinterPlateReferences?
    @State private var check: PrinterPlateCheck?
    @State private var checking = false
    @State private var checkError: String?
    @State private var runner = ActionRunner()
    @State private var roi: PrinterPlateROI = .default
    @State private var roiDirty = false
    @State private var editingRef: PrinterPlateReference?
    @State private var labelDraft = ""
    @State private var newLabel = ""
    @State private var showCalibrate = false
    @State private var confirmClear = false
    @State private var refreshKey = 0

    private var client: APIClient { session.client }
    private var printer: Printer? { store.printer(printerId) }
    private var printerStatus: PrinterStatus? { store.statuses[printerId] }
    private var canUpdate: Bool { session.can("printers:update") }
    private var canCamera: Bool { session.can("camera:view") }
    private var maxRefs: Int { references?.maxReferences ?? status?.maxReferences ?? 5 }
    private var refCount: Int { references?.references.count ?? status?.referenceCount ?? 0 }

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding(get: { printer?.plateDetectionEnabled ?? false }, set: { on in Task { await setEnabled(on) } })) {
                    VStack(alignment: .leading) {
                        Text("Check Plate Before Printing")
                        Text("Queued prints wait until the camera sees an empty plate.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!canUpdate || runner.isRunning)
                if let status {
                    if status.available == false {
                        Label(status.message ?? "Plate detection isn't available on this server.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        InfoRow("Calibration", status.calibrated == true ? "\(refCount) of \(maxRefs) references" : "Not calibrated")
                    }
                }
                if printerStatus?.chamberLight == false {
                    HStack {
                        Label("The chamber light is off; detection works best with it on.", systemImage: "lightbulb.slash")
                            .font(.footnote).foregroundStyle(.orange)
                        Spacer()
                        if session.can("printers:control") {
                            Button("Turn On") {
                                Task { await runner.run { try await client.call(.post, "printers/\(printerId)/chamber-light", query: ["on": true]) } }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section {
                if checking {
                    HStack { ProgressView(); Text("Checking the plate…") }
                } else if let check {
                    Label(check.needsCalibration == true ? "Calibration required" : (check.isEmpty ? "Plate is empty" : "Objects detected"),
                          systemImage: check.needsCalibration == true ? "questionmark.circle" : (check.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(check.needsCalibration == true ? .secondary : (check.isEmpty ? Color.green : Color.orange))
                        .font(.headline)
                    if check.needsCalibration != true {
                        HStack {
                            if let c = check.confidence { Text("Confidence \(Fmt.percent(c * 100))") }
                            Spacer()
                            if let d = check.differencePercent { Text("Difference \(Fmt.number(d))%") }
                        }
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let msg = check.message { Text(msg).font(.footnote).foregroundStyle(.secondary) }
                    if check.lightWarning == true { Label("Lighting looks too dark for a reliable result.", systemImage: "lightbulb").font(.footnote).foregroundStyle(.orange) }
                    if let img = check.debugImage {
                        Image(uiImage: img).resizable().scaledToFit().clipShape(.rect(cornerRadius: 10))
                    }
                } else if let checkError {
                    Label(checkError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Button { Task { await runCheck() } } label: { Label("Check Plate Now", systemImage: "camera.viewfinder") }
                    .disabled(checking || !canCamera)
            } header: {
                Text("Current Plate")
            }

            Section {
                if let refs = references?.references, !refs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(refs) { ref in referenceTile(ref) }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Text("No references yet. With an empty plate installed, add a reference so the camera knows what “empty” looks like.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if canCamera {
                    Button { newLabel = ""; showCalibrate = true } label: {
                        Label(refCount == 0 ? "Calibrate Empty Plate" : "Add Reference (\(refCount)/\(maxRefs))", systemImage: "plus.viewfinder")
                    }
                    if refCount > 0 {
                        Button("Remove All References", role: .destructive) { confirmClear = true }
                    }
                }
            } header: {
                Text("References")
            } footer: {
                Text("Keep a reference for each build plate you use. When full, the oldest reference is replaced.")
            }

            if canUpdate {
                Section {
                    roiSlider("Left", value: $roi.x, range: 0...0.9)
                    roiSlider("Top", value: $roi.y, range: 0...0.9)
                    roiSlider("Width", value: $roi.w, range: 0.1...1)
                    roiSlider("Height", value: $roi.h, range: 0.1...1)
                    HStack {
                        Button("Reset") { roi = .default; roiDirty = true }
                        Spacer()
                        Button("Save Region") { Task { await saveROI() } }.disabled(!roiDirty || runner.isRunning)
                    }
                } header: {
                    Text("Detection Region")
                } footer: {
                    Text("Only this part of the camera image is compared (fractions of the frame).")
                }
            }
        }
        .navigationTitle("Plate Detection")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .actionAlerts(runner)
        .alert("Add Reference", isPresented: $showCalibrate) {
            TextField("Label (e.g. Textured PEI)", text: $newLabel)
            Button("Capture") { Task { await calibrate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Make sure the plate is empty. The current camera image becomes a reference.")
        }
        .alert("Rename Reference", isPresented: Binding(get: { editingRef != nil }, set: { if !$0 { editingRef = nil } })) {
            TextField("Label", text: $labelDraft)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirm("Remove all plate references?", isPresented: $confirmClear, message: "Detection needs to be calibrated again afterwards.", action: "Remove All") {
            Task {
                await runner.run("References removed") {
                    try await client.call(.delete, "printers/\(printerId)/camera/plate-detection/calibrate")
                    await load()
                }
            }
        }
    }

    @ViewBuilder
    private func referenceTile(_ ref: PrinterPlateReference) -> some View {
        VStack(spacing: 4) {
            RemoteImage(path: ref.thumbnailUrl ?? "printers/\(printerId)/camera/plate-detection/references/\(ref.index)/thumbnail",
                        contentMode: .fill, reloadKey: "\(ref.timestamp ?? "")-\(refreshKey)", systemImage: "photo")
                .frame(width: 120, height: 80)
                .clipShape(.rect(cornerRadius: 8))
            Text(ref.label?.isEmpty == false ? ref.label! : "Reference \(ref.index + 1)").font(.caption).lineLimit(1)
            if let t = ref.timestamp { Text(Fmt.date(t, style: .dateTime.month().day())).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(width: 120)
        .contextMenu {
            if canCamera {
                Button { labelDraft = ref.label ?? ""; editingRef = ref } label: { Label("Rename", systemImage: "pencil") }
                Button(role: .destructive) {
                    Task {
                        await runner.run("Reference deleted") {
                            try await client.call(.delete, "printers/\(printerId)/camera/plate-detection/references/\(ref.index)")
                            await load()
                        }
                    }
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private func roiSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 56, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; roiDirty = true }), in: range, step: 0.01)
            Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospacedDigit()).frame(width: 36)
        }
    }

    // MARK: Networking

    private func load() async {
        status = try? await client.get("printers/\(printerId)/camera/plate-detection/status")
        references = try? await client.get("printers/\(printerId)/camera/plate-detection/references")
        refreshKey += 1
        if check == nil { await runCheck() }
    }

    private func runCheck() async {
        guard canCamera else { return }
        checking = true
        defer { checking = false }
        do {
            var req = client.makeRequest(.get, "printers/\(printerId)/camera/check-plate", query: ["include_debug_image": true])
            req.timeoutInterval = 45
            let result: PrinterPlateCheck = try await client.perform(req)
            check = result
            checkError = nil
            if let r = result.roi, !roiDirty { roi = r }
        } catch {
            checkError = error.localizedDescription
        }
    }

    private func setEnabled(_ on: Bool) async {
        struct Body: Encodable { var plateDetectionEnabled: Bool }
        await runner.run(on ? "Plate check enabled" : "Plate check disabled") {
            try await client.call(.patch, "printers/\(printerId)", body: Body(plateDetectionEnabled: on))
            await store.refresh()
        }
    }

    private func saveROI() async {
        struct Body: Encodable { var plateDetectionRoi: PrinterPlateROI }
        await runner.run("Region saved") {
            try await client.call(.patch, "printers/\(printerId)", body: Body(plateDetectionRoi: roi))
            roiDirty = false
            await runCheck()
        }
    }

    private func calibrate() async {
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        await runner.run {
            var req = client.makeRequest(.post, "printers/\(printerId)/camera/plate-detection/calibrate", query: ["label": label.isEmpty ? nil : .string(label)])
            req.timeoutInterval = 45
            let result: PrinterPlateCalibrateResult = try await client.perform(req)
            if !result.success { throw APIError(status: 0, message: result.message ?? "Calibration failed", code: nil, detail: nil) }
            runner.successMessage = result.message ?? "Reference added"
            check = nil
            await load()
        }
    }

    private func rename() async {
        guard let ref = editingRef else { return }
        editingRef = nil
        await runner.run {
            try await client.call(.put, "printers/\(printerId)/camera/plate-detection/references/\(ref.index)", query: ["label": .string(labelDraft)])
            references = try? await client.get("printers/\(printerId)/camera/plate-detection/references")
        }
    }
}
