import SwiftUI

struct PrinterDetailView: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss
    let printerId: Int

    @State private var runner = ActionRunner()
    @State private var showCamera = true
    @State private var fullscreenCamera = false
    @State private var showEdit = false
    @State private var confirmStop = false
    @State private var confirmDelete = false
    @State private var showHMS = false

    private var printer: Printer? { store.printer(printerId) }
    private var status: PrinterStatus? { store.statuses[printerId] }
    private var client: APIClient { session.client }

    var body: some View {
        ScrollView {
            if let printer {
                let columns = hSize == .regular ? [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)] : [GridItem(.flexible())]
                VStack(spacing: 16) {
                    if session.can("camera:view"), showCamera {
                        PrinterCameraView(printerId: printerId, rotation: printer.cameraRotation ?? 0)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 16))
                            .overlay(alignment: .topTrailing) {
                                Button { fullscreenCamera = true } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right").padding(8)
                                }
                                .buttonStyle(.glass)
                                .padding(8)
                            }
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        jobCard(printer)
                        TemperaturesCard(printerId: printerId, status: status, runner: runner)
                        if let status, !(status.hmsErrors ?? []).isEmpty {
                            hmsCard(status)
                        }
                        AMSCard(printerId: printerId, status: status, runner: runner)
                        ControlsCard(printerId: printerId, status: status, runner: runner)
                        infoCard(printer)
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("Printer Not Found", systemImage: "printer")
            }
        }
        .navigationTitle(printer?.name ?? "Printer")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            try? await client.call(.post, "printers/\(printerId)/refresh-status")
            await store.refreshStatus(printerId)
        }
        .toolbar { toolbar }
        .actionAlerts(runner)
        .fullScreenCover(isPresented: $fullscreenCamera) {
            FullscreenCameraView(printerId: printerId, title: printer?.name ?? "", rotation: printer?.cameraRotation ?? 0)
        }
        .sheet(isPresented: $showEdit) {
            if let printer { PrinterEditView(printer: printer) { Task { await store.refresh() } } }
        }
        .sheet(isPresented: $showHMS) {
            if let status { HMSErrorsView(printerId: printerId, errors: status.hmsErrors ?? []) }
        }
        .confirm("Stop the current print?", isPresented: $confirmStop, message: "This cannot be undone.", action: "Stop Print") {
            Task { await runner.run("Print stopped") { try await client.call(.post, "printers/\(printerId)/print/stop") } }
        }
        .confirm("Delete \(printer?.name ?? "printer")?", isPresented: $confirmDelete, message: "Print archives are kept.") {
            Task {
                await runner.run {
                    try await client.call(.delete, "printers/\(printerId)", query: ["delete_archives": false])
                    await store.refresh()
                    dismiss()
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if session.can("camera:view") {
                    Toggle(isOn: $showCamera) { Label("Show Camera", systemImage: "video") }
                }
                NavigationLink { PrinterFilesView(printerId: printerId) } label: { Label("Printer Files", systemImage: "sdcard") }
                NavigationLink { PrinterMoreView(printerId: printerId) } label: { Label("More Tools", systemImage: "ellipsis.circle") }
                Divider()
                Button { Task { await runner.run("Status refreshed") { try await client.call(.post, "printers/\(printerId)/refresh-status") } } } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                if status?.connected == true {
                    Button { Task { await runner.run("Disconnected") { try await client.call(.post, "printers/\(printerId)/disconnect"); await store.refreshStatus(printerId) } } } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                } else {
                    Button { Task { await runner.run("Connecting…") { try await client.call(.post, "printers/\(printerId)/connect"); await store.refreshStatus(printerId) } } } label: {
                        Label("Connect", systemImage: "bolt")
                    }
                }
                if session.can("printers:update") {
                    Button { showEdit = true } label: { Label("Edit Printer", systemImage: "pencil") }
                }
                if session.can("printers:delete") {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Printer", systemImage: "trash") }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    @ViewBuilder
    private func jobCard(_ printer: Printer) -> some View {
        DetailCard(title: "Current Job", systemImage: "cube") {
            if let status, status.isActiveJob {
                HStack(alignment: .top, spacing: 12) {
                    RemoteImage(path: status.coverUrl, contentMode: .fit, reloadKey: status.gcodeFile, systemImage: "cube")
                        .frame(width: 96, height: 96)
                        .clipShape(.rect(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.jobName ?? "Printing").font(.headline).lineLimit(3)
                        HStack { PrinterStateBadge(status: status); if let stage = status.stgCurName, !stage.isEmpty { Text(stage).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                ProgressView(value: (status.progress ?? 0) / 100).tint(status.isPaused ? .orange : .accentColor)
                HStack {
                    VStack(alignment: .leading) { Text(Fmt.percent(status.progress)).font(.title3.bold()); Text("Progress").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    VStack { Text("\(status.layerNum ?? 0)/\(status.totalLayers ?? 0)").font(.title3.bold()); Text("Layer").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(Fmt.minutes(status.remainingTime)).font(.title3.bold())
                        Text(eta(status.remainingTime)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .monospacedDigit()
                if session.can("printers:control") {
                    HStack {
                        if status.isPaused {
                            Button { Task { await runner.run { try await client.call(.post, "printers/\(printerId)/print/resume") } } } label: {
                                Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button { Task { await runner.run { try await client.call(.post, "printers/\(printerId)/print/pause") } } } label: {
                                Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                        Button(role: .destructive) { confirmStop = true } label: {
                            Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    SpeedPicker(printerId: printerId, status: status, runner: runner)
                    if (status.printableObjectsCount ?? 0) > 1 {
                        NavigationLink { SkipObjectsView(printerId: printerId) } label: {
                            Label("Skip Objects…", systemImage: "square.slash")
                        }
                    }
                }
            } else {
                HStack {
                    Image(systemName: status?.connected == false ? "wifi.slash" : "checkmark.circle")
                        .font(.title2).foregroundStyle(status?.connected == false ? .red : .green)
                    VStack(alignment: .leading) {
                        Text(status?.connected == false ? "Offline" : (status?.state == "FINISH" ? "Last print finished" : status?.state == "FAILED" ? "Last print failed" : "Idle"))
                            .font(.headline)
                        if let name = status?.jobName, status?.state == "FINISH" || status?.state == "FAILED" {
                            Text(name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if status?.awaitingPlateClear == true, session.can("printers:clear_plate") {
                    Button { Task { await runner.run("Plate marked clear") { try await client.call(.post, "printers/\(printerId)/clear-plate") } } } label: {
                        Label("Mark Plate Cleared", systemImage: "checkmark.rectangle")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func eta(_ minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Remaining" }
        return "ETA " + Date().addingTimeInterval(Double(minutes) * 60).formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private func hmsCard(_ status: PrinterStatus) -> some View {
        DetailCard(title: "Errors & Warnings", systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            ForEach(Array((status.hmsErrors ?? []).prefix(3).enumerated()), id: \.offset) { _, error in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { StatusBadge(text: error.severityLabel, color: error.severity <= 2 ? .red : .orange); Text(error.fullCode ?? error.code).font(.caption.monospaced()) }
                    Text(error.description ?? "Unknown error").font(.subheadline)
                }
            }
            HStack {
                Button("Details") { showHMS = true }
                Spacer()
                if session.can("printers:control") {
                    Button("Clear") { Task { await runner.run("Errors cleared") { try await client.call(.post, "printers/\(printerId)/hms/clear") } } }
                }
            }
        }
    }

    @ViewBuilder
    private func infoCard(_ printer: Printer) -> some View {
        DetailCard(title: "Printer", systemImage: "info.circle") {
            InfoRow("Model", printer.model)
            InfoRow("Serial", printer.serialNumber)
            InfoRow("IP Address", printer.ipAddress)
            InfoRow("Location", printer.location)
            InfoRow("Firmware", status?.firmwareVersion)
            if let wifi = status?.wifiSignal { InfoRow("Wi-Fi", "\(wifi) dBm") }
            if status?.wiredNetwork == true { InfoRow("Network", "Ethernet") }
            if let nozzles = status?.nozzles?.filter({ !($0.nozzleDiameter ?? "").isEmpty }), !nozzles.isEmpty {
                InfoRow("Nozzle", nozzles.map { "\($0.nozzleDiameter ?? "") mm \(($0.nozzleType ?? "").replacingOccurrences(of: "_", with: " "))" }.joined(separator: ", "))
            }
            InfoRow("SD Card", status?.sdcard == true ? "Inserted" : "None")
            if let door = status?.doorOpen { InfoRow("Door", door ? "Open" : "Closed") }
            InfoRow("Auto-Archive", printer.autoArchive == true ? "On" : "Off")
        }
    }
}

/// Rounded card container used on detail screens.
struct DetailCard<Content: View>: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let systemImage {
                Label(title, systemImage: systemImage).font(.headline).foregroundStyle(tint == .accentColor ? .primary : tint)
            } else {
                Text(title).font(.headline)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }
}

struct SpeedPicker: View {
    @Environment(AppSession.self) private var session
    let printerId: Int
    let status: PrinterStatus
    let runner: ActionRunner

    var body: some View {
        Picker("Speed", selection: Binding(
            get: { status.speedLevel ?? 2 },
            set: { mode in Task { await runner.run { try await session.client.call(.post, "printers/\(printerId)/print-speed", query: ["mode": .int(mode)]) } } }
        )) {
            ForEach(PrinterStatus.speedLevels, id: \.0) { level in Text(level.1).tag(level.0) }
        }
        .pickerStyle(.segmented)
    }
}

struct HMSErrorsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    let errors: [HMSError]
    @State private var runner = ActionRunner()

    var body: some View {
        NavigationStack {
            List(Array(errors.enumerated()), id: \.offset) { _, error in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        StatusBadge(text: error.severityLabel, color: error.severity <= 2 ? .red : .orange)
                        Text(error.fullCode ?? error.code).font(.caption.monospaced())
                        Spacer()
                        if let url = URL(string: "https://wiki.bambulab.com/en/x1/troubleshooting/hmscode/\((error.fullCode ?? error.code).replacingOccurrences(of: "-", with: "_"))") {
                            Link(destination: url) { Image(systemName: "safari") }
                        }
                    }
                    Text(error.description ?? "Unknown error")
                    if let actions = error.actions, !actions.isEmpty, session.can("printers:control") {
                        HStack {
                            ForEach(actions, id: \.self) { action in
                                Button(action.replacingOccurrences(of: "_", with: " ").capitalized) {
                                    Task {
                                        await runner.run("Sent") {
                                            struct Body: Encodable { var action: String; var printError: String; var jobId: String? }
                                            let code = error.fullCode ?? error.code.replacingOccurrences(of: "_", with: "")
                                            try await session.client.call(.post, "printers/\(printerId)/hms/execute-action", body: Body(action: action, printError: code, jobId: error.jobId))
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .navigationTitle("HMS Errors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if session.can("printers:control") {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear All") { Task { await runner.run { try await session.client.call(.post, "printers/\(printerId)/hms/clear"); dismiss() } } }
                    }
                }
            }
            .actionAlerts(runner)
        }
    }
}

struct FullscreenCameraView: View {
    @Environment(\.dismiss) private var dismiss
    let printerId: Int
    let title: String
    var rotation: Int = 0
    var body: some View {
        NavigationStack {
            PrinterCameraView(printerId: printerId, rotation: rotation, fps: 15)
                .ignoresSafeArea()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}
