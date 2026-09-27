import Testing
import Foundation
@testable import Bambuddy

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try APICoders.decoder.decode(T.self, from: Data(json.utf8))
}

private func encodedObject(_ body: [String: JSONValue]) throws -> [String: Any] {
    let data = try APICoders.encoder.encode(body)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

struct ProjectsModelTests {
    @Test func decodesProjectList() throws {
        let json = """
        [{"id":3,"name":"Desk organizer","description":null,"color":"#3b82f6","status":"active",
          "target_count":10,"target_parts_count":null,"target_sets":null,"budget":null,"tags":"office, gifts",
          "due_date":"2026-10-01T00:00:00","priority":"high","created_at":"2026-09-01T10:00:00.123456",
          "archive_count":4,"total_items":6,"completed_count":5,"failed_count":1,"queue_count":2,
          "progress_percent":40.0,"parent_id":null,"child_count":1,
          "archives":[{"id":11,"print_name":"Tray","thumbnail_path":"archives/11/thumb.png","status":"completed",
                       "filament_type":"PLA, PETG","filament_color":"#FF0000,00FF00"},
                      {"id":12,"print_name":null,"thumbnail_path":null,"status":"failed","filament_type":null,"filament_color":null}],
          "url":"https://makerworld.com/models/1","cover_image_filename":"cover_abc.jpg"},
         {"id":4,"name":"Minimal","description":"x","color":null,"status":"archived","target_count":null,
          "created_at":"2026-09-02T10:00:00"}]
        """
        let list = try decode([ProjectListEntry].self, json)
        #expect(list.count == 2)
        #expect(list[0].archives?.count == 2)
        #expect(list[0].archives?[1].printName == nil)
        #expect(list[0].coverImageFilename == "cover_abc.jpg")
        #expect(list[1].archiveCount == nil)
        #expect(ProjectCardView.progress(list[0]) == 0.4)
        #expect(ProjectPalette.splitList(list[0].archives?[0].filamentType) == ["PLA", "PETG"])
    }

    @Test func decodesProjectDetailWithNulls() throws {
        let json = """
        {"id":3,"name":"Desk organizer","description":null,"color":null,"status":"active","target_count":null,
         "target_parts_count":null,"target_sets":null,"notes":null,"attachments":null,"tags":null,"due_date":null,
         "priority":"normal","budget":null,"is_template":false,"template_source_id":null,"parent_id":null,
         "parent_name":null,"children":[],"descendant_count":0,"created_at":"2026-09-01T10:00:00",
         "updated_at":"2026-09-02T10:00:00","stats":null,"rollup_stats":null,"url":null,"cover_image_filename":null}
        """
        let p = try decode(ProjectDetail.self, json)
        #expect(p.stats == nil)
        #expect(p.children?.isEmpty == true)
        #expect(p.attachments == nil)
    }

    @Test func decodesProjectDetailFull() throws {
        let json = """
        {"id":5,"name":"Robot","description":"Arm","color":"#22c55e","status":"completed","target_count":8,
         "target_parts_count":20,"target_sets":2,"notes":"<p>Hello <strong>world</strong></p>",
         "attachments":[{"filename":"a1b2.pdf","original_name":"manual.pdf","size":2048,"uploaded_at":"2026-09-03T12:00:00.123456"}],
         "tags":"robots","due_date":"2026-12-24T00:00:00","priority":"urgent","budget":150.5,"is_template":true,
         "template_source_id":2,"parent_id":1,"parent_name":"Workshop",
         "children":[{"id":6,"name":"Gripper","color":null,"status":"active","progress_percent":null,"descendant_count":0,
                      "total_archives":2,"completed_prints":2,"total_print_time_hours":3.5,"total_filament_grams":120.0,"total_cost":4.2}],
         "descendant_count":1,"created_at":"2026-09-01T10:00:00","updated_at":"2026-09-02T10:00:00",
         "stats":{"total_archives":6,"total_items":12,"completed_prints":10,"failed_prints":2,"queued_prints":1,
                  "in_progress_prints":0,"total_print_time_hours":12.25,"total_filament_grams":850.0,"progress_percent":75.0,
                  "parts_progress_percent":50.0,"estimated_cost":20.0,"total_energy_kwh":1.234,"total_energy_cost":0.5,
                  "remaining_prints":2,"remaining_parts":10,"bom_total_items":3,"bom_completed_items":1,"bom_cost":30.0},
         "rollup_stats":{"total_archives":8,"total_items":14,"completed_prints":12,"failed_prints":2,"queued_prints":1,
                  "in_progress_prints":0,"total_print_time_hours":15.75,"total_filament_grams":970.0,"progress_percent":null,
                  "parts_progress_percent":null,"estimated_cost":24.0,"total_energy_kwh":0.0,"total_energy_cost":0.0,
                  "remaining_prints":null,"remaining_parts":null,"bom_total_items":3,"bom_completed_items":1,"bom_cost":30.0},
         "url":null,"cover_image_filename":null}
        """
        let p = try decode(ProjectDetail.self, json)
        #expect(p.stats?.totalCost == 50.5)
        #expect(p.children?.first?.totalCost == 4.2)
        #expect(p.attachments?.first?.displayName == "manual.pdf")
        #expect(p.rollupStats?.progressPercent == nil)
        let form = ProjectEditForm(project: p)
        #expect(form.hasDueDate)
        #expect(form.budget == "150.5")
        #expect(form.targetSets == "2")
    }

    @Test func decodesBOMTimelineAndProgress() throws {
        let bom = try decode([ProjectBOMItem].self, """
        [{"id":1,"project_id":5,"name":"M3 screws","quantity_needed":20,"quantity_acquired":20,"unit_price":null,
          "sourcing_url":null,"archive_id":null,"archive_name":null,"stl_filename":null,"remarks":null,"sort_order":0,
          "is_complete":true,"created_at":"2026-09-01T10:00:00","updated_at":"2026-09-01T10:00:00"},
         {"id":2,"project_id":5,"name":"Bearing","quantity_needed":4,"quantity_acquired":1,"unit_price":1.25,
          "sourcing_url":"https://example.com/b","archive_id":11,"archive_name":"Tray","stl_filename":"b.stl","remarks":"608ZZ",
          "sort_order":1,"created_at":"2026-09-01T10:00:00","updated_at":"2026-09-01T10:00:00"}]
        """)
        #expect(bom[0].complete)
        #expect(!bom[1].complete)
        #expect(bom[1].isComplete == nil)

        let timeline = try decode([ProjectTimelineEvent].self, """
        [{"event_type":"print_completed","timestamp":"2026-09-03T12:00:00","title":"Tray","description":"Completed on P1S",
          "metadata":{"archive_id":11,"printer_id":1,"filament_grams":42.5}},
         {"event_type":"project_created","timestamp":"2026-09-01T10:00:00","title":"Project created","description":null,"metadata":null}]
        """)
        #expect(timeline[0].metadata?["archive_id"]?.intValue == 11)
        #expect(timeline[1].metadata == nil)

        let progress = try decode([ProjectFileProgressEntry].self, #"[{"file_id":7,"completed_count":3}]"#)
        #expect(progress.first?.completedCount == 3)
    }

    @Test func decodesProjectArchives() throws {
        // Shape produced by archive_to_response().
        let json = """
        [{"id":11,"printer_id":1,"project_id":5,"project_name":"Robot","filename":"tray.gcode.3mf","file_path":"archives/x",
          "file_size":123456,"content_hash":"abc","thumbnail_path":"archives/11/thumb.png","timelapse_path":null,
          "source_3mf_path":null,"f3d_path":null,"duplicates":null,"duplicate_count":0,"duplicate_sequence":0,
          "original_archive_id":null,"print_name":"Tray","plate_id":1,"print_time_seconds":3600,"filament_used_grams":42.5,
          "filament_type":"PLA","filament_color":"#FF0000","layer_height":0.2,"total_layers":100,"nozzle_diameter":0.4,
          "bed_temperature":60,"bed_type":"Textured PEI Plate","nozzle_temperature":220,"sliced_for_model":"P1S",
          "status":"completed","started_at":"2026-09-03T11:00:00","completed_at":"2026-09-03T12:00:00",
          "extra_data":{"plates":[1]},"makerworld_url":null,"designer":null,"external_url":null,"is_favorite":false,
          "tags":null,"notes":null,"cost":1.2,"photos":null,"failure_reason":null,"quantity":2,"energy_kwh":null,
          "energy_cost":null,"created_at":"2026-09-03T12:00:01","created_by_id":null,"created_by_username":null,
          "time_accuracy":null,"run_count":1,"last_run_at":null}]
        """
        let list = try decode([ProjectArchiveEntry].self, json)
        #expect(list.first?.displayName == "Tray")
        #expect(list.first?.quantity == 2)
    }

    @Test func decodesLibraryFoldersAndFiles() throws {
        let folders = try decode([ProjectLibraryFolder].self, """
        [{"id":2,"name":"Robot parts","parent_id":null,"project_id":5,"archive_id":null,"project_name":"Robot",
          "archive_name":null,"is_external":false,"external_path":null,"external_readonly":false,"external_show_hidden":false,
          "file_count":3,"latest_activity_at":null,"created_at":"2026-09-01T10:00:00","updated_at":"2026-09-01T10:00:00"}]
        """)
        #expect(folders.first?.fileCount == 3)

        let tree = try decode([ProjectLibraryFolderNode].self, """
        [{"id":1,"name":"Root","parent_id":null,"project_id":null,"file_count":0,
          "children":[{"id":2,"name":"Child","parent_id":1,"project_id":5,"project_name":"Robot","children":[]}]}]
        """)
        let flat = tree.flatMap { $0.flattened() }
        #expect(flat.map(\.node.id) == [1, 2])
        #expect(flat.last?.depth == 1)

        let files = try decode([ProjectLibraryFile].self, """
        [{"id":7,"folder_id":2,"is_external":false,"filename":"arm.gcode.3mf","file_type":"gcode.3mf","file_size":1000,
          "thumbnail_path":null,"print_count":2,"duplicate_count":0,"created_by_id":null,"created_by_username":null,
          "created_at":"2026-09-01T10:00:00","fs_modified_at":null,"print_name":"Arm","print_time_seconds":7200,
          "filament_used_grams":55.0,"sliced_for_model":"P1S","tags":[],"variant_group_id":null,"variant_count":0},
         {"id":8,"folder_id":2,"filename":"base.3mf","file_type":"3mf","file_size":1000,"thumbnail_path":null,
          "print_count":0,"created_at":"2026-09-01T10:00:00"}]
        """)
        #expect(files[0].isPrintable)
        #expect(!files[1].isPrintable)
    }

    @Test func decodesUploadResponses() throws {
        let r = try decode(ProjectUploadResult.self, """
        {"status":"success","filename":"abc.pdf","original_name":"manual.pdf",
         "attachments":[{"filename":"abc.pdf","original_name":"manual.pdf","size":10,"uploaded_at":"2026-09-03T12:00:00"}]}
        """)
        #expect(r.attachments?.count == 1)
        let cover = try decode(ProjectUploadResult.self, #"{"status":"success","filename":"cover_1.jpg","size":100}"#)
        #expect(cover.filename == "cover_1.jpg")
    }

    @Test func editBodySendsNullToClearOnlyWhenEditing() throws {
        var form = ProjectEditForm()
        form.name = "  Robot  "
        form.targetPlates = "5"

        let create = try encodedObject(form.body(isEdit: false))
        #expect(create["name"] as? String == "Robot")
        #expect(create["target_count"] as? Int == 5)
        #expect(create.keys.contains("tags") == false)
        #expect(create.keys.contains("due_date") == false)
        #expect(create.keys.contains("status") == false)
        #expect(create.keys.contains("parent_id") == false)

        let edit = try encodedObject(form.body(isEdit: true))
        #expect(edit["tags"] is NSNull)
        #expect(edit["due_date"] is NSNull)
        #expect(edit["url"] is NSNull)
        #expect(edit["budget"] is NSNull)
        #expect(edit["target_sets"] is NSNull)
        #expect(edit["parent_id"] as? Int == 0)
        #expect(edit["status"] as? String == "active")

        form.tags = "a, b"
        form.hasDueDate = true
        form.dueDate = try #require(ProjectDates.calendarDate("2026-12-24T00:00:00"))
        form.budget = "12,5"
        let edited = try encodedObject(form.body(isEdit: true))
        #expect(edited["tags"] as? String == "a, b")
        #expect(edited["due_date"] as? String == "2026-12-24T00:00:00")
        #expect(edited["budget"] as? Double == 12.5)
    }

    @Test func dueDatesIgnoreTimeZones() throws {
        let d = try #require(ProjectDates.calendarDate("2026-10-01T00:00:00"))
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        #expect(c.year == 2026 && c.month == 10 && c.day == 1)
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 23)))
        #expect(ProjectDates.daysUntil("2026-10-01T00:00:00", now: now) == 3)
    }

    @Test @MainActor func notesRoundTrip() {
        #expect(ProjectDetailStore.plainNotes("<p>Line &amp; one</p><p>Two</p>") == "Line & one\nTwo")
        #expect(ProjectDetailStore.notesHTML("a < b\n\nc") == "<p>a &lt; b</p><p></p><p>c</p>")
        #expect(ProjectDetailStore.notesHTML("   ") == "")
    }
}

struct MaintenanceModelTests {
    // Captured from a live server (P1S, hours-based items).
    static let overviewJSON = """
    [{"printer_id":1,"printer_name":"Office Printer","printer_model":"P1S","total_print_hours":0.8002777777777778,
      "maintenance_items":[
        {"id":1,"printer_id":1,"printer_name":"Office Printer","printer_model":"P1S","maintenance_type_id":1,
         "maintenance_type_name":"Clean Carbon Rods","maintenance_type_icon":"Sparkles","maintenance_type_wiki_url":null,
         "enabled":true,"interval_hours":100.0,"interval_type":"hours","current_hours":0.8002777777777778,
         "hours_since_maintenance":0.8002777777777778,"hours_until_due":99.19972222222222,"days_since_maintenance":null,
         "days_until_due":null,"is_due":false,"is_warning":false,"last_performed_at":null},
        {"id":9,"printer_id":1,"printer_name":"Office Printer","printer_model":null,"maintenance_type_id":12,
         "maintenance_type_name":"Replace filter","maintenance_type_icon":null,"maintenance_type_wiki_url":"https://example.com",
         "enabled":true,"interval_hours":30.0,"interval_type":"days","current_hours":0.8,"hours_since_maintenance":0.8,
         "hours_until_due":0,"days_since_maintenance":31.5,"days_until_due":-1.5,"is_due":true,"is_warning":false,
         "last_performed_at":"2026-08-25T08:00:00.123456"}],
      "due_count":1,"warning_count":0}]
    """

    @Test func decodesOverview() throws {
        let overview = try decode([MaintenancePrinterOverview].self, Self.overviewJSON)
        let printer = try #require(overview.first)
        #expect(printer.maintenanceItems.count == 2)
        #expect(printer.sortedItems.first?.id == 9)
        #expect(printer.nextTask?.maintenanceTypeName == "Replace filter")

        let hours = printer.maintenanceItems[0]
        #expect(!hours.isDaysBased)
        #expect(hours.statusText == "99 h left")
        #expect(abs(hours.progress - 0.008) < 0.001)

        let days = printer.maintenanceItems[1]
        #expect(days.isDaysBased)
        #expect(days.statusText == "Overdue by 2 days")
        #expect(days.progress == 1)
    }

    @Test func decodesTypesHistoryAndRecords() throws {
        let types = try decode([MaintenanceTypeInfo].self, """
        [{"name":"Check Belt Tension","description":"Verify and adjust belt tension for X/Y axes","default_interval_hours":200.0,
          "interval_type":"hours","icon":"Ruler","wiki_url":null,"id":7,"is_system":true,"created_at":"2026-08-20T14:40:34"},
         {"name":"Replace filter","id":12,"is_system":false,"created_at":"2026-08-20T14:40:34"}]
        """)
        #expect(types[0].interval == 200)
        #expect(types[1].kind == "hours")
        #expect(MaintenanceIcons.symbol(for: types[0].icon) == "ruler")
        #expect(MaintenanceIcons.symbol(for: "Unknown") == "wrench.adjustable")

        let history = try decode([MaintenanceHistoryEntry].self, """
        [{"notes":null,"id":1,"printer_maintenance_id":9,"performed_at":"2026-08-25T08:00:00.123456","hours_at_maintenance":0.5},
         {"notes":"Swapped PTFE","id":2,"printer_maintenance_id":9,"performed_at":"2026-09-25T08:00:00","hours_at_maintenance":12.0}]
        """)
        #expect(history.count == 2)
        #expect(history[0].notes == nil)

        let record = try decode(MaintenanceItemRecord.self, """
        {"id":9,"printer_id":1,"maintenance_type_id":12,
         "maintenance_type":{"name":"Replace filter","description":null,"default_interval_hours":30.0,"interval_type":"days",
                             "icon":"Filter","wiki_url":null,"id":12,"is_system":false,"created_at":"2026-08-20T14:40:34"},
         "custom_interval_hours":null,"enabled":true,"last_performed_at":null,"last_performed_hours":0.0,
         "created_at":"2026-08-20T14:40:34","updated_at":"2026-08-20T14:40:34"}
        """)
        #expect(record.maintenanceType?.kind == "days")

        let restore = try decode(MaintenanceRestoreResult.self, #"{"restored":2}"#)
        #expect(restore.restored == 2)
    }

    @Test func formatsIntervals() {
        #expect(MaintenanceFormat.interval(30, type: "days") == "Monthly")
        #expect(MaintenanceFormat.interval(45, type: "days") == "Every 45 days")
        #expect(MaintenanceFormat.interval(100, type: "hours") == "Every 100 print hours")
        #expect(MaintenanceFormat.amount(0.5, daysBased: false) == "30 min")
        #expect(MaintenanceFormat.amount(21, daysBased: true) == "3 weeks")
    }
}
