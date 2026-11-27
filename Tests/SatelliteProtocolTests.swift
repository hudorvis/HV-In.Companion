import Foundation

@main
struct SatelliteProtocolTests {
    static func main() throws {
        try testFraming()
        testMessages()
        testConfiguration()
        testPhysicalKeyPresses()
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
}
