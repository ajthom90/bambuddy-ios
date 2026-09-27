import Testing
import Foundation
import UIKit
@testable import Bambuddy

/// General, Costs & Energy, Cameras, Updates and External Links settings pages.
struct SettingsGeneralTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try APICoders.encoder.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any])
    }

    // MARK: General

    @Test func decodesStorageUsage() throws {
        // Real response from GET /system/storage-usage (v1.2.5.5) plus an "other" bucket.
        let json = """
        {"roots":["/app/data/archive","/app/logs"],"total_bytes":946145,"total_formatted":"924.0 KB",
         "categories":[{"key":"database","label":"Database","bytes":856064,"formatted":"836.0 KB","percent_of_total":90.48},
                       {"key":"logs","label":"Logs","bytes":87253,"formatted":"85.2 KB","percent_of_total":9.22},
                       {"key":"archives","label":"Archives","bytes":0,"formatted":"0 B","percent_of_total":0.0}],
         "other_breakdown":[{"bucket":"cache","label":"cache","kind":"system","deletable":false,"bytes":2757,"formatted":"2.7 KB","percent_of_total":0.29}],
         "scan_errors":0,"generated_at":"2026-09-26T19:57:03.803308+00:00",
         "cache":{"hit":false,"age_seconds":0,"max_age_seconds":300}}
        """
        let usage = try decode(SettingsGeneralStorageUsage.self, json)
        #expect(usage.totalBytes == 946145)
        #expect(usage.totalFormatted == "924.0 KB")
        #expect(usage.categories?.count == 3)
        #expect(usage.visibleCategories.map(\.key) == ["database", "logs"])
        #expect(usage.categories?.first?.percentOfTotal == 90.48)
        #expect(usage.otherBreakdown?.first?.kind == "system")
        #expect(usage.otherBreakdown?.first?.deletable == false)
        #expect(usage.cache?.maxAgeSeconds == 300)
        #expect(usage.scanErrors == 0)
    }

    @Test func decodesMiscGeneralResponses() throws {
        let ffmpeg = try decode(SettingsGeneralFfmpegStatus.self, #"{"installed":false,"path":null}"#)
        #expect(ffmpeg.installed == false)
        #expect(ffmpeg.path == nil)
        let installed = try decode(SettingsGeneralFfmpegStatus.self, #"{"installed":true,"path":"/usr/bin/ffmpeg"}"#)
        #expect(installed.path == "/usr/bin/ffmpeg")

        let cleared = try decode(SettingsGeneralClearLogsResult.self, #"{"deleted":3,"message":"Deleted 3 logs older than 30 days"}"#)
        #expect(cleared.deleted == 3)
    }

    @Test func archivePurgeSettingsRoundTrip() throws {
        let settings = try decode(SettingsGeneralArchivePurge.self, #"{"enabled":false,"days":365,"purge_stats":false}"#)
        #expect(settings.days == 365)
        #expect(settings.purgeStats == false)
        let body = try encodedObject(SettingsGeneralArchivePurge(enabled: true, days: 30, purgeStats: true))
        #expect(body["purge_stats"] as? Bool == true)
        #expect(body["days"] as? Int == 30)
        #expect(body["enabled"] as? Bool == true)
    }

    @Test func trashSettingsRoundTrip() throws {
        let json = #"{"retention_days":30,"auto_purge_enabled":false,"auto_purge_days":90,"auto_purge_include_never_printed":true}"#
        let settings = try decode(SettingsGeneralTrashSettings.self, json)
        #expect(settings.retentionDays == 30)
        #expect(settings.autoPurgeDays == 90)
        #expect(settings.autoPurgeIncludeNeverPrinted == true)
        let body = try encodedObject(settings)
        #expect(Set(body.keys) == ["retention_days", "auto_purge_enabled", "auto_purge_days", "auto_purge_include_never_printed"])
    }

    @Test func generalChoices() {
        #expect(SettingsGeneralChoices.clampPurgeDays(1) == 7)
        #expect(SettingsGeneralChoices.clampPurgeDays(90) == 90)
        #expect(SettingsGeneralChoices.clampPurgeDays(99_999) == 3650)
        #expect(SettingsGeneralChoices.languageCodes.contains("pt-BR"))
        let english = SettingsGeneralChoices.languageLabel("en", displayLocale: Locale(identifier: "en_US"))
        #expect(english.hasPrefix("English"))
        let german = SettingsGeneralChoices.languageLabel("de", displayLocale: Locale(identifier: "en_US"))
        #expect(german.contains("German"))
    }

    // MARK: Costs

    @Test func costsHelpers() throws {
        #expect(SettingsCostsCurrencies.codes.count == 32)
        #expect(SettingsCostsCurrencies.symbol(for: "EUR") == "€")
        #expect(SettingsCostsCurrencies.symbol(for: "chf") == "Fr.")
        #expect(SettingsCostsCurrencies.symbol(for: "XYZ") == "XYZ")
        #expect(SettingsCostsCurrencies.label(for: "USD", locale: Locale(identifier: "en_US")).hasPrefix("USD"))

        let result = try decode(SettingsCostsRebuildResult.self,
                                #"{"status":"success","transactions_rebuilt":12,"message":"Rebuilt 12 wallet ledger values"}"#)
        #expect(result.transactionsRebuilt == 12)
        #expect(result.status == "success")
    }

    // MARK: Cameras

    @Test func decodesCameraTestResults() throws {
        let ok = try decode(SettingsCameraTestResult.self, #"{"success":true,"resolution":"1920x1080","coalesced":false}"#)
        #expect(ok.success == true)
        #expect(ok.resolution == "1920x1080")
        let failed = try decode(SettingsCameraTestResult.self, #"{"success":false,"error":"Connection failed: TimeoutError","coalesced":false}"#)
        #expect(failed.success == false)
        #expect(failed.error == "Connection failed: TimeoutError")
    }

    @Test func cameraPatchBodiesUseSnakeCaseAndExplicitNulls() throws {
        func json(_ value: JSONValue) throws -> String { String(decoding: try APICoders.encoder.encode(value), as: UTF8.self) }
        #expect(try json(SettingsCameraPatch.url("  ")) == #"{"external_camera_url":null}"#)
        #expect(try json(SettingsCameraPatch.url(" rtsp://cam/stream ")) == #"{"external_camera_url":"rtsp:\/\/cam\/stream"}"#)
        #expect(try json(SettingsCameraPatch.snapshotURL("")) == #"{"external_camera_snapshot_url":null}"#)
        #expect(try json(SettingsCameraPatch.enabled(true)) == #"{"external_camera_enabled":true}"#)
        #expect(try json(SettingsCameraPatch.type("usb")) == #"{"external_camera_type":"usb"}"#)
        #expect(try json(SettingsCameraPatch.rotation(180)) == #"{"camera_rotation":180}"#)
        #expect(SettingsCameraPatch.supportsSnapshotURL("rtsp"))
        #expect(!SettingsCameraPatch.supportsSnapshotURL("snapshot"))
    }

    // MARK: Updates

    @Test func decodesUpdateResponses() throws {
        let version = try decode(SettingsUpdateVersion.self, #"{"version":"1.2.5.5","repo":"maziggy/bambuddy"}"#)
        #expect(version.version == "1.2.5.5")

        let full = """
        {"update_available":true,"current_version":"1.2.5.5","latest_version":"1.2.5.6","release_name":"v1.2.5.6",
         "release_notes":"**Bambuddy 1.2.5.6**\\r\\n\\r\\n- Fix one","release_url":"https://github.com/maziggy/bambuddy/releases/tag/v1.2.5.6",
         "published_at":"2026-09-20T10:00:00Z","is_docker":true,"is_ha_addon":false,"is_windows_installer":false,
         "update_method":"docker","installer_download_url":null,"compose_dir_detected":"/opt/bambuddy"}
        """
        let check = try decode(SettingsUpdateCheck.self, full)
        #expect(check.updateAvailable == true)
        #expect(check.latestVersion == "1.2.5.6")
        #expect(check.resolvedMethod == "docker")
        #expect(check.composeDirDetected == "/opt/bambuddy")
        #expect(check.installerDownloadUrl == nil)
        #expect(!check.canInstallInApp)

        let git = try decode(SettingsUpdateCheck.self, #"{"update_available":true,"latest_version":"2.0.0","update_method":"git","is_docker":false}"#)
        #expect(git.canInstallInApp)

        let rateLimited = try decode(SettingsUpdateCheck.self,
            #"{"update_available":false,"current_version":"1.2.5.5","latest_version":null,"error":"GitHub rate limit reached; retry later","retry_after_seconds":1800}"#)
        #expect(rateLimited.error != nil)
        #expect(rateLimited.retryAfterSeconds == 1800)

        let disabled = try decode(SettingsUpdateCheck.self,
            #"{"update_available":false,"current_version":"1.2.5.5","latest_version":null,"message":"Update checks are disabled"}"#)
        #expect(disabled.message == "Update checks are disabled")
        #expect(disabled.resolvedMethod == "git")

        let legacy = try decode(SettingsUpdateCheck.self, #"{"update_available":true,"is_ha_addon":true,"is_docker":true}"#)
        #expect(legacy.resolvedMethod == "ha_addon")

        let status = try decode(SettingsUpdateStatus.self, #"{"status":"downloading","progress":40,"message":"Applying updates...","error":null}"#)
        #expect(status.isRunning)
        #expect(status.progress == 40)
        let idle = try decode(SettingsUpdateStatus.self, #"{"status":"idle","progress":100,"message":"Update available","error":null}"#)
        #expect(!idle.isRunning)

        let started = try decode(SettingsUpdateApplyResult.self,
            #"{"success":true,"message":"Update started","status":{"status":"downloading","progress":10,"message":"Starting update...","error":null}}"#)
        #expect(started.success == true)
        #expect(started.status?.progress == 10)
        let refused = try decode(SettingsUpdateApplyResult.self,
            #"{"success":false,"is_docker":true,"message":"Docker installations cannot be updated in-app."}"#)
        #expect(refused.isDocker == true)
        #expect(refused.status == nil)
    }

    @Test func composeCommand() {
        #expect(SettingsUpdateInstructions.composeCommand(savedDirectory: "", detectedDirectory: nil)
                == "docker compose pull && docker compose up -d")
        #expect(SettingsUpdateInstructions.composeCommand(savedDirectory: nil, detectedDirectory: "/opt/bambuddy")
                == "cd /opt/bambuddy && docker compose pull && docker compose up -d")
        #expect(SettingsUpdateInstructions.composeCommand(savedDirectory: " /srv/my stack ", detectedDirectory: "/opt/bambuddy")
                == "cd \"/srv/my stack\" && docker compose pull && docker compose up -d")
    }

    @Test func decodesFirmware() throws {
        let json = """
        {"updates":[{"printer_id":1,"printer_name":"Office Printer","model":"P1S","current_version":"01.09.01.00",
          "latest_version":"01.10.00.00","update_available":true,"download_url":"https://public-cdn.bblmw.com/x.zip",
          "release_notes":"# Version 01.10.00.00\\n## New Features:\\n1. Thing","available_versions":[
            {"version":"01.10.00.00","file_available":true,"download_url":"https://public-cdn.bblmw.com/x.zip","release_notes":null,"release_time":"2026-03-30"},
            {"version":"01.09.01.00","file_available":false,"download_url":null,"release_notes":null,"release_time":null}]},
          {"printer_id":2,"printer_name":"Garage","model":null,"current_version":null,"latest_version":null,"update_available":false,
           "download_url":null,"release_notes":null,"available_versions":[]}],
         "updates_available":1}
        """
        let updates = try decode(SettingsFirmwareUpdates.self, json)
        #expect(updates.updatesAvailable == 1)
        #expect(updates.updates?.count == 2)
        #expect(updates.updates?.first?.availableVersions?.first?.fileAvailable == true)
        #expect(updates.updates?.last?.currentVersion == nil)

        let latest = try decode([SettingsFirmwareLatest].self, """
        [{"model_key":"x1","version":"01.12.00.00","download_url":"https://public-cdn.bblmw.com/a.zip","release_notes":"# Version 01.12.00.00"},
         {"model_key":"a1-mini","version":"01.07.00.00","download_url":"https://public-cdn.bblmw.com/b.zip","release_notes":null},
         {"model_key":"h2d-pro","version":"01.00.00.00","download_url":"https://public-cdn.bblmw.com/c.zip"}]
        """)
        #expect(latest.map(\.familyName) == ["X1 Series", "A1 mini", "H2D Pro"])
        #expect(latest[1].releaseNotes == nil)
    }

    @Test func splitsReleaseNotesMarkdown() {
        let md = "# Version 01.10\r\n## New Features:\r\n1. External spool\r\n2. **Drying** presets\r\n\r\nSome text\r\ncontinued\r\n- bullet\r\n  - nested\r\n---\r\n"
        let blocks = SettingsUpdateMarkdown.blocks(from: md)
        #expect(blocks == [
            .heading(level: 1, text: "Version 01.10"),
            .heading(level: 2, text: "New Features:"),
            .numbered(marker: "1.", text: "External spool", indent: 0),
            .numbered(marker: "2.", text: "**Drying** presets", indent: 0),
            .paragraph("Some text continued"),
            .bullet(text: "bullet", indent: 0),
            .bullet(text: "nested", indent: 1),
            .rule,
        ])
        #expect(String(SettingsUpdateMarkdown.inline("**Bold** text").characters) == "Bold text")
    }

    // MARK: External links

    @Test func decodesExternalLinks() throws {
        let json = """
        [{"name":"Wiki","url":"https://wiki.example.com","icon":"book","open_in_new_tab":false,"id":1,"custom_icon":null,
          "sort_order":0,"created_at":"2026-01-05T10:00:00","updated_at":"2026-01-05T10:00:00"},
         {"name":"Shop","url":"http://shop.local","icon":"shopping-cart","open_in_new_tab":true,"id":4,
          "custom_icon":"3f2a9c0d1e.png","sort_order":1,"created_at":"2026-01-06T10:00:00","updated_at":"2026-01-07T08:30:00"}]
        """
        let links = try decode([SettingsExternalLink].self, json)
        #expect(links.count == 2)
        #expect(links[0].customIconPath == nil)
        #expect(links[1].customIconPath == "external-links/4/icon")
        #expect(links[1].openInNewTab == true)
        #expect(SettingsExternalLinkIcons.symbol(for: links[1].icon) == "cart")
        #expect(SettingsExternalLinkIcons.symbol(for: "unknown") == "link")
        #expect(SettingsExternalLinkIcons.all.count == 30)
    }

    @Test func externalLinkBodies() throws {
        let body = try encodedObject(SettingsExternalLinkBody(name: "Wiki", url: "https://wiki", icon: "book", openInNewTab: true))
        #expect(Set(body.keys) == ["name", "url", "icon", "open_in_new_tab"])
        #expect(body["open_in_new_tab"] as? Bool == true)
        let reorder = try encodedObject(SettingsExternalLinkReorder(ids: [3, 1, 2]))
        #expect(reorder["ids"] as? [Int] == [3, 1, 2])
    }

    @Test func externalLinkValidation() {
        #expect(SettingsExternalLinkIcons.isValidURL("https://example.com"))
        #expect(!SettingsExternalLinkIcons.isValidURL("https://"))
        #expect(!SettingsExternalLinkIcons.isValidURL("ftp://example.com"))
        #expect(SettingsExternalLinkIcons.isValidName("Wiki"))
        #expect(!SettingsExternalLinkIcons.isValidName("   "))
        #expect(!SettingsExternalLinkIcons.isValidName(String(repeating: "a", count: 51)))
    }

    @Test func iconUploadPreparation() throws {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)
        let upload = try SettingsExternalLinkUpload.make(data: svg, fileExtension: "SVG")
        #expect(upload.fileName == "icon.svg")
        #expect(upload.mimeType == "image/svg+xml")

        let jpeg = try SettingsExternalLinkUpload.make(data: Data([0xFF, 0xD8]), fileExtension: "jpeg")
        #expect(jpeg.fileName == "icon.jpg")

        // Formats the server rejects are converted to PNG when they decode as an image.
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        let heicLike = try #require(image.jpegData(compressionQuality: 0.8))
        let converted = try SettingsExternalLinkUpload.make(data: heicLike, fileExtension: "heic")
        #expect(converted.fileName == "icon.png")
        #expect(UIImage(data: converted.data)?.size.width == 256)

        #expect(throws: (any Error).self) { try SettingsExternalLinkUpload.make(data: Data("nope".utf8), fileExtension: "bmp") }
    }
}
