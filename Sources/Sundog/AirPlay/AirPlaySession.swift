import CFairPlay
import CryptoKit
import Foundation
import Network

/// One AirPlay control connection from an iPhone.
///
/// The order of requests for screen mirroring:
/// 1. `GET /info`: the receiver capabilities.
/// 2. `POST /pair-setup` and `POST /pair-verify`: legacy pairing with Ed25519 and X25519.
/// 3. `POST /fp-setup` (two times): the FairPlay handshake.
/// 4. `SETUP` with `ekey`: the session key and the timing port.
/// 5. `SETUP` with `streams`: the mirror stream (type 110) and the audio stream (type 96).
/// 6. `RECORD`, then `GET_PARAMETER`, `SET_PARAMETER`, and `POST /feedback` while the session runs.
/// 7. `TEARDOWN`.
///
/// Only `queue` reads and writes the state.
final class AirPlaySession: @unchecked Sendable {
    enum Event {
        case connecting
        case mirroringStarted
        case videoSize(CGSize)
        case mirroringEnded
    }

    private let connection: NWConnection
    private let identity: AirPlayIdentity
    private let sink: VideoSink
    private let queue: DispatchQueue
    private let onEvent: (Event) -> Void
    var onClose: (() -> Void)?

    private var buffer = Data()
    private var pending: [RTSPRequest] = []
    private var isHandling = false

    // Pairing
    private var verifyKey: Data?
    private var verifyIV: Data?
    private var ourAgreementKey: Data?
    private var theirAgreementKey: Data?
    private var theirSigningKey: Data?
    private var sharedSecret: Data?
    private var isPaired = false

    // FairPlay and streams
    private var keyMessage: Data?
    private var sessionKey: Data?
    private var timing: TimingClient?
    private var mirror: MirrorStream?
    private var audioListeners: [NWListener] = []
    private var audioConnections: [NWConnection] = []
    private static let maximumPendingRequests = 32

    init(connection: NWConnection, identity: AirPlayIdentity, sink: VideoSink, queue: DispatchQueue,
         onEvent: @escaping (Event) -> Void) {
        self.connection = connection
        self.identity = identity
        self.sink = sink
        self.queue = queue
        self.onEvent = onEvent
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() {
        guard let onClose else { return }
        self.onClose = nil
        stopStreams()
        connection.cancel()
        onClose()
    }

    // MARK: Connection

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.buffer.append(data)
                self.parseRequests()
            }
            if isComplete || error != nil {
                self.close()
            } else {
                self.receive()
            }
        }
    }

    private func parseRequests() {
        do {
            while let request = try RTSPRequest.parse(from: &buffer) {
                pending.append(request)
                // An iPhone sends one request at a time. A long queue means a misbehaving client.
                if pending.count > Self.maximumPendingRequests {
                    close()
                    return
                }
            }
        } catch {
            close()
            return
        }
        handleNext()
    }

    private func handleNext() {
        guard !isHandling, !pending.isEmpty else { return }
        isHandling = true
        let request = pending.removeFirst()
        handle(request) { [weak self] response in
            guard let self else { return }
            self.connection.send(content: response.serialized(for: request), completion: .contentProcessed { _ in })
            if response.closesConnection {
                self.close()
                return
            }
            self.isHandling = false
            self.handleNext()
        }
    }

    // MARK: Requests

    private func handle(_ request: RTSPRequest, reply: @escaping @Sendable (RTSPResponse) -> Void) {
        switch (request.method, request.path) {
        case ("GET", "/info"):
            reply(info(request))
        case ("POST", "/pair-setup"):
            reply(request.body.count == 32 ? .binary(identity.publicKey) : .failure(400, "Bad Request"))
        case ("POST", "/pair-verify"):
            reply(pairVerify(request.body))
        case ("POST", "/fp-setup"):
            reply(fairPlaySetup(request.body))
        case ("OPTIONS", _):
            reply(RTSPResponse(headers: [("Public", "SETUP, RECORD, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER")]))
        case ("SETUP", _):
            setup(request, reply: reply)
        case ("GET_PARAMETER", _):
            reply(RTSPResponse(headers: [("Content-Type", "text/parameters")], body: Data("volume: 0.000000\r\n".utf8)))
        case ("RECORD", _):
            reply(RTSPResponse(headers: [("Audio-Latency", "11025"), ("Audio-Jack-Status", "connected; type=analog")]))
        case ("TEARDOWN", _):
            teardown(request)
            reply(.ok)
        default:
            // SET_PARAMETER, FLUSH, POST /feedback, POST /audioMode, and other requests do not have an action.
            reply(.ok)
        }
    }

    private func info(_ request: RTSPRequest) -> RTSPResponse {
        if let qualifier = (request.plistBody?["qualifier"] as? [String])?.first {
            switch qualifier {
            case "txtAirPlay": return .plist(["txtAirPlay": identity.airPlayTXT])
            case "txtRAOP": return .plist(["txtRAOP": identity.raopTXT])
            default: break
            }
        }

        let display: [String: Any] = [
            "uuid": identity.pairingID,
            "widthPhysical": 0,
            "heightPhysical": 0,
            "width": AirPlayIdentity.displayWidth,
            "height": AirPlayIdentity.displayHeight,
            "widthPixels": AirPlayIdentity.displayWidth,
            "heightPixels": AirPlayIdentity.displayHeight,
            "rotation": false,
            "refreshRate": 1.0 / 60.0,
            "maxFPS": 60,
            "overscanned": false,
            "features": 14,
        ]
        let audioLatency: (Int) -> [String: Any] = { type in
            ["type": type, "audioType": "default", "inputLatencyMicros": 0, "outputLatencyMicros": false]
        }
        let audioFormat: (Int) -> [String: Any] = { type in
            ["type": type, "audioInputFormats": 0x3FF_FFFC, "audioOutputFormats": 0x3FF_FFFC]
        }
        return .plist([
            "deviceID": identity.deviceID,
            "macAddress": identity.deviceID,
            "pk": identity.publicKey,
            "features": NSNumber(value: AirPlayIdentity.features),
            "name": identity.name,
            "pi": identity.pairingID,
            "vv": 2,
            "statusFlags": 68,
            "keepAliveLowPower": 1,
            "keepAliveSendStatsAsBody": true,
            "sourceVersion": AirPlayIdentity.sourceVersion,
            "model": AirPlayIdentity.model,
            "initialVolume": 0.0,
            "audioLatencies": [audioLatency(100), audioLatency(101)],
            "audioFormats": [audioFormat(100), audioFormat(101)],
            "displays": [display],
        ])
    }

    /// Legacy pairing. Step 1 exchanges X25519 keys and signatures. Step 2 checks the signature of the iPhone.
    private func pairVerify(_ body: Data) -> RTSPResponse {
        let bytes = [UInt8](body)
        guard bytes.count == 68 else { return .failure(400, "Bad Request") }

        if bytes[0] == 1 {
            let theirs = Data(bytes[4..<36])
            guard let theirPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs) else {
                return .failure(400, "Bad Request", close: true)
            }
            let ours = Curve25519.KeyAgreement.PrivateKey()
            guard let secret = try? ours.sharedSecretFromKeyAgreement(with: theirPublic) else {
                return .failure(400, "Bad Request", close: true)
            }
            let shared = secret.withUnsafeBytes { Data($0) }
            let ourPublic = ours.publicKey.rawRepresentation
            let key = (Data("Pair-Verify-AES-Key".utf8) + shared).sha512Prefix(16)
            let iv = (Data("Pair-Verify-AES-IV".utf8) + shared).sha512Prefix(16)
            guard var signature = try? identity.signature(for: ourPublic + theirs),
                  let cipher = AESCTR(key: key, iv: iv) else {
                return .failure(500, "Internal Server Error", close: true)
            }
            cipher.apply(to: &signature)

            sharedSecret = shared
            ourAgreementKey = ourPublic
            theirAgreementKey = theirs
            theirSigningKey = Data(bytes[36..<68])
            verifyKey = key
            verifyIV = iv
            isPaired = false
            return .binary(ourPublic + signature)
        }

        guard let verifyKey, let verifyIV, let ourAgreementKey, let theirAgreementKey, let theirSigningKey,
              let cipher = AESCTR(key: verifyKey, iv: verifyIV),
              let theirPublic = try? Curve25519.Signing.PublicKey(rawRepresentation: theirSigningKey) else {
            return .failure(470, "Connection Authorization Required", close: true)
        }
        // The key stream continues after the 64 bytes that Sundog used to encrypt its signature.
        var skipped = Data(count: 64)
        cipher.apply(to: &skipped)
        var signature = Data(bytes[4..<68])
        cipher.apply(to: &signature)
        guard theirPublic.isValidSignature(signature, for: theirAgreementKey + ourAgreementKey) else {
            return .failure(470, "Connection Authorization Required", close: true)
        }
        isPaired = true
        return .ok
    }

    private func fairPlaySetup(_ body: Data) -> RTSPResponse {
        let request = [UInt8](body)
        switch request.count {
        case 16:
            var response = [UInt8](repeating: 0, count: 142)
            guard sundog_fairplay_setup(request, &response) == 0 else { return .failure(501, "Not Implemented") }
            keyMessage = nil
            return .binary(Data(response))
        case 164:
            var response = [UInt8](repeating: 0, count: 32)
            guard sundog_fairplay_handshake(request, &response) == 0 else { return .failure(501, "Not Implemented") }
            keyMessage = body
            return .binary(Data(response))
        default:
            return .failure(400, "Bad Request")
        }
    }

    private func setup(_ request: RTSPRequest, reply: @escaping @Sendable (RTSPResponse) -> Void) {
        guard let plist = request.plistBody else {
            reply(.failure(400, "Bad Request"))
            return
        }

        if let encryptedKey = plist["ekey"] as? Data {
            guard encryptedKey.count == 72, let keyMessage else {
                reply(.failure(400, "Bad Request", close: true))
                return
            }
            var key = [UInt8](repeating: 0, count: 16)
            sundog_fairplay_decrypt([UInt8](keyMessage), [UInt8](encryptedKey), &key)
            var sessionKey = Data(key)
            if isPaired, let sharedSecret {
                sessionKey = (sessionKey + sharedSecret).sha512Prefix(16)
            }
            self.sessionKey = sessionKey

            let remoteTimingPort = (plist["timingPort"] as? NSNumber)?.uint16Value ?? 0
            startTiming(remotePort: remoteTimingPort) { localPort in
                reply(.plist(["eventPort": 0, "timingPort": Int(localPort)]))
            }
            return
        }

        guard let streams = plist["streams"] as? [[String: Any]] else {
            reply(.ok)
            return
        }
        setupStreams(streams, reply: reply)
    }

    private func setupStreams(_ streams: [[String: Any]], reply: @escaping @Sendable (RTSPResponse) -> Void) {
        let results = QueueLocal<[[String: Any]]>([])
        let group = DispatchGroup()

        for stream in streams {
            let type = (stream["type"] as? NSNumber)?.intValue
            switch type {
            case 110:
                guard let sessionKey, let id = stream["streamConnectionID"] as? NSNumber,
                      let mirror = MirrorStream(
                        sessionKey: sessionKey, streamConnectionID: Self.unsigned(id), sink: sink, queue: queue)
                else { continue }
                self.mirror?.stop()
                self.mirror = mirror
                mirror.onVideoSize = { [weak self] size in self?.onEvent(.videoSize(size)) }
                mirror.onFirstFrame = { [weak self] in self?.onEvent(.mirroringStarted) }
                onEvent(.connecting)
                mirror.onEnd = { [weak self] in self?.endMirroring() }
                group.enter()
                mirror.start { port in
                    if let port {
                        results.value.append(["type": 110, "dataPort": Int(port)])
                    }
                    group.leave()
                }
            case 96:
                // Sundog does not play audio. It accepts the stream and drops the packets.
                group.enter()
                openDiscardPorts(count: 2) { ports in
                    if ports.count == 2 {
                        results.value.append(["type": 96, "dataPort": Int(ports[0]), "controlPort": Int(ports[1])])
                    }
                    group.leave()
                }
            default:
                continue
            }
        }

        group.notify(queue: queue) {
            reply(.plist(["streams": results.value]))
        }
    }

    private func teardown(_ request: RTSPRequest) {
        let streams = request.plistBody?["streams"] as? [[String: Any]]
        let types = streams?.compactMap { ($0["type"] as? NSNumber)?.intValue }
        if types == nil || types!.contains(110) {
            endMirroring()
        }
        if types == nil {
            stopStreams()
        }
    }

    private func endMirroring() {
        guard mirror != nil else { return }
        mirror?.stop()
        mirror = nil
        // The receiver clears the shared video sink, and only for the session that shows video.
        onEvent(.mirroringEnded)
    }

    private func stopStreams() {
        endMirroring()
        timing?.stop()
        timing = nil
        audioListeners.forEach { $0.cancel() }
        audioListeners.removeAll()
        audioConnections.forEach { $0.cancel() }
        audioConnections.removeAll()
    }

    // MARK: Ports

    private func startTiming(remotePort: UInt16, ready: @escaping @Sendable (UInt16) -> Void) {
        guard remotePort != 0, case let .hostPort(host, _) = connection.endpoint,
              let port = NWEndpoint.Port(rawValue: remotePort) else {
            ready(0)
            return
        }
        timing?.stop()
        let timing = TimingClient(host: host, port: port, queue: queue)
        self.timing = timing
        timing.start(ready: ready)
    }

    private func openDiscardPorts(count: Int, ready: @escaping @Sendable ([UInt16]) -> Void) {
        let ports = QueueLocal<[UInt16]>([])
        let remaining = QueueLocal(count)
        for _ in 0..<count {
            guard let listener = try? NWListener(using: .udp) else {
                remaining.value -= 1
                continue
            }
            audioListeners.append(listener)
            let reported = QueueLocal(false)
            listener.stateUpdateHandler = { state in
                guard !reported.value else { return }
                switch state {
                case .ready:
                    reported.value = true
                    if let port = listener.port?.rawValue { ports.value.append(port) }
                    remaining.value -= 1
                case .failed, .cancelled, .waiting:
                    reported.value = true
                    remaining.value -= 1
                default:
                    return
                }
                if remaining.value == 0 { ready(ports.value) }
            }
            listener.newConnectionHandler = { [weak self, queue] connection in
                self?.audioConnections.append(connection)
                connection.start(queue: queue)
                Self.discard(connection)
            }
            listener.start(queue: queue)
        }
        if remaining.value == 0 { ready(ports.value) }
    }

    private static func discard(_ connection: NWConnection) {
        connection.receiveMessage { _, _, _, error in
            if error == nil { discard(connection) }
        }
    }

    /// A property list can store a large stream ID as a negative signed integer.
    private static func unsigned(_ number: NSNumber) -> UInt64 {
        String(cString: number.objCType) == "Q" ? number.uint64Value : UInt64(bitPattern: number.int64Value)
    }
}

/// Sends NTP-style timing requests to the iPhone. An AirPlay receiver must send these requests.
final class TimingClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, queue: DispatchQueue) {
        connection = NWConnection(host: host, port: port, using: .udp)
        self.queue = queue
    }

    /// Calls `ready` on the queue with the local UDP port, or with 0 if it fails.
    func start(ready: @escaping @Sendable (UInt16) -> Void) {
        let reported = QueueLocal(false)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !reported.value else { return }
            switch state {
            case .ready:
                reported.value = true
                var localPort: UInt16 = 0
                if case let .hostPort(_, port) = self.connection.currentPath?.localEndpoint {
                    localPort = port.rawValue
                }
                ready(localPort)
                self.receive()
                self.startRequests()
            case .failed, .cancelled, .waiting:
                reported.value = true
                ready(0)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        connection.cancel()
    }

    private func startRequests() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 3)
        timer.setEventHandler { [weak self] in self?.sendRequest() }
        timer.resume()
        self.timer = timer
    }

    private func sendRequest() {
        var request = [UInt8](repeating: 0, count: 32)
        request[0] = 0x80
        request[1] = 0xD2
        request[3] = 0x07
        let ntpSeconds = Date().timeIntervalSince1970 + 2_208_988_800
        let seconds = UInt32(ntpSeconds)
        let fraction = UInt32((ntpSeconds - Double(seconds)) * 4_294_967_296)
        for byte in 0..<4 {
            request[24 + byte] = UInt8(truncatingIfNeeded: seconds >> (24 - 8 * byte))
            request[28 + byte] = UInt8(truncatingIfNeeded: fraction >> (24 - 8 * byte))
        }
        connection.send(content: Data(request), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receiveMessage { [weak self] _, _, _, error in
            if error == nil { self?.receive() }
        }
    }
}
