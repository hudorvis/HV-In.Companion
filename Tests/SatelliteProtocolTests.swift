import Foundation

@main
struct SatelliteProtocolTests {
    static func main() throws {
        try testFraming()
        testMessages()
        testConfiguration()
        try testCompanionGridConfig()
        testPhysicalKeyPresses()
        testDeckLayout()
        testButtonReplies()
        testVerification()
        try testSavedServers()
        print("Satellite protocol tests passed")
    }

    static func testFraming() throws {
        var framing = SatelliteFraming()
        let first = try framing.append(Data("BEGIN CompanionVersion=4.3.0 ApiVersion=1.10.0\r".utf8))
        precondition(first.isEmpty)
        let second = try framing.append(Data("\nCAPS SUBSCRIPTIONS=1\nKEY-".utf8))
        precondition(second == ["BEGIN CompanionVersion=4.3.0 ApiVersion=1.10.0", "CAPS SUBSCRIPTIONS=1"])
        let third = try framing.append(Data("STATE KEY=0\n\n".utf8))
        precondition(third == ["KEY-STATE KEY=0"])
        do {
            _ = try framing.append(Data(repeating: 65, count: SatelliteFraming.limit + 1))
            preconditionFailure("Oversized line accepted")
        } catch SatelliteFramingError.lineTooLong {}
        do {
            _ = try framing.append(Data([0xFF, 10]))
            preconditionFailure("Invalid UTF-8 accepted")
        } catch SatelliteFramingError.invalidUTF8 {}
    }

    static func testMessages() {
        let hello = SatelliteMessage(#"BEGIN CompanionVersion="4.3.0-stable" ApiVersion="1.10.0" "#)
        precondition(hello?["COMPANIONVERSION"] == "4.3.0-stable")
        precondition(hello?["APIVERSION"] == "1.10.0")
        let failure = SatelliteMessage(#"ADD-SUB ERROR MESSAGE="Try \"Enable Button Subscriptions API\" first" "#)
        precondition(failure?.failed == true)
        precondition(failure?["MESSAGE"] == #"Try "Enable Button Subscriptions API" first"#)
        let bitmap = SatelliteMessage(#"SUB-STATE SUBID="setup-artwork" TYPE="BUTTON" BITMAP="data:image/png;base64,AA==" "#)
        precondition(bitmap?["BITMAP"] == "data:image/png;base64,AA==")
        precondition(bitmap?.diagnosticLine.contains("AA==") == false)
        let ack = SatelliteMessage(#"ADD-DEVICE OK DEVICEID="surface" "#)
        precondition(ack?.succeeded == true && ack?["DEVICEID"] == "surface")
        let ping = SatelliteMessage(#"PING arbitrary "text"#)
        precondition(ping?.body == #"arbitrary "text"#)
        precondition(SatelliteMessage(#"ERROR MESSAGE="incomplete"#) == nil)
        for version in ["1.10.0", "1.16.1", "1.100.0"] {
            precondition(SatelliteMessage.supportsSubscriptions(apiVersion: version))
        }
        for version in ["1.9.0", "2.0.0", "1.10", "1.10.", "1.10.bad"] {
            precondition(!SatelliteMessage.supportsSubscriptions(apiVersion: version))
        }
    }

    static func testConfiguration() {
        let configuration = SurfaceConfiguration(host: " companion.local ", port: "16623", columns: 8, rows: 6)
        precondition(configuration?.host == "companion.local")
        precondition(configuration?.keyIndex("47") == 47)
        precondition(configuration?.keyIndex("5/7") == 47)
        for key in ["48", "5/8", "6/0", "/0/0", "0//0", "-1"] {
            precondition(configuration?.keyIndex(key) == nil)
        }
        precondition(SurfaceConfiguration(host: "192.168.1.100", port: "16623", columns: 3, rows: 2) != nil)
        for host in ["https://companion.local", "companion.local:16623", "192.168.1.999", "", "host..local"] {
            precondition(SurfaceConfiguration(host: host, port: "16623", columns: 5, rows: 3) == nil)
        }
        precondition(SurfaceConfiguration(host: "companion.local", port: "0", columns: 5, rows: 3) == nil)
    }

    static func testCompanionGridConfig() throws {
        let original = SurfaceConfiguration(host: "desk.local", port: "19000", columns: 5, rows: 3)!
        let data = Data(base64Encoded: original.gridConfigFields)!
        let advertised = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        precondition(advertised.map { $0["label"] as? String } == ["Row Count", "Column Count"])
        precondition(advertised.map { $0["default"] as? Int } == [3, 5])
        precondition(advertised.allSatisfy { ($0["max"] as? Int) == 32 })

        func apply(_ json: String) -> SurfaceConfiguration? {
            original.applyingGridConfig(Data(json.utf8).base64EncodedString())
        }
        let resized = apply(#"{"rows":8,"columns":12}"#)
        precondition(resized?.host == "desk.local" && resized?.port == 19000)
        precondition(resized?.keyIndex("7/11") == 95)
        precondition(resized?.keyPressCommand(deviceID: "phone", index: 95, pressed: true)
                     == "KEY-PRESS DEVICEID=phone KEY=7/11 PRESSED=1")
        precondition(apply(#"{"columns":8}"#)?.rows == 3)
        precondition(apply(#"{"rows":3,"columns":5}"#) == original)
        precondition(apply(#"{"rows":0}"#) == nil)
        precondition(apply(#"{"columns":33}"#) == nil)
        precondition(apply(#"{"rows":3.5}"#) == nil)
        precondition(original.applyingGridConfig("invalid base64!") == nil)
    }

    static func testPhysicalKeyPresses() {
        let grid = SurfaceConfiguration(bonjourName: "Studio", columns: 5, rows: 3)!
        precondition(grid.keyPressCommand(deviceID: "surface", index: 0, pressed: true)
                     == "KEY-PRESS DEVICEID=surface KEY=0/0 PRESSED=1")
        precondition(grid.keyPressCommand(deviceID: "surface", index: 7, pressed: true)
                     == "KEY-PRESS DEVICEID=surface KEY=1/2 PRESSED=1")
        precondition(grid.keyPressCommand(deviceID: "surface", index: 7, pressed: false)
                     == "KEY-PRESS DEVICEID=surface KEY=1/2 PRESSED=0")
        precondition(grid.keyPressCommand(deviceID: "surface", index: 15, pressed: false) == nil)
    }

    static func testButtonReplies() {
        let accepted = SatelliteMessage(#"KEY-PRESS OK DEVICEID="surface""#)!
        let refused = SatelliteMessage(#"KEY-PRESS ERROR DEVICEID="surface" MESSAGE="Invalid key""#)!
        let other = SatelliteMessage(#"KEY-STATE DEVICEID="surface" KEY=0/0 PRESSED=1"#)!
        precondition(SatelliteButtonReply(accepted, deviceID: "surface")?.result == .accepted)
        precondition(SatelliteButtonReply(refused, deviceID: "surface")?.result == .rejected("Invalid key"))
        precondition(SatelliteButtonReply(accepted, deviceID: "different") == nil)
        precondition(SatelliteButtonReply(other, deviceID: "surface") == nil)
    }

    static func testSavedServers() throws {
        let studioConfig = SurfaceConfiguration(bonjourName: "Studio A", columns: 5, rows: 3)!
        let truckConfig = SurfaceConfiguration(bonjourName: "OB Truck", columns: 8, rows: 4)!
        let manualConfig = SurfaceConfiguration(host: "studio.local", port: "16623", columns: 3, rows: 2)!
        let studio = SavedCompanion(configuration: studioConfig, bonjourID: "studio")
        let truck = SavedCompanion(configuration: truckConfig, bonjourID: "truck")
        let manual = SavedCompanion(configuration: manualConfig, bonjourID: nil)
        let profiles = [studio, truck, manual]
        let history = try JSONEncoder().encode(profiles)
        let restored = try JSONDecoder().decode([SavedCompanion].self, from: history)
        precondition(restored == profiles)
        precondition(SavedCompanion.automaticMatch(in: restored, discoveredIDs: ["studio", "unknown"]) == studio)
        precondition(SavedCompanion.automaticMatch(in: restored, discoveredIDs: ["truck"]) == truck)
        precondition(SavedCompanion.automaticMatch(in: restored, discoveredIDs: ["studio", "truck"]) == nil)
        precondition(SavedCompanion.automaticMatch(in: restored, discoveredIDs: ["studio", "studio"]) == nil)
        precondition(SavedCompanion.automaticMatch(in: restored, discoveredIDs: ["studio.local"]) == nil)
        let renamed = SurfaceConfiguration(bonjourName: "Studio A (new name)", columns: 5, rows: 3)!
        precondition(SavedCompanion(configuration: renamed, bonjourID: "studio").id == studio.id)
    }

    static func testVerification() {
        var result = SatelliteVerification()
        result.webSocket = true
        result.compatibleAPI = true
        result.subscriptionsEnabled = true
        result.registered = true
        result.subscriptionAccepted = true
        precondition(!result.complete)
        result.subscriptionArtwork = true
        precondition(!result.complete)
        result.surfaceArtwork = true
        precondition(result.complete)
    }

    static func testDeckLayout() {
        let portrait = DeckLayout(size: CGSize(width: 366, height: 600), columns: 5, rows: 3, corner: 0)
        precondition(portrait.center == CGPoint(x: 183, y: 300))

        let size = CGSize(width: 780, height: 356)
        let offset = CGPoint(x: -20, y: 10)
        let full = DeckLayout(size: size, columns: 16, rows: 7, corner: 44, centerOffset: offset)
        precondition(full.center == CGPoint(x: 370, y: 188))
        let width = 16 * full.side + 15 * full.gap
        let height = 7 * full.side + 6 * full.gap
        let deck = CGRect(x: full.center.x - width / 2, y: full.center.y - height / 2,
                          width: width, height: height)
        precondition(CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01).contains(deck))
        precondition(!deck.intersects(CGRect(x: 736, y: 0, width: 44, height: 44)))
    }
}
