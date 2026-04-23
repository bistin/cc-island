import Foundation

/// A fully-parsed HTTP/1.x request ready for dispatch. Minimal — just
/// what `LocalServer` needs to route `/event` vs `/response` and hand
/// the body to `processEvent`.
public struct HTTPRequest: Equatable {
    public let method: String
    public let path: String
    /// Header names are lowercased for case-insensitive lookup.
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum HTTPParseResult: Equatable {
    /// Headers or body are still incomplete — caller should keep reading.
    case needMore
    /// Full request in hand.
    case done(HTTPRequest)
    /// Framing error — reject with 400.
    case invalid(String)
    /// Declared `Content-Length` + headers exceeds the caller's cap —
    /// reject with 413 without reading the body.
    case tooLarge
}

/// Pure HTTP/1.x request framing. Handles partial buffers (TCP delivers
/// a byte stream; a single `recv` may return headers only, headers
/// plus part of the body, multiple concatenated requests on a
/// keep-alive connection, etc.). Caller passes in everything received
/// so far and re-calls on each new chunk.
public enum HTTPParser {
    private static let headerBodySeparator = Data([0x0d, 0x0a, 0x0d, 0x0a])

    /// Parse whatever's been accumulated so far.
    ///
    /// - Parameter data: bytes received so far on the connection.
    /// - Parameter maxTotalBytes: upper bound on `header-bytes + Content-Length`.
    ///   Returns `.tooLarge` without reading the body if declared size exceeds it.
    ///
    /// Headers are decoded as UTF-8. RFC 7230 technically allows
    /// ISO-8859-1 in field values, but every client that talks to this
    /// localhost server (`curl`, `URLSession`, the Swift hook binary)
    /// emits ASCII-only headers, so strict UTF-8 is an acceptable
    /// simplification.
    public static func parse(_ data: Data, maxTotalBytes: Int) -> HTTPParseResult {
        guard let sepRange = data.range(of: headerBodySeparator) else {
            // Headers not yet complete. If we've already buffered more than
            // the caller's cap just looking for the separator, bail out
            // rather than keep reading forever.
            if data.count > maxTotalBytes {
                return .tooLarge
            }
            return .needMore
        }

        let headerBytes = data.subdata(in: 0..<sepRange.lowerBound)
        guard let headerStr = String(data: headerBytes, encoding: .utf8) else {
            return .invalid("headers are not valid UTF-8")
        }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .invalid("empty request")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            return .invalid("malformed request line: \(requestLine)")
        }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        var seenContentLength: String?
        var hasTransferEncoding = false
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                // RFC 7230 §3.3.2: duplicate values only acceptable if they agree.
                if let previous = seenContentLength, previous != value {
                    return .invalid("conflicting Content-Length: \(previous) vs \(value)")
                }
                seenContentLength = value
            case "transfer-encoding":
                if !value.isEmpty { hasTransferEncoding = true }
            default:
                headers[name] = value
            }
        }

        // TE without a decoder is a framing hazard — reject.
        if hasTransferEncoding {
            return .invalid("Transfer-Encoding not supported")
        }

        let expectedBodyLen: Int
        if let raw = seenContentLength {
            guard let n = Int(raw), n >= 0 else {
                return .invalid("invalid Content-Length: \(raw)")
            }
            expectedBodyLen = n
        } else {
            expectedBodyLen = 0
        }

        // Fail fast on declared oversize, before buffering more body.
        let totalDeclared = sepRange.upperBound + expectedBodyLen
        if totalDeclared > maxTotalBytes {
            return .tooLarge
        }

        let bodyStart = sepRange.upperBound
        let bodyAvailable = data.count - bodyStart
        if bodyAvailable < expectedBodyLen {
            return .needMore
        }

        let body = expectedBodyLen == 0
            ? Data()
            : data.subdata(in: bodyStart..<(bodyStart + expectedBodyLen))
        return .done(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}
