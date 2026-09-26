import SwiftUI

struct PrinterEditView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let printer: Printer?
    var onSave: () -> Void

    @State private var name = ""
    @State private var serial = ""
    @State private var ip = ""
    @State private var accessCode = ""
    @State private var model = "X1C"
    @State private var location = ""
    @State private var autoArchive = true
    @State private var isActive = true
    @State private var cameraRotation = 0
    @State private var externalCameraEnabled = false
    @State private var externalCameraURL = ""
    @State private var externalCameraType = "mjpeg"
    @State private var printHoursOffset: Double = 0
    @State private var runner = ActionRunner()
    @State private var testResult: String?
    @State private var showDiscovery = false

    static let models = ["X1C", "X1", "X1E", "P1S", "P1P", "P2S", "A1", "A1 Mini", "H2D", "H2S", "H2C"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Model", selection: $model) {
                        ForEach(Self.models + (Self.models.contains(model) ? [] : [model]), id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Location (optional)", text: $location)
                }
                Section {
                    TextField("IP Address", text: $ip).keyboardType(.numbersAndPunctuation).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Serial Number", text: $serial).autocorrectionDisabled().textInputAutocapitalization(.characters).disabled(printer != nil)
                    SecureField(printer == nil ? "Access Code" : "Access Code (unchanged)", text: $accessCode)
                    if printer == nil {
                        Button("Test Connection") { Task { await test() } }
                            .disabled(ip.isEmpty || serial.isEmpty || accessCode.isEmpty)
                        if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                        if session.can("discovery:scan") {
                            Button("Discover Printers on Network…") { showDiscovery = true }
                        }
                    }
                } header: { Text("Connection") } footer: {
                    Text("Find the access code on the printer's screen under Settings → Network (LAN mode).")
                }
                Section("Options") {
                    Toggle("Auto-Archive Prints", isOn: $autoArchive)
                    if printer != nil { Toggle("Active", isOn: $isActive) }
                    Picker("Camera Rotation", selection: $cameraRotation) {
                        ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                    }
                    if printer != nil {
                        HStack {
                            Text("Print Hours Offset")
                            Spacer()
                            TextField("0", value: $printHoursOffset, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                        }
                    }
                }
                if printer != nil {
                    Section("External Camera") {
                        Toggle("Use External Camera", isOn: $externalCameraEnabled)
                        if externalCameraEnabled {
                            Picker("Type", selection: $externalCameraType) {
                                Text("MJPEG").tag("mjpeg")
                                Text("RTSP").tag("rtsp")
                                Text("Snapshot").tag("snapshot")
                                Text("USB").tag("usb")
                            }
                            TextField("URL", text: $externalCameraURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                }
            }
            .navigationTitle(printer == nil ? "Add Printer" : "Edit Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.isEmpty || ip.isEmpty || serial.isEmpty || (printer == nil && accessCode.isEmpty) || runner.isRunning)
                }
            }
            .actionAlerts(runner)
            .sheet(isPresented: $showDiscovery) {
                DiscoveryView { found in
                    ip = found.ipAddress
                    serial = found.serialNumber ?? serial
                    if name.isEmpty { name = found.name ?? "" }
                    if let m = found.model { model = m }
                }
            }
            .onAppear(perform: populate)
        }
    }

    private func populate() {
        guard let printer else { return }
        name = printer.name
        serial = printer.serialNumber
        ip = printer.ipAddress
        model = printer.model ?? model
        location = printer.location ?? ""
        autoArchive = printer.autoArchive ?? true
        isActive = printer.isActive
        cameraRotation = printer.cameraRotation ?? 0
        externalCameraEnabled = printer.externalCameraEnabled ?? false
        externalCameraURL = printer.externalCameraUrl ?? ""
        externalCameraType = printer.externalCameraType ?? "mjpeg"
        printHoursOffset = printer.printHoursOffset ?? 0
    }

    private func test() async {
        testResult = "Testing…"
        do {
            let r: JSONValue = try await session.client.send(.post, "printers/test", query: ["ip_address": .string(ip), "serial_number": .string(serial), "access_code": .string(accessCode)])
            let ok = r["success"]?.boolValue ?? false
            testResult = ok ? "Connected successfully" + (r["model"]?.stringValue.map { " (\($0))" } ?? "") : (r["message"]?.stringValue ?? r["error"]?.stringValue ?? "Connection failed")
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func save() async {
        await runner.run {
            if let printer {
                struct Update: Encodable {
                    var name: String; var ipAddress: String; var accessCode: String?; var model: String; var location: String
                    var isActive: Bool; var autoArchive: Bool; var cameraRotation: Int; var printHoursOffset: Double
                    var externalCameraEnabled: Bool; var externalCameraUrl: String?; var externalCameraType: String?
                }
                let body = Update(name: name, ipAddress: ip, accessCode: accessCode.isEmpty ? nil : accessCode, model: model, location: location,
                                  isActive: isActive, autoArchive: autoArchive, cameraRotation: cameraRotation, printHoursOffset: printHoursOffset,
                                  externalCameraEnabled: externalCameraEnabled, externalCameraUrl: externalCameraURL.isEmpty ? nil : externalCameraURL,
                                  externalCameraType: externalCameraEnabled ? externalCameraType : nil)
                try await session.client.call(.patch, "printers/\(printer.id)", body: body)
            } else {
                let body = PrinterCreate(name: name, serialNumber: serial, ipAddress: ip, accessCode: accessCode, model: model,
                                         location: location.isEmpty ? nil : location, autoArchive: autoArchive)
                try await session.client.call(.post, "printers/", body: body)
            }
            onSave()
            dismiss()
        }
    }
}
