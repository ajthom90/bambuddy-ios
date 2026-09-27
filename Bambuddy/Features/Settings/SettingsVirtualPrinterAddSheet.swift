import SwiftUI

/// Sheet for `POST /virtual-printers`, covering every field the create endpoint accepts.
struct SettingsVirtualPrinterAddSheet: View {
    let model: SettingsVirtualPrinterModel

    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var printerStore
    @Environment(\.dismiss) private var dismiss
    @State private var runner = ActionRunner()

    @State private var name = ""
    @State private var mode: SettingsVPMode = .archive
    @State private var modelCode = ""          // "" = server default
    @State private var accessCode = ""
    @State private var targetPrinterID: Int?
    @State private var bindIP = ""
    @State private var remoteIP = ""
    @State private var autoDispatch = true
    @State private var forceColorMatch = false
    @State private var saveAmsMapping = false
    @State private var gcodeInjection = false
    @State private var enableNow = false

    /// Non-proxy printers with a target inherit the target's access code on the server.
    private var needsOwnAccessCode: Bool { mode != .proxy && targetPrinterID == nil }

    private var problem: String? {
        if needsOwnAccessCode, let p = SettingsVPValidation.accessCodeProblem(accessCode) { return p }
        if mode == .proxy && targetPrinterID == nil { return "Choose the real printer to relay to." }
        if enableNow {
            return SettingsVPValidation.enableProblem(mode: mode, bindIp: bindIP, targetPrinterId: targetPrinterID,
                                                      hasAccessCode: !accessCode.isEmpty)
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Bambuddy"))
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the slicer's printer list.")
                }

                Section("Mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(SettingsVPMode.allCases) { m in
                            Text(m.title).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.summary).font(.footnote).foregroundStyle(.secondary)
                }

                Section {
                    Picker("Target Printer", selection: $targetPrinterID) {
                        Text(mode == .proxy ? "Choose…" : "None").tag(Int?.none)
                        ForEach(printerStore.printers) { p in
                            Text("\(p.name) (\(p.ipAddress))").tag(Int?.some(p.id))
                        }
                    }
                } footer: {
                    Text(mode == .proxy
                         ? "Required: the real printer the slicer is relayed to. Its model is used automatically."
                         : "Optional. When set, slicer connections are bridged to this printer and its access code is used.")
                }

                if mode != .proxy {
                    Section {
                        Picker("Printer Model", selection: $modelCode) {
                            Text("Default").tag("")
                            ForEach(model.sortedModels, id: \.code) { entry in
                                Text("\(entry.name) (\(entry.code))").tag(entry.code)
                            }
                        }
                    } footer: {
                        Text("The model the slicer sees. Default is \(defaultModelName).")
                    }
                }

                if needsOwnAccessCode {
                    Section {
                        SecureField("8 characters", text: $accessCode)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: accessCode) { _, v in if v.count > 8 { accessCode = String(v.prefix(8)) } }
                    } header: {
                        Text("Access Code")
                    } footer: {
                        Text(accessCode.isEmpty
                             ? "You can set it later, but it's required before the printer can be enabled."
                             : "\(accessCode.count) of 8 characters. Enter the same code in the slicer.")
                    }
                }

                if mode == .queue {
                    Section("Queue Options") {
                        Toggle(isOn: $autoDispatch) {
                            SettingsLabel("Dispatch Automatically", help: "Start queued prints on a matching idle printer without waiting for you.")
                        }
                        Toggle(isOn: $forceColorMatch) {
                            SettingsLabel("Require Exact Colors", help: "Only dispatch to printers whose loaded filament colors match the job.")
                        }
                        Toggle(isOn: $saveAmsMapping) {
                            SettingsLabel("Keep Slicer AMS Mapping", help: "Store the slot mapping chosen in the slicer with the queued job.")
                        }
                        Toggle(isOn: $gcodeInjection) {
                            SettingsLabel("Inject G-code Snippets", help: "Apply your configured G-code snippets to jobs queued from this printer.")
                        }
                    }
                }

                Section {
                    Picker("Bind Interface", selection: $bindIP) {
                        Text("Not Set").tag("")
                        ForEach(model.interfaces) { iface in Text(iface.menuLabel).tag(iface.ip) }
                    }
                    Picker("Remote Interface", selection: $remoteIP) {
                        Text("None").tag("")
                        ForEach(model.interfaces) { iface in Text(iface.menuLabel).tag(iface.ip) }
                    }
                } header: {
                    Text("Network")
                } footer: {
                    Text("Slicers connect to the bind interface's address; each enabled virtual printer needs its own. A remote interface is only needed when the slicer is on another network.")
                }

                Section {
                    Toggle("Enable Now", isOn: $enableNow)
                } footer: {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Text("You can finish setting it up and enable it later.")
                    }
                }
            }
            .navigationTitle("New Virtual Printer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if runner.isRunning {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }.disabled(problem != nil)
                    }
                }
            }
            .actionAlerts(runner)
            .task {
                if model.interfaces.isEmpty { await model.refreshInterfaces(client: session.client) }
                if printerStore.printers.isEmpty { await printerStore.refresh() }
            }
        }
    }

    private var defaultModelName: String {
        model.models["BL-P001"] ?? "the X1 Carbon"
    }

    private func create() async {
        let body = SettingsVirtualPrinterCreate.make(
            name: name, mode: mode, modelCode: modelCode, accessCode: accessCode, targetPrinterID: targetPrinterID,
            bindIP: bindIP, remoteIP: remoteIP, autoDispatch: autoDispatch, forceColorMatch: forceColorMatch,
            saveAmsMapping: saveAmsMapping, gcodeInjection: gcodeInjection, enabled: enableNow)
        await runner.run {
            let created: SettingsVirtualPrinter = try await session.client.send(.post, "virtual-printers", body: body)
            model.replace(created)
            await model.refreshList(client: session.client)
            dismiss()
        }
    }
}

extension SettingsVirtualPrinterCreate {
    /// Builds the create body from the sheet's inputs, leaving out fields that don't apply to the mode
    /// so the backend defaults (and target-printer inheritance) take effect.
    static func make(name: String, mode: SettingsVPMode, modelCode: String, accessCode: String, targetPrinterID: Int?,
                     bindIP: String, remoteIP: String, autoDispatch: Bool, forceColorMatch: Bool,
                     saveAmsMapping: Bool, gcodeInjection: Bool, enabled: Bool) -> SettingsVirtualPrinterCreate {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = SettingsVirtualPrinterCreate()
        body.name = trimmed.isEmpty ? "Bambuddy" : trimmed
        body.enabled = enabled
        body.mode = mode.rawValue
        if mode != .proxy, !modelCode.isEmpty { body.model = modelCode }
        if mode != .proxy, targetPrinterID == nil, !accessCode.isEmpty { body.accessCode = accessCode }
        body.targetPrinterId = targetPrinterID
        if mode == .queue {
            body.autoDispatch = autoDispatch
            body.queueForceColorMatch = forceColorMatch
            body.saveAmsMapping = saveAmsMapping
            body.gcodeInjection = gcodeInjection
        }
        if !bindIP.isEmpty { body.bindIp = bindIP }
        if !remoteIP.isEmpty { body.remoteInterfaceIp = remoteIP }
        return body
    }
}
