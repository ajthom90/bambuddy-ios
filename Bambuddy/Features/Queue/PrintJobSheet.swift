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
/// Owned by the Queue feature. Presents its own `NavigationStack`.
struct PrintJobSheet: View {
    enum Mode: Hashable, Sendable { case printNow, addToQueue }

    let source: PrintSource
    var mode: Mode = .printNow
    var onComplete: (() -> Void)? = nil

    var body: some View {
        QueueJobForm(source: source, context: .create(mode), onComplete: onComplete)
    }
}

extension PrintSource {
    var queueArchiveId: Int? { if case .archive(let id, _) = self { id } else { nil } }
    var queueLibraryFileId: Int? { if case .libraryFile(let id, _) = self { id } else { nil } }

    /// API path prefix of the source (`archives/12` or `library/files/7`).
    var queueAPIPath: String {
        switch self {
        case .archive(let id, _): "archives/\(id)"
        case .libraryFile(let id, _): "library/files/\(id)"
        }
    }
}

/// Whether the job form creates new queue items or edits an existing one.
enum QueueJobContext: Hashable, Sendable {
    case create(PrintJobSheet.Mode)
    case edit(QueueItem)
}

/// Per-slot filament override used for model-based ("any P1S") assignment.
struct QueueFilamentOverride: Hashable, Sendable {
    var type: String
    var color: String
    var forceColorMatch: Bool
}

/// All user choices in the print / queue form, plus the request bodies built from them.
struct QueueJobDraft: Hashable, Sendable {
    enum Assignment: String, Hashable, Sendable { case printer, model }
    enum Schedule: String, Hashable, Sendable, CaseIterable { case asap, queue, scheduled }

    var assignment: Assignment = .printer
    var printerIds: [Int] = []
    var targetModel: String?
    var targetLocation: String?
    var plateIds: [Int] = []
    var quantity = 1
    var plateQuantities: [Int: Int] = [:]

    var bedLevelling = "auto"
    var flowCali = "auto"
    var nozzleOffsetCali = "auto"
    var vibrationCali = true
    var layerInspect = false
    var timelapse = false
    var useAms = true
    var preheatOverride = "inherit"
    var preheatChamberTarget: Int?

    var schedule: Schedule = .asap
    var scheduledDate = Date().addingTimeInterval(3600)
    var manualStart = false
    var requirePreviousSuccess = false
    var autoOffAfter = false
    var gcodeInjection = false
    var staggerEnabled = false
    var staggerGroupSize = 2
    var staggerIntervalMinutes = 5

    var costCenterId: Int?
    var estimatedCost: Double?
    var overrides: [Int: QueueFilamentOverride] = [:]

    var singlePlateId: Int? { plateIds.count == 1 ? plateIds[0] : nil }

    static func isoString(_ date: Date) -> String { date.formatted(.iso8601) }

    /// Fields shared by create and update requests.
    func commonFields(plateId: Int?, amsMapping: [Int]?, printerId: Int?) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "require_previous_success": .bool(requirePreviousSuccess),
            "auto_off_after": .bool(autoOffAfter),
            "gcode_injection": .bool(gcodeInjection),
            "manual_start": .bool(schedule == .queue && manualStart),
            "bed_levelling": .string(bedLevelling),
            "flow_cali": .string(flowCali),
            "vibration_cali": .bool(vibrationCali),
            "layer_inspect": .bool(layerInspect),
            "timelapse": .bool(timelapse),
            "use_ams": .bool(useAms),
            "nozzle_offset_cali": .string(nozzleOffsetCali),
            "preheat_override": .string(preheatOverride),
            "preheat_chamber_target_override": preheatOverride == "off" ? .null : (preheatChamberTarget.map { .number(Double($0)) } ?? .null),
            "plate_id": plateId.map { .number(Double($0)) } ?? .null,
        ]
        if assignment == .printer {
            body["printer_id"] = printerId.map { .number(Double($0)) } ?? .null
            body["target_model"] = .null
            body["target_location"] = .null
            if let amsMapping { body["ams_mapping"] = .array(amsMapping.map { .number(Double($0)) }) }
        } else {
            body["printer_id"] = .null
            body["target_model"] = targetModel.map { .string($0) } ?? .null
            body["target_location"] = targetLocation.map { .string($0) } ?? .null
        }
        if let costCenterId {
            body["cost_center_id"] = .number(Double(costCenterId))
            if let estimatedCost { body["estimated_cost"] = .number(estimatedCost) }
        }
        return body
    }

    /// Model-mode filament overrides for the given requirement slots.
    func overridesPayload(for requirements: [QueueFilamentRequirement]) -> JSONValue? {
        var entries: [JSONValue] = []
        let validSlots = Set(requirements.compactMap(\.slotId))
        for slot in overrides.keys.sorted() where requirements.isEmpty || validSlots.contains(slot) {
            guard let o = overrides[slot] else { continue }
            entries.append([
                "slot_id": .number(Double(slot)),
                "type": .string(o.type),
                "color": .string(o.color),
                "force_color_match": .bool(o.forceColorMatch),
            ])
        }
        return entries.isEmpty ? nil : .array(entries)
    }

    /// Body for `POST queue/`.
    func createBody(
        source: PrintSource, printerId: Int?, plateId: Int?, amsMapping: [Int]?,
        requirements: [QueueFilamentRequirement], quantity: Int, batchId: Int?,
        insertPosition: Int?, scheduledOverride: Date?
    ) -> JSONValue {
        var body = commonFields(plateId: plateId, amsMapping: amsMapping, printerId: printerId)
        if let id = source.queueArchiveId { body["archive_id"] = .number(Double(id)) }
        if let id = source.queueLibraryFileId { body["library_file_id"] = .number(Double(id)) }
        if assignment == .model, let o = overridesPayload(for: requirements) { body["filament_overrides"] = o }
        if quantity > 1 { body["quantity"] = .number(Double(quantity)) }
        if let batchId { body["batch_id"] = .number(Double(batchId)) }
        if schedule == .asap, let insertPosition {
            body["insert_at_top"] = true
            body["insert_position"] = .number(Double(insertPosition))
        }
        if let scheduledOverride {
            body["scheduled_time"] = .string(Self.isoString(scheduledOverride))
        } else if schedule == .scheduled {
            body["scheduled_time"] = .string(Self.isoString(scheduledDate))
        }
        return .object(body)
    }

    /// Body for `PATCH queue/{id}`.
    func updateBody(printerId: Int?, plateId: Int?, amsMapping: [Int]?, requirements: [QueueFilamentRequirement]) -> JSONValue {
        var body = commonFields(plateId: plateId, amsMapping: amsMapping, printerId: printerId)
        body["scheduled_time"] = schedule == .scheduled ? .string(Self.isoString(scheduledDate)) : .null
        if assignment == .printer {
            body["ams_mapping"] = amsMapping.map { .array($0.map { .number(Double($0)) }) } ?? .null
        } else {
            body["filament_overrides"] = overridesPayload(for: requirements) ?? .null
        }
        return .object(body)
    }

    /// Seeds the draft from an existing queue item.
    init(item: QueueItem) {
        if let p = item.printerId { printerIds = [p] }
        if item.printerId == nil, let model = item.targetModel, !model.isEmpty {
            assignment = .model
            targetModel = model
            targetLocation = item.targetLocation
        }
        if let plate = item.plateId { plateIds = [plate] }
        bedLevelling = item.bedLevelling ?? "auto"
        flowCali = item.flowCali ?? "auto"
        nozzleOffsetCali = item.nozzleOffsetCali ?? "auto"
        vibrationCali = item.vibrationCali ?? true
        layerInspect = item.layerInspect ?? false
        timelapse = item.timelapse ?? false
        useAms = item.useAms ?? true
        preheatOverride = item.preheatOverride ?? "inherit"
        preheatChamberTarget = item.preheatChamberTargetOverride
        if item.hasRealSchedule, let d = item.scheduledDate {
            schedule = .scheduled
            scheduledDate = d
        } else {
            schedule = .queue
        }
        manualStart = item.manualStart ?? false
        requirePreviousSuccess = item.requirePreviousSuccess ?? false
        autoOffAfter = item.autoOffAfter ?? false
        gcodeInjection = item.gcodeInjection ?? false
        costCenterId = item.costCenterId
        estimatedCost = item.estimatedCost
        for raw in item.filamentOverrides ?? [] {
            guard let slot = raw["slot_id"]?.intValue else { continue }
            overrides[slot] = QueueFilamentOverride(
                type: raw["type"]?.stringValue ?? "",
                color: raw["color"]?.stringValue ?? "",
                forceColorMatch: raw["force_color_match"]?.boolValue ?? false
            )
        }
    }

    init() {}
}

/// A printer's live status plus the AMS → extruder map (dual-nozzle printers), fetched fresh.
struct QueuePrinterSnapshot: Sendable {
    var status: PrinterStatus
    var extruderMap: [String: Int]
    var trays: [QueueLoadedTray] { QueueAMSMatcher.loadedTrays(status, extruderMap: extruderMap) }

    var isDispatchable: Bool {
        guard status.connected, status.awaitingPlateClear != true else { return false }
        return ["IDLE", "FINISH", "FAILED"].contains(status.state ?? "")
    }
}

// MARK: - Form

struct QueueJobForm: View {
    @Environment(AppSession.self) private var session
    @Environment(PrinterStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let source: PrintSource
    let context: QueueJobContext
    var onComplete: (() -> Void)?

    @State private var draft: QueueJobDraft
    @State private var settings: JSONValue?
    @State private var sourceInfo: JSONValue?
    @State private var plates: QueuePlatesResponse?
    @State private var platesError: String?
    @State private var requirements: [QueueFilamentRequirement] = []
    @State private var requirementsLoaded = false
    @State private var snapshots: [Int: QueuePrinterSnapshot] = [:]
    @State private var loadingSnapshots = false
    @State private var manual: [Int: Int] = [:]
    @State private var useSlicerMapping = false
    @State private var availableFilaments: [QueueAvailableFilament] = []
    @State private var costCenters: [JSONValue] = []
    @State private var isSubmitting = false
    @State private var progress: (Int, Int) = (0, 0)
    @State private var showMismatchConfirm = false
    @State private var showPipelineRun = false
    @State private var runner = ActionRunner()
    @State private var initialPrinterIds: [Int] = []
    @State private var initialPlateId: Int?
    @State private var defaultsApplied = false

    init(source: PrintSource, context: QueueJobContext, onComplete: (() -> Void)? = nil) {
        self.source = source
        self.context = context
        self.onComplete = onComplete
        var d: QueueJobDraft
        var manualSeed: [Int: Int] = [:]
        switch context {
        case .edit(let item):
            d = QueueJobDraft(item: item)
            manualSeed = QueueAMSMatcher.manualOverrides(from: item.amsMapping)
        case .create(let mode):
            d = QueueJobDraft()
            d.schedule = mode == .printNow ? .asap : .queue
        }
        _draft = State(initialValue: d)
        _manual = State(initialValue: manualSeed)
        _initialPrinterIds = State(initialValue: d.printerIds)
        _initialPlateId = State(initialValue: d.singlePlateId)
    }

    private var client: APIClient { session.client }
    private var isEditing: Bool { if case .edit = context { true } else { false } }
    private var editingItem: QueueItem? { if case .edit(let item) = context { item } else { nil } }
    private var createMode: PrintJobSheet.Mode? { if case .create(let m) = context { m } else { nil } }

    private var plateList: [QueuePlateInfo] { plates?.plates ?? [] }
    private var isMultiPlate: Bool { plateList.count > 1 }
    private var multiPlateSelection: Bool { draft.plateIds.count > 1 }
    private var slicedForModel: String? {
        sourceInfo?["sliced_for_model"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
    private var candidatePrinters: [Printer] {
        store.printers.filter { $0.isActive || isEditing }
    }
    private var models: [String] {
        Array(Set(store.printers.filter(\.isActive).compactMap(\.model).filter { !$0.isEmpty })).sorted()
    }
    private var locations: [String] {
        guard let model = draft.targetModel else { return [] }
        return Array(Set(store.printers.filter { $0.isActive && $0.model == model }.compactMap(\.location).filter { !$0.isEmpty })).sorted()
    }
    private var singlePrinterId: Int? {
        draft.assignment == .printer && draft.printerIds.count == 1 ? draft.printerIds[0] : nil
    }
    private var showsDualNozzleOptions: Bool {
        if draft.assignment == .model {
            return draft.targetModel.map { QueueModelCompat.dualNozzleModels.contains(QueueModelCompat.normalize($0)) } ?? false
        }
        return draft.printerIds.contains { id in store.printer(id)?.nozzleCount == 2 }
    }
    private var hasGcodeSnippets: Bool { !(settings?["gcode_snippets"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var billingEnabled: Bool { settings?["billing_enabled"]?.boolValue ?? false }
    private var usePerPlateQuantities: Bool { !isEditing && isMultiPlate }
    private var effectiveQuantity: Int { draft.assignment == .printer && draft.printerIds.count > 1 ? 1 : draft.quantity }

    /// Slicer's own saved AMS pick for this archive, when it was resolved against the chosen printer.
    private var slicerMapping: [Int]? {
        guard let pid = singlePrinterId,
              let saved = sourceInfo?["extra_data"]?["slicer_ams_mapping"],
              saved["printer_id"]?.intValue == pid,
              let arr = saved["mapping"]?.arrayValue?.compactMap(\.intValue), !arr.isEmpty else { return nil }
        return arr
    }

    private func matches(for printerId: Int, manual: [Int: Int]) -> [QueueSlotMatch] {
        QueueAMSMatcher.match(requirements: requirements, trays: snapshots[printerId]?.trays ?? [], manual: manual)
    }

    /// The mapping sent for a printer (nil lets the scheduler map at dispatch).
    private func mapping(for printerId: Int) -> [Int]? {
        guard !multiPlateSelection, !requirements.isEmpty, let snap = snapshots[printerId], !snap.trays.isEmpty else { return nil }
        let m = matches(for: printerId, manual: printerId == singlePrinterId ? manual : [:])
        return QueueAMSMatcher.mapping(m)
    }

    private var hasMissingFilament: Bool {
        guard draft.assignment == .printer, !multiPlateSelection else { return false }
        return draft.printerIds.contains { pid in
            snapshots[pid] != nil && matches(for: pid, manual: pid == singlePrinterId ? manual : [:]).contains { $0.quality == .missing }
        }
    }

    private var canSubmit: Bool {
        if isSubmitting { return false }
        switch draft.assignment {
        case .printer:
            if draft.printerIds.isEmpty { return false }
            if singlePrinterId != nil, loadingSnapshots { return false }
        case .model:
            guard let model = draft.targetModel else { return false }
            if !QueueModelCompat.isCompatible(slicedFor: slicedForModel, target: model) { return false }
        }
        if isMultiPlate && draft.plateIds.isEmpty { return false }
        if billingEnabled && !costCenters.isEmpty && draft.costCenterId == nil { return false }
        return true
    }

    private var title: String {
        switch context {
        case .edit: "Edit Queue Item"
        case .create(.printNow): "Print"
        case .create(.addToQueue): "Add to Queue"
        }
    }

    private var submitTitle: String {
        switch context {
        case .edit: "Save"
        case .create:
            draft.schedule == .asap && draft.assignment == .printer ? "Print" : "Queue"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                if isMultiPlate || platesError != nil { platesSection }
                printerSection
                filamentSection
                if !isEditing && !usePerPlateQuantities && !(draft.assignment == .printer && draft.printerIds.count > 1) {
                    Section {
                        Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1...99)
                    } footer: {
                        if draft.quantity > 1 { Text("Queues \(draft.quantity) copies, grouped as a batch.") }
                    }
                }
                scheduleSection
                optionsSection
                if billingEnabled { costCenterSection }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isSubmitting)
            .overlay {
                if isSubmitting {
                    VStack(spacing: 12) {
                        ProgressView()
                        if progress.1 > 1 { Text("\(progress.0) of \(progress.1)").font(.footnote).foregroundStyle(.secondary) }
                    }
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle) {
                        if hasMissingFilament && !isEditing { showMismatchConfirm = true } else { Task { await submit() } }
                    }
                    .disabled(!canSubmit)
                }
                if !isEditing, session.can("pipelines:run") {
                    ToolbarItem(placement: .secondaryAction) {
                        Button { showPipelineRun = true } label: { Label("Run with Pipeline…", systemImage: "flowchart") }
                    }
                }
            }
            .confirmationDialog("Filament not loaded", isPresented: $showMismatchConfirm, titleVisibility: .visible) {
                Button(submitTitle + " Anyway") { Task { await submit() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("One or more filament slots have no matching filament loaded on the selected printer. The printer may use the wrong material.")
            }
            .sheet(isPresented: $showPipelineRun) {
                QueuePipelineRunSheet(source: source, onStarted: { dismiss(); onComplete?() })
            }
            .actionAlerts(runner)
            .task { await loadInitial() }
            .task(id: draft.singlePlateId ?? -1) { await loadRequirements() }
            .task(id: draft.printerIds) { await loadSnapshots() }
            .task(id: "\(draft.targetModel ?? "")|\(draft.targetLocation ?? "")") { await loadAvailableFilaments() }
            .onChange(of: draft.printerIds) { _, _ in resetMappingIfNeeded() }
            .onChange(of: draft.plateIds) { _, _ in resetMappingIfNeeded() }
            .onChange(of: draft.targetModel) { old, _ in if old != nil { draft.overrides = [:] } }
        }
    }

    // MARK: Sections

    private var sourceThumbnail: String {
        if let plate = draft.singlePlateId, plateList.first(where: { $0.index == plate })?.hasThumbnail == true {
            return "\(source.queueAPIPath)/plate-thumbnail/\(plate)"
        }
        return "\(source.queueAPIPath)/thumbnail"
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                RemoteImage(path: sourceThumbnail, systemImage: "cube")
                    .frame(width: 56, height: 56)
                    .clipShape(.rect(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.headline).lineLimit(2)
                    if let model = slicedForModel {
                        Label("Sliced for \(model)", systemImage: "printer").font(.caption).foregroundStyle(.secondary)
                    }
                    if let bed = currentBedType {
                        Label(bed, systemImage: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let item = editingItem, (item.variants?.count ?? 0) > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cross-model alternatives").font(.subheadline.weight(.medium))
                    ForEach(Array((item.variants ?? []).enumerated()), id: \.offset) { i, v in
                        Text("\(i + 1). \(v.filename ?? "?") — \(v.targetModel ?? "?")").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Alternatives can't be changed after queueing.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var currentBedType: String? {
        let plate = draft.singlePlateId.flatMap { id in plateList.first { $0.index == id } } ?? plateList.first
        return plate?.bedType.flatMap { $0.isEmpty ? nil : $0 } ?? editingItem?.bedType
    }

    private var platesSection: some View {
        Section {
            if let platesError {
                Label(platesError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            }
            ForEach(plateList) { plate in
                let selected = draft.plateIds.contains(plate.index)
                VStack(alignment: .leading, spacing: 6) {
                    Button { togglePlate(plate.index) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selected ? (isEditing ? "largecircle.fill.circle" : "checkmark.circle.fill") : "circle")
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                                .font(.title3)
                            RemoteImage(path: plate.hasThumbnail == true ? "\(source.queueAPIPath)/plate-thumbnail/\(plate.index)" : nil, systemImage: "square.stack.3d.up")
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plate.label).lineLimit(1)
                                HStack(spacing: 8) {
                                    if let t = plate.printTimeSeconds { Label(Fmt.duration(seconds: Double(t)), systemImage: "timer") }
                                    if let g = plate.filamentUsedGrams { Label(Fmt.grams(g), systemImage: "scalemass") }
                                    if let objs = plate.objectCount ?? plate.objects?.count, objs > 0 { Text("\(objs) obj") }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                if let fil = plate.filaments, !fil.isEmpty {
                                    HStack(spacing: 3) {
                                        ForEach(Array(fil.enumerated()), id: \.offset) { _, f in ColorSwatch(hex: f.color, size: 12) }
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    if usePerPlateQuantities && selected && !(draft.assignment == .printer && draft.printerIds.count > 1) {
                        Stepper("Copies: \(draft.plateQuantities[plate.index] ?? 1)", value: Binding(
                            get: { draft.plateQuantities[plate.index] ?? 1 },
                            set: { draft.plateQuantities[plate.index] = $0 }
                        ), in: 1...99)
                        .font(.subheadline)
                    }
                }
            }
        } header: {
            HStack {
                Text("Plates")
                Spacer()
                if !isEditing && isMultiPlate {
                    Button(draft.plateIds.count == plateList.count ? "None" : "All") {
                        draft.plateIds = draft.plateIds.count == plateList.count ? [] : plateList.map(\.index)
                    }
                    .font(.caption)
                }
            }
        } footer: {
            if multiPlateSelection {
                Text("Each selected plate is queued as its own job. AMS slots are matched per plate when the job starts.")
            }
        }
    }

    private func togglePlate(_ index: Int) {
        if isEditing {
            draft.plateIds = [index]
        } else if let i = draft.plateIds.firstIndex(of: index) {
            draft.plateIds.remove(at: i)
        } else {
            draft.plateIds = (draft.plateIds + [index]).sorted()
        }
    }

    @ViewBuilder
    private var printerSection: some View {
        let lockedVariants = (editingItem?.variants?.count ?? 0) > 1
        if !lockedVariants {
            Section {
                if !models.isEmpty {
                    Picker("Assign to", selection: $draft.assignment) {
                        Text("Specific Printer").tag(QueueJobDraft.Assignment.printer)
                        Text("Any \(draft.targetModel ?? slicedForModel ?? "Model")").tag(QueueJobDraft.Assignment.model)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.assignment) { _, mode in
                        if mode == .model, draft.targetModel == nil, let m = slicedForModel, models.contains(m) { draft.targetModel = m }
                    }
                }
                if draft.assignment == .printer {
                    if candidatePrinters.isEmpty {
                        Text("No printers available.").foregroundStyle(.secondary)
                    }
                    ForEach(candidatePrinters) { printer in
                        printerRow(printer)
                    }
                } else {
                    Picker("Model", selection: $draft.targetModel) {
                        Text("Select…").tag(String?.none)
                        ForEach(models, id: \.self) { m in
                            Text(QueueModelCompat.isCompatible(slicedFor: slicedForModel, target: m) ? m : "\(m) (incompatible)").tag(String?.some(m))
                        }
                    }
                    if !locations.isEmpty {
                        Picker("Location", selection: $draft.targetLocation) {
                            Text("Any Location").tag(String?.none)
                            ForEach(locations, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                    }
                }
            } header: {
                Text(draft.assignment == .printer ? "Printers" : "Printer Model")
            } footer: {
                if draft.assignment == .model {
                    if let m = draft.targetModel, !QueueModelCompat.isCompatible(slicedFor: slicedForModel, target: m) {
                        Text("This file was sliced for \(slicedForModel ?? "another model") and can't be sent to \(m) printers.").foregroundStyle(.red)
                    } else {
                        Text("The job starts on whichever matching printer becomes free first.")
                    }
                } else if draft.printerIds.count > 1 {
                    Text("One job is queued per selected printer.")
                }
            }
        }
    }

    private func printerRow(_ printer: Printer) -> some View {
        let selected = draft.printerIds.contains(printer.id)
        let status = store.statuses[printer.id]
        let compatible = QueueModelCompat.isCompatible(slicedFor: slicedForModel, target: printer.model)
        return Button {
            if let i = draft.printerIds.firstIndex(of: printer.id) { draft.printerIds.remove(at: i) }
            else if isEditing { draft.printerIds = [printer.id] }
            else { draft.printerIds.append(printer.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(printer.name).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if let model = printer.model { Text(model) }
                        if let loc = printer.location, !loc.isEmpty { Text("· \(loc)") }
                        if !printer.isActive { Text("· Disabled") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if !compatible {
                        Text("File was sliced for \(slicedForModel ?? "?")").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let status {
                    StatusBadge(text: status.stateLabel, color: status.connected ? (status.isActiveJob ? .blue : .green) : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Filament

    @ViewBuilder
    private var filamentSection: some View {
        if draft.assignment == .printer, !draft.printerIds.isEmpty, !multiPlateSelection, !requirements.isEmpty {
            if let pid = singlePrinterId {
                Section {
                    if loadingSnapshots && snapshots[pid] == nil {
                        HStack { ProgressView(); Text("Reading AMS…").foregroundStyle(.secondary) }
                    } else if snapshots[pid]?.trays.isEmpty ?? true {
                        Label("No filament detected on this printer. The printer's own mapping will be used.", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    } else {
                        ForEach(matches(for: pid, manual: manual)) { m in
                            slotMappingRow(m, printerId: pid)
                        }
                        if slicerMapping != nil {
                            Toggle("Use slicer's saved slot mapping", isOn: $useSlicerMapping)
                                .onChange(of: useSlicerMapping) { _, on in
                                    manual = on ? QueueAMSMatcher.manualOverrides(from: slicerMapping) : [:]
                                }
                        }
                        if !manual.isEmpty {
                            Button("Reset to Automatic Mapping") { manual = [:]; useSlicerMapping = false }
                        }
                    }
                } header: {
                    HStack {
                        Text("AMS Mapping")
                        Spacer()
                        Button { Task { await loadSnapshots() } } label: { Image(systemName: "arrow.clockwise") }
                            .font(.caption)
                    }
                } footer: {
                    Text("Tap a slot to choose which loaded spool feeds it.")
                }
            } else {
                Section("AMS Mapping") {
                    ForEach(draft.printerIds, id: \.self) { pid in
                        let ms = matches(for: pid, manual: [:])
                        let missing = ms.filter { $0.quality == .missing }.count
                        let colorOff = ms.filter { $0.quality == .typeOnly }.count
                        HStack {
                            Text(store.printer(pid)?.name ?? "Printer \(pid)")
                            Spacer()
                            if snapshots[pid] == nil {
                                ProgressView()
                            } else if missing > 0 {
                                StatusBadge(text: "\(missing) missing", color: .red)
                            } else if colorOff > 0 {
                                StatusBadge(text: "\(colorOff) color differs", color: .orange)
                            } else {
                                StatusBadge(text: "Matched", color: .green)
                            }
                        }
                    }
                    Text("Slots are matched automatically on each printer.").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if draft.assignment == .model, !requirements.isEmpty, !multiPlateSelection {
            Section {
                ForEach(requirements, id: \.self) { req in
                    overrideRow(req)
                }
            } header: {
                Text("Filament")
            } footer: {
                Text("Optionally require a different loaded filament per slot, or force an exact color match.")
            }
        }
    }

    private func slotMappingRow(_ m: QueueSlotMatch, printerId: Int) -> some View {
        let trays = snapshots[printerId]?.trays ?? []
        let slot = m.requirement.slotId ?? 0
        return Menu {
            Button { manual[slot] = nil; useSlicerMapping = false } label: { Label("Automatic", systemImage: "wand.and.stars") }
            Divider()
            ForEach(trays) { tray in
                Button {
                    manual[slot] = tray.globalTrayId
                } label: {
                    if manual[slot] == tray.globalTrayId { Label(tray.menuTitle, systemImage: "checkmark") } else { Text(tray.menuTitle) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text("\(slot)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                ColorSwatch(hex: m.requirement.color, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.requirement.type ?? "?").foregroundStyle(.primary)
                    if let g = m.requirement.usedGrams { Text(Fmt.grams(g)).font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                if let tray = m.tray {
                    ColorSwatch(hex: tray.color, size: 20)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(tray.label).foregroundStyle(.primary)
                        Text(tray.subBrands.isEmpty ? tray.type : tray.subBrands).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text("Not loaded").foregroundStyle(.red)
                }
                qualityIcon(m)
            }
        }
    }

    @ViewBuilder
    private func qualityIcon(_ m: QueueSlotMatch) -> some View {
        switch m.quality {
        case .match: Image(systemName: m.isManual ? "hand.point.up.fill" : "checkmark.circle.fill").foregroundStyle(.green)
        case .typeOnly: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .missing: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func overrideRow(_ req: QueueFilamentRequirement) -> some View {
        let slot = req.slotId ?? 0
        let current = draft.overrides[slot]
        return VStack(alignment: .leading, spacing: 6) {
            Menu {
                Button("As sliced (\(req.type ?? "?"))") {
                    if let force = draft.overrides[slot]?.forceColorMatch, force {
                        draft.overrides[slot] = QueueFilamentOverride(type: req.type ?? "", color: req.color ?? "", forceColorMatch: true)
                    } else {
                        draft.overrides[slot] = nil
                    }
                }
                ForEach(Array(availableFilaments.enumerated()), id: \.offset) { _, f in
                    Button("\(f.type ?? "?") \(f.traySubBrands.flatMap { $0.isEmpty ? nil : "· \($0)" } ?? "") · #\(QueueAMSMatcher.normalizedHex(f.color).uppercased())") {
                        draft.overrides[slot] = QueueFilamentOverride(type: f.type ?? "", color: f.color ?? "", forceColorMatch: current?.forceColorMatch ?? false)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text("\(slot)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                    ColorSwatch(hex: req.color, size: 20)
                    Text(req.type ?? "?").foregroundStyle(.primary)
                    Spacer()
                    if let current, current.type != req.type || QueueAMSMatcher.normalizedHex(current.color) != QueueAMSMatcher.normalizedHex(req.color) {
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        ColorSwatch(hex: current.color, size: 20)
                        Text(current.type).foregroundStyle(.primary)
                    } else {
                        Text("As sliced").foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Force color match", isOn: Binding(
                get: { draft.overrides[slot]?.forceColorMatch ?? false },
                set: { on in
                    var o = draft.overrides[slot] ?? QueueFilamentOverride(type: req.type ?? "", color: req.color ?? "", forceColorMatch: false)
                    o.forceColorMatch = on
                    let isDefault = !on && o.type == req.type && QueueAMSMatcher.normalizedHex(o.color) == QueueAMSMatcher.normalizedHex(req.color)
                    draft.overrides[slot] = isDefault ? nil : o
                }
            ))
            .font(.subheadline)
        }
    }

    // MARK: Schedule & options

    private var scheduleSection: some View {
        Section {
            Picker("When", selection: $draft.schedule) {
                Text("ASAP").tag(QueueJobDraft.Schedule.asap)
                Text("Queue").tag(QueueJobDraft.Schedule.queue)
                Text("Scheduled").tag(QueueJobDraft.Schedule.scheduled)
            }
            .pickerStyle(.segmented)
            if draft.schedule == .scheduled {
                DatePicker("Start at", selection: $draft.scheduledDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
            }
            if draft.schedule == .queue {
                Toggle(isOn: $draft.manualStart) { Label("Require manual start", systemImage: "hand.raised") }
            }
            Toggle("Only if previous print succeeded", isOn: $draft.requirePreviousSuccess)
            Toggle(isOn: $draft.autoOffAfter) { Label("Power off printer when done", systemImage: "power") }
                .disabled(!session.can("printers:control"))
            if hasGcodeSnippets {
                Toggle(isOn: $draft.gcodeInjection) { Label("Inject G-code snippets", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            if !isEditing, draft.assignment == .printer, draft.printerIds.count > 1 {
                Toggle("Stagger start times", isOn: $draft.staggerEnabled)
                if draft.staggerEnabled {
                    Stepper("Printers per group: \(draft.staggerGroupSize)", value: $draft.staggerGroupSize, in: 1...max(1, draft.printerIds.count))
                    Stepper("Interval: \(draft.staggerIntervalMinutes) min", value: $draft.staggerIntervalMinutes, in: 1...240)
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            switch draft.schedule {
            case .asap: Text("Goes to the front of the queue and starts as soon as the printer is free.")
            case .queue: Text(draft.manualStart ? "Waits in the queue until you start it." : "Added to the end of the queue.")
            case .scheduled: Text("Starts at the chosen time if the printer is free.")
            }
        }
    }

    private func triStatePicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            ForEach(QueueCalibrationMode.allCases) { Text($0.label).tag($0.rawValue) }
        }
    }

    private var optionsSection: some View {
        Section("Print Options") {
            triStatePicker("Bed Leveling", $draft.bedLevelling)
            triStatePicker("Flow Calibration", $draft.flowCali)
            if showsDualNozzleOptions { triStatePicker("Nozzle Offset Calibration", $draft.nozzleOffsetCali) }
            Toggle("Vibration Calibration", isOn: $draft.vibrationCali)
            Toggle("First Layer Inspection", isOn: $draft.layerInspect)
            Toggle("Timelapse", isOn: $draft.timelapse)
            Toggle("Use AMS", isOn: $draft.useAms)
            Picker("Preheat & Heat Soak", selection: $draft.preheatOverride) {
                Text("Default").tag("inherit")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            if draft.preheatOverride != "off" {
                Stepper(value: Binding(
                    get: { draft.preheatChamberTarget ?? 0 },
                    set: { draft.preheatChamberTarget = $0 <= 0 ? nil : min($0, 65) }
                ), in: 0...65, step: 5) {
                    LabeledContent("Chamber Target", value: draft.preheatChamberTarget.map { "\($0)°C" } ?? "Filament default")
                }
            }
        }
    }

    private var costCenterSection: some View {
        Section("Cost Center") {
            if costCenters.isEmpty {
                Text("You have no cost center that can print.").foregroundStyle(.red)
            } else {
                Picker("Charge to", selection: $draft.costCenterId) {
                    ForEach(Array(costCenters.enumerated()), id: \.offset) { _, c in
                        Text(c["name"]?.stringValue ?? "?").tag(c["id"]?.intValue)
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func loadInitial() async {
        async let s: JSONValue? = try? client.get("settings/")
        async let info: JSONValue? = try? client.get(source.queueAPIPath)
        let (settingsValue, infoValue) = await (s, info)
        settings = settingsValue
        sourceInfo = infoValue
        if !defaultsApplied, !isEditing, let settingsValue {
            defaultsApplied = true
            draft.bedLevelling = settingsValue["default_bed_levelling"]?.stringValue ?? draft.bedLevelling
            draft.flowCali = settingsValue["default_flow_cali"]?.stringValue ?? draft.flowCali
            draft.nozzleOffsetCali = settingsValue["default_nozzle_offset_cali"]?.stringValue ?? draft.nozzleOffsetCali
            draft.vibrationCali = settingsValue["default_vibration_cali"]?.boolValue ?? draft.vibrationCali
            draft.layerInspect = settingsValue["default_layer_inspect"]?.boolValue ?? draft.layerInspect
            draft.timelapse = settingsValue["default_timelapse"]?.boolValue ?? draft.timelapse
            draft.staggerGroupSize = settingsValue["stagger_group_size"]?.intValue ?? draft.staggerGroupSize
            draft.staggerIntervalMinutes = settingsValue["stagger_interval_minutes"]?.intValue ?? draft.staggerIntervalMinutes
            if draft.printerIds.isEmpty {
                let active = store.printers.filter(\.isActive)
                if active.count == 1 {
                    draft.printerIds = [active[0].id]
                } else if let def = settingsValue["default_printer_id"]?.intValue, active.contains(where: { $0.id == def }) {
                    draft.printerIds = [def]
                }
            }
        }
        if billingEnabled {
            let centers: [JSONValue] = (try? await client.get("finance/cost-centers/mine")) ?? []
            costCenters = centers.filter { ($0["can_print"]?.boolValue ?? false) && ($0["is_active"]?.boolValue ?? true) }
            if draft.costCenterId == nil || !costCenters.contains(where: { $0["id"]?.intValue == draft.costCenterId }) {
                let preferred = costCenters.first { $0["is_private"]?.boolValue == true } ?? costCenters.first
                draft.costCenterId = preferred?["id"]?.intValue
            }
        }
        do {
            let p: QueuePlatesResponse = try await client.get("\(source.queueAPIPath)/plates")
            plates = p
            platesError = nil
            if draft.plateIds.isEmpty, let first = p.plates?.first {
                draft.plateIds = [first.index]
                initialPlateId = isEditing ? initialPlateId : first.index
            }
        } catch {
            if source.queueArchiveId != nil {
                platesError = "The archived file couldn't be read. It may have been deleted."
            }
        }
    }

    private func loadRequirements() async {
        if isMultiPlate && draft.singlePlateId == nil { requirements = []; return }
        var query: [String: QueryValue?] = [:]
        if let plate = draft.singlePlateId { query["plate_id"] = .int(plate) }
        let reqs: QueueFilamentRequirements? = try? await client.get("\(source.queueAPIPath)/filament-requirements", query: query)
        requirements = (reqs?.filaments ?? []).filter { $0.usedInPlate != false }.sorted { ($0.slotId ?? 0) < ($1.slotId ?? 0) }
        requirementsLoaded = true
    }

    private func loadSnapshots() async {
        let ids = draft.printerIds
        guard !ids.isEmpty else { return }
        loadingSnapshots = true
        defer { loadingSnapshots = false }
        let client = client
        await withTaskGroup(of: (Int, QueuePrinterSnapshot?).self) { group in
            for id in ids {
                group.addTask {
                    guard let raw: JSONValue = try? await client.get("printers/\(id)/status"),
                          let status = try? raw.decode(PrinterStatus.self) else { return (id, nil) }
                    var map: [String: Int] = [:]
                    for (k, v) in raw["ams_extruder_map"]?.objectValue ?? [:] { if let i = v.intValue { map[k] = i } }
                    return (id, QueuePrinterSnapshot(status: status, extruderMap: map))
                }
            }
            for await (id, snap) in group {
                if let snap { snapshots[id] = snap }
                else if let cached = store.statuses[id] { snapshots[id] = QueuePrinterSnapshot(status: cached, extruderMap: [:]) }
            }
        }
    }

    private func loadAvailableFilaments() async {
        guard draft.assignment == .model, let model = draft.targetModel else { availableFilaments = []; return }
        availableFilaments = (try? await client.get("printers/available-filaments", query: ["model": .string(model), "location": .of(draft.targetLocation)])) ?? []
    }

    private func resetMappingIfNeeded() {
        if isEditing {
            if draft.printerIds.sorted() != initialPrinterIds.sorted() || draft.singlePlateId != initialPlateId {
                manual = [:]
                useSlicerMapping = false
            }
        } else {
            manual = [:]
            useSlicerMapping = false
        }
    }

    // MARK: Submit

    private func quantity(forPlate plate: Int?) -> Int {
        guard usePerPlateQuantities, let plate else { return effectiveQuantity }
        if draft.assignment == .printer && draft.printerIds.count > 1 { return 1 }
        return max(1, draft.plateQuantities[plate] ?? 1)
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        if let item = editingItem {
            await runner.run {
                let pid = draft.assignment == .printer ? draft.printerIds.first : nil
                let body = draft.updateBody(
                    printerId: pid, plateId: draft.singlePlateId,
                    amsMapping: pid.flatMap { mapping(for: $0) }, requirements: requirements
                )
                let _: QueueItem = try await client.send(.patch, "queue/\(item.id)", body: body)
                // Extra printers picked while editing become new queue items.
                for extra in draft.printerIds.dropFirst() where draft.assignment == .printer {
                    let create = draft.createBody(source: source, printerId: extra, plateId: draft.singlePlateId, amsMapping: mapping(for: extra),
                                                  requirements: requirements, quantity: 1, batchId: nil, insertPosition: nil, scheduledOverride: nil)
                    let _: QueueItem = try await client.send(.post, "queue/", body: create)
                }
                onComplete?()
                dismiss()
            }
            return
        }

        let platesToQueue: [Int?] = draft.plateIds.count > 1 ? draft.plateIds.map { Optional($0) } : [draft.singlePlateId]
        let printers: [Int?] = draft.assignment == .model ? [nil] : draft.printerIds.map { Optional($0) }
        let total = platesToQueue.count * printers.count
        progress = (0, total)

        // Several runs from one source on one target become a batch order with per-plate targets.
        var batchId: Int?
        let totalRuns = platesToQueue.reduce(0) { $0 + quantity(forPlate: $1) }
        if (platesToQueue.count > 1 || totalRuns > 1) && (draft.assignment == .model || draft.printerIds.count == 1) {
            let base = source.name.replacingOccurrences(of: ".gcode.3mf", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: ".3mf", with: "", options: .caseInsensitive)
            let name = platesToQueue.count > 1 ? "\(base.isEmpty ? "Batch" : base) · \(platesToQueue.count) plates" : "\(base.isEmpty ? "Batch" : base) ×\(totalRuns)"
            var batchBody: [String: JSONValue] = ["name": .string(name)]
            if let id = source.queueArchiveId { batchBody["archive_id"] = .number(Double(id)) }
            if let id = source.queueLibraryFileId { batchBody["library_file_id"] = .number(Double(id)) }
            batchBody["plates"] = .array(platesToQueue.enumerated().map { i, plate in
                [
                    "plate_id": plate.map { .number(Double($0)) } ?? .null,
                    "plate_name": plate.flatMap { p in plateList.first { $0.index == p }?.name }.map { .string($0) } ?? .null,
                    "quantity_target": .number(Double(quantity(forPlate: plate))),
                    "sort_order": .number(Double(i)),
                ]
            })
            let batch: QueueBatch? = try? await client.send(.post, "queue/batches", body: JSONValue.object(batchBody))
            batchId = batch?.id
        }

        var errors: [String] = []
        var successes = 0
        var insertCounts: [String: Int] = [:]
        let staggerBase = draft.schedule == .scheduled ? draft.scheduledDate : Date()
        var counter = 0
        for plate in platesToQueue {
            for (i, printer) in printers.enumerated() {
                counter += 1
                progress = (counter, total)
                let qty = quantity(forPlate: plate)
                var insertPosition: Int?
                if draft.schedule == .asap {
                    let key = printer.map { "p\($0)" } ?? "u"
                    insertPosition = (insertCounts[key] ?? 0) + 1
                    insertCounts[key] = insertPosition! + qty - 1
                }
                var scheduled: Date?
                if draft.staggerEnabled, draft.assignment == .printer, draft.printerIds.count > 1 {
                    let group = i / max(1, draft.staggerGroupSize)
                    if group > 0 { scheduled = staggerBase.addingTimeInterval(Double(group * draft.staggerIntervalMinutes * 60)) }
                }
                let body = draft.createBody(
                    source: source, printerId: printer, plateId: plate,
                    amsMapping: printer.flatMap { mapping(for: $0) },
                    requirements: requirements, quantity: qty, batchId: batchId,
                    insertPosition: insertPosition, scheduledOverride: scheduled
                )
                do {
                    let _: QueueItem = try await client.send(.post, "queue/", body: body)
                    successes += 1
                } catch {
                    let printerName = printer.flatMap { store.printer($0)?.name } ?? draft.targetModel.map { "Any \($0)" } ?? ""
                    let plateName = plate.map { "Plate \($0)" }
                    let label = [printerName, plateName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    errors.append(label.isEmpty ? error.localizedDescription : "\(label): \(error.localizedDescription)")
                }
            }
        }
        if errors.isEmpty {
            onComplete?()
            dismiss()
        } else {
            runner.errorMessage = successes > 0
                ? "\(successes) queued, \(errors.count) failed:\n" + errors.joined(separator: "\n")
                : errors.joined(separator: "\n")
            if successes > 0 { onComplete?() }
        }
    }
}
