import Foundation
import Security
import CryptoKit

enum TVCertificateDecision: Equatable { case matched, approvalRequired, rejected }
enum TVCertificatePolicy {
    static func decide(expected: String?, received: String, canApprove: Bool) -> TVCertificateDecision {
        if let expected { return expected == received ? .matched : .rejected }
        return canApprove ? .approvalRequired : .rejected
    }
}

// Samsung TVs present a private certificate on the Smart View port. Explicit first-time
// approval pins the leaf for this host; an existing pin must always match.
final class TVCertificateTrust: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    static let port = 8002
    let host: String
    private let lock = NSLock()
    private var fingerprint: String?
    private var approval: (@Sendable (String, String) async -> Bool)?
    private var trustError: Error?
    private var opening: [Int: CheckedContinuation<Void, Error>] = [:]
    init(host: String) { self.host = host }
    func configure(fingerprint: String?, approval: (@Sendable (String, String) async -> Bool)?) {
        lock.lock()
        self.fingerprint = fingerprint
        self.approval = approval
        trustError = nil
        lock.unlock()
    }
    func approvedFingerprint() -> String? {
        lock.lock(); defer { lock.unlock() }
        return fingerprint
    }
    private func reject(_ message: String, _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        lock.lock(); trustError = RemoteError.message(message); lock.unlock()
        completion(.cancelAuthenticationChallenge, nil)
    }
    private func approve(_ digest: String) {
        lock.lock(); fingerprint = digest; lock.unlock()
    }
    func open(_ task: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); opening[task.taskIdentifier] = continuation; lock.unlock()
            task.resume()
        }
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock(); let continuation = opening.removeValue(forKey: webSocketTask.taskIdentifier); lock.unlock()
        continuation?.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = opening.removeValue(forKey: task.taskIdentifier); let failure = trustError; lock.unlock()
        continuation?.resume(throwing: failure ?? error ?? RemoteError.message("The TV connection closed before it opened."))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        guard challenge.protectionSpace.host == host, challenge.protectionSpace.port == Self.port,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificates.first else {
            reject("The TV did not provide a certificate for the selected local address.", completionHandler)
            return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        lock.lock(); let expected = fingerprint; let requestApproval = approval; lock.unlock()
        switch TVCertificatePolicy.decide(expected: expected, received: digest, canApprove: requestApproval != nil) {
        case .matched:
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        case .rejected:
            reject(expected == nil
                ? "This TV has no trusted certificate yet. Click Connect to confirm first-time pairing."
                : "The TV certificate has changed. Verify the device and pair it again in Settings.", completionHandler)
            return
        case .approvalRequired: break
        }
        guard let requestApproval else {
            reject("This TV has no trusted certificate yet. Click Connect to confirm first-time pairing.", completionHandler)
            return
        }
        Task {
            guard await requestApproval(host, digest) else {
                reject("The TV certificate was not approved.", completionHandler)
                return
            }
            approve(digest)
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

enum RemoteError: LocalizedError {
    case message(String)
    /// Only the person can fix this (trust the TV, choose Allow, pair again), so retrying on a timer would not help.
    case needsUser(String)
    var errorDescription: String? {
        switch self { case .message(let text), .needsUser(let text): return text }
    }
}

/// Frames for the Samsung Smart View remote channel (Tizen, 2016 and later).
enum TizenMessage {
    static let clientName = "SamsungTizen-menubar"
    static func channelURL(host: String, token: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"; components.host = host; components.port = TVCertificateTrust.port
        components.path = "/api/v2/channels/samsung.remote.control"
        var items = [URLQueryItem(name: "name", value: Data(clientName.utf8).base64EncodedString())]
        if let token, !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items
        return components.url
    }
    static func key(_ code: String) -> [String: Any] {
        ["method": "ms.remote.control", "params": ["Cmd": "Click", "DataOfCmd": code, "Option": "false", "TypeOfRemote": "SendRemoteKey"]]
    }
    static func text(_ text: String) -> [String: Any] {
        ["method": "ms.remote.control", "params": ["Cmd": Data(text.utf8).base64EncodedString(), "DataOfCmd": "base64", "TypeOfRemote": "SendInputString"]]
    }
    static let textEnd: [String: Any] = ["method": "ms.remote.control", "params": ["TypeOfRemote": "SendInputEnd"]]
    static func emit(_ event: String, data: [String: Any]? = nil) -> [String: Any] {
        var params: [String: Any] = ["event": event, "to": "host"]
        if let data { params["data"] = data }
        return ["method": "ms.channel.emit", "params": params]
    }
    /// Store apps (type 2) open through a deep link; native apps (type 4) need a native launch.
    static func launch(_ appID: String, type: Int?) -> [String: Any] {
        emit("ed.apps.launch", data: ["appId": appID, "action_type": type == 4 ? "NATIVE_LAUNCH" : "DEEP_LINK", "metaTag": ""])
    }
}

enum TizenHandshake: Equatable {
    case connected(token: String?)
    case unauthorized
    case timedOut
    static func parse(_ object: [String: Any]) -> TizenHandshake? {
        switch object["event"] as? String {
        case "ms.channel.connect":
            let token = (object["data"] as? [String: Any])?["token"]
            let text = (token as? String) ?? (token as? NSNumber)?.stringValue
            return .connected(token: text?.isEmpty == false ? text : nil)
        case "ms.channel.unauthorized": return .unauthorized
        case "ms.channel.timeOut": return .timedOut
        default: return nil
        }
    }
}

struct TizenApp: Equatable {
    let id: String
    let name: String
    let type: Int?
    let iconPath: String?
    static func list(_ object: [String: Any]) -> [TizenApp] {
        let outer = object["data"] as? [String: Any]
        let rows = outer?["data"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let id = row["appId"] as? String, !id.isEmpty, let name = row["name"] as? String, seen.insert(id).inserted else { return nil }
            let type = (row["app_type"] as? NSNumber)?.intValue ?? (row["app_type"] as? String).flatMap(Int.init)
            return TizenApp(id: id, name: name, type: type, iconPath: row["icon"] as? String)
        }
    }
}

private final class PingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        if let error { pending?.resume(throwing: error) } else { pending?.resume() }
    }
}

@MainActor final class TizenConnection {
    let host: String
    private let session: URLSession
    private let trust: TVCertificateTrust
    private var socket: URLSessionWebSocketTask?
    private var ready = false
    private var receiver: Task<Void, Never>?
    private var handshake: CheckedContinuation<TizenHandshake, Error>?
    private var earlyHandshake: TizenHandshake?
    private var waiters: [(id: UUID, events: Set<String>, continuation: CheckedContinuation<[String: Any]?, Error>)] = []
    var onPairing: (() -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onEvent: ((String, String) -> Void)?
    var onTextInput: ((Bool) -> Void)?
    var onCertificateTrust: (@MainActor (String, String) async -> Bool)?
    init(host: String) {
        self.host = host
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        trust = TVCertificateTrust(host: host)
        session = URLSession(configuration: configuration, delegate: trust, delegateQueue: nil)
    }

    func connect(allowFirstUseTrust: Bool = false) async throws {
        guard Self.localHost(host) else { throw RemoteError.message("Enter the TV's local IPv4 address.") }
        let pairingHost = host
        let saved = await Task.detached(priority: .userInitiated) {
            (PairingToken.read(pairingHost), TVCertificatePin.read(pairingHost))
        }.value
        let storedToken = saved.0, storedPin = saved.1
        let confirmation = onCertificateTrust
        guard storedPin != nil || (allowFirstUseTrust && confirmation != nil) else {
            throw RemoteError.needsUser("This TV has no trusted certificate yet. Click Connect to confirm first-time pairing.")
        }
        let approval: (@Sendable (String, String) async -> Bool)?
        if allowFirstUseTrust {
            approval = { host, fingerprint in await confirmation?(host, fingerprint) ?? false }
        } else { approval = nil }
        trust.configure(fingerprint: storedPin, approval: approval)
        guard let url = TizenMessage.channelURL(host: host, token: storedToken) else { throw RemoteError.message("Enter the TV's local IPv4 address.") }
        try Task.checkCancellation()
        let ws = session.webSocketTask(with: url); socket = ws
        try await trust.open(ws)
        ready = false; earlyHandshake = nil
        receiver = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let frame = try await ws.receive()
                    let data: Data
                    switch frame { case .string(let s): data = Data(s.utf8); case .data(let d): data = d; @unknown default: continue }
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    self?.handle(object)
                }
            } catch { if !Task.isCancelled { self?.failed(error) } }
        }
        // Without a saved token the TV asks for permission before it answers.
        if storedToken == nil { onPairing?() }
        let answer = try await waitForHandshake(timeout: storedToken == nil ? 75 : 15)
        try Task.checkCancellation()
        switch answer {
        case .unauthorized:
            throw RemoteError.needsUser(storedToken == nil
                ? "The TV denied the connection. Choose Allow on the TV, or remove this Mac from the TV's device list and try again."
                : "The TV no longer accepts this Mac. Use Forget pairing in Settings, then connect again.")
        case .timedOut:
            throw RemoteError.needsUser("Pairing timed out. Choose Allow on the TV and try again.")
        case .connected(let token):
            if let token, token != storedToken {
                try await Task.detached(priority: .userInitiated) { try PairingToken.save(token, host: pairingHost) }.value
            }
        }
        // First-use trust is durable only after the TV has authorized this Mac.
        if storedPin == nil, let fingerprint = trust.approvedFingerprint() {
            try await Task.detached(priority: .userInitiated) { try TVCertificatePin.save(fingerprint, host: pairingHost) }.value
        }
        ready = true
    }
    nonisolated static func validHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) && Int($0).map { (0...255).contains($0) } == true }
    }
    nonisolated static func localHost(_ host: String) -> Bool {
        guard validHost(host) else { return false }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 169 && octets[1] == 254)
    }
    private func waitForHandshake(timeout: UInt64) async throws -> TizenHandshake {
        if let answer = earlyHandshake { earlyHandshake = nil; return answer }
        return try await withCheckedThrowingContinuation { continuation in
            handshake = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                guard let self, let pending = self.handshake else { return }
                self.handshake = nil
                pending.resume(throwing: RemoteError.message("Pairing timed out. Choose Allow on the TV and try again."))
            }
        }
    }
    private func handle(_ object: [String: Any]) {
        let event = object["event"] as? String ?? ""
        if let answer = TizenHandshake.parse(object) {
            if let pending = handshake { handshake = nil; pending.resume(returning: answer) }
            else if !ready { earlyHandshake = answer }
            else if answer == .unauthorized { failed(RemoteError.message("The TV revoked this Mac's access.")) }
            return
        }
        switch event {
        case "ms.remote.imeStart": onTextInput?(true)
        case "ms.remote.imeEnd": onTextInput?(false)
        case "ms.error":
            let message = (object["data"] as? [String: Any])?["message"] as? String ?? "The TV rejected the command."
            onEvent?("Error", message)
        default: break
        }
        if let index = waiters.firstIndex(where: { $0.events.contains(event) }) {
            waiters.remove(at: index).continuation.resume(returning: object)
        }
    }
    private func failed(_ error: Error) {
        handshake?.resume(throwing: error); handshake = nil
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.continuation.resume(throwing: error) }
        onDisconnect?(error)
    }
    func close() {
        receiver?.cancel(); receiver = nil; socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; session.invalidateAndCancel()
        handshake?.resume(throwing: CancellationError()); handshake = nil
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }
    private func send(_ object: [String: Any]) async throws {
        guard let ws = socket else { throw RemoteError.message("Connect to the TV first.") }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }
    /// Sends a frame and waits for the first reply among `events`; nil when the TV stays silent.
    private func exchange(_ object: [String: Any], events: Set<String>, timeout: UInt64) async throws -> [String: Any]? {
        guard socket != nil else { throw RemoteError.message("Connect to the TV first.") }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((id, events, continuation))
            Task { [weak self] in
                do { try await self?.send(object) }
                catch { self?.resolve(id, .failure(error)) }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                self?.resolve(id, .success(nil))
            }
        }
    }
    private func resolve(_ id: UUID, _ result: Result<[String: Any]?, Error>) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(with: result)
    }
    func key(_ code: String) async throws { try await send(TizenMessage.key(code)) }
    func sendText(_ text: String) async throws {
        // Record that text was sent, never the text itself.
        onEvent?("Command", "Text input")
        try await send(TizenMessage.text(text))
    }
    func finishText() async throws { try await send(TizenMessage.textEnd) }
    func installedApps() async throws -> [TizenApp] {
        onEvent?("Read", "ed.installedApp.get")
        guard let answer = try await exchange(TizenMessage.emit("ed.installedApp.get"), events: ["ed.installedApp.get"], timeout: 4) else {
            throw RemoteError.message("The TV did not send its app list.")
        }
        return TizenApp.list(answer)
    }
    /// Tizen 5.5 drops the Smart View launch frame without an error. DIAL (the casting service the
    /// phone apps use) opens the apps registered there, the REST endpoint opens the rest, and the
    /// frame stays as the last try for older firmware.
    func launch(_ appID: String, type: Int?, dial: String?) async throws {
        if let dial, await launchThroughDIAL(dial) { return }
        if await launchThroughREST(appID) { return }
        // Some firmware opens the app without confirming it, so silence is not a failure.
        let answer = try await exchange(TizenMessage.launch(appID, type: type), events: ["ed.apps.launch", "ms.error"], timeout: 4)
        if answer?["event"] as? String == "ms.error" {
            throw RemoteError.message((answer?["data"] as? [String: Any])?["message"] as? String ?? "The TV could not open this app.")
        }
    }
    /// DIAL answers 201 when it starts the app and also brings an app running in the background to the front.
    private func launchThroughDIAL(_ name: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "http"; components.host = host; components.port = 8080; components.path = "/ws/apps/\(name)"
        guard let url = components.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpMethod = "POST"; request.httpBody = Data()
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return [200, 201].contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    /// Uses the pinned certificate of the Smart View port; the TV answers `true` once the app is open.
    private func launchThroughREST(_ appID: String) async -> Bool {
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.port = TVCertificateTrust.port
        components.path = "/api/v2/applications/\(appID)"
        guard let url = components.url else { return false }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "false"
    }
    func icon(_ path: String) async throws -> Data {
        let answer = try await exchange(TizenMessage.emit("ed.apps.icon", data: ["iconPath": path]), events: ["ed.apps.icon"], timeout: 6)
        guard let encoded = (answer?["data"] as? [String: Any])?["imageData"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw RemoteError.message("The TV did not send this icon.")
        }
        return data
    }
    /// Detects a silently dropped socket; the receive loop then reports the disconnect.
    func checkAlive() async throws {
        guard let ws = socket else { throw RemoteError.message("Connect to the TV first.") }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result = PingResult(continuation)
                ws.sendPing { error in result.finish(error) }
                Task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    result.finish(RemoteError.message("The TV stopped responding."))
                }
            }
        } catch { ws.cancel(with: .goingAway, reason: nil); throw error }
    }
}
