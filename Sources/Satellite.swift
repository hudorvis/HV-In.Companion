import Foundation
import Network
import UIKit
import Combine

final class Satellite: ObservableObject {
    @Published private(set) var status = "Disconnected"
    @Published private(set) var images: [Int: UIImage] = [:]
    @Published private(set) var connected = false
    @Published private(set) var held: Set<Int> = []
    private var socket: NWConnection?
    private var buffer = Data()
    private var timer: Timer?
    private var lastResponse = Date()
    private var ready = false
    private var enabled = false
    private var target = ""
    private var port: UInt16 = 16622
    private var columns = 5
    private var rows = 3
    private let id: String = {
        let key = "surfaceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()
    func connect(host: String, port: UInt16, columns: Int, rows: Int) {
        disconnect()
        target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, port > 0 else { status = "Invalid address"; return }
        self.port = port; self.columns = columns; self.rows = rows
        enabled = true; start()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.enabled else { return }
            if self.socket == nil { self.start() }
            else if Date().timeIntervalSince(self.lastResponse) > 8 { self.failed() }
            else if self.ready { self.send("PING incompanion") }
        }
    }
    private func start() {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        status = "Connecting"; lastResponse = Date(); buffer.removeAll()
        let c = NWConnection(host: NWEndpoint.Host(target), port: p, using: .tcp)
        socket = c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self, let c, self.socket === c else { return }
            switch state {
            case .ready: self.ready = true; self.receive(c)
            case .failed(_), .cancelled: self.failed()
            default: break
            }
        }
        c.start(queue: .main)
    }
    private func failed() {
        let old = socket; socket = nil; old?.cancel()
        ready = false; connected = false; held.removeAll(); images.removeAll(); buffer.removeAll()
        status = enabled ? "Reconnecting" : "Disconnected"
    }
    func disconnect() {
        enabled = false; timer?.invalidate(); timer = nil
        releaseAll(); failed()
    }
    private func send(_ line: String) {
        guard let c = socket else { return }
        c.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self, weak c] error in
            guard let self, let c, self.socket === c, error != nil else { return }; self.failed()
        })
    }
    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, error in
            guard let self, let c, self.socket === c else { return }
            if let data { self.buffer.append(data) }
            while let end = self.buffer.firstIndex(of: 10) {
                let line = String(decoding: self.buffer[..<end], as: UTF8.self).trimmingCharacters(in: .newlines)
                self.buffer.removeSubrange(...end); self.handle(line)
                guard self.socket === c else { return }
            }
            if done || error != nil || self.buffer.count > 2_000_000 { self.failed() } else { self.receive(c) }
        }
    }
    private func handle(_ line: String) {
        lastResponse = Date()
        let parts = line.split(separator: " ")
        guard let command = parts.first else { return }
        let fields = Dictionary(parts.dropFirst().compactMap { part -> (String,String)? in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false); guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }, uniquingKeysWith: { _, new in new })
        switch command {
        case "BEGIN":
            let version = (fields["ApiVersion"] ?? "0").split(separator: ".").compactMap { Int($0) }
            guard version.count >= 2, version[0] == 1 else { disconnect(); status = "Unsupported API"; return }
            send("ADD-DEVICE DEVICEID=\(id) PRODUCT_NAME=\"In.Companion\" KEYS_TOTAL=\(columns * rows) KEYS_PER_ROW=\(columns) BITMAPS=true BRIGHTNESS=false")
        case "ADD-DEVICE":
            if parts.dropFirst().first == "OK" { connected = true; status = "Connected" }
            else { disconnect(); status = "Registration failed" }
        case "PING": send("PONG" + String(line.dropFirst(4)))
        case "KEYS-CLEAR": if fields["DEVICEID"] == id { images.removeAll() }
        case "KEY-STATE":
            guard fields["DEVICEID"] == id, let key = fields["KEY"] else { return }
            let rc = key.split(separator: "/").compactMap { Int($0) }
            let index = Int(key) ?? (rc.count == 2 && (0..<rows).contains(rc[0]) && (0..<columns).contains(rc[1]) ? rc[0] * columns + rc[1] : -1)
            guard (0..<(columns * rows)).contains(index) else { return }
            if let b = fields["BITMAP"], let image = Self.bitmap(b) { images[index] = image }
            else if fields["BITMAP"] != nil { images.removeValue(forKey: index) }
        default: break
        }
    }
    static func bitmap(_ value: String) -> UIImage? {
        if value.hasPrefix("data:"), let comma = value.firstIndex(of: ","), let d = Data(base64Encoded: String(value[value.index(after: comma)...])) { return UIImage(data: d) }
        guard let data = Data(base64Encoded: value), data.count > 0, data.count % 3 == 0 else { return nil }
        let side = Int(Double(data.count / 3).squareRoot())
        guard side > 0, side <= 512, side * side * 3 == data.count else { return nil }
        var rgba = Data(capacity: side * side * 4)
        let bytes = [UInt8](data)
        for i in stride(from: 0, to: bytes.count, by: 3) { rgba.append(contentsOf: [bytes[i], bytes[i+1], bytes[i+2], 255]) }
        guard let provider = CGDataProvider(data: rgba as CFData), let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
    func press(_ index: Int, _ down: Bool) {
        guard connected, (0..<(columns * rows)).contains(index) else { return }
        if down { guard held.insert(index).inserted else { return } }
        else { guard held.remove(index) != nil else { return } }
        send("KEY-PRESS DEVICEID=\(id) KEY=\(index) PRESSED=\(down)")
    }
    func releaseAll() { for index in Array(held) { press(index, false) } }
}
