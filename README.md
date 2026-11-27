# In.Companion v26.11.27.05

Native iPhone and iPad control surface for Bitfocus Companion 4.3 or later.

## Connect over Wi-Fi

1. Put the iPhone or iPad on the same local network as the Companion computer. The computer can use wired Ethernet on that LAN.
2. In Companion, open **Settings → Protocols** and enable **Button Subscriptions API**.
3. In Companion **5.1.3 or later**, open **Settings → General**, give the installation a recognisable name, and enable **Announce Companion on the network (mDNS/Bonjour)**. For 4.3 or a version that does not advertise the short Satellite WebSocket service type, see the host announcement below.
4. Open In.Companion and allow **Local Network** access. Tap the connection status or server name at the top, then pick your installation under **Nearby**. The surface opens as soon as Companion sends button artwork.
5. In Companion, open **Surfaces → Configured Surfaces** and select **In.Companion**. Configure the startup page and assignments in Companion. Repeat for each installation.

On return to a network, In.Companion reconnects automatically if one saved Bonjour server is available. If several saved servers are present, tap the connection status or server name to choose. The iPhone identifies servers by the ID in their Bonjour advertisements and uses the currently advertised address and port. Each server retains its own surface setup via the iPhone's persistent Satellite ID. Any manual address saved in an earlier revision is also available in the picker. New surfaces use a 5 × 3 grid. Existing saved surfaces keep their grid.

### Announce an older Companion host

On the Mac running Companion, open Terminal and run:

```sh
dns-sd -R "Studio Companion" _comp-sat-ws._tcp local 16623 id=studio-companion
```

On a Linux host with Avahi, the equivalent is:

```sh
avahi-publish-service "Studio Companion" _comp-sat-ws._tcp 16623 id=studio-companion
```

Use an ID unique to each Companion computer, keep it the same between visits, and use the actual **Satellite WebSocket Listen Port**. Leave the command running while you need discovery.

The app verifies the WebSocket, Satellite API 1.10 or later within major version 1, surface registration, and actual bitmap delivery from both the surface and a read-only button subscription. The subscription uses an absolute page location. The registered surface follows Companion’s own page, lock and button handling. See the [Bitfocus Satellite API](https://companion.free/for-developers/Satellite-API/).

The operating grid uses Companion’s original bitmaps. The top-right arrow toggles full screen in both modes. During a disconnect, the app clears the artwork and disables input. Planned disconnects release held buttons before closing. An abrupt network failure can prevent a release from reaching Companion, and the app never replays button input after reconnecting.

### Check button input

Press and release a key, then tap the status or server name. **Last button reply** shows whether Companion accepted that input. An accepted input is a Satellite protocol reply. The page change still depends on the button action and the target configured in Companion. For a page jump on the iPhone, edit the button, use **Surface: Set to page**, and select **Current surface** as the target. Check that the destination is allowed for the In.Companion surface or its group.

## Build and test

On macOS with Xcode and XcodeGen installed:

```sh
swiftc Sources/SatelliteProtocol.swift Tests/SatelliteProtocolTests.swift -o /tmp/incompanion-protocol-tests
/tmp/incompanion-protocol-tests
python3 scripts/verify_app_icon.py
xcodegen generate
open In.Companion.xcodeproj
```

GitHub Actions checks the protocol, saved-server matching and iOS Simulator compilation. Physical iPhone and iPad testing against a live Companion instance is required to verify Local Network permission, touch handling and end-to-end operation.

Codemagic uses the `ios-release` workflow, App Store Connect integration `In.Sync`, Apple ID `6839444405` and bundle ID `au.h-v.in.companion`. Main branch pushes trigger builds. The workflow sets the build number, signs the IPA and uploads it to App Store Connect. Public review submission is disabled.

## App Store screenshots

The GitHub Actions build captures five unframed screenshots per platform: vision switching, live cues, audio, full-screen controls and the server picker. Its artifact contains iPhone 1206 × 2622 and iPad 2064 × 2752 JPEGs in separate folders. The capture uses the actual SwiftUI interface with representative Companion artwork and server names available only in the debug screenshot build. Codemagic release builds exclude that data.
