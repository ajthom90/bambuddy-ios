import Foundation
import Testing
@testable import Bambuddy

/// Decoding and encoding tests for the Virtual Printers, Failure Detection (Obico) and
/// SpoolBuddy settings pages.
struct SettingsVirtualPrintersTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APICoders.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try APICoders.encoder.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Virtual printers

    @Test func decodesEmptyLiveList() throws {
        let json = #"{"printers":[],"models":{"BL-P001":"X1C","BL-P002":"X1","C13":"X1E","N2S":"A1","N1":"A1 Mini","O1C2":"H2C"}}"#
        let list = try decode(SettingsVirtualPrinterList.self, json)
        #expect(list.printers?.isEmpty == true)
        // Dictionary keys must stay verbatim (not snake-case converted).
        #expect(list.models?["BL-P001"] == "X1C")
        #expect(list.models?["O1C2"] == "H2C")
        #expect(list.models?["N1"] == "A1 Mini")
    }

    @Test func decodesVirtualPrintersIncludingProxyStatus() throws {
        let json = """
        {"printers":[
          {"id":1,"name":"Bambuddy","enabled":true,"mode":"queue","model":"BL-P001","model_name":"X1C",
           "access_code_set":true,"serial":"01S00C391800001","target_printer_id":null,"auto_dispatch":true,
           "queue_force_color_match":false,"save_ams_mapping":true,"gcode_injection":false,"bind_ip":"192.168.1.50",
           "remote_interface_ip":null,"tailscale_disabled":true,"position":1,
           "status":{"running":true,"pending_files":2}},
          {"id":2,"name":"Relay","enabled":true,"mode":"proxy","model":"C12","model_name":"P1S",
           "access_code_set":false,"serial":"01P00A123456789","target_printer_id":3,"auto_dispatch":true,
           "queue_force_color_match":false,"save_ams_mapping":false,"gcode_injection":false,"bind_ip":"10.0.0.5",
           "remote_interface_ip":"192.168.2.10","tailscale_disabled":false,"position":2,
           "status":{"running":true,"pending_files":0,"proxy":{"running":true,"target_host":"192.168.1.20",
             "ftp_port":990,"mqtt_port":8883,"bind_ports":[3000,3002],"ftp_connections":1,"mqtt_connections":2,
             "bind_connections":0}}},
          {"id":3,"name":"Old","enabled":false,"mode":"immediate","model":"BL-P001","model_name":"X1C",
           "access_code_set":false,"serial":"x","target_printer_id":null,"auto_dispatch":true,
           "queue_force_color_match":false,"save_ams_mapping":false,"gcode_injection":false,"bind_ip":null,
           "remote_interface_ip":null,"tailscale_disabled":true,"position":3,"status":{"running":false,"pending_files":0}}
        ],"models":{"BL-P001":"X1C"}}
        """
        let list = try decode(SettingsVirtualPrinterList.self, json)
        let printers = try #require(list.printers)
        #expect(printers.count == 3)
        let queue = printers[0]
        #expect(queue.modeKind == .queue)
        #expect(queue.accessCodeSet == true)
        #expect(queue.saveAmsMapping == true)
        #expect(queue.bindIp == "192.168.1.50")
        #expect(queue.status?.pendingFiles == 2)
        #expect(queue.isRunning)
        let proxy = printers[1]
        #expect(proxy.modeKind == .proxy)
        #expect(proxy.targetPrinterId == 3)
        #expect(proxy.remoteInterfaceIp == "192.168.2.10")
        #expect(proxy.tailscaleDisabled == false)
        #expect(proxy.status?.proxy?.targetHost == "192.168.1.20")
        #expect(proxy.status?.proxy?.bindPorts == [3000, 3002])
        #expect(proxy.status?.proxy?.mqttConnections == 2)
        #expect(printers[2].modeKind == .archive)
        #expect(printers[2].bindIp == nil)
    }

    @Test func normalizesLegacyModes() {
        #expect(SettingsVPMode.normalized("immediate") == .archive)
        #expect(SettingsVPMode.normalized("print_queue") == .queue)
        #expect(SettingsVPMode.normalized("review") == .review)
        #expect(SettingsVPMode.normalized("proxy") == .proxy)
        #expect(SettingsVPMode.normalized(nil) == .archive)
        #expect(SettingsVPMode.normalized("something_new") == .archive)
    }

    @Test func decodesNetworkInterfacesTailscaleAndCertificate() throws {
        let ifaces = try decode(SettingsVPNetworkInterfaces.self,
            #"{"interfaces":[{"name":"eth0","ip":"172.16.22.2","netmask":"255.255.255.0","subnet":"172.16.22.0/24","is_alias":false,"label":"eth0"},{"name":"eth0","ip":"172.16.22.3","netmask":"255.255.255.0","subnet":"172.16.22.0/24","is_alias":true,"label":"eth0:1"},{"name":"wlan0","ip":"10.0.0.2","netmask":"255.0.0.0","subnet":"10.0.0.0/8"}]}"#)
        #expect(ifaces.interfaces?.count == 3)
        #expect(ifaces.interfaces?[1].isAlias == true)
        #expect(ifaces.interfaces?[2].isAlias == nil)
        #expect(ifaces.interfaces?[1].menuLabel.contains("alias") == true)

        let ts = try decode(SettingsVPTailscaleStatus.self,
            #"{"available":false,"fqdn":"","hostname":"","tailnet_name":"","tailscale_ips":[],"error":"failed to connect to local tailscaled; it doesn't appear to be running"}"#)
        #expect(ts.available == false)
        #expect(ts.error?.hasPrefix("failed") == true)
        let ts2 = try decode(SettingsVPTailscaleStatus.self,
            #"{"available":true,"fqdn":"host.tail1234.ts.net","hostname":"host","tailnet_name":"tail1234.ts.net","tailscale_ips":["100.64.0.1","fd7a::1"],"error":null}"#)
        #expect(ts2.tailnetName == "tail1234.ts.net")
        #expect(ts2.tailscaleIps?.first == "100.64.0.1")

        let cert = try decode(SettingsVPCACertificate.self,
            #"{"pem":"-----BEGIN CERTIFICATE-----\nMIIC\n-----END CERTIFICATE-----\n","fingerprint_sha256":"DC:2A:36:89","not_valid_after":"2046-09-21T19:55:34+00:00"}"#)
        #expect(cert.fingerprintSha256 == "DC:2A:36:89")
        #expect(cert.pem?.hasPrefix("-----BEGIN CERTIFICATE-----") == true)
        #expect(APICoders.parseDate(cert.notValidAfter ?? "") != nil)
    }

    @Test func decodesDiagnosticResult() throws {
        let json = """
        {"vp_id":2,"vp_name":"Relay","mode":"archive","overall":"problems","checks":[
          {"id":"enabled","status":"pass","params":{}},
          {"id":"running","status":"pass","params":{}},
          {"id":"bind_interface","status":"fail","params":{"bind_ip":"192.168.1.50"}},
          {"id":"access_code","status":"pass","params":{}},
          {"id":"target_printer","status":"skip","params":{}},
          {"id":"port_ftps","status":"fail","params":{"port":990}},
          {"id":"port_mqtt","status":"pass","params":{"port":8883}},
          {"id":"port_bind","status":"fail","params":{"port":3002,"port_plain":3000}},
          {"id":"privileged_ports","status":"fail","params":{"port":990}},
          {"id":"certificate","status":"pass","params":{}}
        ]}
        """
        let result = try decode(SettingsVPDiagnosticResult.self, json)
        #expect(result.vpId == 2)
        #expect(result.overall == "problems")
        let checks = try #require(result.checks)
        #expect(checks.count == 10)
        #expect(checks[2].params?.bindIp == "192.168.1.50")
        #expect(checks[7].params?.portPlain == 3000)
        #expect(SettingsVPDiagnosticText.title(checks[7]).contains("3000"))
        #expect(SettingsVPDiagnosticText.detail(checks[2])?.contains("192.168.1.50") == true)
        #expect(SettingsVPDiagnosticText.detail(checks[4]) != nil)          // skip text
        #expect(SettingsVPDiagnosticText.detail(checks[1]) == nil)          // pass, nothing to add
        #expect(SettingsVPDiagnosticText.title(SettingsVPDiagnosticCheck(id: "new_check", status: "pass", params: nil)) == "New Check")
    }

    @Test func encodesUpdateBodyWithOnlySetKeys() throws {
        var body = SettingsVirtualPrinterUpdate()
        body.tailscaleDisabled = false
        body.bindIp = ""
        body.queueForceColorMatch = true
        let object = try encodedObject(body)
        #expect(Set(object.keys) == ["tailscale_disabled", "bind_ip", "queue_force_color_match"])
        #expect(object["bind_ip"] as? String == "")

        let all = SettingsVirtualPrinterUpdate(name: "A", enabled: true, mode: "queue", model: "C12", accessCode: "12345678",
                                               targetPrinterId: 4, autoDispatch: false, queueForceColorMatch: true,
                                               saveAmsMapping: true, gcodeInjection: true, bindIp: "1.2.3.4",
                                               remoteInterfaceIp: "5.6.7.8", tailscaleDisabled: true)
        let keys = Set(try encodedObject(all).keys)
        #expect(keys == ["name", "enabled", "mode", "model", "access_code", "target_printer_id", "auto_dispatch",
                         "queue_force_color_match", "save_ams_mapping", "gcode_injection", "bind_ip",
                         "remote_interface_ip", "tailscale_disabled"])
    }

    @Test func buildsCreateBodyPerMode() throws {
        let queue = SettingsVirtualPrinterCreate.make(
            name: "  ", mode: .queue, modelCode: "C12", accessCode: "abcdefgh", targetPrinterID: nil,
            bindIP: "10.0.0.5", remoteIP: "", autoDispatch: false, forceColorMatch: true,
            saveAmsMapping: false, gcodeInjection: true, enabled: true)
        let q = try encodedObject(queue)
        #expect(q["name"] as? String == "Bambuddy")
        #expect(q["mode"] as? String == "queue")
        #expect(q["model"] as? String == "C12")
        #expect(q["access_code"] as? String == "abcdefgh")
        #expect(q["auto_dispatch"] as? Bool == false)
        #expect(q["queue_force_color_match"] as? Bool == true)
        #expect(q["gcode_injection"] as? Bool == true)
        #expect(q["bind_ip"] as? String == "10.0.0.5")
        #expect(q["remote_interface_ip"] == nil)
        #expect(q["target_printer_id"] == nil)

        let proxy = SettingsVirtualPrinterCreate.make(
            name: "Relay", mode: .proxy, modelCode: "C12", accessCode: "abcdefgh", targetPrinterID: 7,
            bindIP: "", remoteIP: "192.168.2.1", autoDispatch: true, forceColorMatch: false,
            saveAmsMapping: false, gcodeInjection: false, enabled: false)
        let p = try encodedObject(proxy)
        #expect(p["target_printer_id"] as? Int == 7)
        #expect(p["model"] == nil)          // inherited from the target on the server
        #expect(p["access_code"] == nil)
        #expect(p["auto_dispatch"] == nil)
        #expect(p["bind_ip"] == nil)
        #expect(p["remote_interface_ip"] as? String == "192.168.2.1")
        #expect(p["enabled"] as? Bool == false)
    }

    @Test func validatesEnableRequirements() {
        #expect(SettingsVPValidation.accessCodeProblem("") == nil)
        #expect(SettingsVPValidation.accessCodeProblem("1234567") != nil)
        #expect(SettingsVPValidation.accessCodeProblem("12345678") == nil)
        #expect(SettingsVPValidation.enableProblem(mode: .archive, bindIp: nil, targetPrinterId: nil, hasAccessCode: true) != nil)
        #expect(SettingsVPValidation.enableProblem(mode: .proxy, bindIp: "1.1.1.1", targetPrinterId: nil, hasAccessCode: true) != nil)
        #expect(SettingsVPValidation.enableProblem(mode: .proxy, bindIp: "1.1.1.1", targetPrinterId: 2, hasAccessCode: false) == nil)
        #expect(SettingsVPValidation.enableProblem(mode: .queue, bindIp: "1.1.1.1", targetPrinterId: nil, hasAccessCode: false) != nil)
        #expect(SettingsVPValidation.enableProblem(mode: .queue, bindIp: "1.1.1.1", targetPrinterId: 3, hasAccessCode: false) == nil)
        #expect(SettingsVPValidation.enableProblem(mode: .review, bindIp: "1.1.1.1", targetPrinterId: nil, hasAccessCode: true) == nil)
    }

    // MARK: Obico

    @Test func decodesLiveObicoStatus() throws {
        let json = #"{"is_running":true,"last_error":null,"per_printer":{},"thresholds":{"low":0.38,"high":0.78},"history":[],"enabled":false,"ml_url":"","sensitivity":"medium","action":"notify","poll_interval":10,"external_url_configured":true}"#
        let status = try decode(SettingsObicoStatus.self, json)
        #expect(status.isRunning == true)
        #expect(status.thresholds?.high == 0.78)
        #expect(status.pollInterval == 10)
        #expect(status.externalUrlConfigured == true)
        #expect(status.perPrinter?.isEmpty == true)
    }

    @Test func decodesObicoStatusWithActivePrintsAndHistory() throws {
        let json = """
        {"is_running":true,"last_error":"ML API call failed for printer 2: timeout",
         "per_printer":{"1":{"class":"warning","frame_count":14,"score":0.4521,"error":null},
                        "2":{"class":"error","frame_count":0,"score":0,"error":"Camera snapshot failed"},
                        "3":{"class":"unknown","frame_count":0,"score":0.0,"error":null}},
         "thresholds":{"low":0.285,"high":0.585},
         "history":[{"printer_id":1,"task_name":"Benchy","timestamp":"2026-09-26T12:00:01.123456+00:00","current_p":0.61,"score":0.4521,"class":"warning","detections":2},
                    {"printer_id":1,"task_name":null,"timestamp":"2026-09-26T11:59:51+00:00","current_p":0.0,"score":0.1,"class":"safe","detections":0}],
         "enabled":true,"ml_url":"http://192.168.1.10:3333","sensitivity":"high","action":"pause_and_off","poll_interval":15,
         "external_url_configured":false}
        """
        let status = try decode(SettingsObicoStatus.self, json)
        #expect(status.perPrinter?["1"]?.verdict == "warning")
        #expect(status.perPrinter?["1"]?.frameCount == 14)
        #expect(status.perPrinter?["2"]?.error == "Camera snapshot failed")
        #expect(status.perPrinter?["3"]?.verdict == "unknown")
        #expect(status.history?.count == 2)
        #expect(status.history?[0].verdict == "warning")
        #expect(status.history?[0].currentP == 0.61)
        #expect(status.history?[0].taskName == "Benchy")
        #expect(status.history?[1].taskName == nil)
        #expect(status.action == "pause_and_off")
    }

    @Test func decodesObicoPrinterStatus() throws {
        let live = try decode(SettingsObicoPrinterStatus.self,
            #"{"enabled":false,"monitored_printers":null,"per_printer":{},"last_error":null}"#)
        #expect(live.monitoredPrinters == nil)
        let some = try decode(SettingsObicoPrinterStatus.self,
            #"{"enabled":true,"monitored_printers":[1,4],"per_printer":{"4":{"class":"safe","frame_count":3,"score":0.02,"error":null}},"last_error":null}"#)
        #expect(some.monitoredPrinters == [1, 4])
        #expect(some.perPrinter?["4"]?.verdict == "safe")
    }

    @Test func obicoTestConnectionBodyAndResult() throws {
        let body = try encodedObject(SettingsObicoTestRequest(url: "http://ml:3333", token: nil))
        #expect(Set(body.keys) == ["url"])       // omitted token = test the saved one
        let withToken = try encodedObject(SettingsObicoTestRequest(url: "http://ml:3333", token: ""))
        #expect(withToken["token"] as? String == "")

        let ok = try decode(SettingsObicoTestResult.self, #"{"ok":true,"status_code":200,"body":"ok","error":null,"auth_ok":null}"#)
        #expect(ok.authOk == nil)
        #expect(SettingsObicoTestText.describe(ok).success)
        let rejected = try decode(SettingsObicoTestResult.self,
            #"{"ok":false,"status_code":401,"body":"Unauthorized","error":"The ML API is reachable but rejected the token.","auth_ok":false}"#)
        #expect(SettingsObicoTestText.describe(rejected).message.contains("rejected"))
        let unhealthy = try decode(SettingsObicoTestResult.self, #"{"ok":false,"status_code":503,"body":"down","error":null,"auth_ok":null}"#)
        #expect(SettingsObicoTestText.describe(unhealthy).message == "HTTP 503 — down")
    }

    @Test func obicoPrinterSelectionRoundTrip() {
        #expect(SettingsObicoPrinterSelection.parse("") == nil)
        #expect(SettingsObicoPrinterSelection.parse("None") == nil)
        #expect(SettingsObicoPrinterSelection.parse("[]") == [])
        #expect(SettingsObicoPrinterSelection.parse("[3, 1]") == [3, 1])
        #expect(SettingsObicoPrinterSelection.parse("garbage") == nil)
        #expect(SettingsObicoPrinterSelection.encode(nil) == "")
        #expect(SettingsObicoPrinterSelection.encode([3, 1, 3]) == "[1,3]")
        #expect(SettingsObicoPrinterSelection.encode([]) == "[]")
        // From "all", unticking one printer keeps the others.
        #expect(SettingsObicoPrinterSelection.toggled(nil, printer: 2, on: false, allPrinters: [1, 2, 3]) == [1, 3])
        #expect(SettingsObicoPrinterSelection.toggled([1], printer: 3, on: true, allPrinters: [1, 2, 3]) == [1, 3])
        #expect(SettingsObicoPrinterSelection.toggled([1, 3], printer: 3, on: true, allPrinters: [1, 2, 3]) == [1, 3])
    }

    // MARK: SpoolBuddy

    @Test func decodesSpoolBuddyDevices() throws {
        let json = """
        [
          {"id":1,"device_id":"sb-a1b2c3","hostname":"spoolbuddy","ip_address":"192.168.1.60","firmware_version":"1.2.5",
           "has_nfc":true,"has_scale":true,"tare_offset":-8421,"calibration_factor":412.37,"nfc_reader_type":"PN532",
           "nfc_connection":"i2c","backend_url":"http://192.168.1.10:8000","display_brightness":80,"display_blank_timeout":300,
           "has_backlight":true,"last_calibrated_at":"2026-09-01T10:00:00","last_seen":"2026-09-26T12:00:00.123456",
           "pending_command":null,"nfc_ok":true,"scale_ok":false,"uptime_s":86400,"update_status":"complete",
           "update_message":"Updated to 1.2.5",
           "system_stats":{"os":{"os":"Debian GNU/Linux 12","kernel":"6.6.31","arch":"aarch64","python":"3.11.2"},
             "cpu_temp_c":51.2,"cpu_count":4,"load_avg":[0.42,0.3,0.25],
             "memory":{"total_mb":3796,"available_mb":2900,"used_mb":896.5,"percent":23.6},
             "disk":{"total_gb":29.1,"used_gb":6.4,"free_gb":22.7,"percent":22},"system_uptime_s":172800},
           "online":true,"ssh_public_key":null,"created_at":"2026-08-01T09:00:00","updated_at":"2026-09-26T12:00:00"},
          {"id":2,"device_id":"sb-old","hostname":"spoolbuddy-old","ip_address":"192.168.1.61","firmware_version":null,
           "has_nfc":false,"has_scale":true,"tare_offset":0,"calibration_factor":1.0,"nfc_reader_type":null,
           "nfc_connection":null,"backend_url":null,"display_brightness":100,"display_blank_timeout":0,
           "has_backlight":false,"last_calibrated_at":null,"last_seen":null,"pending_command":"reboot",
           "nfc_ok":false,"scale_ok":false,"uptime_s":0,"update_status":null,"update_message":null,
           "system_stats":null,"online":false,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}
        ]
        """
        let devices = try decode([SettingsSpoolBuddyDevice].self, json)
        #expect(devices.count == 2)
        let d = devices[0]
        #expect(d.deviceId == "sb-a1b2c3")
        #expect(d.tareOffset == -8421)
        #expect(d.calibrationFactor == 412.37)
        #expect(d.uptimeS == 86400)
        #expect(d.isOnline)
        #expect(d.systemStats?.cpuTempC == 51.2)
        #expect(d.systemStats?.cpuCount == 4)
        #expect(d.systemStats?.loadAvg?.first == 0.42)
        #expect(d.systemStats?.memory?.usedMb == 896.5)
        #expect(d.systemStats?.disk?.usedGb == 6.4)
        #expect(d.systemStats?.systemUptimeS == 172800)
        #expect(d.systemStats?.os?.python == "3.11.2")
        #expect(devices[1].systemStats == nil)
        #expect(devices[1].pendingCommand == "reboot")
        #expect(devices[1].lastSeen == nil)
        #expect(!devices[1].isOnline)
    }

    @Test func toleratesMalformedSystemStats() throws {
        let json = #"{"id":3,"device_id":"x","hostname":"h","ip_address":"1.2.3.4","has_nfc":true,"has_scale":true,"tare_offset":0,"calibration_factor":1,"nfc_ok":true,"scale_ok":true,"uptime_s":5,"system_stats":{"cpu_temp_c":"n/a","load_avg":"high","memory":{"percent":12}},"online":true,"created_at":"2026-01-01T00:00:00","updated_at":"2026-01-01T00:00:00"}"#
        let device = try decode(SettingsSpoolBuddyDevice.self, json)
        #expect(device.systemStats?.cpuTempC == nil)
        #expect(device.systemStats?.loadAvg == nil)
        #expect(device.systemStats?.memory?.percent == 12)
    }

    @Test func decodesSpoolBuddyAuxiliaryResponses() throws {
        let check = try decode(SettingsSpoolBuddyUpdateCheck.self,
            #"{"current_version":"1.2.4","latest_version":"1.2.5.5","update_available":true}"#)
        #expect(check.updateAvailable == true)
        #expect(check.latestVersion == "1.2.5.5")
        let queued = try decode(SettingsSpoolBuddyActionResponse.self, #"{"status":"queued","command":"reboot"}"#)
        #expect(queued.command == "reboot")
        let busy = try decode(SettingsSpoolBuddyActionResponse.self, #"{"status":"already_updating","message":"Update already in progress"}"#)
        #expect(busy.status == "already_updating")
        let key = try decode(SettingsSpoolBuddySSHKey.self, #"{"public_key":"ssh-ed25519 AAAAC3Nz bambuddy"}"#)
        #expect(key.publicKey?.hasPrefix("ssh-ed25519") == true)

        let body = try encodedObject(SettingsSpoolBuddyCommandRequest(command: SettingsSpoolBuddyCommand.restartDaemon.rawValue))
        #expect(body["command"] as? String == "restart_daemon")
        #expect(SettingsSpoolBuddyCommand.restartBrowser.rawValue == "restart_browser")
        #expect(SettingsSpoolBuddyCommand.shutdown.isDestructive)
    }
}
