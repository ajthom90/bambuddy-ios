import Testing
import Foundation
@testable import Bambuddy

/// Decoding tests for the Archives feature, with fixtures shaped after the
/// backend's Pydantic schemas and the dicts its routes build (nulls included).
struct ArchivesTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    static let fullArchive = #"""
    {
      "id": 42, "printer_id": 1, "project_id": 3, "project_name": "Desk organizer",
      "filename": "benchy.gcode.3mf", "file_path": "archive/1/20260926_benchy/benchy.gcode.3mf",
      "file_size": 1834221, "content_hash": "ab12cd34ef56",
      "thumbnail_path": "archive/1/20260926_benchy/thumbnail.png",
      "timelapse_path": "archive/1/20260926_benchy/timelapse.mp4",
      "source_3mf_path": "archive/1/20260926_benchy/source.3mf", "f3d_path": null,
      "duplicates": [{"id": 12, "print_name": "Benchy", "created_at": "2026-09-01T10:00:00", "match_type": "exact"}],
      "duplicate_count": 1, "duplicate_sequence": 1, "original_archive_id": 12,
      "object_count": 2, "print_name": "Benchy", "plate_id": 2,
      "print_time_seconds": 3600, "actual_time_seconds": 3720, "time_accuracy": 96.8,
      "filament_used_grams": 14.52, "filament_type": "PLA, PETG", "filament_color": "#FF0000,#00FF00",
      "layer_height": 0.2, "total_layers": 240, "nozzle_diameter": 0.4, "bed_temperature": 55,
      "bed_type": "Textured PEI Plate", "nozzle_temperature": 220, "sliced_for_model": "P1S",
      "status": "completed", "started_at": "2026-09-26T10:00:00.123456", "completed_at": "2026-09-26T11:02:00+00:00",
      "extra_data": {"printable_objects": {"1": "a", "2": "b"}, "slicer_ams_mapping": {"mapping": [0, 1], "printer_id": 1}},
      "makerworld_url": "https://makerworld.com/en/models/1", "designer": "Someone", "external_url": null,
      "is_favorite": true, "tags": "calibration, test ,", "notes": "Great print", "cost": 0.43,
      "photos": ["a1b2c3d4.jpg", "e5f6a7b8.png"], "failure_reason": null, "quantity": 2,
      "energy_kwh": 0.123, "energy_cost": 0.04, "created_at": "2026-09-26T11:02:05",
      "created_by_id": null, "created_by_username": null,
      "run_count": 3, "last_run_at": "2026-09-26T11:02:00", "total_filament_actual_grams": 40.1,
      "successful_run_count": 2, "failed_run_count": 1
    }
    """#

    @Test func decodesFullArchive() throws {
        let a = try decode(ArchivesRecord.self, Self.fullArchive)
        #expect(a.id == 42)
        #expect(a.source3mfPath == "archive/1/20260926_benchy/source.3mf")
        #expect(a.f3dPath == nil)
        #expect(a.duplicates?.first?.matchType == "exact")
        #expect(a.displayName == "Benchy")
        #expect(a.tagList == ["calibration", "test"])
        #expect(a.materials == ["PLA", "PETG"])
        #expect(a.colors == ["#FF0000", "#00FF00"])
        #expect(a.photoNames == ["a1b2c3d4.jpg", "e5f6a7b8.png"])
        #expect(a.isSliced)
        #expect(a.wasPrinted)
        #expect(a.favorite)
        #expect(a.slicerAmsMappingPrinterId == 1)
        #expect(a.externalLink?.host() == "makerworld.com")
        #expect(a.createdDate != nil)
    }

    @Test func decodesMinimalFallbackArchive() throws {
        // A no-3MF fallback / bare upload: almost everything null.
        let json = #"""
        {"id": 7, "printer_id": null, "filename": "unknown", "file_path": "", "file_size": 0,
         "content_hash": null, "thumbnail_path": null, "timelapse_path": null, "print_name": null,
         "print_time_seconds": null, "filament_used_grams": null, "filament_type": null,
         "filament_color": null, "layer_height": null, "nozzle_diameter": null, "bed_temperature": null,
         "nozzle_temperature": null, "status": "archived", "started_at": null, "completed_at": null,
         "extra_data": null, "makerworld_url": null, "designer": null, "is_favorite": false,
         "tags": null, "notes": null, "cost": null, "photos": null, "failure_reason": null,
         "created_at": null}
        """#
        let a = try decode(ArchivesRecord.self, json)
        #expect(a.displayName == "unknown")
        #expect(!a.isSliced)
        #expect(!a.wasPrinted)
        #expect(a.photoNames.isEmpty)
        #expect(a.tagList.isEmpty)
        #expect(a.externalLink == nil)
        let list = try decode([ArchivesRecord].self, "[\(json), \(Self.fullArchive)]")
        #expect(list.count == 2)
    }

    @Test func updateBodyEncodesExplicitNulls() throws {
        var body = ArchivesUpdate()
        body.set("project_id", nil as Int?)
        body.set("failure_reason", nil as String?)
        body.set("print_name", "New name")
        body.set("quantity", 3)
        body.set("filament_used_grams", 12.5)
        body.set("is_favorite", true)
        let data = try APICoders.encoder.encode(body)
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(object["project_id"]?.isNull == true)
        #expect(object["failure_reason"]?.isNull == true)
        #expect(object["print_name"]?.stringValue == "New name")
        #expect(object["quantity"]?.intValue == 3)
        #expect(object["filament_used_grams"]?.doubleValue == 12.5)
        #expect(object["is_favorite"]?.boolValue == true)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"project_id\":null"))
    }

    @Test func logEntryUpdateEncoding() throws {
        let clear = ArchivesLogEntryUpdate(status: nil, failureReason: .some(nil))
        let text = String(decoding: try APICoders.encoder.encode(clear), as: UTF8.self)
        #expect(text == #"{"failure_reason":null}"#)
        let set = ArchivesLogEntryUpdate(status: "failed", failureReason: "warping")
        let obj = try JSONDecoder().decode(JSONValue.self, from: try APICoders.encoder.encode(set))
        #expect(obj["status"]?.stringValue == "failed")
        #expect(obj["failure_reason"]?.stringValue == "warping")
        let none = ArchivesLogEntryUpdate(status: "completed", failureReason: nil)
        #expect(String(decoding: try APICoders.encoder.encode(none), as: UTF8.self) == #"{"status":"completed"}"#)
    }

    @Test func decodesPlates() throws {
        let json = #"""
        {"archive_id": 42, "filename": "benchy.gcode.3mf", "is_multi_plate": true, "has_gcode": true,
         "embedded_printer": "Bambu Lab P1S 0.4 nozzle", "embedded_process": null, "design_overrides": [],
         "plates": [
           {"index": 1, "name": "Plate A", "objects": ["Benchy"], "object_count": 1, "has_thumbnail": true,
            "thumbnail_url": "/api/v1/archives/42/plate-thumbnail/1", "print_time_seconds": 3600,
            "filament_used_grams": 14.5, "bed_type": "Textured PEI Plate",
            "filaments": [{"slot_id": 1, "type": "PLA", "color": "#FF0000", "used_grams": 14.5, "used_meters": 4.8, "used_in_plate": true}]},
           {"index": 2, "name": null, "objects": [], "object_count": 0, "has_thumbnail": false,
            "thumbnail_url": null, "print_time_seconds": null, "filament_used_grams": null, "filaments": [], "bed_type": null}
         ]}
        """#
        let p = try decode(ArchivesPlatesInfo.self, json)
        #expect(p.plates?.count == 2)
        #expect(p.plates?.first?.filaments?.first?.usedGrams == 14.5)
        #expect(p.plates?.last?.thumbnailUrl == nil)
        let empty = try decode(ArchivesPlatesInfo.self, #"{"archive_id": 1, "filename": "x.3mf", "plates": [], "is_multi_plate": false}"#)
        #expect(empty.plates?.isEmpty == true)
    }

    @Test func decodesPrintLog() throws {
        let json = #"""
        {"items": [
          {"id": 9, "archive_id": 42, "print_name": "Benchy", "printer_name": "P1S", "printer_id": 1,
           "status": "completed", "started_at": "2026-09-26T10:00:00", "completed_at": "2026-09-26T11:00:00",
           "duration_seconds": 3600, "filament_type": "PLA", "filament_color": "#FF0000", "filament_used_grams": 14.5,
           "cost": 0.43, "energy_kwh": null, "energy_cost": null, "failure_reason": null,
           "thumbnail_path": "archive/thumb.png", "created_by_id": null, "created_by_username": null,
           "created_at": "2026-09-26T11:00:01.000001"},
          {"id": 10, "archive_id": null, "print_name": null, "printer_name": null, "printer_id": null,
           "status": "failed", "started_at": null, "completed_at": null, "duration_seconds": null,
           "filament_type": null, "filament_color": null, "filament_used_grams": null, "cost": null,
           "energy_kwh": null, "energy_cost": null, "failure_reason": "warping", "thumbnail_path": null,
           "created_by_id": 2, "created_by_username": "alice", "created_at": "2026-09-26T12:00:00"}
        ], "total": 2}
        """#
        let page = try decode(ArchivesLogPage.self, json)
        #expect(page.total == 2)
        #expect(page.items[1].failureReason == "warping")
        #expect(page.items[0].colors == ["#FF0000"])
        let empty = try decode(ArchivesLogPage.self, #"{"items":[],"total":0}"#)
        #expect(empty.items.isEmpty)
    }

    @Test func decodesComparison() throws {
        let json = #"""
        {"archives": [
           {"id": 1, "print_name": "A", "status": "completed", "created_at": "2026-09-01T00:00:00", "printer_id": 1, "project_name": null},
           {"id": 2, "print_name": "B", "status": "failed", "created_at": null, "printer_id": null, "project_name": "P"}],
         "comparison": [
           {"field": "layer_height", "label": "Layer Height", "unit": "mm", "values": ["0.2", "0.28"], "raw_values": [0.2, 0.28], "has_difference": true},
           {"field": "filament_type", "label": "Filament", "unit": null, "values": ["PLA", null], "raw_values": ["PLA", null], "has_difference": true}],
         "differences": [
           {"field": "layer_height", "label": "Layer Height", "unit": "mm", "values": ["0.2", "0.28"], "raw_values": [0.2, 0.28], "has_difference": true}],
         "success_correlation": {"has_both_outcomes": true, "successful_count": 1, "failed_count": 1,
           "insights": [
             {"field": "layer_height", "label": "Layer Height", "success_avg": 0.2, "failed_avg": 0.28, "insight": "Successful prints had lower Layer Height"},
             {"field": "filament_type", "label": "Filament", "success_values": ["PLA"], "failed_values": [], "insight": "Different Filament"}]}}
        """#
        let c = try decode(ArchivesComparison.self, json)
        #expect(c.archives.count == 2)
        #expect(c.comparison?.first?.values?.last?.stringValue == "0.28")
        #expect(c.successCorrelation?.insights?.count == 2)
        let noCorr = try decode(ArchivesComparison.Correlation.self, #"{"has_both_outcomes": false, "message": "Need both"}"#)
        #expect(noCorr.hasBothOutcomes == false)
    }

    @Test func decodesSmallResponses() throws {
        let tags = try decode([ArchivesTagCount].self, #"[{"name":"calibration","count":3},{"name":"gift","count":1}]"#)
        #expect(tags.first?.count == 3)
        let impact = try decode(ArchivesDeleteImpact.self, #"{"related_queue_items": 2, "currently_printing": 0}"#)
        #expect(impact.relatedQueueItems == 2)
        let warn = try decode(ArchivesNo3mfWarning.self, #"{"has_fallback": false, "reason": null}"#)
        #expect(warn.hasFallback == false)
        let photo = try decode(ArchivesPhotosResponse.self, #"{"status":"uploaded","filename":"abcd1234.jpg","photos":["abcd1234.jpg"]}"#)
        #expect(photo.photos?.count == 1)
        let deleted = try decode(ArchivesPhotosResponse.self, #"{"status":"deleted","photos":null}"#)
        #expect(deleted.photos == nil)
        let scan = try decode(ArchivesTimelapseScanResult.self, #"""
        {"status":"not_found","message":"No matching timelapse found - please select manually",
         "available_files":[{"name":"video_2026.mp4","path":"/timelapse/video_2026.mp4","size":1024,"mtime":null}]}
        """#)
        #expect(scan.availableFiles?.first?.name == "video_2026.mp4")
        let attached = try decode(ArchivesTimelapseScanResult.self, #"{"status":"exists","message":"Timelapse already attached"}"#)
        #expect(attached.availableFiles == nil)
        let media = try decode(ArchivesPrinterMedia.self, #"""
        {"archive_id": 42, "printer_id": 1, "local_timelapse": {"name": "timelapse.mp4", "size": 2048},
         "remote_files": [{"name":"a.mp4","path":"/timelapse/a.mp4","size":10,"mtime":"2026-09-26T10:00:00","kind":"timelapse"}],
         "warnings": ["ipcam_unavailable"]}
        """#)
        #expect(media.remoteFiles?.first?.kind == "timelapse")
        let info = try decode(ArchivesTimelapseInfo.self, #"{"duration": 12.5, "width": 1920, "height": 1080, "fps": 30, "codec": "h264", "file_size": 123, "has_audio": false}"#)
        #expect(info.width == 1920)
        let similar = try decode([ArchivesSimilar].self, #"[{"archive":{"id":3,"print_name":"B","status":"completed","created_at":null},"match_reason":"Same print name","match_score":100}]"#)
        #expect(similar.first?.id == 3)
    }

    @Test func decodesProjectPage() throws {
        let json = #"""
        {"title": "Benchy", "description": "<p>Hello <b>world</b></p>", "designer": "CreativeTools",
         "designer_user_id": null, "license": "CC-BY", "copyright": null, "creation_date": "2026-01-01",
         "modification_date": null, "origin": "original", "profile_title": null, "profile_description": null,
         "profile_cover": null, "profile_user_id": null, "profile_user_name": null, "design_model_id": "123",
         "design_profile_id": null, "design_region": null,
         "model_pictures": [{"name": "pic.png", "path": "Auxiliaries/Model Pictures/pic.png", "url": "/api/v1/archives/1/project-image/Auxiliaries/Model%20Pictures/pic.png"}],
         "profile_pictures": [], "thumbnails": []}
        """#
        let page = try decode(ArchivesProjectPage.self, json)
        #expect(page.modelPictures?.count == 1)
        #expect(page.license == "CC-BY")
    }

    @Test func decodesPurgeAndUploadAndLookups() throws {
        let preview = try decode(ArchivesPurgePreview.self, #"{"count": 4, "total_bytes": 123456, "sample_filenames": ["a.3mf"], "older_than_days": 90}"#)
        #expect(preview.count == 4)
        let result = try decode(ArchivesPurgeResult.self, #"{"deleted": 4, "purge_stats": false}"#)
        #expect(result.deleted == 4)
        let settings = try decode(ArchivesPurgeSettings.self, #"{"enabled": false, "days": 365, "purge_stats": false}"#)
        #expect(settings.days == 365)
        let body = String(decoding: try APICoders.encoder.encode(ArchivesPurgeRequest(olderThanDays: 30, purgeStats: true)), as: UTF8.self)
        #expect(body.contains("\"older_than_days\":30"))
        let upload = try decode(ArchivesBulkUploadResult.self, #"""
        {"uploaded": 1, "failed": 1, "results": [{"filename": "a.3mf", "id": 5, "status": "archived"}],
         "errors": [{"filename": "b.txt", "error": "Only .3mf files are supported"}]}
        """#)
        #expect(upload.errors?.first?.filename == "b.txt")
        let projects = try decode([ArchivesProjectOption].self, #"""
        [{"id": 1, "name": "Desk", "description": null, "color": "#00ae42", "status": "active", "target_count": null,
          "archive_count": 3, "parent_id": null, "archives": [], "created_at": "2026-01-01T00:00:00"}]
        """#)
        #expect(projects.first?.color == "#00ae42")
        let users = try decode([ArchivesUserOption].self, #"[{"id": 1, "username": "admin"}]"#)
        #expect(users.first?.username == "admin")
        let add = String(decoding: try APICoders.encoder.encode(ArchivesAddToProjectBody(archiveIds: [1, 2])), as: UTF8.self)
        #expect(add == #"{"archive_ids":[1,2]}"#)
    }

    @Test func vocabularyLabels() {
        #expect(ArchivesVocabulary.failureLabel("warping") == "Warping")
        #expect(ArchivesVocabulary.failureLabel("free text") == "free text")
        #expect(ArchivesVocabulary.failureLabel(nil) == nil)
        #expect(ArchivesVocabulary.statusLabel("aborted") == "Cancelled")
        #expect(ArchivesVocabulary.statusLabel("weird_state") == "Weird_State")
    }
}
