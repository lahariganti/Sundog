import CryptoKit
import Foundation

/// The persistent identity that Sundog shows to iPhones on the network.
struct AirPlayIdentity: Sendable {
    static let model = "AppleTV3,2"
    static let sourceVersion = "220.68"
    /// AirPlay feature bits: mirroring with FairPlay and legacy pairing, H.264 only.
    static let features: UInt64 = 0x5A7F_FEE6

    let name: String
    /// A MAC-style address, for example "AA:BB:CC:DD:EE:FF".
    let deviceID: String
    let pairingID: String
    let signingKey: Curve25519.Signing.PrivateKey

    var publicKey: Data { signingKey.publicKey.rawRepresentation }

    static func load(name: String, defaults: UserDefaults = .standard) -> AirPlayIdentity {
        let keyName = "airplay.signingKey"
        let signingKey: Curve25519.Signing.PrivateKey
        if let raw = defaults.data(forKey: keyName),
           let stored = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            signingKey = stored
        } else {
            signingKey = Curve25519.Signing.PrivateKey()
            defaults.set(signingKey.rawRepresentation, forKey: keyName)
        }

        let deviceIDName = "airplay.deviceID"
        let deviceID: String
        if let stored = defaults.string(forKey: deviceIDName) {
            deviceID = stored
        } else {
            var bytes = (0..<6).map { _ in UInt8.random(in: 0...255) }
            // A locally administered, unicast address.
            bytes[0] = (bytes[0] | 0x02) & 0xFE
            deviceID = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            defaults.set(deviceID, forKey: deviceIDName)
        }

        let pairingIDName = "airplay.pairingID"
        let pairingID: String
        if let stored = defaults.string(forKey: pairingIDName) {
            pairingID = stored
        } else {
            pairingID = UUID().uuidString.lowercased()
            defaults.set(pairingID, forKey: pairingIDName)
        }

        return AirPlayIdentity(name: name, deviceID: deviceID, pairingID: pairingID, signingKey: signingKey)
    }

    func signature(for message: Data) throws -> Data {
        try signingKey.signature(for: message)
    }

    // MARK: Bonjour

    var featuresText: String {
        String(format: "0x%X,0x%X", UInt32(Self.features & 0xFFFF_FFFF), UInt32(Self.features >> 32))
    }

    var publicKeyHex: String {
        publicKey.map { String(format: "%02x", $0) }.joined()
    }

    var raopServiceName: String {
        deviceID.replacingOccurrences(of: ":", with: "") + "@" + name
    }

    var airPlayTXT: Data {
        Self.txtRecord([
            "deviceid": deviceID,
            "features": featuresText,
            "flags": "0x4",
            "model": Self.model,
            "pk": publicKeyHex,
            "pi": pairingID,
            "pw": "false",
            "srcvers": Self.sourceVersion,
            "vv": "2",
        ])
    }

    var raopTXT: Data {
        Self.txtRecord([
            "am": Self.model,
            "ch": "2",
            "cn": "0,1,2,3",
            "da": "true",
            "et": "0,3,5",
            "ft": featuresText,
            "md": "0,1,2",
            "pk": publicKeyHex,
            "pw": "false",
            "rhd": "5.6.0.0",
            "sf": "0x4",
            "sr": "44100",
            "ss": "16",
            "sv": "false",
            "tp": "UDP",
            "txtvers": "1",
            "vn": "65537",
            "vs": Self.sourceVersion,
            "vv": "2",
        ])
    }

    /// Encodes a DNS-SD TXT record: each entry is a length byte and "key=value".
    private static func txtRecord(_ entries: [String: String]) -> Data {
        var data = Data()
        for key in entries.keys.sorted() {
            let entry = Data("\(key)=\(entries[key]!)".utf8)
            data.append(UInt8(entry.count))
            data.append(entry)
        }
        return data
    }
}
