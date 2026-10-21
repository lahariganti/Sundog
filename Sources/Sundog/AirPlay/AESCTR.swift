import CommonCrypto
import CryptoKit
import Foundation

/// AES-128-CTR with one continuous key stream across all frame boundaries.
/// CommonCrypto retains partial counter blocks between updates.
final class AESCTR {
    private var cryptor: CCCryptorRef?

    init?(key: Data, iv: Data) {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { return nil }
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count,
                    nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        guard status == kCCSuccess, cryptor != nil else { return nil }
    }

    deinit {
        if let cryptor { CCCryptorRelease(cryptor) }
    }

    func apply(to data: inout Data) {
        data.withUnsafeMutableBytes { apply(to: $0) }
    }

    func apply(to buffer: UnsafeMutableRawBufferPointer) {
        apply(from: UnsafeRawBufferPointer(buffer), to: buffer)
    }

    /// Input and output may be the same buffer. CTR emits exactly one output
    /// byte per input byte and supports arbitrary, non-block-aligned updates.
    func apply(from source: UnsafeRawBufferPointer, to destination: UnsafeMutableRawBufferPointer) {
        precondition(destination.count >= source.count)
        guard !source.isEmpty else { return }
        var moved = 0
        let status = CCCryptorUpdate(cryptor, source.baseAddress, source.count,
                                     destination.baseAddress, destination.count, &moved)
        // A cryptor error must never become silently corrupted video.
        precondition(status == kCCSuccess && moved == source.count,
                     "AES-CTR update failed (status: \(status), bytes: \(moved)/\(source.count))")
    }
}

extension Data {
    /// The first `length` bytes of the SHA-512 digest of this data.
    func sha512Prefix(_ length: Int) -> Data {
        Data(SHA512.hash(data: self).prefix(length))
    }
}
