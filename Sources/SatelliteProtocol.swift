import Foundation

struct SurfaceConfiguration: Codable, Equatable {
    static let defaultPort: UInt16 = 16623

    let host: String
    let port: UInt16
    let columns: Int
    let rows: Int

    init?(host: String, port: String, columns: Int, rows: Int) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = address.split(separator: ".", omittingEmptySubsequences: false)
        guard !address.isEmpty, address.utf8.count <= 253,
              labels.allSatisfy(Self.validLabel),
              let port = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)), port > 0,
              (1...8).contains(columns), (1...6).contains(rows) else { return nil }
        if labels.count == 4, labels.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }) {
            guard labels.allSatisfy({ UInt8($0) != nil }) else { return nil }
        }
        self.host = host
        self.port = port
        self.columns = columns
        self.rows = rows
    }

    init?(bonjourName: String, columns: Int, rows: Int) {
        guard !bonjourName.isEmpty, (1...8).contains(columns), (1...6).contains(rows) else { return nil }
        host = bonjourName
        port = Self.defaultPort
        self.columns = columns
        self.rows = rows
    }

    private static func validLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
            && label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }

    func keyIndex(_ key: String) -> Int? {
        if let index = Int(key) {
            return (0..<(rows * columns)).contains(index) ? index : nil
        }
        let coordinates = key.split(separator: "/", omittingEmptySubsequences: false)
        guard coordinates.count == 2, let row = Int(coordinates[0]), let column = Int(coordinates[1]),
              (0..<rows).contains(row), (0..<columns).contains(column) else { return nil }
        return row * columns + column
    }
}

struct SavedCompanion: Codable, Equatable, Identifiable {
    let configuration: SurfaceConfiguration
    let bonjourID: String?

    var id: String {
        if let bonjourID { return "bonjour:\(bonjourID)" }
        return "manual:\(configuration.host.lowercased()):\(configuration.port)"
    }

    static func automaticMatch(in profiles: [SavedCompanion], discoveredIDs: [String]) -> SavedCompanion? {
        let knownIDs = Set(profiles.compactMap(\.bonjourID))
        let matches = discoveredIDs.filter { knownIDs.contains($0) }
        guard matches.count == 1, let id = matches.first else { return nil }
        return profiles.first { $0.bonjourID == id }
    }
}

struct SatelliteMessage {
    let command: String
    let body: String
    let flags: Set<String>
    let fields: [String: String]

    init?(_ line: String) {
        guard let start = line.firstIndex(where: { $0 != " " }) else { return nil }
        let trimmed = line[start...]
        let separator = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
        command = trimmed[..<separator].uppercased()
        body = separator == trimmed.endIndex ? "" : String(trimmed[trimmed.index(after: separator)...])
        // The heartbeat payload is opaque and must be echoed without tokenization.
        if command == "PING" || command == "PONG" {
            flags = []
            fields = [:]
            return
        }
        var tokens: [String] = []
        var quoted = false
        var escaped = false
        // Scan UTF-8 to keep large ASCII bitmap fields inexpensive to parse.
        var bytes: [UInt8] = []
        func finishToken() {
            guard !bytes.isEmpty else { return }
            tokens.append(String(decoding: bytes, as: UTF8.self))
            bytes.removeAll(keepingCapacity: true)
        }
        for byte in body.utf8 {
            if escaped {
                bytes.append(byte)
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                quoted.toggle()
            } else if byte == 32 && !quoted {
                finishToken()
            } else {
                bytes.append(byte)
            }
        }
        guard !quoted, !escaped else { return nil }
        finishToken()

        var flags: Set<String> = []
        var fields: [String: String] = [:]
        for token in tokens {
            if let equal = token.firstIndex(of: "=") {
                fields[token[..<equal].uppercased()] = String(token[token.index(after: equal)...])
            } else {
                flags.insert(token.uppercased())
            }
        }
        self.flags = flags
        self.fields = fields
    }

    subscript(_ field: String) -> String? { fields[field] }
    var succeeded: Bool { flags.contains("OK") }
    var failed: Bool { command == "ERROR" || flags.contains("ERROR") }

    static func supportsSubscriptions(apiVersion: String) -> Bool {
        let parts = apiVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let major = Int(parts[0]), let minor = Int(parts[1]),
              let patch = Int(parts[2]), patch >= 0 else { return false }
        return major == 1 && minor >= 10
    }

    var diagnosticLine: String {
        if command == "PING" || command == "PONG" { return "\(command) \(body)" }
        let parameters = fields.keys.sorted().compactMap { key -> String? in
            guard let value = fields[key] else { return nil }
            if key == "BITMAP" { return "BITMAP=<\(value.utf8.count) bytes>" }
            let preview = String(value.prefix(240))
            return "\(key)=\(preview)"
        }
        return ([command] + flags.sorted() + parameters).joined(separator: " ")
    }
}

enum SatelliteFramingError: Error {
    case invalidUTF8
    case lineTooLong
}

struct SatelliteFraming {
    static let limit = 2 * 1024 * 1024
    private var pending = Data()

    mutating func append(_ bytes: Data) throws -> [String] {
        var lines: [String] = []
        var remaining = bytes[...]
        while let newline = remaining.firstIndex(of: 10) {
            try appendFragment(remaining[..<newline])
            if pending.last == 13 { pending.removeLast() }
            guard let line = String(data: pending, encoding: .utf8) else { throw SatelliteFramingError.invalidUTF8 }
            if !line.isEmpty { lines.append(line) }
            pending.removeAll(keepingCapacity: true)
            remaining = remaining[remaining.index(after: newline)...]
        }
        try appendFragment(remaining)
        return lines
    }

    private mutating func appendFragment(_ bytes: Data.SubSequence) throws {
        guard pending.count + bytes.count <= Self.limit else { throw SatelliteFramingError.lineTooLong }
        pending.append(contentsOf: bytes)
    }
}

struct SatelliteVerification {
    var webSocket = false
    var compatibleAPI = false
    var subscriptionsEnabled = false
    var registered = false
    var subscriptionAccepted = false
    var subscriptionArtwork = false
    var surfaceArtwork = false

    var complete: Bool {
        webSocket && compatibleAPI && subscriptionsEnabled && registered
            && subscriptionAccepted && subscriptionArtwork && surfaceArtwork
    }
}
