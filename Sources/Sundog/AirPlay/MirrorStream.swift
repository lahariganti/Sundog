import CommonCrypto
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
    private var cipher: AESCTR
    private let listener: NWListener
    private var connection: NWConnection?
    private var formatDescription: CMVideoFormatDescription?
    private var hasVideo = false
    private var firstTimestamp: UInt64?
    private var presentationStart = CMTime.invalid
    private var rejectedFrames = 0
    private let auditKey: Data
    private let auditIV: Data
    private var encryptedByteCount: UInt64 = 0
    private var packetCount = 0
    private var acceptedFrameCount = 0
    private var packetHistory: [String] = []
    private var consecutiveRejectedFrames = 0
    private struct PendingRecovery {
        let frame: Data
        let timestamp: UInt64
        let offset: UInt64
        let format: CMVideoFormatDescription
        let candidates: [Int64]
    }
    private var pendingRecovery: PendingRecovery?

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
        self.auditKey = key
        self.auditIV = iv
        self.listener = listener
        self.sink = sink
        self.queue = queue
    }

    /// Starts to listen for a connection. Calls `ready` on `queue` with the data port, or with nil if it fails.
    func start(ready: @escaping @Sendable (UInt16?) -> Void) {
        Self.logger.notice("Stream recovery v3 active: confirm two frames before adjusting cipher position")
        let reported = QueueLocal(false)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !reported.value else { return }
            switch state {
            case .ready:
                reported.value = true
                ready(self.listener.port?.rawValue)
            case .failed, .cancelled, .waiting:
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
            self.packetCount += 1
            let flags = header.dropFirst(4).prefix(4).map { String(format: "%02x", $0) }.joined()
            self.packetHistory.append("packet=\(self.packetCount) flags=\(flags) size=\(payloadLength) cipherOffset=\(self.encryptedByteCount)")
            if self.packetHistory.count > 12 { self.packetHistory.removeFirst() }
            guard payloadLength <= Self.maximumPayloadLength else {
                self.connection?.cancel()
                return
            }
            guard payloadLength > 0 else {
                self.readHeader()
                return
            }
            self.receive(payloadLength) { payload in
                self.handle(type: header[header.startIndex + 4], payload: payload,
                            timestamp: header.littleEndianUInt64(at: 8))
                self.readHeader()
            }
        }
    }

    private func receive(_ length: Int, then handler: @escaping @Sendable (Data) -> Void) {
        connection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else {
                Self.logger.error("TCP receive incomplete: expected=\(length), actual=\(data?.count ?? 0), complete=\(isComplete), error=\(String(describing: error), privacy: .public)")
                if isComplete || error != nil { self.connection?.cancel() }
                return
            }
            handler(data)
        }
    }

    private func handle(type: UInt8, payload: Data, timestamp: UInt64) {
        switch type {
        case 0:
            show(encryptedFrame: payload, timestamp: timestamp)
        case 1:
            let isHEVC = payload.count > 8 && payload[payload.startIndex + 4..<payload.startIndex + 8] == Data("hvc1".utf8)
            let description = isHEVC ? Self.formatDescription(fromHVC1: payload) : Self.formatDescription(fromAVCC: payload)
            guard let description else { return }
            formatDescription = description
            let dimensions = CMVideoFormatDescriptionGetPresentationDimensions(
                description, usePixelAspectRatio: true, useCleanAperture: true)
            Self.logger.notice("Video format: \(isHEVC ? "H.265" : "H.264", privacy: .public) \(Int(dimensions.width)) x \(Int(dimensions.height))")
            onVideoSize?(dimensions)
        default:
            break
        }
    }

    private func show(encryptedFrame frame: Data, timestamp: UInt64) {
        let streamOffset = encryptedByteCount
        encryptedByteCount += UInt64(frame.count)
        guard let formatDescription else {
            // The key stream must remain aligned, also before the first codec record.
            var discarded = frame
            cipher.apply(to: &discarded)
            return
        }
        // AirPlay timestamps are NTP 32.32 values. Keep their relative timing,
        // anchored to the local host clock rather than the sender's clock epoch.
        if firstTimestamp == nil {
            firstTimestamp = timestamp
            presentationStart = CMClockGetTime(CMClockGetHostTimeClock())
        }
        let elapsed = Double(Int64(bitPattern: timestamp &- firstTimestamp!)) / 4_294_967_296.0
        let pts = CMTimeAdd(presentationStart, CMTime(seconds: elapsed, preferredTimescale: 1_000_000_000))
        var failureReason = "unknown"
        var auditResult = "not reached"
        let expectedPrefix = Self.auditPrefix(frame, key: auditKey, iv: auditIV, offset: streamOffset)
        guard let sample = Self.sampleBuffer(frame, format: formatDescription, cipher: cipher,
                                            presentationTime: pts, onFailure: { failureReason = $0 },
                                            inspectDecrypted: { bytes in
            if let expectedPrefix {
                auditResult = bytes.prefix(expectedPrefix.count).elementsEqual(expectedPrefix) ? "MATCH" : "MISMATCH"
            } else {
                auditResult = "reference calculation failed"
            }
        }) else {
            rejectedFrames += 1
            // Allocation errors cannot establish a new encryption position.
            guard !failureReason.hasPrefix("CM") else {
                Self.logger.error("Sample creation failed: \(failureReason, privacy: .public)")
                pendingRecovery = nil
                return
            }
            consecutiveRejectedFrames += 1
            let codec = CMFormatDescriptionGetMediaSubType(formatDescription)
            if let pending = pendingRecovery {
                pendingRecovery = nil
                if CMFormatDescriptionGetMediaSubType(pending.format) == codec,
                   let delta = Self.confirmedOffset(previous: pending.frame, previousOffset: pending.offset,
                                                    current: frame, currentOffset: streamOffset,
                                                    candidates: pending.candidates, key: auditKey, iv: auditIV, codec: codec),
                   let position = Self.shiftedOffset(pending.offset, by: delta),
                   let replacement = Self.cipherAtOffset(key: auditKey, iv: auditIV, offset: position) {
                    cipher = replacement
                    encryptedByteCount = position
                    consecutiveRejectedFrames = 0
                    Self.logger.notice("Resynchronized video cipher: delta=\(delta), confirmedFrames=2")
                    // Replay both held packets, using their respective codec records.
                    self.formatDescription = pending.format
                    show(encryptedFrame: pending.frame, timestamp: pending.timestamp)
                    self.formatDescription = formatDescription
                    show(encryptedFrame: frame, timestamp: timestamp)
                    return
                }
            }
            if consecutiveRejectedFrames == 1 || consecutiveRejectedFrames % 60 == 1 {
                Self.logger.error("First rejection: accepted=\(self.acceptedFrameCount), cipherOffset=\(streamOffset), CTR audit=\(auditResult, privacy: .public)")
                for entry in packetHistory { Self.logger.error("Packet trace: \(entry, privacy: .public)") }
                let candidates = Self.probeOffsets(frame, key: auditKey, iv: auditIV, offset: streamOffset, codec: codec)
                if !candidates.isEmpty {
                    pendingRecovery = PendingRecovery(frame: frame, timestamp: timestamp, offset: streamOffset,
                                                      format: formatDescription, candidates: candidates)
                }
                Self.logger.notice("Recovery candidates: \(String(describing: candidates), privacy: .public)")
            }
            if rejectedFrames == 1 || rejectedFrames % 60 == 0 {
                Self.logger.error("Rejected video sample (count: \(self.rejectedFrames), CTR audit=\(auditResult, privacy: .public)): \(failureReason, privacy: .public)")
            }
            return
        }
        consecutiveRejectedFrames = 0
        pendingRecovery = nil
        sink.enqueue(sample)
        acceptedFrameCount += 1
        if !hasVideo {
            hasVideo = true
            onFirstFrame?()
        }
    }

    // MARK: Core Media

    static func shiftedOffset(_ offset: UInt64, by delta: Int64) -> UInt64? {
        if delta >= 0 {
            let (result, overflow) = offset.addingReportingOverflow(UInt64(delta))
            return overflow ? nil : result
        }
        let magnitude = delta.magnitude
        return offset >= magnitude ? offset - magnitude : nil
    }

    /// Requires consecutive frames and one unique offset validating both full
    /// access units. A plausible prefix alone never changes the live cipher.
    static func confirmedOffset(previous: Data, previousOffset: UInt64,
                                current: Data, currentOffset: UInt64,
                                candidates: [Int64], key: Data, iv: Data,
                                codec: CMVideoCodecType) -> Int64? {
        let (end, overflow) = previousOffset.addingReportingOverflow(UInt64(previous.count))
        guard !overflow, end == currentOffset else { return nil }
        let confirmed = Set(candidates).filter { delta in
            guard let first = shiftedOffset(previousOffset, by: delta),
                  let second = shiftedOffset(currentOffset, by: delta),
                  let a = auditDecrypt(previous, key: key, iv: iv, offset: first),
                  let b = auditDecrypt(current, key: key, iv: iv, offset: second) else { return false }
            return a.withUnsafeBytes { isSyncFrame($0, codec: codec) != nil }
                && b.withUnsafeBytes { isSyncFrame($0, codec: codec) != nil }
        }
        return confirmed.count == 1 ? confirmed.first : nil
    }

    static func cipherAtOffset(key: Data, iv: Data, offset: UInt64) -> AESCTR? {
        guard iv.count == 16 else { return nil }
        var counter = [UInt8](iv)
        var increment = offset / 16
        for index in stride(from: 15, through: 0, by: -1) {
            let sum = UInt64(counter[index]) + (increment & 255)
            counter[index] = UInt8(sum & 255)
            increment = (increment >> 8) + (sum >> 8)
        }
        guard let cipher = AESCTR(key: key, iv: Data(counter)) else { return nil }
        var skip = Data(count: Int(offset % 16))
        cipher.apply(to: &skip)
        return cipher
    }

    /// Independently checks the first bytes at an absolute stream position.
    /// AES-ECB encrypts explicit counter blocks, with no shared CTR state.
    /// Only agreement and byte counts are logged, never keys or video bytes.
    static func auditPrefix(_ frame: Data, key: Data, iv: Data, offset: UInt64) -> [UInt8]? {
        auditDecrypt(Data(frame.prefix(32)), key: key, iv: iv, offset: offset)
    }

    static func auditDecrypt(_ frame: Data, key: Data, iv: Data, offset: UInt64) -> [UInt8]? {
        guard key.count == 16, iv.count == 16 else { return nil }
        let prefixCount = frame.count
        guard prefixCount > 0 else { return [] }
        let skip = Int(offset % 16)
        let blocks = (skip + prefixCount + 15) / 16
        var counter = [UInt8](iv)
        var increment = offset / 16
        for index in stride(from: 15, through: 0, by: -1) {
            let sum = UInt64(counter[index]) + (increment & 255)
            counter[index] = UInt8(sum & 255)
            increment = (increment >> 8) + (sum >> 8)
        }
        var input: [UInt8] = []
        for _ in 0..<blocks {
            input.append(contentsOf: counter)
            for index in stride(from: 15, through: 0, by: -1) {
                counter[index] &+= 1
                if counter[index] != 0 { break }
            }
        }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, keyBytes.count, nil,
                            inputBytes.baseAddress, inputBytes.count,
                            outputBytes.baseAddress, outputBytes.count, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == input.count else { return nil }
        return zip(frame.prefix(prefixCount), output.dropFirst(skip)).map { $0.0 ^ $0.1 }
    }

    /// Bounded candidate search. A separate second-frame check must confirm a
    /// unique candidate before it is used to change the live cipher.
    static func probeOffsets(_ frame: Data, key: Data, iv: Data, offset: UInt64,
                             codec: CMVideoCodecType, radius: Int = 262_144) -> [Int64] {
        guard frame.count >= 5, frame.count <= 1 << 20, radius >= 0, radius <= 262_144,
              offset <= UInt64(Int64.max) - UInt64(radius) else { return [] }
        let lower = offset > UInt64(radius) ? offset - UInt64(radius) : 0
        let upper = offset + UInt64(radius)
        let windowCount = Int(upper - lower) + 5
        guard let stream = auditDecrypt(Data(count: windowCount), key: key, iv: iv, offset: lower) else { return [] }
        let input = [UInt8](frame.prefix(5))
        var matches: [Int64] = []
        var attempts = 0
        for index in 0...Int(upper - lower) {
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(input[$1] ^ stream[index + $1]) }
            guard length > 0, length <= frame.count - 4 else { continue }
            let header = input[4] ^ stream[index + 4]
            guard header & 0x80 == 0 else { continue }
            if codec == kCMVideoCodecType_H264 {
                let type = header & 0x1F
                guard (1...8).contains(type) || type == 9 || type == 12 else { continue }
            }
            attempts += 1
            guard attempts <= 32 else { break }
            let position = lower + UInt64(index)
            guard let plain = auditDecrypt(frame, key: key, iv: iv, offset: position) else { continue }
            if plain.withUnsafeBytes({ isSyncFrame($0, codec: codec) != nil }) {
                matches.append(Int64(position) - Int64(offset))
            }
        }
        return matches
    }

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

    /// Always consumes the ciphertext, even if Core Media cannot allocate a sample.
    static func sampleBuffer(_ frame: Data, format: CMVideoFormatDescription, cipher: AESCTR,
                             presentationTime: CMTime, onFailure: (String) -> Void = { _ in },
                             inspectDecrypted: (UnsafeRawBufferPointer) -> Void = { _ in }) -> CMSampleBuffer? {
        var plain = frame
        cipher.apply(to: &plain)
        plain.withUnsafeBytes(inspectDecrypted)
        return sampleBufferFromPlaintext(plain, format: format, presentationTime: presentationTime, onFailure: onFailure)
    }

    private static func sampleBufferFromPlaintext(_ frame: Data, format: CMVideoFormatDescription,
                                                 presentationTime: CMTime, onFailure: (String) -> Void) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let allocationStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: frame.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: frame.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard allocationStatus == noErr, let block else {
            onFailure("CMBlockBufferCreateWithMemoryBlock status=\(allocationStatus)")
            return nil
        }

        var destination: UnsafeMutablePointer<CChar>?
        var contiguousLength = 0
        let pointerStatus = CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &contiguousLength, dataPointerOut: &destination
        )
        guard pointerStatus == noErr, let destination, contiguousLength == frame.count else {
            onFailure("CMBlockBufferGetDataPointer status=\(pointerStatus), length=\(contiguousLength), frame=\(frame.count)")
            return nil
        }
        frame.withUnsafeBytes { source in
            UnsafeMutableRawBufferPointer(start: destination, count: frame.count).copyMemory(from: source)
        }

        // A syntactically invalid decrypted access unit must not be submitted to
        // the decoder. The cipher has already consumed it to retain alignment.
        let bytes = UnsafeRawBufferPointer(start: destination, count: frame.count)
        guard let isSync = isSyncFrame(bytes, codec: CMFormatDescriptionGetMediaSubType(format), onInvalid: onFailure) else { return nil }

        var sample: CMSampleBuffer?
        var size = frame.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime,
                                        decodeTimeStamp: .invalid)
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else {
            onFailure("CMSampleBufferCreateReady status=\(sampleStatus), bytes=\(frame.count)")
            return nil
        }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
            // Without NotSync, Core Media assumes EVERY sample is a keyframe.
            // P/B frames depend on the decoder retaining earlier reference frames.
            for key in [kCMSampleAttachmentKey_NotSync, kCMSampleAttachmentKey_DependsOnOthers] {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(),
                                     Unmanaged.passUnretained(isSync ? kCFBooleanFalse : kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    /// Validates every 4-byte length-prefixed NAL unit in an access unit and
    /// identifies H.264 IDR or HEVC random-access pictures. nil means malformed.
    static func isSyncFrame(_ bytes: UnsafeRawBufferPointer, codec: CMVideoCodecType,
                            onInvalid: (String) -> Void = { _ in }) -> Bool? {
        guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC else {
            onInvalid("unsupported codec=\(codec)")
            return nil
        }
        var offset = 0
        var hasPicture = false
        var isSync = false
        while offset < bytes.count {
            guard bytes.count - offset >= 4 else {
                onInvalid("truncated NAL length at offset=\(offset), bytes=\(bytes.count)")
                return nil
            }
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
            offset += 4
            guard length > 0, length <= bytes.count - offset else {
                onInvalid("invalid decrypted NAL length=\(length), offset=\(offset - 4), available=\(bytes.count - offset)")
                return nil
            }
            guard bytes[offset] & 0x80 == 0 else {
                onInvalid("decrypted NAL forbidden bit set at offset=\(offset), length=\(length)")
                return nil
            }
            if codec == kCMVideoCodecType_H264 {
                let type = bytes[offset] & 0x1F
                if (1...5).contains(type) { hasPicture = true }
                if type == 5 { isSync = true }
            } else {
                guard length >= 2, bytes[offset + 1] & 0x07 != 0 else {
                    onInvalid("invalid HEVC header at offset=\(offset), length=\(length)")
                    return nil
                }
                let type = (bytes[offset] >> 1) & 0x3F
                if type <= 31 { hasPicture = true }
                if (16...21).contains(type) { isSync = true }
            }
            offset += length
        }
        if !hasPicture { onInvalid("access unit has no picture NAL, bytes=\(bytes.count)") }
        return hasPicture ? isSync : nil
    }
}

extension Data {
    func littleEndianUInt64(at offset: Int) -> UInt64 {
        let start = startIndex + offset
        return self[start..<start + 8].enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * $1.offset) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<start + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }
}
