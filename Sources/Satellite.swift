import Combine
import Foundation
import Network
import UIKit

@MainActor
final class Satellite: ObservableObject {
    enum Stage: String {
        case disconnected = "Disconnected"
        case opening = "Opening WebSocket"
        case greeting = "Waiting for Companion"
        case capabilities = "Checking API capabilities"
        case registering = "Registering surface"
        case artwork = "Verifying button artwork"
        case connected = "Connected"
        case reconnecting = "Waiting to retry"
        case failed = "Connection failed"
    }

    static let surfaceName = "In.Companion"
    private static let probeID = "setup-artwork"
    private static let bitmapSize = 96

    @Published private(set) var stage: Stage = .disconnected
    @Published private(set) var verification = SatelliteVerification()
    @Published private(set) var images: [Int: UIImage] = [:]
    @Published private(set) var held: Set<Int> = []
    @Published private(set) var remoteHeld: Set<Int> = []
    @Published private(set) var configuration: SurfaceConfiguration?
    @Published private(set) var companionVersion: String?
    @Published private(set) var apiVersion: String?
    @Published private(set) var lastSuccess = UserDefaults.standard.object(forKey: "lastSatelliteConnection") as? Date
    @Published private(set) var imageCount = 0
    @Published private(set) var log: [String] = []
    @Published private(set) var error: String?

    var connected: Bool { stage == .connected }
    var usesTestConfiguration: Bool { temporary }
    var mayDisconnect: Bool { socket != nil || retryTask != nil || wantsConnection }

    let surfaceID: String = {
        let key = "surfaceID"
        if let saved = UserDefaults.standard.string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()

    private var socket: NWConnection?
    private var drainingSocket: NWConnection?
    private var framing = SatelliteFraming()
    private var timeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var wantsConnection = false
    private var temporary = false
    private var retryDelay = 1
    private var lastPong = ContinuousClock.now
    private var probesSent = 0
    private var probesAnswered = 0
    private var probeStarted = false
    private var firstArtworkLocation: String?
    private var bitmapFormat = ""

    func connect(_ configuration: SurfaceConfiguration, testing: Bool = false) {
        disconnect()
        self.configuration = configuration
        temporary = testing
        wantsConnection = true
        retryDelay = 1
        error = nil
        resetVerification()
        setStage(.opening)
        if drainingSocket == nil { start() }
    }

    func acceptTest() {
        guard connected else { return }
        temporary = false
        recordSuccess()
    }

    func discardTest() {
        guard temporary else { return }
        disconnect()
        temporary = false
    }

    func disconnect() {
        wantsConnection = false
        retryTask?.cancel()
        retryTask = nil
        if let socket, verification.webSocket {
            releaseAll()
            // The Network framework sends content in enqueue order. Wait for QUIT to be
            // processed by the transport before cancelling, with a bounded drain on loss.
            drainingSocket = socket
            transmit("QUIT", on: socket) { [weak self, weak socket] _ in
                guard let self, let socket else { return }
                self.finishDrain(socket)
            }
            Task { @MainActor [weak self, weak socket] in
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, let socket else { return }
                self.finishDrain(socket)
            }
        } else {
            socket?.cancel()
        }
        socket = nil
        stopTimers()
        clearSurface()
        resetVerification()
        setStage(.disconnected)
    }

    func press(_ index: Int, _ down: Bool) {
        guard connected, let socket else { return }
        if down {
            guard images[index] != nil, held.insert(index).inserted else { return }
        } else {
            guard held.remove(index) != nil else { return }
        }
        transmit("KEY-PRESS DEVICEID=\(surfaceID) KEY=\(index) PRESSED=\(down ? 1 : 0)", on: socket)
    }

    func releaseAll() {
        for index in held.sorted() { press(index, false) }
    }

    func clearDiagnostics() {
        log.removeAll()
        imageCount = 0
        error = nil
    }

    var diagnostics: String {
        let success = lastSuccess?.formatted(date: .abbreviated, time: .standard) ?? "—"
        return [
            "In.Companion v26.11.26.05",
            "Server: \(configuration?.host ?? "—")",
            "Port: \(configuration.map { String($0.port) } ?? "—")",
            "Protocol: Satellite WebSocket",
            "Status: \(stage.rawValue)",
            "Companion: \(companionVersion ?? "—")",
            "API: \(apiVersion ?? "—")",
            "Surface: \(Self.surfaceName) (\(surfaceID))",
            "Last successful connection: \(success)",
            "Button images received: \(imageCount)",
            "Last error: \(error ?? "—")"
        ].joined(separator: "\n") + "\n\n" + log.joined(separator: "\n")
    }

    private func start() {
        guard wantsConnection, socket == nil, let configuration,
              let port = NWEndpoint.Port(rawValue: configuration.port) else { return }
        resetVerification()
        framing = SatelliteFraming()
        probesSent = 0
        probesAnswered = 0
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.maximumMessageSize = SatelliteFraming.limit
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        let connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: port, using: parameters)
        socket = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            DispatchQueue.main.async {
                guard let self, let connection, self.socket === connection else { return }
                self.handleState(state, on: connection)
            }
        }
        setStage(.opening)
        armTimeout(on: connection, message: "WebSocket did not open. Check the hostname, Satellite WebSocket port and Local Network access.", seconds: 10)
        connection.start(queue: .main)
    }

    private func handleState(_ state: NWConnection.State, on connection: NWConnection) {
        switch state {
        case .ready:
            verification.webSocket = true
            setStage(.greeting)
            armTimeout(on: connection, message: "WebSocket opened but Companion did not send its API greeting.", seconds: 5)
            startHeartbeat(on: connection)
            receive(on: connection)
        case .waiting(let networkError):
            appendLog("WebSocket waiting · \(describe(networkError))")
        case .failed(let networkError):
            let localDenied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
            fail(localDenied
                 ? "Local Network access is off. Enable it for In.Companion in iOS Settings and retry."
                 : "\(stage.rawValue): \(describe(networkError))", retry: !localDenied)
        case .cancelled:
            fail("WebSocket was cancelled.")
        default:
            break
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, context, _, networkError in
            DispatchQueue.main.async {
                guard let self, let connection, self.socket === connection else { return }
                if let networkError {
                    self.fail("WebSocket receive: \(self.describe(networkError))")
                    return
                }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if metadata?.opcode == .close || (data == nil && metadata == nil) {
                    self.fail("Companion closed the WebSocket.")
                    return
                }
                if let data, metadata?.opcode == .text || metadata?.opcode == .binary {
                    do {
                        let lines = try self.framing.append(data)
                        for line in lines {
                            guard self.socket === connection else { return }
                            self.handle(line, on: connection)
                        }
                    } catch {
                        self.fail("Companion sent an invalid Satellite message: \(error).", retry: false)
                    }
                }
                if self.socket === connection { self.receive(on: connection) }
            }
        }
    }

    private func handle(_ line: String, on connection: NWConnection) {
        guard let message = SatelliteMessage(line) else {
            appendLog("RX · Malformed Satellite message")
            return
        }
        let sampleKeyState = !verification.surfaceArtwork || imageCount % 32 == 0
        let sampleHeartbeat = message.command != "PONG"
            || (Int(message.body.trimmingCharacters(in: .whitespaces)) ?? 1) % 15 == 1
        if (message.command != "KEY-STATE" || sampleKeyState) && sampleHeartbeat {
            appendLog("RX · " + message.diagnosticLine)
        }
        if message.failed {
            let detail = "\(message.command): \(message["MESSAGE"] ?? "Companion rejected the command.")"
            switch message.command {
            case "ADD-DEVICE", "ADD-SUB": fail(detail, retry: false)
            case "KEY-PRESS": fail(detail)
            default: error = detail
            }
            return
        }
        switch message.command {
        case "PING":
            transmit("PONG \(message.body)", on: connection)
        case "PONG":
            if let sequence = Int(message.body.trimmingCharacters(in: .whitespaces)),
               sequence > probesAnswered, sequence <= probesSent {
                probesAnswered = sequence
                lastPong = .now
            }
        case "BEGIN" where stage == .greeting:
            companionVersion = message["COMPANIONVERSION"]
            apiVersion = message["APIVERSION"]
            guard let apiVersion, SatelliteMessage.supportsSubscriptions(apiVersion: apiVersion) else {
                fail("Companion 4.3 or later is required. Satellite API reported \(apiVersion ?? "no version").", retry: false)
                return
            }
            verification.compatibleAPI = true
            setStage(.capabilities)
            armTimeout(on: connection, message: "Companion did not advertise Satellite API capabilities.", seconds: 5)
        case "CAPS" where stage == .capabilities:
            guard Self.isTrue(message["SUBSCRIPTIONS"]) else {
                fail("Enable Button Subscriptions API in Companion → Settings → Protocols, then retry.", retry: false)
                return
            }
            verification.subscriptionsEnabled = true
            guard let configuration else { return }
            let formats = message["BITMAP_FORMATS"]?.split(separator: ",") ?? []
            bitmapFormat = formats.contains("png") ? " BITMAP_FORMAT=png" : ""
            setStage(.registering)
            armTimeout(on: connection, message: "Companion did not acknowledge the surface. Check its Surfaces tab and Satellite settings.", seconds: 10)
            transmit("ADD-DEVICE DEVICEID=\(surfaceID) PRODUCT_NAME=\"\(Self.surfaceName)\" KEYS_TOTAL=\(configuration.rows * configuration.columns) KEYS_PER_ROW=\(configuration.columns) BITMAPS=\(Self.bitmapSize) BRIGHTNESS=0\(bitmapFormat)", on: connection)
        case "ADD-DEVICE" where stage == .registering:
            guard message.succeeded, message["DEVICEID"] == surfaceID else { return }
            verification.registered = true
            setStage(.artwork)
            armTimeout(on: connection, message: "Surface registered, but verification is incomplete. Check that the surface is active in Companion and artwork is being sent.", seconds: 15)
            subscribeForVerification(on: connection)
        case "KEYS-CLEAR" where message["DEVICEID"] == surfaceID:
            releaseAll()
            clearSurface()
        case "KEY-STATE" where message["DEVICEID"] == surfaceID:
            handleKeyState(message, on: connection)
        case "ADD-SUB" where message.succeeded && message["SUBID"] == Self.probeID:
            verification.subscriptionAccepted = true
            finishVerification(on: connection)
        case "SUB-STATE" where message["SUBID"] == Self.probeID && !verification.subscriptionArtwork:
            guard let data = message["BITMAP"], Self.bitmap(data) != nil else { return }
            imageCount += 1
            verification.subscriptionArtwork = true
            transmit("REMOVE-SUB SUBID=\(Self.probeID)", on: connection)
            finishVerification(on: connection)
        default:
            break
        }
    }

    private func handleKeyState(_ message: SatelliteMessage, on connection: NWConnection) {
        guard let rawKey = message["KEY"], let index = configuration?.keyIndex(rawKey) else { return }
        if let value = message["BITMAP"] {
            if let artwork = Self.bitmap(value) {
                images[index] = artwork
                imageCount += 1
                if !verification.surfaceArtwork {
                    verification.surfaceArtwork = true
                    firstArtworkLocation = Self.validLocation(message["LOCATION"])
                }
            } else {
                press(index, false)
                images.removeValue(forKey: index)
                appendLog("KEY-STATE · Invalid bitmap for key \(rawKey)")
            }
        }
        if Self.isTrue(message["PRESSED"]) { remoteHeld.insert(index) }
        else { remoteHeld.remove(index) }
        subscribeForVerification(on: connection)
        finishVerification(on: connection)
    }

    private func subscribeForVerification(on connection: NWConnection) {
        guard verification.registered, verification.surfaceArtwork, !probeStarted else { return }
        probeStarted = true
        // System controls may omit LOCATION. Use a valid coordinate for the probe in that case.
        let location = firstArtworkLocation ?? "1/0/0"
        transmit("ADD-SUB SUBID=\(Self.probeID) LOCATION=\(location) BITMAP=\(Self.bitmapSize)\(bitmapFormat)", on: connection)
    }

    private func finishVerification(on connection: NWConnection) {
        guard stage == .artwork, verification.complete, !images.isEmpty, socket === connection else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        retryDelay = 1
        error = nil
        setStage(.connected)
        if !temporary { recordSuccess() }
    }

    private func recordSuccess() {
        let now = Date()
        lastSuccess = now
        UserDefaults.standard.set(now, forKey: "lastSatelliteConnection")
    }

    private func transmit(_ line: String, on connection: NWConnection, completion: ((NWError?) -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "satellite", metadata: [metadata])
        if line.hasPrefix("PING ") {
            // Keep a sample of periodic heartbeat traffic without rolling setup out of the log.
            if probesSent % 15 == 1 { appendLog("TX · " + line) }
        } else {
            appendLog("TX · " + line)
        }
        connection.send(content: Data((line + "\n").utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self, weak connection] networkError in
            DispatchQueue.main.async {
                if let completion {
                    completion(networkError)
                } else if let self, let connection, self.socket === connection, let networkError {
                    self.fail("WebSocket send: \(self.describe(networkError))")
                }
            }
        })
    }

    private func armTimeout(on connection: NWConnection, message: String, seconds: Int) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self, weak connection] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, let connection, self.socket === connection else { return }
            if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                self.fail("Local Network access is off. Enable it for In.Companion in iOS Settings and retry.", retry: false)
            } else {
                self.fail(message)
            }
        }
    }

    private func startHeartbeat(on connection: NWConnection) {
        lastPong = .now
        heartbeatTask = Task { @MainActor [weak self, weak connection] in
            while !Task.isCancelled {
                guard let self, let connection, self.socket === connection else { return }
                if self.lastPong.duration(to: .now) > .seconds(7) {
                    self.fail("Companion stopped responding to Satellite keepalives.")
                    return
                }
                self.probesSent += 1
                self.transmit("PING \(self.probesSent)", on: connection)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private func fail(_ detail: String, retry: Bool = true) {
        error = detail
        appendLog("Error · " + detail)
        let previous = socket
        socket = nil
        previous?.cancel()
        stopTimers()
        clearSurface()
        guard wantsConnection, !temporary, retry else {
            wantsConnection = false
            setStage(.failed)
            return
        }
        setStage(.reconnecting)
        let delay = retryDelay
        retryDelay = min(delay * 2, 15)
        retryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.retryTask = nil
            self.start()
        }
    }

    private func stopTimers() {
        timeoutTask?.cancel()
        timeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func finishDrain(_ connection: NWConnection) {
        guard drainingSocket === connection else { return }
        drainingSocket = nil
        connection.cancel()
        if wantsConnection { start() }
    }

    private func resetVerification() {
        verification = SatelliteVerification()
        companionVersion = nil
        apiVersion = nil
        probeStarted = false
        firstArtworkLocation = nil
    }

    private func clearSurface() {
        held.removeAll()
        remoteHeld.removeAll()
        images.removeAll()
    }

    private func setStage(_ stage: Stage) {
        guard self.stage != stage else { return }
        self.stage = stage
        appendLog(stage.rawValue)
    }

    private func appendLog(_ message: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(message)")
        if log.count > 160 { log.removeFirst(log.count - 160) }
    }

    private func describe(_ error: NWError) -> String { "\(error.localizedDescription) [\(error)]" }

    private static func isTrue(_ value: String?) -> Bool {
        value == "1" || value?.lowercased() == "true"
    }

    private static func validLocation(_ value: String?) -> String? {
        guard let value else { return nil }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } } ? value : nil
    }

    static func bitmap(_ value: String) -> UIImage? {
        if value.hasPrefix("data:image/png;base64,"), let comma = value.firstIndex(of: ","),
           let bytes = Data(base64Encoded: String(value[value.index(after: comma)...])),
           let image = UIImage(data: bytes), image.size == CGSize(width: CGFloat(bitmapSize), height: CGFloat(bitmapSize)) {
            return image
        }
        let side = bitmapSize
        guard let bytes = Data(base64Encoded: value), bytes.count == side * side * 3 else { return nil }
        var pixels = Data(repeating: 255, count: side * side * 4)
        pixels.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for pixel in 0..<(side * side) {
                    destination[pixel * 4] = source[pixel * 3]
                    destination[pixel * 4 + 1] = source[pixel * 3 + 1]
                    destination[pixel * 4 + 2] = source[pixel * 3 + 2]
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: side * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
