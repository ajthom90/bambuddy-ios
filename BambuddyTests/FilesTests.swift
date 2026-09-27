import Testing
import Foundation
@testable import Bambuddy

/// Decoding tests for the Files (library) and MakerWorld models, using payload
/// shapes taken from the backend route code, Pydantic schemas and web mocks.
struct FilesTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Folders

    @Test func decodesFolderTree() throws {
        let json = """
        [{"id":1,"name":"Functional","parent_id":null,"project_id":3,"archive_id":null,"project_name":"Garage",
          "archive_name":null,"is_external":false,"external_path":null,"external_readonly":false,"file_count":4,
          "latest_activity_at":"2026-09-20T10:11:12.123456","children":[
            {"id":2,"name":"Brackets","parent_id":1,"project_id":null,"archive_id":null,"project_name":null,"archive_name":null,
             "is_external":false,"external_path":null,"external_readonly":false,"file_count":0,"latest_activity_at":null,"children":[]}]},
         {"id":7,"name":"NAS","parent_id":null,"is_external":true,"external_path":"/mnt/nas","external_readonly":true,"file_count":120,"children":[]}]
        """
        let tree = try decode([LibraryFolderNode].self, json)
        #expect(tree.count == 2)
        #expect(tree[0].linkDescription == "Project: Garage")
        #expect(tree[0].subfolders.first?.name == "Brackets")
        #expect(tree[1].readOnly)
        #expect(LibraryFolderTree.find(2, in: tree)?.parentId == 1)
        #expect(LibraryFolderTree.path(to: 2, in: tree).map(\.id) == [1, 2])
        #expect(LibraryFolderTree.descendantIds(of: 1, in: tree) == [1, 2])
        #expect(LibraryFolderTree.flatten(tree).map(\.depth) == [0, 1, 0])
    }

    @Test func decodesFolderResponseAndReadme() throws {
        let folder = try decode(LibraryFolderInfo.self, """
        {"id":5,"name":"New","parent_id":null,"project_id":null,"archive_id":null,"project_name":null,"archive_name":null,
         "is_external":true,"external_path":"/data/x","external_readonly":true,"external_show_hidden":false,"file_count":0,
         "latest_activity_at":null,"created_at":"2026-09-26T12:00:00","updated_at":"2026-09-26T12:00:00"}
        """)
        #expect(folder.id == 5 && folder.externalShowHidden == false)
        let readme = try decode(LibraryFolderReadme.self, ##"{"filename":"README.md","content":"# Hi","truncated":false}"##)
        #expect(readme.content == "# Hi")
        let scan = try decode(LibraryScanResult.self, #"{"status":"success","added":3,"removed":1}"#)
        #expect(scan.added == 3)
    }

    // MARK: Files

    @Test func decodesFileList() throws {
        let json = """
        [{"id":11,"folder_id":1,"is_external":false,"filename":"Benchy.gcode.3mf","file_type":"gcode.3mf","file_size":2048576,
          "thumbnail_path":"/data/thumbs/abc.png","print_count":2,"duplicate_count":0,"created_by_id":null,"created_by_username":null,
          "created_at":"2026-09-01T08:00:00","fs_modified_at":null,"print_name":"3DBenchy","print_time_seconds":3120,
          "filament_used_grams":12.34,"sliced_for_model":"P1S","tags":[{"id":1,"name":"test"}],"variant_group_id":null,"variant_count":0},
         {"id":12,"folder_id":null,"filename":"bracket.stl","file_type":"stl","file_size":1000,"thumbnail_path":null,"print_count":0,
          "created_at":"2026-09-02T08:00:00Z","print_time_seconds":null,"filament_used_grams":null,"sliced_for_model":null}]
        """
        let files = try decode([LibraryFileSummary].self, json)
        #expect(files[0].displayName == "3DBenchy")
        #expect(files[0].isSliced)
        #expect(files[0].tags?.first?.name == "test")
        #expect(files[0].printTimeSeconds == 3120)
        #expect(!files[1].isSliced)
        #expect(LibraryFileKind.isSliceable(filename: files[1].filename, fileType: files[1].fileType))
        #expect(files[1].displayName == "bracket.stl")
    }

    @Test func decodesFileDetail() throws {
        let json = """
        {"id":11,"folder_id":1,"folder_name":"Functional","project_id":null,"project_name":null,"is_external":false,
         "filename":"Benchy.3mf","file_path":"library/files/abc.3mf","file_type":"gcode.3mf","file_size":2048576,
         "file_hash":"deadbeefcafebabe0123","thumbnail_path":"x.png",
         "metadata":{"print_time_seconds":3120.0,"filament_used_grams":12.3,"layer_height":0.2,"nozzle_diameter":0.4,
                     "filament_type":"PLA","filament_color":"#FFFFFF;#000000","printable_objects":{"1":"Benchy"},
                     "makerworld_url":"https://makerworld.com/models/1","filament_slots":[{"slot":1}]},
         "print_count":0,"last_printed_at":null,"notes":null,
         "duplicates":[{"id":20,"filename":"Benchy (1).3mf","folder_id":null,"folder_name":null,"created_at":"2026-09-02T00:00:00"}],
         "duplicate_count":1,"created_by_id":1,"created_by_username":"aj","created_at":"2026-09-01T08:00:00",
         "updated_at":"2026-09-01T08:00:00","print_name":null,"print_time_seconds":3120,"filament_used_grams":12.3,"sliced_for_model":null}
        """
        let file = try decode(LibraryFileDetail.self, json)
        #expect(file.isSliced)
        #expect(file.metadata?["filament_type"]?.stringValue == "PLA")
        #expect(file.metadata?["makerworld_url"]?.stringValue == "https://makerworld.com/models/1")
        #expect(file.duplicates?.first?.id == 20)
        #expect(file.displayName == "Benchy.3mf")
        let minimal = try decode(LibraryFileDetail.self, #"{"id":1,"folder_id":null,"project_id":null,"filename":"a.gcode","file_path":"p","file_type":"gcode","file_size":1,"file_hash":null,"thumbnail_path":null,"metadata":null,"print_count":0,"last_printed_at":null,"notes":null,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}"#)
        #expect(minimal.metadata == nil)
    }

    @Test func classifiesFileNames() {
        #expect(LibraryFileKind.type(of: "a.GCODE.3mf") == "gcode.3mf")
        #expect(LibraryFileKind.type(of: "model.stl") == "stl")
        #expect(LibraryFileKind.isSliced(filename: "Foo.3mf", fileType: "gcode.3mf"))
        #expect(!LibraryFileKind.isSliceable(filename: "Foo.gcode.3mf", fileType: nil))
        #expect(!LibraryFileKind.isSliceable(filename: "Foo.step", fileType: "step"))
        #expect(LibraryFileKind.splitExtension("Robot.gcode.3mf") == ("Robot", ".gcode.3mf"))
        #expect(LibraryFileKind.splitExtension("notes") == ("notes", ""))
        #expect(LibraryFileKind.invalidCharacter(in: "a:b") == ":")
        #expect(LibraryFileKind.invalidCharacter(in: "fine name") == nil)
        #expect(LibraryFileKind.isMesh(filename: "x.STL"))
    }

    @Test func decodesPlatesAndFilaments() throws {
        let plates = try decode(LibraryPlatesResponse.self, """
        {"file_id":11,"filename":"Benchy.3mf","plates":[
          {"index":1,"name":"Hull","objects":["Benchy"],"object_count":1,"has_thumbnail":true,
           "thumbnail_url":"/api/v1/library/files/11/plate-thumbnail/1","print_time_seconds":3120,"filament_used_grams":12.3,
           "filaments":[{"slot_id":1,"type":"PLA","color":"#FFFFFFFF","used_grams":12.3,"used_meters":4.1}]},
          {"index":2,"name":null,"objects":[],"object_count":0,"has_thumbnail":false,"thumbnail_url":null,
           "print_time_seconds":null,"filament_used_grams":null,"filaments":[]}],
         "is_multi_plate":true,"embedded_printer":"Bambu Lab P1S 0.4 nozzle","embedded_process":null,
         "design_overrides":[{"key":"wall_loops","value":"3"}]}
        """)
        #expect(plates.plates?.count == 2)
        #expect(plates.plates?[0].filaments?.first?.slotId == 1)
        #expect(plates.embeddedPrinter == "Bambu Lab P1S 0.4 nozzle")
        let empty = try decode(LibraryPlatesResponse.self, #"{"file_id":3,"filename":"a.stl","plates":[],"is_multi_plate":false}"#)
        #expect(empty.plates?.isEmpty == true)
        let reqs = try decode(LibraryFilamentRequirements.self, """
        {"file_id":11,"filename":"Benchy.3mf","plate_id":null,"filaments":[{"slot_id":2,"type":"PETG","color":"#000000","used_grams":1.5,"used_meters":0.5,"used_in_plate":false}]}
        """)
        #expect(reqs.filaments?.first?.usedInPlate == false)
    }

    @Test func decodesStats() throws {
        let stats = try decode(LibraryStats.self, """
        {"total_files":0,"total_folders":0,"total_size_bytes":0,"files_by_type":{"gcode.3mf":2,"stl":1},"total_prints":0,
         "disk_free_bytes":10558607720448,"disk_total_bytes":10558608244736,"disk_used_bytes":524288}
        """)
        #expect(stats.diskFreeBytes == 10558607720448)
        #expect(stats.filesByType?["gcode.3mf"]?.intValue == 2)
    }

    // MARK: Tags, uploads, bulk

    @Test func decodesTagsAndUploads() throws {
        let tags = try decode([LibraryTag].self, #"[{"id":1,"name":"PLA","file_count":3,"created_at":"2026-09-01T00:00:00","updated_at":"2026-09-01T00:00:00"}]"#)
        #expect(tags.first?.fileCount == 3)
        let assign = try decode(LibraryTagAssignResult.self, #"{"files_updated":2,"associations_added":2,"associations_removed":0}"#)
        #expect(assign.filesUpdated == 2)
        let upload = try decode(LibraryUploadResult.self, #"{"id":9,"filename":"a.3mf","file_type":"3mf","file_size":10,"thumbnail_path":null,"duplicate_of":4,"metadata":{"print_name":"A"}}"#)
        #expect(upload.duplicateOf == 4)
        let zip = try decode(LibraryZipResult.self, #"{"extracted":2,"folders_created":1,"files":[{"filename":"a.stl","file_id":3,"folder_id":8},{"filename":"b.stl","file_id":4}],"errors":[{"filename":"c.txt","error":"bad"}]}"#)
        #expect(zip.files?.count == 2 && zip.errors?.first?.error == "bad")
        let queue = try decode(LibraryQueueAddResult.self, #"{"added":[{"file_id":1,"filename":"a.gcode","queue_item_id":5}],"errors":[{"file_id":2,"filename":"b.stl","error":"Not a sliced file."}]}"#)
        #expect(queue.added?.first?.queueItemId == 5)
        let thumbs = try decode(LibraryThumbnailBatchResult.self, #"{"processed":1,"succeeded":0,"failed":1,"results":[{"file_id":1,"filename":"a.stl","success":false,"error":"boom"}]}"#)
        #expect(thumbs.results?.first?.error == "boom")
        let bulk = try decode(LibraryBulkDeleteResult.self, #"{"deleted_files":3,"deleted_folders":0}"#)
        #expect(bulk.deletedFiles == 3)
        let move = try decode(LibraryMoveResult.self, #"{"status":"success","moved":2,"skipped":[],"skipped_reasons":{}}"#)
        #expect(move.moved == 2)
        let del = try decode(LibraryDeleteFileResult.self, #"{"status":"success","message":"File moved to trash","trashed":true}"#)
        #expect(del.trashed == true)
    }

    @Test func decodesVariantGroup() throws {
        let group = try decode(LibraryVariantGroup.self, """
        {"id":3,"name":null,"members":[{"library_file_id":1,"filename":"a_P1S.gcode.3mf","target_model":"P1S","position":0},
                                       {"library_file_id":2,"filename":"a_H2D.gcode.3mf","target_model":"H2D","position":1}]}
        """)
        #expect(group.members?.map(\.id) == [1, 2])
    }

    // MARK: Trash & purge

    @Test func decodesTrashAndPurge() throws {
        let page = try decode(LibraryTrashPage.self, """
        {"items":[{"id":4,"filename":"old.3mf","file_size":100,"thumbnail_path":null,"folder_id":null,"folder_name":null,
                   "created_by_id":null,"created_by_username":null,"deleted_at":"2026-09-20T00:00:00","auto_purge_at":"2026-10-20T00:00:00"}],
         "total":1,"retention_days":30}
        """)
        #expect(page.items.first?.autoPurgeAt != nil)
        #expect(try decode(LibraryTrashPage.self, #"{"items":[],"total":0,"retention_days":30}"#).items.isEmpty)
        let settings = try decode(LibraryTrashSettings.self, #"{"retention_days":30,"auto_purge_enabled":false,"auto_purge_days":90,"auto_purge_include_never_printed":true}"#)
        #expect(settings.autoPurgeDays == 90)
        let encoded = try JSONValue.from(settings)
        #expect(encoded["retention_days"]?.intValue == 30)
        let preview = try decode(LibraryPurgePreview.self, #"{"count":2,"total_bytes":2048,"sample_filenames":["a.3mf","b.stl"],"older_than_days":90,"include_never_printed":true}"#)
        #expect(preview.sampleFilenames?.count == 2)
        #expect(try decode(LibraryPurgeResult.self, #"{"moved_to_trash":2}"#).movedToTrash == 2)
        #expect(try decode(LibraryEmptyTrashResult.self, #"{"deleted":5}"#).deleted == 5)
    }

    // MARK: Slicing

    @Test func decodesSlicerPresetsAndJobs() throws {
        let catalog = try decode(LibrarySlicerPresetCatalog.self, """
        {"orca_cloud":{"printer":[],"process":[],"filament":[]},
         "cloud":{"printer":[{"id":"GP004","name":"Bambu Lab P1S 0.4 nozzle","source":"cloud"}],"process":[],"filament":[]},
         "local":{"printer":[],"process":[{"id":"12","name":"0.20mm Standard","source":"local","compatible_printers":["Bambu Lab P1S 0.4 nozzle"]}],
                  "filament":[{"id":"13","name":"Generic PLA","source":"local","filament_type":"PLA","filament_colour":"#FFFFFF","compatible_printers":null}]},
         "standard":{"printer":[],"process":[],"filament":[]},
         "cloud_status":"ok","orca_cloud_status":"not_authenticated"}
        """)
        #expect(catalog.printers.first?.key == "cloud:GP004")
        #expect(catalog.processes.first?.compatiblePrinters?.first == "Bambu Lab P1S 0.4 nozzle")
        #expect(catalog.filaments.first?.filamentType == "PLA")

        let enqueued = try decode(LibrarySliceEnqueued.self, #"{"job_id":7,"status":"pending","status_url":"/api/v1/slice-jobs/7"}"#)
        #expect(enqueued.jobId == 7)
        let running = try decode(LibrarySliceJob.self, """
        {"job_id":7,"status":"running","kind":"library_file","source_id":11,"source_name":"a.stl","created_at":"2026-09-26T10:00:00+00:00",
         "started_at":"2026-09-26T10:00:01+00:00","completed_at":null,
         "progress":{"stage":"Generating G-code","total_percent":45,"plate_percent":45,"plate_index":1,"plate_count":1,"updated_at":1790000000.5}}
        """)
        #expect(running.progress?.totalPercent == 45)
        #expect(!running.isFinished)
        let done = try decode(LibrarySliceJob.self, """
        {"job_id":7,"status":"completed","kind":"library_file","source_id":11,"source_name":"a.stl","created_at":"x","started_at":null,"completed_at":null,"progress":null,
         "result":{"library_file_id":42,"name":"a.gcode.3mf","print_time_seconds":600,"filament_used_g":3.2,"filament_used_mm":1000.0,"used_embedded_settings":false,"external_write_fallback":null}}
        """)
        #expect(done.resultFileId == 42)
        let failed = try decode(LibrarySliceJob.self, #"{"job_id":8,"status":"failed","kind":"library_file","source_id":1,"source_name":"b","created_at":"x","started_at":null,"completed_at":null,"progress":null,"error_status":400,"error_detail":"bad preset"}"#)
        #expect(failed.errorDetail == "bad preset" && failed.isFinished)
    }

    @Test func encodesSliceAndMoveBodies() throws {
        let ref = LibraryPresetRefBody(source: "cloud", id: "GP004")
        let body = LibrarySliceBody(printerPreset: ref, processPreset: ref, filamentPreset: ref, filamentPresets: [ref],
                                    filamentColours: nil, plate: 0, bedType: nil, useEmbeddedSettings: nil, autoOrient: true, autoArrange: nil)
        let json = try JSONValue.from(body)
        #expect(json["printer_preset"]?["source"]?.stringValue == "cloud")
        #expect(json["filament_presets"]?.arrayValue?.count == 1)
        #expect(json["plate"]?.intValue == 0)
        #expect(json["auto_orient"]?.boolValue == true)
        #expect(json["bed_type"] == nil)

        let move = try JSONValue.from(LibraryFileMoveBody(fileIds: [1, 2], folderId: nil))
        #expect(move["folder_id"]?.isNull == true)
        #expect(move["file_ids"]?.arrayValue?.count == 2)

        let update = try JSONValue.from(LibraryFolderUpdateBody(parentId: 0))
        #expect(update["parent_id"]?.intValue == 0)
        #expect(update["name"] == nil)
    }

    @Test func decodesServerSettingsAndPickers() throws {
        let settings = try decode(LibraryServerSettings.self, #"{"use_slicer_api":false,"library_disk_warning_gb":5.0,"preferred_slicer":"bambu_studio","other":1}"#)
        #expect(settings.useSlicerApi == false)
        let projects = try decode([LibraryProjectOption].self, ##"[{"id":1,"name":"Garage","description":null,"color":"#00AE42","status":"active","target_count":null}]"##)
        #expect(projects.first?.status == "active")
        let archives = try decode([LibraryArchiveOption].self, #"[{"id":3,"print_name":null,"filename":"x.gcode.3mf","status":"completed"}]"#)
        #expect(archives.first?.displayName == "x.gcode.3mf")
    }

    // MARK: MakerWorld

    @Test func decodesMakerWorldResolve() throws {
        let json = """
        {"model_id":1400373,"profile_id":1452154,
         "design":{"id":1400373,"title":"Seed Starter","designCreator":{"name":"Meyui","avatar":""},
                   "coverUrl":"https://makerworld.bblmw.com/img/cover.png","license":"Standard","downloadCount":1234,
                   "summary":"<p>A seed <b>starter</b></p><img src='x.png'>","tags":["garden","seed"]},
         "instances":[{"id":1452154,"profileId":298919107,"title":"9 cells","cover":"","materialCnt":1,"needAms":false,"downloadCount":500,
                       "compatibility":{"devProductName":"A1"},"otherCompatibility":[{"devProductName":"P1S"},{"devProductName":"X1C"}],
                       "pictures":[{"name":"a","url":"https://makerworld.bblmw.com/a.png"},{"name":"b","url":""}]},
                      {"id":1452158,"profileId":298919564,"title":"12 cells","cover":"https://makerworld.bblmw.com/c.png","materialCnt":2,
                       "needAms":true,"downloadCount":120,"compatibility":null,"otherCompatibility":null},
                      {"title":"broken, no id"}],
         "already_imported_library_ids":[5]}
        """
        let model = try decode(MakerWorldResolvedModel.self, json)
        #expect(model.title == "Seed Starter")
        #expect(model.creatorName == "Meyui")
        #expect(model.tags == ["garden", "seed"])
        #expect(model.plates.count == 2)
        #expect(model.plates[0].primaryPrinter == "A1")
        #expect(model.plates[0].otherPrinters == ["P1S", "X1C"])
        #expect(model.plates[0].pictures.count == 1)
        #expect(model.plates[0].cover == nil)
        #expect(model.plates[1].needsAMS)
        #expect(model.plates[1].pictures.first?.name == "cover")
        #expect(model.webURL?.absoluteString == "https://makerworld.com/models/1400373#profileId-1452154")
        #expect(model.alreadyImportedLibraryIds == [5])
    }

    @Test func decodesMakerWorldStatusImportAndRecent() throws {
        let status = try decode(MakerWorldStatus.self, #"{"has_cloud_token":true,"can_download":true,"sign_in_expired":false}"#)
        #expect(status.canDownload == true)
        let result = try decode(MakerWorldImportResult.self, #"{"library_file_id":9,"filename":"Seed.3mf","folder_id":2,"profile_id":298919107,"was_existing":false}"#)
        #expect(result.libraryFileId == 9)
        let recent = try decode([MakerWorldRecentImport].self, #"[{"library_file_id":9,"filename":"Seed.3mf","folder_id":null,"thumbnail_path":null,"source_url":"https://makerworld.com/models/1#profileId-2","created_at":"2026-09-26T10:00:00"}]"#)
        #expect(recent.first?.sourceUrl?.contains("profileId-2") == true)
        let body = try JSONValue.from(MakerWorldImportBody(modelId: 1, profileId: 2, instanceId: 3, folderId: nil))
        #expect(body["model_id"]?.intValue == 1)
        #expect(body["instance_id"]?.intValue == 3)
    }

    @MainActor
    @Test func makerWorldHelpers() {
        let client = APIClient(baseURL: URL(string: "https://example.com")!)
        let proxied = MakerWorldMedia.proxied("https://makerworld.bblmw.com/img/a.png", client: client)
        #expect(proxied?.hasPrefix("https://example.com/api/v1/makerworld/thumbnail?url=https%3A%2F%2Fmakerworld.bblmw.com") == true)
        #expect(MakerWorldMedia.proxied("https://other.com/a.png", client: client) == "https://other.com/a.png")
        #expect(MakerWorldMedia.proxied("", client: client) == nil)
        let text = MakerWorldMedia.plainText(fromHTML: "<p>Hello <b>world</b></p><img src='https://x/y.png'>")
        #expect(text.contains("Hello world"))
        #expect(MakerWorldMedia.looksLikeModelURL("https://makerworld.com/en/models/1400373-slug#profileId-1"))
    }

    // MARK: Upload body

    @Test func buildsMultipartBody() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("files-test-\(UUID().uuidString).stl")
        try Data("solid x\nendsolid x\n".utf8).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }
        let body = try LibraryUploader.makeBody(file: src, fileName: "My \"part\".stl", boundary: "B")
        defer { try? FileManager.default.removeItem(at: body) }
        let text = try String(contentsOf: body, encoding: .utf8)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"My 'part'.stl\"\r\n"))
        #expect(text.contains("solid x\nendsolid x\n"))
        #expect(text.hasSuffix("\r\n--B--\r\n"))
    }
}
