import Testing
import Foundation
@testable import Bambuddy

struct QueueTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Queue items

    static let pendingItemJSON = """
    {
      "id": 12, "printer_id": 1, "target_model": null, "target_location": null,
      "required_filament_types": null, "filament_overrides": null, "waiting_reason": null,
      "archive_id": 5, "library_file_id": null, "cost_center_id": null, "estimated_cost": null,
      "position": 2, "scheduled_time": null, "require_previous_success": false,
      "auto_off_after": true, "manual_start": true, "filament_short": false, "skip_filament_check": false,
      "ams_mapping": [0, -1, 5], "plate_id": 2, "bed_levelling": "auto", "flow_cali": "on",
      "vibration_cali": true, "layer_inspect": false, "timelapse": true, "use_ams": true,
      "nozzle_offset_cali": "auto", "preheat_override": "inherit", "preheat_chamber_target_override": null,
      "status": "pending", "started_at": null, "completed_at": null, "error_message": null,
      "created_at": "2026-09-26T18:58:58.123456", "archive_name": "Benchy.gcode.3mf",
      "archive_thumbnail": "archives/5/thumb.png", "archive_deleted": false, "library_file_name": null,
      "library_file_thumbnail": null, "printer_name": "Office Printer", "print_time_seconds": 3720,
      "filament_used_grams": 14.2, "filament_type": "PLA", "filament_color": "#FFFFFF",
      "layer_height": 0.2, "nozzle_diameter": 0.4, "sliced_for_model": "P1S", "bed_type": "Textured PEI Plate",
      "archive_has_slicer_ams_mapping": false, "created_by_id": null, "created_by_username": null,
      "batch_id": 3, "batch_name": "Benchy ×3", "variants": [], "been_jumped": false,
      "gcode_injection": false, "cleanup_library_after_dispatch": false, "nozzle_mapping": null,
      "nozzle_rack_choice": {"1": 3}
    }
    """

    @Test func decodesPendingQueueItem() throws {
        let item = try decode(QueueItem.self, Self.pendingItemJSON)
        #expect(item.id == 12)
        #expect(item.isPending)
        #expect(item.isStaged)
        #expect(item.amsMapping == [0, -1, 5])
        #expect(item.displayName == "Benchy.gcode.3mf")
        #expect(item.targetLabel == "Office Printer")
        #expect(item.thumbnailPath == "archives/5/plate-thumbnail/2")
        #expect(item.source == .archive(id: 5, name: "Benchy.gcode.3mf"))
        #expect(item.nozzleRackChoice?["1"]?.intValue == 3)
        #expect(!item.hasRealSchedule)
    }

    @Test func decodesModelBasedAndHistoryItems() throws {
        let json = """
        [
          {"id": 1, "printer_id": null, "target_model": "X1C", "target_location": "Lab",
           "required_filament_types": ["PLA", "PETG"],
           "filament_overrides": [{"slot_id": 1, "type": "PETG", "color": "#FF0000", "color_name": "Red", "force_color_match": true}],
           "waiting_reason": "No idle X1C printer", "archive_id": null, "library_file_id": 9, "position": 1,
           "scheduled_time": "2027-12-01T00:00:00", "require_previous_success": false, "auto_off_after": false,
           "manual_start": false, "status": "pending", "started_at": null, "completed_at": null,
           "error_message": null, "created_at": "2026-09-26T10:00:00Z", "library_file_name": "part.3mf",
           "library_file_thumbnail": "thumb", "variants": [
             {"library_file_id": 9, "filename": "part_x1c.3mf", "target_model": "X1C", "position": 0},
             {"library_file_id": 10, "filename": "part_h2d.3mf", "target_model": "H2D", "position": 1}
           ]},
          {"id": 2, "printer_id": 1, "archive_id": 4, "library_file_id": null, "position": 0,
           "scheduled_time": null, "require_previous_success": true, "auto_off_after": false, "manual_start": false,
           "status": "skipped", "started_at": null, "completed_at": "2026-09-26T12:00:00",
           "error_message": "Previous print failed or was aborted", "created_at": "2026-09-26T11:00:00",
           "archive_deleted": true, "archive_name": null, "archive_thumbnail": null, "printer_name": "P1S"},
          {"id": 3, "printer_id": null, "archive_id": 4, "library_file_id": null, "position": 0,
           "scheduled_time": null, "require_previous_success": false, "auto_off_after": false, "manual_start": false,
           "status": "cancelled", "started_at": null, "completed_at": null, "error_message": null, "created_at": null}
        ]
        """
        let items = try decode([QueueItem].self, json)
        #expect(items.count == 3)
        #expect(items[0].isModelBased)
        #expect(items[0].targetLabel == "Any X1C / H2D @ Lab")
        #expect(items[0].filamentOverrides?.first?["force_color_match"]?.boolValue == true)
        #expect(items[0].isLibraryFile)
        #expect(items[0].thumbnailPath == "library/files/9/thumbnail")
        // Placeholder far-future schedules count as "no specific time".
        #expect(!items[0].hasRealSchedule)
        #expect(items[1].isHistory)
        #expect(items[1].thumbnailPath == nil)
        #expect(items[1].displayName == "Archive #4")
        #expect(items[2].isUnassigned)
        #expect(items[2].targetLabel == "Unassigned")
    }

    @Test func draftFromItemRoundTripsToUpdateBody() throws {
        var item = try decode(QueueItem.self, Self.pendingItemJSON)
        item.scheduledTime = Date().addingTimeInterval(7200).formatted(.iso8601)
        item.manualStart = false
        let draft = QueueJobDraft(item: item)
        #expect(draft.schedule == .scheduled)
        #expect(draft.printerIds == [1])
        #expect(draft.plateIds == [2])
        let body = draft.updateBody(printerId: 1, plateId: 2, amsMapping: [3, -1], requirements: [])
        #expect(body["printer_id"]?.intValue == 1)
        #expect(body["target_model"]?.isNull == true)
        #expect(body["ams_mapping"]?.arrayValue?.compactMap(\.intValue) == [3, -1])
        #expect(body["flow_cali"]?.stringValue == "on")
        #expect(body["timelapse"]?.boolValue == true)
        #expect(body["auto_off_after"]?.boolValue == true)
        #expect(body["scheduled_time"]?.stringValue != nil)
        #expect(body["manual_start"]?.boolValue == false)
    }

    @Test func createBodyForAsapModelAssignment() throws {
        var draft = QueueJobDraft()
        draft.assignment = .model
        draft.targetModel = "P1S"
        draft.schedule = .asap
        draft.overrides[2] = QueueFilamentOverride(type: "PETG", color: "#00FF00", forceColorMatch: true)
        let reqs = [QueueFilamentRequirement(slotId: 1, type: "PLA", color: "#FFFFFF"), QueueFilamentRequirement(slotId: 2, type: "PLA", color: "#000000")]
        let body = draft.createBody(source: .libraryFile(id: 7, name: "x.3mf"), printerId: nil, plateId: 1, amsMapping: [1, 2],
                                    requirements: reqs, quantity: 3, batchId: 11, insertPosition: 1, scheduledOverride: nil)
        #expect(body["library_file_id"]?.intValue == 7)
        #expect(body["archive_id"] == nil)
        #expect(body["printer_id"]?.isNull == true)
        #expect(body["target_model"]?.stringValue == "P1S")
        #expect(body["ams_mapping"] == nil)
        #expect(body["quantity"]?.intValue == 3)
        #expect(body["batch_id"]?.intValue == 11)
        #expect(body["insert_at_top"]?.boolValue == true)
        #expect(body["insert_position"]?.intValue == 1)
        #expect(body["scheduled_time"] == nil)
        let overrides = body["filament_overrides"]?.arrayValue
        #expect(overrides?.count == 1)
        #expect(overrides?.first?["slot_id"]?.intValue == 2)
        #expect(overrides?.first?["force_color_match"]?.boolValue == true)
        // Encodes as snake_case JSON the server accepts.
        let data = try APICoders.encoder.encode(body)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"insert_at_top\":true"))
    }

    @Test func createBodyForQueuedManualStart() {
        var draft = QueueJobDraft()
        draft.schedule = .queue
        draft.manualStart = true
        let body = draft.createBody(source: .archive(id: 3, name: "a"), printerId: 2, plateId: nil, amsMapping: nil,
                                    requirements: [], quantity: 1, batchId: nil, insertPosition: nil, scheduledOverride: nil)
        #expect(body["manual_start"]?.boolValue == true)
        #expect(body["insert_at_top"] == nil)
        #expect(body["quantity"] == nil)
        #expect(body["plate_id"]?.isNull == true)
        #expect(body["archive_id"]?.intValue == 3)
    }

    @Test func decodesSmallResponses() throws {
        let bulk = try decode(QueueBulkUpdateResult.self, #"{"updated_count": 3, "skipped_count": 1, "message": "Updated 3 items (1 skipped)"}"#)
        #expect(bulk.updatedCount == 3)
        let del = try decode(QueueDeleteResult.self, #"{"message": "Item cancelled rather than deleted", "deleted": false}"#)
        #expect(del.deleted == false)
        let resume = try decode(QueueResumeResult.self, #"{"acknowledged": 1, "restored": 2}"#)
        #expect(resume.restored == 2)
        let ungroup = try decode(QueueUngroupResult.self, #"{"ungrouped_count": 4, "message": "ok"}"#)
        #expect(ungroup.ungroupedCount == 4)
    }

    // MARK: Batches

    @Test func decodesBatchOrders() throws {
        let json = """
        [{"id": 3, "name": "Benchy ×3", "archive_id": 5, "library_file_id": null, "quantity": 3, "status": "active",
          "created_at": "2026-09-26T18:00:00", "completed_at": null, "created_by_id": null, "created_by_username": null,
          "project_id": null, "due_date": "2026-09-20T00:00:00", "notes": null, "pending_count": 1, "printing_count": 1,
          "completed_count": 1, "failed_count": 0, "cancelled_count": 0, "skipped_count": 0, "has_targets": true,
          "target_count": 3, "remaining_count": 2, "dispatchable_count": 1, "actual_cost": null,
          "estimated_remaining_cost": 1.5, "filament_used_grams": 14.0, "print_time_seconds": 3600,
          "plates": [{"plate_id": 1, "plate_name": null, "quantity_target": 3, "dispatched": 2, "remaining": 1,
                      "pending_count": 1, "printing_count": 1, "completed_count": 1, "failed_count": 0,
                      "cancelled_count": 0, "skipped_count": 0, "actual_cost": null, "estimated_remaining_cost": null,
                      "filament_used_grams": null, "print_time_seconds": 0, "can_dispatch": true}]},
         {"id": 4, "name": "Legacy", "quantity": 2, "status": "completed", "created_at": null}]
        """
        let batches = try decode([QueueBatch].self, json)
        #expect(batches[0].progressDenominator == 3)
        #expect(batches[0].strandedCount == 1)
        #expect(batches[0].isOverdue)
        #expect(batches[0].plates?.first?.label == "Plate 1")
        #expect(batches[1].plates == nil)
        #expect(batches[1].progressDenominator == 0)
    }

    // MARK: Plates & filament requirements

    @Test func decodesPlatesAndRequirements() throws {
        let plates = try decode(QueuePlatesResponse.self, """
        {"archive_id": 5, "filename": "multi.3mf", "is_multi_plate": true, "has_gcode": true,
         "embedded_printer": null, "embedded_process": null, "design_overrides": [],
         "plates": [
          {"index": 1, "name": "Cube", "objects": ["Cube"], "object_count": 1, "has_thumbnail": true,
           "thumbnail_url": "/api/v1/archives/5/plate-thumbnail/1", "print_time_seconds": 1200,
           "filament_used_grams": 5.5, "filaments": [{"slot_id": 1, "type": "PLA", "color": "#FF0000", "used_grams": 5.5, "used_meters": 1.8}],
           "bed_type": "Cool Plate"},
          {"index": 2, "name": null, "objects": [], "object_count": 0, "has_thumbnail": false, "thumbnail_url": null,
           "print_time_seconds": null, "filament_used_grams": null, "filaments": [], "bed_type": null}
         ]}
        """)
        #expect(plates.isMultiPlate == true)
        #expect(plates.plates?[0].label == "Plate 1 · Cube")
        #expect(plates.plates?[1].label == "Plate 2")

        let reqs = try decode(QueueFilamentRequirements.self, """
        {"archive_id": 5, "filename": "multi.3mf", "plate_id": 1, "filaments": [
          {"slot_id": 1, "type": "PLA", "color": "#FF0000FF", "used_grams": 5.5, "used_meters": 1.8,
           "tray_info_idx": "GFA00", "used_in_plate": true, "nozzle_id": 0},
          {"slot_id": 3, "type": "PETG", "color": "#000000", "used_grams": 2.0, "used_meters": 0.6, "tray_info_idx": ""}
        ]}
        """)
        #expect(reqs.filaments?.count == 2)
        #expect(reqs.filaments?[0].trayInfoIdx == "GFA00")
        #expect(reqs.filaments?[1].nozzleId == nil)

        let available = try decode([QueueAvailableFilament].self, #"[{"type":"PLA","color":"#FFF144FF","tray_info_idx":"P510aba0","tray_sub_brands":"","extruder_id":0},{"type":"PETG","color":"#000000","tray_info_idx":"","tray_sub_brands":"PETG HF","extruder_id":null}]"#)
        #expect(available.count == 2)
    }

    // MARK: AMS matching

    private func status(_ json: String) throws -> PrinterStatus { try decode(PrinterStatus.self, json) }

    @Test func matchesSlotsToLoadedTrays() throws {
        let s = try status("""
        {"id": 1, "name": "P1S", "connected": true, "state": "IDLE",
         "ams": [{"id": 0, "humidity": 3, "temp": 25.0, "tray": [
            {"id": 0, "tray_type": "PLA", "tray_color": "FFFFFFFF", "tray_info_idx": "GFA00", "remain": 80},
            {"id": 1, "tray_type": "PLA", "tray_color": "F0F0F5FF", "tray_info_idx": "GFL99", "remain": 20},
            {"id": 2, "tray_type": "PETG", "tray_color": "000000FF", "tray_info_idx": "GFG00", "remain": 50},
            {"id": 3, "tray_type": "", "tray_color": null}
         ]}],
         "vt_tray": [{"id": 254, "tray_type": "TPU", "tray_color": "FF0000FF"}]}
        """)
        let trays = QueueAMSMatcher.loadedTrays(s)
        #expect(trays.map(\.globalTrayId) == [0, 1, 2, 254])
        #expect(trays.map(\.label) == ["A1", "A2", "A3", "External"])

        let reqs = [
            QueueFilamentRequirement(slotId: 1, type: "PLA", color: "#F2F2F2", trayInfoIdx: "GFL99"),
            QueueFilamentRequirement(slotId: 2, type: "PLA", color: "#FFFFFF"),
            QueueFilamentRequirement(slotId: 4, type: "PETG", color: "#101010"),
            QueueFilamentRequirement(slotId: 5, type: "ABS", color: "#FFFFFF"),
        ]
        let matches = QueueAMSMatcher.match(requirements: reqs, trays: trays)
        #expect(matches[0].tray?.globalTrayId == 1) // preset id wins
        #expect(matches[1].tray?.globalTrayId == 0) // exact colour, tray 1 already used
        #expect(matches[2].tray?.globalTrayId == 2)
        #expect(matches[2].quality == .match) // similar colour
        #expect(matches[3].tray == nil)
        #expect(matches[3].quality == .missing)
        #expect(QueueAMSMatcher.mapping(matches) == [1, 0, -1, 2, -1])

        let manual = QueueAMSMatcher.match(requirements: reqs, trays: trays, manual: [2: 254])
        #expect(manual[1].tray?.globalTrayId == 254)
        #expect(manual[1].isManual)
        #expect(manual[1].quality == .missing) // TPU for a PLA slot
        #expect(QueueAMSMatcher.manualOverrides(from: [3, -1, 7]) == [1: 3, 3: 7])
    }

    @Test func htAndDualExternalLabels() throws {
        let s = try status("""
        {"id": 2, "name": "H2D", "connected": true,
         "ams": [{"id": 128, "tray": [{"id": 0, "tray_type": "PLA", "tray_color": "00FF00FF"}]}],
         "vt_tray": [{"id": 254, "tray_type": "PLA", "tray_color": "FFFFFFFF"}, {"id": 255, "tray_type": "PETG", "tray_color": "000000FF"}]}
        """)
        let trays = QueueAMSMatcher.loadedTrays(s, extruderMap: ["128": 0])
        #expect(trays.map(\.label) == ["HT-A", "Ext-L", "Ext-R"])
        #expect(trays.map(\.globalTrayId) == [128, 254, 255])
        #expect(trays.map(\.extruderId) == [0, 1, 0])
        // A slot bound to nozzle 1 may only use trays feeding extruder 1.
        let m = QueueAMSMatcher.match(requirements: [QueueFilamentRequirement(slotId: 1, type: "PLA", color: "#00FF00", nozzleId: 1)], trays: trays)
        #expect(m[0].tray?.globalTrayId == 254)
        #expect(m[0].quality == .typeOnly)
    }

    @Test func modelCompatibility() {
        #expect(QueueModelCompat.isCompatible(slicedFor: "X1C", target: "P1S"))
        #expect(!QueueModelCompat.isCompatible(slicedFor: "X1C", target: "A1"))
        #expect(QueueModelCompat.isCompatible(slicedFor: nil, target: "A1"))
        #expect(QueueModelCompat.isCompatible(slicedFor: "H2D-Pro", target: "h2d pro"))
    }

    // MARK: Pipelines

    @Test func decodesPipelinesAndRuns() throws {
        let list = try decode(QueuePipelineList.self, """
        {"pipelines": [{"name": "Production", "description": null,
          "printer_preset": {"source": "cloud", "id": "GM030"}, "process_preset": {"source": "standard", "id": "0.20mm Standard"},
          "filament_presets": [{"source": "local", "id": "abc"}], "bed_type": null, "id": 1, "created_by": null,
          "created_at": "2026-09-26T18:00:00", "updated_at": "2026-09-26T18:00:00", "target_kind": "printer_class",
          "target_printer_id": null, "target_model_class": "X1C", "fanout_strategy": "round_robin"}]}
        """)
        #expect(list.pipelines?.first?.hasTarget == true)
        #expect(list.pipelines?.first?.filamentPresets?.first?.source == "local")

        let runs = try decode(QueuePipelineRunList.self, """
        {"runs": [{"id": 1, "pipeline_id": 1, "pipeline_name": "Production Batch", "source_library_file_id": 42,
          "source_archive_id": null, "source_filename": "widget.3mf", "parent_run_id": null, "copies": 3,
          "copies_completed": 1, "copies_failed": 2, "copies_cancelled": 0, "copies_in_progress": 0,
          "status": "partial_failure", "slice_job_id": 7, "sliced_library_file_id": 43, "eligibility_overridden": false,
          "error_message": null, "created_by": null, "created_at": "2026-09-26T18:00:00Z", "started_at": null,
          "completed_at": null, "target_kind": "specific_printer", "target_printer_id": 1, "target_model_class": null,
          "fanout_strategy": null,
          "jobs": [{"id": 1, "pipeline_run_id": 1, "copy_index": 0, "assigned_printer_id": 1,
                    "assigned_printer_name": "X1C #1", "queue_entry_id": 99, "status": "completed",
                    "error_message": null, "dispatched_at": "2026-09-26T18:05:00Z", "completed_at": null},
                   {"id": 2, "pipeline_run_id": 1, "copy_index": 1, "assigned_printer_id": null,
                    "queue_entry_id": null, "status": "failed", "error_message": "Printer offline"}]}],
         "total": 1}
        """)
        let run = try #require(runs.runs?.first)
        #expect(run.canRetryFailed)
        #expect(!run.isInFlight)
        #expect(run.jobs?.count == 2)
        #expect(run.jobs?[1].errorMessage == "Printer offline")
        let clear = try decode(QueuePipelineClearResult.self, #"{"deleted": 4}"#)
        #expect(clear.deleted == 4)
    }

    @Test func decodesEligibilityAndPresets() throws {
        let report = try decode(QueuePipelineEligibility.self, """
        {"ok": false, "target_kind": "printer_class", "target_printer_id": null, "target_printer_name": null,
         "target_model_class": "X1C", "issues": [{"kind": "no_class_matches", "slot_index": null, "expected": null, "actual": null}],
         "printer_reports": [{"printer_id": 1, "printer_name": "X1C #1", "ok": false,
           "issues": [{"kind": "filament_type_mismatch", "slot_index": 0, "expected": "PLA", "actual": "PETG"}]}]}
        """)
        #expect(report.ok == false)
        #expect(report.printerReports?.first?.issues?.first?.summary == "Filament type mismatch · slot 1 · expected PLA · found PETG")

        let catalog = try decode(QueueSlicerPresetCatalog.self, """
        {"orca_cloud": {"printer": [], "process": [], "filament": []},
         "cloud": {"printer": [{"id": "GM030", "name": "Bambu Lab A1 0.4 nozzle", "source": "cloud", "filament_type": null, "filament_colour": null, "compatible_printers": null}], "process": [], "filament": []},
         "local": {"printer": [], "process": [], "filament": [{"id": "abc", "name": "My PLA", "source": "local", "filament_type": "PLA", "filament_colour": "#FFFFFF", "compatible_printers": ["X1C"]}]},
         "standard": {"printer": [], "process": [], "filament": []},
         "cloud_status": "ok", "orca_cloud_status": "not_authenticated"}
        """)
        #expect(catalog.all("printer").count == 1)
        #expect(catalog.name(for: QueuePipelinePresetRef(source: "local", id: "abc"), slot: "filament") == "My PLA")
        #expect(catalog.orcaCloudStatus == "not_authenticated")
    }

    // MARK: Queue logic

    @Test func groupsRowsAndPlansTimeline() throws {
        let base = try decode(QueueItem.self, Self.pendingItemJSON)
        var a = base; a.id = 1; a.batchId = nil; a.position = 1; a.manualStart = false
        var b = base; b.id = 2; b.batchId = 9; b.position = 2; b.manualStart = false
        var c = base; c.id = 3; c.batchId = 9; c.position = 3; c.manualStart = false
        var printing = base; printing.id = 4; printing.status = "printing"; printing.batchId = nil
        let rows = QueueRow.group([a, b, c])
        #expect(rows.count == 2)
        #expect(rows[1].items.map(\.id) == [2, 3])

        let now = Date()
        let events = QueueTimelinePlanner.events(items: [printing, a, b, c], statuses: [:], now: now)
        #expect(events.count == 4)
        let queued = events.filter { !$0.printing }.sorted { $0.start < $1.start }
        #expect(queued.map(\.item.id) == [1, 2, 3])
        #expect(queued[0].start >= now)
    }
}
