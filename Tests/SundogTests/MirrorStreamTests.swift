import CoreMedia
import Foundation
import Testing
@testable import Sundog

struct MirrorStreamTests {
    @Test func recoversCipherAfterAnOmittedEncryptedFrame() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = [accessUnit([[0x65, 0x80]]),
                     accessUnit([[0x41] + [UInt8](repeating: 0x27, count: 17_336)]),
                     accessUnit([[0x41, 0x81, 0x22]]),
                     accessUnit([[0x41, 0x82, 0x33, 0x44]]),
                     accessUnit([[0x41, 0x83, 0x55]])]
        let sender = try #require(AESCTR(key: key, iv: iv))
        let encrypted = plain.map { frame in
            var output = frame
            sender.apply(to: &output)
            return output
        }
        let receiver = try #require(AESCTR(key: key, iv: iv))
        var first = encrypted[0]
        receiver.apply(to: &first)
        #expect(first == plain[0])
        // Packet 1 never reaches the receiver, but the sender consumed its bytes.
        var broken = encrypted[2]
        receiver.apply(to: &broken)
        #expect(broken.withUnsafeBytes { MirrorStream.isSyncFrame($0, codec: kCMVideoCodecType_H264) } == nil)
        let offset = UInt64(plain[0].count)
        let candidates = MirrorStream.probeOffsets(encrypted[2], key: key, iv: iv, offset: offset, codec: kCMVideoCodecType_H264)
        let delta = try #require(MirrorStream.confirmedOffset(previous: encrypted[2], previousOffset: offset,
            current: encrypted[3], currentOffset: offset + UInt64(encrypted[2].count),
            candidates: candidates, key: key, iv: iv, codec: kCMVideoCodecType_H264))
        #expect(delta == Int64(plain[1].count))
        let recovered = try #require(MirrorStream.cipherAtOffset(key: key, iv: iv, offset: offset + UInt64(delta)))
        for index in 2..<plain.count {
            var decoded = encrypted[index]
            recovered.apply(to: &decoded)
            #expect(decoded == plain[index])
        }
        var damaged = encrypted[3]
        damaged[0] ^= 0xFF
        #expect(MirrorStream.confirmedOffset(previous: encrypted[2], previousOffset: offset,
            current: damaged, currentOffset: offset + UInt64(encrypted[2].count),
            candidates: candidates, key: key, iv: iv, codec: kCMVideoCodecType_H264) == nil)
        #expect(MirrorStream.confirmedOffset(previous: encrypted[2], previousOffset: offset,
            current: encrypted[3], currentOffset: offset + UInt64(encrypted[2].count) + 1,
            candidates: candidates, key: key, iv: iv, codec: kCMVideoCodecType_H264) == nil)
    }

    @Test func shiftedOffsetsRejectOverflowAndUnderflow() {
        #expect(MirrorStream.shiftedOffset(0, by: -1) == nil)
        #expect(MirrorStream.shiftedOffset(UInt64.max, by: 1) == nil)
        #expect(MirrorStream.shiftedOffset(8, by: -3) == 5)
        #expect(MirrorStream.shiftedOffset(8, by: 3) == 11)
    }

    @Test func offsetProbeFindsKnownPositiveAndNegativeDrift() {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        // Independently encrypted at byte 12345 using Python cryptography.
        let encrypted = Data(hex: "b9eb78fd3d3360f9a7be2034d77a5e2e1789159e566d30f4c1d34e1188483b61d69f654250e4f74e266d2fcbf1243825d328f9069e704949439add7fcc51fea8")
        #expect(MirrorStream.probeOffsets(encrypted, key: key, iv: iv, offset: 12_328,
                                         codec: kCMVideoCodecType_H264, radius: 64) == [17])
        #expect(MirrorStream.probeOffsets(encrypted, key: key, iv: iv, offset: 12_360,
                                         codec: kCMVideoCodecType_H264, radius: 64) == [-15])
        #expect(MirrorStream.probeOffsets(encrypted, key: key, iv: iv, offset: 12_000,
                                         codec: kCMVideoCodecType_H264, radius: 64).isEmpty)
    }

    @Test func independentAuditHandlesUnalignedOffsetsAndCounterCarry() throws {
        // Independent OpenSSL-backed vectors: encrypt 32 zero bytes at each
        // absolute stream position. Auditing them must recover all zeroes.
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        for (offset, encrypted) in [
            (UInt64(15), "e4362b7c3c6773516318a077d7fc5073ae6a2cc3787889374fbeb4c81b17ba6c"),
            (UInt64(65_535), "94ec143c5d3c00648eec859f36dfc3c79361909f8bd24b0c7158b32d872d0d19"),
            (UInt64(4_294_967_295), "aef66bc631ceef52033c8cfc20ccf8a269c072b8f31db2fff985bc60d0ae1bce")
        ] {
            let result = try #require(MirrorStream.auditPrefix(Data(hex: encrypted), key: key, iv: iv, offset: offset))
            #expect(result == [UInt8](repeating: 0, count: 32))
        }
    }

    private func accessUnit(_ nals: [[UInt8]]) -> Data {
        var data = Data()
        for nal in nals {
            let size = UInt32(nal.count)
            data.append(contentsOf: [UInt8(size >> 24), UInt8((size >> 16) & 255),
                                     UInt8((size >> 8) & 255), UInt8(size & 255)])
            data.append(contentsOf: nal)
        }
        return data
    }

    @Test func distinguishesReferenceFramesFromRandomAccessPictures() {
        for (codec, nals, expected) in [
            (kCMVideoCodecType_H264, [[UInt8(0x06), 0], [0x65, 0x80]], true),
            (kCMVideoCodecType_H264, [[UInt8(0x41), 0x80]], false),
            (kCMVideoCodecType_HEVC, [[UInt8(19 << 1), 1, 0x80]], true),
            (kCMVideoCodecType_HEVC, [[UInt8(1 << 1), 1, 0x80]], false)
        ] {
            let result = accessUnit(nals).withUnsafeBytes { MirrorStream.isSyncFrame($0, codec: codec) }
            #expect(result == expected)
        }
    }

    @Test func rejectsTruncatedOrMalformedAccessUnits() {
        for frame in [Data(), Data([0, 0, 0]), Data([0, 0, 0, 0]),
                      Data([0, 0, 0, 8, 0x65]), Data([0, 0, 0, 1, 0xE5]),
                      accessUnit([[0x65, 0x80]]) + Data([0])] {
            let result = frame.withUnsafeBytes { MirrorStream.isSyncFrame($0, codec: kCMVideoCodecType_H264) }
            #expect(result == nil)
        }
    }

    @Test func samplesCarryTimingAndCorrectSyncAttachments() throws {
        // This checks sample metadata, not whether the synthetic picture can decode.
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264, width: 16, height: 16,
            extensions: nil, formatDescriptionOut: &description)
        #expect(status == noErr)
        let format = try #require(description)
        let key = Data(repeating: 0, count: 16)
        let iv = Data(repeating: 0, count: 16)
        let encrypt = try #require(AESCTR(key: key, iv: iv))
        let decrypt = try #require(AESCTR(key: key, iv: iv))
        for (index, header) in [UInt8(0x65), UInt8(0x41)].enumerated() {
            var encrypted = accessUnit([[header, 0x80]])
            encrypt.apply(to: &encrypted)
            let pts = CMTime(value: Int64(index), timescale: 60)
            let sample = try #require(MirrorStream.sampleBuffer(encrypted, format: format, cipher: decrypt,
                                                               presentationTime: pts))
            #expect(CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), pts) == 0)
            let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[String: Any]])
            let flags = try #require(attachments.first)
            #expect(flags[kCMSampleAttachmentKey_NotSync as String] as? Bool == (index != 0))
            #expect(flags[kCMSampleAttachmentKey_DependsOnOthers as String] as? Bool == (index != 0))
        }
    }
}
