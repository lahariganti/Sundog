import Foundation

/// One request on the AirPlay control connection. AirPlay uses an RTSP/1.0 format.
struct RTSPRequest {
    static let maximumBodyLength = 1 << 20

    let method: String
    let path: String
    let version: String
    /// Header names in lowercase.
    let headers: [String: String]
    let body: Data

    var cseq: String? { headers["cseq"] }

    var plistBody: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, format: nil)) as? [String: Any]
    }

    enum ParseError: Error {
        case malformed
    }

    /// Removes one complete request from the front of `buffer`.
    /// Returns nil when the buffer does not hold a complete request yet.
    static func parse(from buffer: inout Data) throws -> RTSPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            if buffer.count > 64 * 1024 { throw ParseError.malformed }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw ParseError.malformed
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3 else { throw ParseError.malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maximumBodyLength else { throw ParseError.malformed }
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)

        let request = RTSPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            version: String(requestLine[2]),
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        )
        buffer = Data(buffer[bodyEnd...])
        return request
    }
}

/// One response on the AirPlay control connection.
struct RTSPResponse {
    var status = 200
    var reason = "OK"
    var headers: [(String, String)] = []
    var body = Data()
    /// Close the connection after this response.
    var closesConnection = false

    static let ok = RTSPResponse()

    static func binary(_ data: Data) -> RTSPResponse {
        RTSPResponse(headers: [("Content-Type", "application/octet-stream")], body: data)
    }

    static func plist(_ object: [String: Any]) -> RTSPResponse {
        let data = (try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)) ?? Data()
        return RTSPResponse(headers: [("Content-Type", "application/x-apple-binary-plist")], body: data)
    }

    static func failure(_ status: Int, _ reason: String, close: Bool = false) -> RTSPResponse {
        RTSPResponse(status: status, reason: reason, closesConnection: close)
    }

    func serialized(for request: RTSPRequest) -> Data {
        var head = "\(request.version) \(status) \(reason)\r\n"
        if let cseq = request.cseq {
            head += "CSeq: \(cseq)\r\n"
        }
        head += "Server: AirTunes/\(AirPlayIdentity.sourceVersion)\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n\r\n"
        return Data(head.utf8) + body
    }
}
