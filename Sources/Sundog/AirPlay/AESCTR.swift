import CommonCrypto
import CryptoKit
import Foundation

/// AES-128 in counter mode as one continuous key stream.
/// A call can end in the middle of a block; the next call continues at the same position.
final class AESCTR {
    private var cryptor: CCCryptorRef?
    private var counter: [UInt8]
    private var keyStream = [UInt8](repeating: 0, count: 16)
    private var keyStreamOffset = 16

    init?(key: Data, iv: Data) {
        guard key.count == 16, iv.count == 16 else { return nil }
        counter = [UInt8](iv)
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreate(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                keyBytes.baseAddress, 16,
                nil,
                &cryptor
            )
        }
        guard status == kCCSuccess else { return nil }
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    /// Encrypts or decrypts `data` in place. Both operations are the same in counter mode.
    func apply(to data: inout Data) {
        data.withUnsafeMutableBytes { apply(to: $0) }
    }

    func apply(to buffer: UnsafeMutableRawBufferPointer) {
        var index = 0
        let count = buffer.count

        while index < count, keyStreamOffset < 16 {
            buffer[index] ^= keyStream[keyStreamOffset]
            keyStreamOffset += 1
            index += 1
        }
        guard index < count else { return }

        let remaining = count - index
        let blockCount = (remaining + 15) / 16
        var counters = [UInt8](repeating: 0, count: blockCount * 16)
        for block in 0..<blockCount {
            counters.replaceSubrange(block * 16..<(block + 1) * 16, with: counter)
            incrementCounter()
        }
        var stream = [UInt8](repeating: 0, count: counters.count)
        var moved = 0
        CCCryptorUpdate(cryptor, counters, counters.count, &stream, stream.count, &moved)

        for offset in 0..<remaining {
            buffer[index + offset] ^= stream[offset]
        }

        let lastBlockStart = (blockCount - 1) * 16
        keyStream = Array(stream[lastBlockStart..<lastBlockStart + 16])
        keyStreamOffset = remaining - lastBlockStart
    }

    private func incrementCounter() {
        for position in stride(from: 15, through: 0, by: -1) {
            counter[position] &+= 1
            if counter[position] != 0 { break }
        }
    }
}

extension Data {
    /// The first `length` bytes of the SHA-512 digest of this data.
    func sha512Prefix(_ length: Int) -> Data {
        Data(SHA512.hash(data: self).prefix(length))
    }
}
