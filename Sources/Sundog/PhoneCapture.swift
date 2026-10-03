import AVFoundation
import CoreMediaIO

/// Finds an iPhone connected by USB and streams its screen into `session`.
///
/// macOS exposes the iPhone screen as a capture device (the same path QuickTime uses),
/// but only after the app opts in to screen capture devices through CoreMediaIO.
@MainActor
final class PhoneCapture {
    enum State: Equatable {
        case waitingForAccess
        case accessDenied
        case waitingForPhone
        case mirroring
    }

    let session = AVCaptureSession()
    var onStateChange: ((State) -> Void)?
    var onVideoSizeChange: ((CGSize) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.lahariganti.Sundog.session")
    private var observers: [NSObjectProtocol] = []
    private var accessGranted = false
    private var deviceID: String?
    private var state: State?

    func start() {
        Self.allowScreenCaptureDevices()

        let names = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
            AVCaptureInput.Port.formatDescriptionDidChangeNotification,
        ]
        for name in names {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(observer)
        }

        update(.waitingForAccess)
        Task {
            accessGranted = await AVCaptureDevice.requestAccess(for: .video)
            refresh()
        }
    }

    private func refresh() {
        guard accessGranted else {
            update(.accessDenied)
            return
        }
        let phone = Self.findPhone()
        if phone?.uniqueID != deviceID {
            connect(phone)
        } else {
            reportVideoSize()
        }
    }

    private func connect(_ phone: AVCaptureDevice?) {
        deviceID = phone?.uniqueID
        update(phone == nil ? .waitingForPhone : .mirroring)

        nonisolated(unsafe) let session = session
        nonisolated(unsafe) let phone = phone
        sessionQueue.async { [weak self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            if let phone, let input = try? AVCaptureDeviceInput(device: phone), session.canAddInput(input) {
                session.addInput(input)
                let audio = AVCaptureAudioPreviewOutput()
                audio.volume = 1
                if session.canAddOutput(audio) {
                    session.addOutput(audio)
                }
            }
            session.commitConfiguration()

            if session.inputs.isEmpty {
                session.stopRunning()
            } else {
                session.startRunning()
            }
            Task { @MainActor in self?.reportVideoSize() }
        }
    }

    private func reportVideoSize() {
        nonisolated(unsafe) let session = session
        sessionQueue.async { [weak self] in
            let port = session.inputs
                .compactMap { $0 as? AVCaptureDeviceInput }
                .flatMap(\.ports)
                .first { $0.mediaType == .video || $0.mediaType == .muxed }
            guard let description = port?.formatDescription else { return }
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            guard dimensions.width > 0, dimensions.height > 0 else { return }
            let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            Task { @MainActor in self?.onVideoSizeChange?(size) }
        }
    }

    private func update(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
    }

    private static func findPhone() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external],
            mediaType: .muxed,
            position: .unspecified
        ).devices.first
    }

    /// Makes iOS devices connected by USB appear as capture devices.
    private static func allowScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }
}
