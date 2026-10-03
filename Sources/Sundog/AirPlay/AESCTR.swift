import CommonCrypto
import CryptoKit
import Foundation

/// AES-128 in counter mode as one continuous key stream.
/// A call can stop in the middle of a block. The next call continues from that position.
final class AESCTR {
    private var cryptor: CCCryptorRef?
    private var counter: [UInt8]
    private var keyStream = [UInt8](repeating: 0, count: 16)
    private var keyStreamOffset = 16
    // Work buffers. They increase to the size of the largest frame. Then the code uses them again.
    private var counters: [UInt8] = []
    private var stream: [UInt8] = []

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
        apply(from: UnsafeRawBufferPointer(buffer), to: buffer)
    }

    /// Writes `source` XOR the key stream to `destination`. The buffers can be the same memory.
    func apply(from source: UnsafeRawBufferPointer, to destination: UnsafeMutableRawBufferPointer) {
        precondition(destination.count >= source.count)
        var index = 0
        let count = source.count

        while index < count, keyStreamOffset < 16 {
            destination[index] = source[index] ^ keyStream[keyStreamOffset]
            keyStreamOffset += 1
            index += 1
        }
        guard index < count else { return }

        let remaining = count - index
        let blockCount = (remaining + 15) / 16
        let length = blockCount * 16
        if counters.count < length {
            counters = [UInt8](repeating: 0, count: length)
            stream = [UInt8](repeating: 0, count: length)
        }
        for block in 0..<blockCount {
            let start = block * 16
            for byte in 0..<16 {
                counters[start + byte] = counter[byte]
            }
            incrementCounter()
        }
        var moved = 0
        CCCryptorUpdate(cryptor, counters, length, &stream, length, &moved)

        stream.withUnsafeBufferPointer { keys in
            var offset = 0
            // XOR eight bytes at a time. Then XOR the remaining bytes.
            while offset + 8 <= remaining {
                let value = source.loadUnaligned(fromByteOffset: index + offset, as: UInt64.self)
                    ^ UnsafeRawPointer(keys.baseAddress! + offset).loadUnaligned(as: UInt64.self)
                destination.storeBytes(of: value, toByteOffset: index + offset, as: UInt64.self)
                offset += 8
            }
            while offset < remaining {
                destination[index + offset] = source[index + offset] ^ keys[offset]
                offset += 1
            }
        }

        let lastBlockStart = (blockCount - 1) * 16
        for byte in 0..<16 {
            keyStream[byte] = stream[lastBlockStart + byte]
        }
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
