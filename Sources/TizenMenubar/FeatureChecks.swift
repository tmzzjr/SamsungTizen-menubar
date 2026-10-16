import Foundation
import AppKit

enum FeatureChecks {
    static func equal<T: Equatable>(_ a: T, _ b: T) throws { guard a == b else { throw RemoteError.message("Check failed: \(a) != \(b)") } }
    static func truth(_ value: Bool) throws { guard value else { throw RemoteError.message("Check failed") } }
    static func rejects(_ operation: () throws -> Void) throws { do { try operation() } catch { return }; throw RemoteError.message("Expected rejection") }
    static func run() async throws {
        try testPackagedResourcesLoadWithoutDeviceConfiguration()
        try testUsageSurvivesRestartAndClipsMidnightWithoutCountingSleep()
        try testHTTPRangeSupportsSeekSuffixAndRejectsInvalidRanges()
        try await testMediaServerStreamsOnlySelectedFileAndSupportsHeadAndRange()
        try testSOAPMetadataEscapesUserFilenameAndURL()
        try testRendererResponsesAreParsed()
        try testRemoteFramesMatchTheSmartViewProtocol()
        try testHandshakeReadsTokenAndRefusals()
        try testInstalledAppListIsParsedAndDeduplicated()
        try testTVDescriptionIsParsed()
        try testCatalogMatchesNamesExactly()
        try testActivityTracksWhatThisMacOpened()
        try testSwipePadSendsOneKeyPerStep()
        try testConnectionAcceptsOnlyLocalIPv4Addresses()
        try testCertificateTrustRequiresApprovalAndRejectsChangedPins()
        try testPairingFileIsPrivateAndForgetRemovesIt()
        try testFreshConfigurationHasNoDeviceIdentityAndLoadsCustomParameters()
        print("PASS: packaged catalog and images; usage persistence, midnight clipping, sleep exclusion; HTTP GET/HEAD/Range/404/416 with DLNA headers; XML escaping and renderer parsing; Smart View key, text, launch and channel frames; pairing token and refusal handshakes; installed app list; TV description; catalog name matching; local activity tracking; swipe pad; local IPv4 boundaries, certificate trust, private pairing file, fresh configuration and custom parameters.")
    }

    static func testPackagedResourcesLoadWithoutDeviceConfiguration() throws {
        let entries = AppCatalog.entries
        try truth(!entries.isEmpty)
        try equal(Set(entries.map(\.title)).count, entries.count)
        for entry in entries {
            try truth(!entry.title.isEmpty)
            try truth(entry.icon != nil || entry.ids?.isEmpty == false)
            guard let icon = entry.icon else { continue }
            guard !icon.contains("/"), !icon.contains(".."),
                  let url = AppResources.bundle.url(forResource: icon, withExtension: nil, subdirectory: "AppAssets"),
                  let image = NSImage(contentsOf: url) else {
                throw RemoteError.message("A packaged catalog icon is missing or invalid")
            }
            try truth(image.isValid)
            try truth(entry.ids?.allSatisfy { !$0.isEmpty } ?? true)
        }
        for name in ["samsung", "playstation", "googlecast", "tv-hero"] {
            guard let url = AppResources.bundle.url(forResource: name, withExtension: "png", subdirectory: "AppAssets"),
                  let image = NSImage(contentsOf: url), image.isValid else {
                throw RemoteError.message("A packaged brand image is missing or invalid")
            }
        }
    }
    static func json(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteError.message("Frame is not a JSON object") }
        return decoded
    }
    static func testRemoteFramesMatchTheSmartViewProtocol() throws {
        let key = try json(TizenMessage.key("KEY_HOME"))
        try equal(key["method"] as? String, "ms.remote.control")
        let params = key["params"] as? [String: Any] ?? [:]
        try equal(params["Cmd"] as? String, "Click"); try equal(params["DataOfCmd"] as? String, "KEY_HOME")
        try equal(params["Option"] as? String, "false"); try equal(params["TypeOfRemote"] as? String, "SendRemoteKey")
        let text = (try json(TizenMessage.text("Olá & 1")))["params"] as? [String: Any] ?? [:]
        try equal(text["DataOfCmd"] as? String, "base64"); try equal(text["TypeOfRemote"] as? String, "SendInputString")
        try equal((text["Cmd"] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }, "Olá & 1")
        func launchType(_ type: Int?) throws -> String? {
            let frame = try json(TizenMessage.launch("3201907018807", type: type))
            try equal(frame["method"] as? String, "ms.channel.emit")
            let params = frame["params"] as? [String: Any] ?? [:]
            try equal(params["event"] as? String, "ed.apps.launch"); try equal(params["to"] as? String, "host")
            let data = params["data"] as? [String: Any] ?? [:]
            try equal(data["appId"] as? String, "3201907018807")
            return data["action_type"] as? String
        }
        try equal(try launchType(2), "DEEP_LINK"); try equal(try launchType(4), "NATIVE_LAUNCH"); try equal(try launchType(nil), "DEEP_LINK")
        guard let url = TizenMessage.channelURL(host: "192.0.2.10", token: "12345678"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw RemoteError.message("Channel URL is invalid") }
        try equal(url.scheme, "wss"); try equal(url.port, 8002); try equal(url.path, "/api/v2/channels/samsung.remote.control")
        let name = components.queryItems?.first { $0.name == "name" }?.value.flatMap { Data(base64Encoded: $0) }
        try equal(name.map { String(decoding: $0, as: UTF8.self) }, TizenMessage.clientName)
        try equal(components.queryItems?.first { $0.name == "token" }?.value, "12345678")
        try truth(TizenMessage.channelURL(host: "192.0.2.10", token: nil)?.query?.contains("token") == false)
    }
    static func testHandshakeReadsTokenAndRefusals() throws {
        try equal(TizenHandshake.parse(["event": "ms.channel.connect", "data": ["id": "x", "token": "11223344"]]), .connected(token: "11223344"))
        try equal(TizenHandshake.parse(["event": "ms.channel.connect", "data": ["token": NSNumber(value: 55667788)]]), .connected(token: "55667788"))
        try equal(TizenHandshake.parse(["event": "ms.channel.connect", "data": ["id": "x"]]), .connected(token: nil))
        try equal(TizenHandshake.parse(["event": "ms.channel.connect", "data": ["token": ""]]), .connected(token: nil))
        try equal(TizenHandshake.parse(["event": "ms.channel.unauthorized"]), .unauthorized)
        try equal(TizenHandshake.parse(["event": "ms.channel.timeOut"]), .timedOut)
        try equal(TizenHandshake.parse(["event": "ms.channel.clientConnect"]), nil)
    }
    static func testInstalledAppListIsParsedAndDeduplicated() throws {
        let answer: [String: Any] = ["event": "ed.installedApp.get", "data": ["data": [
            ["appId": "111299001912", "app_type": 2, "icon": "/opt/a.png", "name": "YouTube"],
            ["appId": "111299001912", "app_type": 2, "name": "YouTube"],
            ["appId": "org.tizen.browser", "app_type": "4", "name": "Internet"],
            ["appId": "", "name": "Broken"],
            ["name": "No id"],
        ]]]
        let apps = TizenApp.list(answer)
        try equal(apps.map(\.id), ["111299001912", "org.tizen.browser"])
        try equal(apps.first?.iconPath, "/opt/a.png"); try equal(apps.first?.type, 2); try equal(apps.last?.type, 4)
        try truth(TizenApp.list(["event": "ed.installedApp.get"]).isEmpty)
    }
    static func testTVDescriptionIsParsed() throws {
        let body = #"{"device":{"OS":"Tizen","PowerState":"standby","firmwareVersion":"Unknown","model":"20_KANTSU2_UHD","modelName":"UN00TEST","name":"[TV] Living room","type":"Samsung SmartTV","wifiMac":"00:11:22:33:44:55"},"name":"[TV] Living room"}"#
        guard let info = TVInfo.parse(Data(body.utf8)) else { throw RemoteError.message("TV description did not parse") }
        try equal(info.displayName, "Living room"); try equal(info.year, "2020"); try equal(info.firmware, "")
        try equal(info.wifiMac, "00:11:22:33:44:55"); try truth(info.isSamsungTV); try truth(!info.isOn)
        let older = TVInfo.parse(Data(#"{"device":{"type":"Samsung SmartTV","model":"UHD"}}"#.utf8))
        try equal(older?.year, nil); try truth(older?.isOn == true); try equal(older?.displayName, "Samsung TV")
        try equal(TVInfo.parse(Data("not json".utf8)), nil)
    }
    static func testCatalogMatchesNamesExactly() throws {
        try equal(AppCatalog.match(title: "Netflix")?.title, "Netflix")
        try equal(AppCatalog.match(title: "  prime   VIDEO ")?.title, "Prime Video")
        try equal(AppCatalog.match(title: "Unknown name", id: "111299001912")?.title, "YouTube")
        try equal(AppCatalog.match(title: "Mad Max Trailers")?.title, nil)
        try equal(AppCatalog.match(title: "Globoplay")?.title, "Globoplay")
        let ids = AppCatalog.entries.flatMap { $0.ids ?? [] }
        try equal(Set(ids).count, ids.count)
        try equal(AppCatalog.match(title: "Internet")?.type, 4)
        try equal(AppCatalog.match(title: "Unknown name", id: "3201907018807")?.dial, "Netflix")
        try equal(AppCatalog.match(title: "Prime Video")?.dial, "AmazonInstantVideo")
    }
    static func testActivityTracksWhatThisMacOpened() throws {
        var activity = TVActivity()
        activity.opened(.app("netflix"))
        activity.pressed("KEY_HOME"); try truth(activity.homeShown); try equal(activity.focus, .app("netflix"))
        activity.pressed("KEY_DOWN"); try truth(activity.homeShown)
        activity.pressed("KEY_RETURN"); try truth(!activity.homeShown); try equal(activity.focus, .app("netflix"))
        activity.pressed("KEY_HOME"); activity.pressed("KEY_ENTER")
        try truth(!activity.homeShown); try equal(activity.focus, .unknown)
        activity.opened(.input("HDMI2")); activity.pressed("KEY_ENTER"); try equal(activity.focus, .input("HDMI2"))
        activity.pressed("KEY_EXIT"); try equal(activity.focus, .input("HDMI2"))
        activity.opened(.app("youtube")); activity.pressed("KEY_EXIT"); try equal(activity.focus, .unknown)
        activity.pressed("KEY_TV"); try equal(activity.focus, .input("TV"))
        activity.pressed("KEY_POWER"); try equal(activity, TVActivity())
    }
    static func testSwipePadSendsOneKeyPerStep() throws {
        var pad = SwipePad(step: 30)
        try equal(pad.drag(dx: 10, dy: 2), [])
        try equal(pad.drag(dx: 25, dy: 3), ["KEY_RIGHT"])
        try equal(pad.drag(dx: 0, dy: -65), ["KEY_UP", "KEY_UP"])
        pad.end()
        try equal(pad.drag(dx: -29, dy: 0), [])
        pad.end()
        try equal(pad.drag(dx: -29, dy: 0), [])
        try equal(pad.drag(dx: -1, dy: 0), ["KEY_LEFT"])
    }
    static func testRendererResponsesAreParsed() throws {
        let volume = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><u:GetVolumeResponse xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\"><CurrentVolume>13\n</CurrentVolume></u:GetVolumeResponse></s:Body></s:Envelope>"
        try equal(UPnPRenderer.value("CurrentVolume", in: volume), "13")
        try equal(UPnPRenderer.value("CurrentMute", in: volume), nil)
        let envelope = UPnPRenderer.envelope(service: UPnPRenderer.rendering, action: "SetVolume", parameters: [("Channel", "Master"), ("DesiredVolume", "20")])
        try truth(XMLParser(data: Data(envelope.utf8)).parse())
        try truth(envelope.contains("<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>20</DesiredVolume>"))
    }

    static func testConnectionAcceptsOnlyLocalIPv4Addresses() throws {
        let allowed = [[10, 0, 0, 0], [10, 255, 255, 255], [172, 16, 0, 0], [172, 31, 255, 255], [192, 168, 0, 0], [192, 168, 255, 255], [169, 254, 1, 1], [169, 254, 254, 254]]
        for octets in allowed {
            try truth(TizenConnection.localHost(octets.map(String.init).joined(separator: ".")))
        }
        for host in ["9.255.255.255", "11.0.0.0", "172.15.255.255", "172.32.0.0", "192.167.255.255", "192.169.0.0", "169.253.255.255", "169.255.0.0", "127.0.0.1", "0.0.0.0", "8.8.8.8", "255.255.255.255", "192.168.1.256", "192.168.1", "localhost", "", "::1"] {
            try truth(!TizenConnection.localHost(host))
        }
    }
    static func testCertificateTrustRequiresApprovalAndRejectsChangedPins() throws {
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "saved-pin", canApprove: false), .matched)
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "saved-pin", canApprove: true), .matched)
        try equal(TVCertificatePolicy.decide(expected: "saved-pin", received: "changed-pin", canApprove: true), .rejected)
        try equal(TVCertificatePolicy.decide(expected: nil, received: "new-pin", canApprove: false), .rejected)
        try equal(TVCertificatePolicy.decide(expected: nil, received: "new-pin", canApprove: true), .approvalRequired)
    }
    static func testFreshConfigurationHasNoDeviceIdentityAndLoadsCustomParameters() throws {
        let suite = "TizenMenubar.FeatureChecks." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw RemoteError.message("Could not create isolated test preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = TVConfiguration(defaults: defaults)
        try equal(fresh.host, "")
        try equal(fresh.name, "Samsung TV")
        try equal(fresh.model, "")
        try equal(fresh.mac, "")
        let address = "203.0.113.10"
        let mac = ["00", "11", "22", "33", "44", "55"].joined(separator: ":")
        defaults.set(address, forKey: "tv.host")
        defaults.set("Test TV", forKey: "tv.name")
        defaults.set("Test model", forKey: "tv.model")
        defaults.set(mac, forKey: "tv.mac")
        let configured = TVConfiguration(defaults: defaults)
        try equal(configured.host, address)
        try equal(configured.name, "Test TV")
        try equal(configured.model, "Test model")
        try equal(configured.mac, mac)
    }

    static func testPairingFileIsPrivateAndForgetRemovesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PairingStore(url: directory.appendingPathComponent("pairing.json"))
        let pin = String(repeating: "a", count: 64)
        try equal(store.entry("tv"), .init())
        try store.update("tv") { $0.token = "12345678" }
        try store.update("tv") { $0.pin = pin }
        try store.update("other") { $0.token = "9" }
        let reopened = PairingStore(url: store.url)
        try equal(reopened.entry("tv"), .init(token: "12345678", pin: pin))
        let mode = (try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue
        try equal(mode, 0o600)
        try equal(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["pairing.json"])
        try reopened.update("tv") { $0 = .init() }
        try equal(reopened.entry("tv"), .init())
        try equal(reopened.entry("other").token, "9")
        try reopened.update("other") { $0 = .init() }
        try truth(!FileManager.default.fileExists(atPath: store.url.path))
    }
    static func testUsageSurvivesRestartAndClipsMidnightWithoutCountingSleep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("usage.json")
        let midnight = Date(timeIntervalSince1970: 86400 * 20000)
        let journal = UsageJournal(url: file)
        journal.observe(host: "tv", appID: "netflix", title: "Netflix", at: midnight.addingTimeInterval(-10))
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(10))
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(30))
        // An hour offline must contribute zero seconds, even for the same app.
        journal.observe(host: "tv", appID: "youtube", title: "YouTube", at: midnight.addingTimeInterval(3630))
        journal.pause(at: midnight.addingTimeInterval(3640))
        try journal.save()
        let restored = UsageJournal(url: file)
        let totals = restored.totals(host: "tv", since: midnight, until: midnight.addingTimeInterval(4000))
        try equal(totals.first?.id, "youtube")
        try equal(totals.first?.seconds, 30)
        try equal(totals.last?.seconds, 10)
        try truth(restored.totals(host: "other", since: midnight).isEmpty)
    }
    static func testHTTPRangeSupportsSeekSuffixAndRejectsInvalidRanges() throws {
        let seek = try MediaHTTP.range("bytes=5-12", size: 10)
        try equal(seek.start, 5); try equal(seek.end, 9); try truth(seek.partial)
        try equal(try MediaHTTP.range("bytes=-3", size: 10).start, 7)
        try equal(try MediaHTTP.range("bytes=3-", size: 10).end, 9)
        try rejects { _ = try MediaHTTP.range("bytes=10-", size: 10) }
        try rejects { _ = try MediaHTTP.range("bytes=6-2", size: 10) }
        try rejects { _ = try MediaHTTP.range("bytes=0-1,4-5", size: 10) }
    }
    static func testMediaServerStreamsOnlySelectedFileAndSupportsHeadAndRange() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data("0123456789".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MediaFileServer(file: file, allowedHost: "127.0.0.1")
        let url = try await server.start()
        defer { server.stop() }
        var request = URLRequest(url: url); request.setValue("bytes=3-6", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        try equal((response as? HTTPURLResponse)?.statusCode, 206)
        try equal(String(decoding: data, as: UTF8.self), "3456")
        request.httpMethod = "HEAD"
        let (empty, head) = try await URLSession.shared.data(for: request)
        try truth(empty.isEmpty)
        try equal((head as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "4")
        try equal((head as? HTTPURLResponse)?.value(forHTTPHeaderField: "contentFeatures.dlna.org"), UPnPRenderer.dlnaFeatures)
        request.httpMethod = "GET"; request.setValue("bytes=99-", forHTTPHeaderField: "Range")
        let (_, invalid) = try await URLSession.shared.data(for: request)
        try equal((invalid as? HTTPURLResponse)?.statusCode, 416)
        let (_, absent) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("secret"))
        try equal((absent as? HTTPURLResponse)?.statusCode, 404)
    }
    static func testSOAPMetadataEscapesUserFilenameAndURL() throws {
        let metadata = UPnPRenderer.metadata(url: URL(string: "http://127.0.0.1/a?x=1&y=2")!, title: "A < B & C", mime: "video/mp4")
        let envelope = UPnPRenderer.envelope(service: UPnPRenderer.transport, action: "SetAVTransportURI", parameters: [("CurrentURIMetaData", metadata)])
        try truth(XMLParser(data: Data(envelope.utf8)).parse())
        try truth(metadata.contains("A &lt; B &amp; C"))
        try truth(envelope.contains("&lt;DIDL-Lite"))
        try truth(metadata.contains("http-get:*:video/mp4:DLNA.ORG_OP=01"))
    }
}
