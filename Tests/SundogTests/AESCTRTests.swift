import Foundation
import Testing
@testable import Sundog

/// If the key stream is incorrect or loses its position, the mirror stream shows incorrect video and gives no error.
struct AESCTRTests {
    // NIST SP 800-38A, F.5.1 CTR-AES128.Encrypt
    let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
    let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
    let plainText = Data(hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
    let cipherText = Data(hex: "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")

    @Test func matchesNISTVector() throws {
        let cipher = try #require(AESCTR(key: key, iv: iv))
        var data = plainText
        cipher.apply(to: &data)
        #expect(data == cipherText)
    }

    @Test func continuesAcrossUnevenChunks() throws {
        let cipher = try #require(AESCTR(key: key, iv: iv))
        var output = Data()
        for range in [0..<5, 5..<21, 21..<22, 22..<32] {
            var chunk = plainText.subdata(in: range)
            cipher.apply(to: &chunk)
            output.append(chunk)
        }
        #expect(output == cipherText)
    }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
