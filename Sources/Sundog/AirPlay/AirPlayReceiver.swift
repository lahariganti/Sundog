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
    private var mirroringSession: ObjectIdentifier?

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
            if self.mirroringSession == id {
                self.mirroringSession = nil
                self.onEvent(.waiting)
            }
        }
        session.start()
    }

    private func sessionEvent(_ event: AirPlaySession.Event, from id: ObjectIdentifier) {
        switch event {
        case .connecting:
            if mirroringSession == nil { onEvent(.connecting) }
        case .mirroringStarted:
            // A new iPhone replaces the current one.
            if let current = mirroringSession, current != id {
                sessions[current]?.close()
            }
            mirroringSession = id
            onEvent(.mirroring)
        case .videoSize(let size):
            onEvent(.videoSize(size))
        case .mirroringEnded:
            if mirroringSession == id {
                mirroringSession = nil
                onEvent(.waiting)
            }
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
