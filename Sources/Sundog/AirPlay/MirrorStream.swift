import CoreMedia
import Foundation
import Network
import os

/// Receives the AirPlay mirror stream on its own TCP port. It decrypts the frames
/// and sends them to the video sink.
///
/// Each packet has a 128-byte header and a payload. Header bytes 0–3 hold the
/// payload size (little endian). Header byte 4 holds the payload type:
/// - 0: an encrypted frame with length-prefixed NAL units.
/// - 1: the unencrypted codec record. For H.264, this is an avcC record.
///   For H.265, this is an `hvc1` sample entry with an hvcC record.
final class MirrorStream: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.lahariganti.Sundog", category: "MirrorStream")
    private static let headerLength = 128
    private static let maximumPayloadLength = 16 << 20

    private let queue: DispatchQueue
    private let sink: VideoSink
    private let cipher: AESCTR
    private let listener: NWListener
    private var connection: NWConnection?
    private var formatDescription: CMVideoFormatDescription?
    private var videoSize: CGSize?
    private var hasVideo = false

    /// The stream calls this on `queue` with the new video size.
    var onVideoSize: ((CGSize) -> Void)?
    /// The stream calls this on `queue` when the first frame arrives.
    var onFirstFrame: (() -> Void)?
    /// The stream calls this on `queue` when the stream ends.
    var onEnd: (() -> Void)?

    /// - Parameters:
    ///   - sessionKey: the 16-byte AES key from SETUP. The caller applies the pairing hash first.
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

    /// Starts to listen for a connection. Calls `ready` on `queue` with the data port, or with nil if it fails.
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
            show(encryptedFrame: payload)
        case 1:
            let isHEVC = payload.count > 8 && payload[payload.startIndex + 4..<payload.startIndex + 8] == Data("hvc1".utf8)
            let description = isHEVC ? Self.formatDescription(fromHVC1: payload) : Self.formatDescription(fromAVCC: payload)
            guard let description else { return }
            formatDescription = description
            let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(
                description, usePixelAspectRatio: true, useCleanAperture: true)
            Self.logger.notice("Video format: \(isHEVC ? "H.265" : "H.264", privacy: .public) \(Int(dimensions.width)) x \(Int(dimensions.height))")
            // A new size, for example after a rotation, needs a new decoder setup.
            if let videoSize, videoSize != dimensions {
                sink.reset()
            }
            videoSize = dimensions
            onVideoSize?(dimensions)
        default:
            break
        }
    }

    private func show(encryptedFrame frame: Data) {
        guard let formatDescription else {
            // The key stream must remain aligned, also before the first codec record.
            var discarded = frame
            cipher.apply(to: &discarded)
            return
        }
        guard let sample = Self.sampleBuffer(frame, format: formatDescription, cipher: cipher) else { return }
        sink.enqueue(sample)
        if !hasVideo {
            hasVideo = true
            onFirstFrame?()
        }
    }

    // MARK: Core Media

    /// Reads the VPS, SPS, and PPS sets from the hvcC box inside an `hvc1` sample entry.
    static func formatDescription(fromHVC1 entry: Data) -> CMVideoFormatDescription? {
        let bytes = [UInt8](entry)
        guard let box = entry.range(of: Data("hvcC".utf8)) else { return nil }
        // The hvcC record: 22 bytes of configuration, the array count, then the arrays.
        var index = entry.distance(from: entry.startIndex, to: box.upperBound) + 22
        guard index < bytes.count else { return nil }
        let arrayCount = Int(bytes[index])
        index += 1
        var sets: [[UInt8]] = []
        for _ in 0..<arrayCount {
            guard index + 3 <= bytes.count else { return nil }
            let nalCount = Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
            index += 3
            for _ in 0..<nalCount {
                guard index + 2 <= bytes.count else { return nil }
                let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                index += 2
                guard length > 0, index + length <= bytes.count else { return nil }
                sets.append(Array(bytes[index..<index + length]))
                index += length
            }
        }
        guard sets.count >= 3 else { return nil }
        return makeFormatDescription(sets) { pointers, sizes, output in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: output
            )
        }
    }

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

        return makeFormatDescription(sets) { pointers, sizes, output in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: sets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: output
            )
        }
    }

    private static func makeFormatDescription(
        _ sets: [[UInt8]],
        create: ([UnsafePointer<UInt8>], [Int], UnsafeMutablePointer<CMVideoFormatDescription?>) -> OSStatus
    ) -> CMVideoFormatDescription? {
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
            return create(pointers, sizes, &description)
        }
        return status == noErr ? description : nil
    }

    /// Decrypts the frame directly into the memory of a new sample buffer.
    static func sampleBuffer(_ frame: Data, format: CMVideoFormatDescription, cipher: AESCTR) -> CMSampleBuffer? {
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

        var destination: UnsafeMutablePointer<CChar>?
        var contiguousLength = 0
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &contiguousLength, dataPointerOut: &destination
        ) == noErr, let destination, contiguousLength == frame.count else { return nil }
        frame.withUnsafeBytes { source in
            cipher.apply(from: source, to: UnsafeMutableRawBufferPointer(start: destination, count: frame.count))
        }

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
