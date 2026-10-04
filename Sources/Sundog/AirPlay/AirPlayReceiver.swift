import Foundation
import Network
import dnssd

/// A receiver for AirPlay screen mirroring. iPhones on the same network show it in Screen Mirroring.
final class AirPlayReceiver: @unchecked Sendable {
    enum Event: Sendable {
        case waiting
        case connecting
        case mirroring
        case videoSize(CGSize)
        case failed
    }

    private let identity: AirPlayIdentity
    private let sink: VideoSink
    private let onEvent: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.lahariganti.Sundog.airplay", qos: .userInteractive)
    private var listener: NWListener?
    private var advertisements: [DNSServiceRef] = []
    private var sessions: [ObjectIdentifier: AirPlaySession] = [:]
    /// The session that shows video.
    private var mirroringSession: ObjectIdentifier?
    /// A session that set up its video stream but has no frame yet, while no session shows video.
    private var connectingSession: ObjectIdentifier?
    /// The last video size of each session, to restore the window shape after a takeover.
    private var videoSizes: [ObjectIdentifier: CGSize] = [:]
    private static let maximumSessions = 8

    init(name: String, sink: VideoSink, onEvent: @escaping @Sendable (Event) -> Void) {
        identity = AirPlayIdentity.load(name: name)
        self.sink = sink
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let listener = try NWListener(using: .tcp)
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                onEvent(.failed)
            }
        }
    }

    /// Ends the current mirroring session. The iPhone stops Screen Mirroring.
    func stopMirroring() {
        queue.async { [self] in
            guard let id = mirroringSession else { return }
            sessions[id]?.close()
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue, advertise(port: port) else {
                onEvent(.failed)
                return
            }
            onEvent(.waiting)
        case .failed:
            onEvent(.failed)
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        // Every client on the local network can connect. Limit the memory that they can use.
        guard sessions.count < Self.maximumSessions else {
            connection.cancel()
            return
        }
        var id: ObjectIdentifier?
        let session = AirPlaySession(connection: connection, identity: identity, sink: sink, queue: queue) { [weak self] event in
            guard let self, let id else { return }
            self.sessionEvent(event, from: id)
        }
        id = ObjectIdentifier(session)
        sessions[id!] = session
        session.onClose = { [weak self] in
            guard let self, let id else { return }
            self.sessions[id] = nil
            self.videoSizes[id] = nil
            self.endSession(id)
        }
        session.start()
    }

    private func sessionEvent(_ event: AirPlaySession.Event, from id: ObjectIdentifier) {
        switch event {
        case .connecting:
            guard mirroringSession == nil else { return }
            connectingSession = id
            onEvent(.connecting)
        case .videoSize(let size):
            videoSizes[id] = size
            if mirroringSession == id || (mirroringSession == nil && connectingSession == id) {
                onEvent(.videoSize(size))
            }
        case .mirroringStarted:
            // A new iPhone replaces the current one. Change the owner first, so that the old
            // session's end neither clears the new video nor shows the waiting screen.
            let previous = mirroringSession
            mirroringSession = id
            if connectingSession == id { connectingSession = nil }
            if let previous, previous != id {
                sessions[previous]?.close()
            }
            if let size = videoSizes[id] { onEvent(.videoSize(size)) }
            onEvent(.mirroring)
        case .mirroringEnded:
            endSession(id)
        }
    }

    /// A session stopped its video or closed.
    private func endSession(_ id: ObjectIdentifier) {
        if mirroringSession == id {
            mirroringSession = nil
            sink.clear()
            onEvent(.waiting)
        } else if connectingSession == id {
            connectingSession = nil
            if mirroringSession == nil { onEvent(.waiting) }
        }
    }

    // MARK: Bonjour

    /// Registers the `_airplay._tcp` and `_raop._tcp` services on the same port.
    private func advertise(port: UInt16) -> Bool {
        advertisements.forEach(DNSServiceRefDeallocate)
        advertisements.removeAll()
        let services: [(name: String, type: String, txt: Data)] = [
            (identity.name, "_airplay._tcp", identity.airPlayTXT),
            (identity.raopServiceName, "_raop._tcp", identity.raopTXT),
        ]
        for service in services {
            var reference: DNSServiceRef?
            let error = service.txt.withUnsafeBytes { txt in
                DNSServiceRegister(
                    &reference, 0, 0, service.name, service.type, nil, nil,
                    port.bigEndian, UInt16(txt.count), txt.baseAddress,
                    { _, _, _, _, _, _, _ in }, nil
                )
            }
            guard error == kDNSServiceErr_NoError, let reference else { return false }
            DNSServiceSetDispatchQueue(reference, queue)
            advertisements.append(reference)
        }
        return true
    }
}
