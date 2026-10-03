import CoreMedia
import Foundation
import Network

/// Receives the AirPlay mirror stream on its own TCP port, decrypts the frames,
/// and sends them to the video sink.
///
/// Each packet has a 128-byte header and a payload. Header bytes 0–3 hold the
/// payload size (little endian). Header byte 4 holds the payload type:
/// 0 is an encrypted frame in AVCC format, 1 is the unencrypted avcC codec record.
final class MirrorStream: @unchecked Sendable {
    private static let headerLength = 128
    private static let maximumPayloadLength = 16 << 20

    private let queue: DispatchQueue
    private let sink: VideoSink
    private let cipher: AESCTR
    private let listener: NWListener
    private var connection: NWConnection?
    private var formatDescription: CMVideoFormatDescription?
    private var hasVideo = false

    /// Called on `queue` with the new video size.
    var onVideoSize: ((CGSize) -> Void)?
    /// Called on `queue` when the first frame arrives.
    var onFirstFrame: (() -> Void)?
    /// Called on `queue` when the stream ends.
    var onEnd: (() -> Void)?

    /// - Parameters:
    ///   - sessionKey: the 16-byte AES key from SETUP, after the pairing hash.
    ///   - streamConnectionID: the `streamConnectionID` of the type 110 stream.
    init?(sessionKey: Data, streamConnectionID: UInt64, sink: VideoSink, queue: DispatchQueue) {
        let key = (Data("AirPlayStreamKey\(streamConnectionID)".utf8) + sessionKey).sha512Prefix(16)
        let iv = (Data("AirPlayStreamIV\(streamConnectionID)".utf8) + sessionKey).sha512Prefix(16)
        guard let cipher = AESCTR(key: key, iv: iv),
              let listener = try? NWListener(using: .tcp) else { return nil }
        self.cipher = cipher
        self.listener = listener
        self.sink = sink
        self.queue = queue
    }

    /// Starts listening. Calls `ready` on `queue` with the data port, or nil on failure.
    func start(ready: @escaping @Sendable (UInt16?) -> Void) {
        let reported = QueueLocal(false)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !reported.value else { return }
            switch state {
            case .ready:
                reported.value = true
                ready(self.listener.port?.rawValue)
            case .failed, .cancelled:
                reported.value = true
                ready(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connection == nil else {
                connection.cancel()
                return
            }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    self?.finish()
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
            self.readHeader()
        }
        listener.start(queue: queue)
    }

    func stop() {
        onEnd = nil
        listener.cancel()
        connection?.cancel()
    }

    private func finish() {
        listener.cancel()
        let end = onEnd
        onEnd = nil
        end?()
    }

    private func readHeader() {
        receive(Self.headerLength) { [weak self] header in
            guard let self else { return }
            let payloadLength = Int(header.littleEndianUInt32(at: 0))
            guard payloadLength <= Self.maximumPayloadLength else {
                self.connection?.cancel()
                return
            }
            guard payloadLength > 0 else {
                self.readHeader()
                return
            }
            self.receive(payloadLength) { payload in
                self.handle(type: header[header.startIndex + 4], payload: payload)
                self.readHeader()
            }
        }
    }

    private func receive(_ length: Int, then handler: @escaping @Sendable (Data) -> Void) {
        connection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else {
                if isComplete || error != nil { self.connection?.cancel() }
                return
            }
            handler(data)
        }
    }

    private func handle(type: UInt8, payload: Data) {
        switch type {
        case 0:
            var frame = payload
            cipher.apply(to: &frame)
            show(frame)
        case 1:
            guard let description = Self.formatDescription(fromAVCC: payload) else { return }
            formatDescription = description
            let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(
                description, usePixelAspectRatio: true, useCleanAperture: true)
            onVideoSize?(dimensions)
        default:
            break
        }
    }

    private func show(_ frame: Data) {
        guard let formatDescription, let sample = Self.sampleBuffer(frame, format: formatDescription) else { return }
        sink.enqueue(sample)
        if !hasVideo {
            hasVideo = true
            onFirstFrame?()
        }
    }

    // MARK: Core Media

    /// Reads the SPS and PPS sets from an avcC record.
    static func formatDescription(fromAVCC record: Data) -> CMVideoFormatDescription? {
        let bytes = [UInt8](record)
        guard bytes.count >= 7 else { return nil }
        var index = 5
        var sets: [[UInt8]] = []

        func readSets(count: Int) -> Bool {
            for _ in 0..<count {
                guard index + 2 <= bytes.count else { return false }
                let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                index += 2
                guard length > 0, index + length <= bytes.count else { return false }
                sets.append(Array(bytes[index..<index + length]))
                index += length
            }
            return true
        }

        let spsCount = Int(bytes[index] & 0x1F)
        index += 1
        guard spsCount > 0, readSets(count: spsCount), index < bytes.count else { return nil }
        let ppsCount = Int(bytes[index])
        index += 1
        guard ppsCount > 0, readSets(count: ppsCount) else { return nil }

        let joined = sets.flatMap { $0 }
        let sizes = sets.map(\.count)
        var description: CMVideoFormatDescription?
        let status = joined.withUnsafeBufferPointer { buffer -> OSStatus in
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(buffer.baseAddress! + offset)
                offset += size
            }
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description
            )
        }
        return status == noErr ? description : nil
    }

    static func sampleBuffer(_ frame: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ) == noErr, let block else { return nil }

        let copied = frame.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = frame.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}

extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<start + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
}
