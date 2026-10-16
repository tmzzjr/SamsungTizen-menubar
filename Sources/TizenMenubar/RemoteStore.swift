import SwiftUI
import AppKit

struct TVApp: Identifiable, Equatable { let id: String; let title: String; let icon: String?; var type: Int? = nil; var iconPath: String? = nil }
struct TVInput: Identifiable, Equatable { let id: String; let label: String; let key: String }
struct RemoteEvent: Identifiable, Codable { let id: UUID; let date: Date; let title: String; let detail: String
    init(title: String, detail: String) { id = UUID(); date = Date(); self.title = title; self.detail = detail }
}

@MainActor final class RemoteStore: ObservableObject {
    @Published var host = TVConfiguration().host
    @Published var name = TVConfiguration().name
    @Published var model = TVConfiguration().model
    @Published var mac = TVConfiguration().mac
    @Published var connected = false
    @Published var connecting = false
    @Published var pairing = false
    @Published var discovering = false
    @Published var devices: [TVDevice] = []
    @Published var apps: [TVApp] = []
    @Published var appsFromCatalog = false
    @Published var volume: Double = 0
    @Published var hasVolume = false
    @Published var muted = false
    @Published private(set) var activity = TVActivity()
    @Published var textInputOpen = false
    /// The TV screen takes a pointer (its web browser), so the swipe pad moves the pointer instead of sending arrows.
    @Published var pointerMode = false
    @Published var error: String?
    @Published var notice: String?
    @Published var events: [RemoteEvent] = []
    @Published var system = ""
    @Published var firmware = ""
    @Published var usageRevision = 0
    @Published var iconRevision = 0
    @Published var mediaFile: URL?
    @Published var mediaBusy = false
    @Published var casting = false
    @Published var mediaStatus = "Choose a video, a song, or a photo."
    @Published var preferredPanelHeight: CGFloat = 740
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "tv.favorites") ?? [])
    @Published var hiddenApps = Set(UserDefaults.standard.stringArray(forKey: "tv.hiddenApps") ?? [])
    @Published var hdmiCount = max(1, min(4, UserDefaults.standard.object(forKey: "tv.hdmiCount") as? Int ?? 3))
    @Published var inputNames = UserDefaults.standard.dictionary(forKey: "tv.inputNames") as? [String: String] ?? [:]
    private(set) var connection: TizenConnection?
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var volumeEdited = Date.distantPast
    private var iconTask: Task<Void, Never>?
    private var autoReconnect = false
    private var renderer: UPnPRenderer?
    private let dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("br.local.TizenRemote")
    private lazy var journal = UsageJournal(url: dataDirectory.appendingPathComponent("usage.json"))
    private var observers: [NSObjectProtocol] = []
    private var fileServer: MediaFileServer?
    private var powerActive = false
    private var swipe = SwipePad()
    init() {
        events = (try? JSONDecoder().decode([RemoteEvent].self, from: Data(contentsOf: dataDirectory.appendingPathComponent("events.json")))) ?? []
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pauseUsage() }
        })
    }

    var pinnedApps: [TVApp] { shortcuts.filter { favorites.contains($0.id) } }
    var homeRequested: Bool { activity.homeShown }
    var inputs: [TVInput] {
        (1...hdmiCount).map { number in
            let id = "HDMI\(number)"
            return TVInput(id: id, label: inputNames[id].flatMap { $0.isEmpty ? nil : $0 } ?? "HDMI \(number)", key: "KEY_HDMI\(number)")
        } + [TVInput(id: "TV", label: inputNames["TV"].flatMap { $0.isEmpty ? nil : $0 } ?? "Live TV", key: "KEY_TV")]
    }
    var currentInput: TVInput? {
        guard !homeRequested, case .input(let id) = activity.focus else { return nil }
        return inputs.first { $0.id == id }
    }
    var currentAppID: String? {
        guard !homeRequested, case .app(let id) = activity.focus else { return nil }
        return id
    }
    var displayForegroundID: String { homeRequested ? "home" : currentAppID ?? currentInput?.id ?? "" }
    func log(_ title: String, _ detail: String) {
        events.insert(RemoteEvent(title: title, detail: detail), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }
        if title != "Read" {
            let persisted = events.filter { $0.title != "Read" }
            do { try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true); try JSONEncoder().encode(persisted).write(to: dataDirectory.appendingPathComponent("events.json"), options: .atomic) }
            catch { notice = "Could not save the local event history." }
        }
    }

    var status: String { pairing ? "Choose Allow on your TV" : connecting ? "Connecting…" : connected ? "Connected" : "Disconnected" }
    var currentApp: String {
        if homeRequested { return "Home menu" }
        if let id = currentAppID { return apps.first { $0.id == id }?.title ?? "TV app" }
        if let input = currentInput { return input.label }
        return connected ? "TV is on" : "Your TV, on your Mac."
    }
    var shortcuts: [TVApp] {
        let preferred = ["netflix", "youtube", "prime video", "disney", "globoplay", "spotify", "max", "apple"]
        return apps.filter { !hiddenApps.contains($0.id) }.sorted { a, b in
            if favorites.contains(a.id) != favorites.contains(b.id) { return favorites.contains(a.id) }
            let ai = preferred.firstIndex { a.title.localizedCaseInsensitiveContains($0) } ?? 100
            let bi = preferred.firstIndex { b.title.localizedCaseInsensitiveContains($0) } ?? 100
            return ai != bi ? ai < bi : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    func connect(allowFirstUseTrust: Bool = true) {
        guard !connecting else { return }
        guard TizenConnection.localHost(host) else { error = "Enter the TV's local IPv4 address or discover a TV on your network."; return }
        autoReconnect = true; error = nil; connecting = true; pairing = false
        pauseUsage()
        connection?.close(); refreshTask?.cancel(); iconTask?.cancel()
        let client = TizenConnection(host: host); connection = client
        client.onCertificateTrust = { host, fingerprint in
            await ConnectionTrustPrompt.confirm(host: host, fingerprint: fingerprint)
        }
        client.onPairing = { [weak self] in self?.pairing = true }
        client.onEvent = { [weak self] title, detail in self?.log(title, detail) }
        client.onTextInput = { [weak self] open in self?.textInputOpen = open }
        client.onPointer = { [weak self] active in self?.pointerMode = active }
        client.onDisconnect = { [weak self, weak client] failure in
            guard let self, self.connection === client else { return }
            self.connected = false; self.hasVolume = false; self.textInputOpen = false; self.pointerMode = false
            self.pauseUsage()
            self.log("Connection lost", failure.localizedDescription)
            if !self.connecting {
                self.notice = "Connection lost. Reconnecting…"
                self.scheduleReconnect()
            }
        }
        connectTask = Task {
            do {
                try await client.connect(allowFirstUseTrust: allowFirstUseTrust)
                guard connection === client else { return }
                connected = true; connecting = false; pairing = false; notice = nil
                await refreshInfo()
                log("Connected", "\(name) · \(host)")
                UserDefaults.standard.set(host, forKey: "tv.host")
                UserDefaults.standard.set(name, forKey: "tv.name")
                UserDefaults.standard.set(mac, forKey: "tv.mac")
                UserDefaults.standard.set(model, forKey: "tv.model")
                renderer = try? await UPnPRenderer.discover(host: host)
                await refresh()
                await refreshState()
                refreshTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        if Task.isCancelled { break }
                        guard (try? await client.checkAlive()) != nil else { break }
                        await refreshState()
                    }
                }
            } catch {
                guard connection === client else { return }
                client.close(); connected = false; connecting = false; pairing = false
                let needsUser: Bool
                if case .needsUser? = error as? RemoteError { needsUser = true } else { needsUser = false }
                self.error = needsUser ? error.localizedDescription : "\(error.localizedDescription) Make sure the TV is on and on the same Wi-Fi network."
                log("Connection failed", error.localizedDescription)
                if allowFirstUseTrust || needsUser { autoReconnect = false }
                scheduleReconnect()
            }
        }
    }
    private func scheduleReconnect() {
        guard autoReconnect else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { try? await Task.sleep(nanoseconds: 5_000_000_000); if !Task.isCancelled { connect(allowFirstUseTrust: false) } }
    }
    func disconnect() {
        pauseUsage()
        fileServer?.stop(); fileServer = nil; casting = false
        autoReconnect = false; connectTask?.cancel(); reconnectTask?.cancel(); refreshTask?.cancel(); volumeTask?.cancel(); iconTask?.cancel()
        connection?.close(); connection = nil; connected = false; connecting = false; pairing = false; hasVolume = false; textInputOpen = false; pointerMode = false
        renderer = nil; apps = []; appsFromCatalog = false
        activity.reset()
    }
    func discover() {
        guard !discovering else { return }; discovering = true; error = nil
        Task { devices = await TVDiscovery.search(); discovering = false; if devices.isEmpty { notice = "No TV found. Turn on your TV or enter its IP address below." } }
    }
    func select(_ tv: TVDevice) {
        disconnect(); host = tv.host; name = tv.name; model = tv.model; mac = tv.mac ?? ""
        connect()
    }
    /// Model, firmware, power state and the Wi-Fi MAC come from the TV's read-only description.
    func refreshInfo() async {
        guard let info = try? await TVInfo.fetch(host: host) else { return }
        if !info.modelName.isEmpty { model = info.modelName }
        if mac.isEmpty, !info.wifiMac.isEmpty { mac = info.wifiMac }
        if name.isEmpty || name == "Samsung TV" { name = info.displayName }
        system = [info.os.isEmpty ? "Tizen" : info.os, info.year].compactMap { $0 }.joined(separator: " · ")
        firmware = info.firmware
        powerActive = info.isOn
    }
    func refresh() async {
        guard let client = connection, connected else { return }
        do {
            let installed = try await client.installedApps()
            guard !installed.isEmpty else { throw RemoteError.message("The TV sent an empty app list.") }
            apps = installed.map { app in
                let known = AppCatalog.match(title: app.name, id: app.id)
                return TVApp(id: app.id, title: app.name, icon: known?.icon, type: app.type, iconPath: app.iconPath)
            }
            appsFromCatalog = false
        } catch {
            // Tizen 5 and later stopped listing apps; offer well-known Samsung app IDs instead.
            apps = AppCatalog.entries.compactMap { entry in entry.ids?.first.map { TVApp(id: $0, title: entry.title, icon: entry.icon, type: entry.type) } }
            appsFromCatalog = true
            log("App list unavailable", error.localizedDescription)
        }
        if UserDefaults.standard.object(forKey: "tv.favorites") == nil {
            favorites = Set(apps.filter { ["Netflix", "YouTube", "Prime Video", "Disney+"].contains(AppCatalog.match(title: $0.title, id: $0.id)?.title ?? "") }.prefix(4).map(\.id))
        }
        loadMissingIcons()
    }
    /// Icons the catalog does not bundle are requested once, one at a time, then cached.
    private func loadMissingIcons() {
        iconTask?.cancel()
        let missing = apps.filter { $0.icon == nil && $0.iconPath != nil && AppIcons.url(for: $0) == nil }
        guard !missing.isEmpty, let client = connection else { return }
        iconTask = Task {
            try? FileManager.default.createDirectory(at: AppIcons.cacheDirectory, withIntermediateDirectories: true)
            var loaded = 0
            for app in missing {
                guard !Task.isCancelled, connection === client, let path = app.iconPath else { break }
                guard let data = try? await client.icon(path), NSImage(data: data) != nil, data.count <= 2_097_152 else { continue }
                if (try? data.write(to: AppIcons.cacheFile(for: app.id), options: .atomic)) != nil { loaded += 1 }
            }
            if loaded > 0, !Task.isCancelled { iconRevision += 1 }
        }
    }
    func refreshState() async {
        guard connection != nil, connected else { return }
        if let info = try? await TVInfo.fetch(host: host) { powerActive = info.isOn } else { powerActive = false }
        await refreshVolume()
        observeUsage()
    }
    private func refreshVolume() async {
        if renderer?.renderingURL == nil { renderer = try? await UPnPRenderer.discover(host: host) }
        guard let renderer, let reading = try? await renderer.volume() else { hasVolume = false; return }
        // A slider drag in progress wins over a reading taken before it finished.
        if Date().timeIntervalSince(volumeEdited) > 1.5 { volume = Double(reading.level) }
        muted = reading.muted; hasVolume = true
    }
    private func observeUsage() {
        guard connected, powerActive, !homeRequested else {
            if homeRequested { journal.pause(); saveUsage() } else { pauseUsage() }
            return
        }
        if let id = currentAppID { journal.observe(host: host, appID: id, title: currentApp) }
        else if let input = currentInput { journal.observe(host: host, appID: "input:" + input.id, title: input.label) }
        else { journal.pause() }
        saveUsage()
    }
    private func changeActivity(_ change: (inout TVActivity) -> Void) {
        let before = activity
        change(&activity)
        if before != activity { observeUsage() }
    }
    func perform(_ action: @escaping (TizenConnection) async throws -> Void) {
        guard connected, let client = connection else { return }
        error = nil
        Task { do { try await action(client) } catch { self.error = error.localizedDescription; self.log("Command failed", error.localizedDescription) } }
    }
    func press(_ key: String) {
        log("Remote", key)
        changeActivity { $0.pressed(key) }
        perform { client in
            try await client.key(key)
            if ["KEY_VOLUP", "KEY_VOLDOWN", "KEY_MUTE"].contains(key) { try? await Task.sleep(nanoseconds: 350_000_000); await self.refreshVolume() }
        }
    }
    func swipePointer(dx: Double, dy: Double) {
        guard connected else { return }
        if pointerMode {
            guard let move = swipe.pointer(dx: dx, dy: dy) else { return }
            perform { client in try await client.movePointer(x: move.x, y: move.y) }
            return
        }
        for key in swipe.drag(dx: dx, dy: dy) { press(key) }
    }
    func tapSwipe() {
        guard pointerMode else { press("KEY_ENTER"); return }
        log("Remote", "Pointer click")
        perform { client in try await client.clickPointer() }
    }
    func endSwipe() { swipe.end() }
    func launch(_ app: TVApp) {
        log("Launch app", app.title)
        changeActivity { $0.opened(.app(app.id)) }
        let dial = AppCatalog.match(title: app.title, id: app.id)?.dial
        perform { client in try await client.launch(app.id, type: app.type, dial: dial) }
    }
    func changeVolume(_ value: Double) {
        volume = min(100, max(0, value)); volumeTask?.cancel(); volumeEdited = Date()
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let renderer, connected else { return }
            do { try await renderer.setVolume(Int(volume)) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func volumeStep(_ up: Bool) { press(up ? "KEY_VOLUP" : "KEY_VOLDOWN") }
    func toggleMute() {
        guard let renderer, hasVolume else { press("KEY_MUTE"); return }
        let target = !muted
        perform { _ in try await renderer.setMute(target); await self.refreshVolume() }
    }
    func input(_ input: TVInput) {
        log("Switch input", input.label)
        changeActivity { $0.opened(.input(input.id)) }
        perform { try await $0.key(input.key) }
    }
    func renameInput(_ input: TVInput, to label: String) {
        inputNames[input.id] = label.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(inputNames, forKey: "tv.inputNames")
    }
    func setHDMICount(_ count: Int) {
        hdmiCount = max(1, min(4, count)); UserDefaults.standard.set(hdmiCount, forKey: "tv.hdmiCount")
    }
    func media(_ key: String) { press(key) }
    func sendText(_ text: String) { guard !text.isEmpty else { return }; perform { try await $0.sendText(text) } }
    func enterText() { perform { try await $0.finishText() } }
    func setHidden(_ app: TVApp, _ hidden: Bool) {
        if hidden { hiddenApps.insert(app.id); favorites.remove(app.id); UserDefaults.standard.set(Array(favorites), forKey: "tv.favorites") }
        else { hiddenApps.remove(app.id) }
        UserDefaults.standard.set(Array(hiddenApps), forKey: "tv.hiddenApps")
    }
    func showHiddenApps() { hiddenApps.removeAll(); UserDefaults.standard.removeObject(forKey: "tv.hiddenApps") }
    func toggleFavorite(_ app: TVApp) {
        if favorites.contains(app.id) { favorites.remove(app.id) } else { favorites.insert(app.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "tv.favorites")
    }
    private func saveUsage() {
        do { try journal.save() } catch { notice = "Could not save usage history." }
        usageRevision += 1
    }
    private func pauseUsage() { journal.pause(); saveUsage(); powerActive = false }
    func usage(days: Int) -> [UsageTotal] {
        let since = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-Double(max(0, days - 1)) * 86400)
        return journal.totals(host: host, since: since)
    }
    var mostUsedApps: [TVApp] { usage(days: 7).compactMap { total in apps.first { $0.id == total.id } } }
    func chooseMedia() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.movie, .audio, .image]; picker.prompt = "Select"; picker.title = "Send media to your Samsung TV"
        if picker.runModal() == .OK { mediaFile = picker.url; mediaStatus = "Ready to send. This will open the file on your TV." }
    }
    func castMedia() {
        guard !mediaBusy, connected, let file = mediaFile else { return }
        mediaBusy = true; error = nil
        let targetHost = host
        Task {
            defer { mediaBusy = false }
            var newServer: MediaFileServer?
            do {
                let control: UPnPRenderer
                if let renderer, renderer.transportURL != nil { control = renderer } else { control = try await UPnPRenderer.discover(host: targetHost); renderer = control }
                let server = MediaFileServer(file: file, allowedHost: targetHost); newServer = server
                let url = try await server.start()
                try await control.play(url, title: file.lastPathComponent, mime: server.mime)
                fileServer?.stop(); fileServer = server; casting = true
                mediaStatus = "Sent to TV · \(file.lastPathComponent)"; log("Send media", file.lastPathComponent)
            } catch { newServer?.stop(); self.error = error.localizedDescription; mediaStatus = "Could not play this file." }
        }
    }
    func controlCast(_ action: String) {
        guard casting, !mediaBusy, let renderer, ["Play", "Pause", "Stop"].contains(action) else { return }
        mediaBusy = true
        Task {
            defer { mediaBusy = false }
            do {
                try await renderer.transport(action)
                if action == "Stop" { fileServer?.stop(); fileServer = nil; casting = false; mediaStatus = "Casting stopped." }
                else { mediaStatus = action == "Pause" ? "Media paused on TV." : "Playing on TV." }
            } catch { self.error = error.localizedDescription }
        }
    }
    func power() {
        if connected {
            log("Remote", "KEY_POWER")
            perform { client in try await client.key("KEY_POWER"); self.disconnect(); self.notice = "TV turned off." }
        } else {
            do { try TVDiscovery.wake(mac: mac, host: host); notice = "Wake signal sent. If the TV stays off, turn on Power On with Mobile in its network settings." }
            catch { self.error = error.localizedDescription }
        }
    }
    func forgetPairing() {
        guard !host.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Forget this TV's pairing?"
        alert.informativeText = "The saved token and certificate for this TV will be removed from this Mac. You can connect and pair again."
        alert.addButton(withTitle: "Forget pairing"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pairingHost = host
        disconnect()
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try PairingToken.delete(pairingHost) }.value
                notice = "Saved pairing removed. Connect to pair this TV again."
            } catch {
                self.error = "Could not remove saved pairing: \(error.localizedDescription)"
            }
        }
    }
}
