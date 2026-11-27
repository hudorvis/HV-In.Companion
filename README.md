# In.Companion v26.11.27.01

Native iPhone and iPad control surface for Bitfocus Companion 4.3 or later.

## Connect over Wi-Fi

1. Put the iPhone or iPad on the same local network as the Companion computer. The computer can use wired Ethernet on that LAN.
2. In Companion, open **Settings → Protocols** and enable **Button Subscriptions API**.
3. In Companion **5.1.3 or later**, open **Settings → General**, give the installation a recognisable name, and enable **Announce Companion on the network (mDNS/Bonjour)**. For 4.3 or a version that does not advertise the short Satellite WebSocket service type, see the host announcement below.
4. Open In.Companion and allow **Local Network** access. Go to **Settings → Connection Setup → Continue** and tap the installation under **Nearby Companion**.
5. Wait for the connection, registration and artwork checks. If you change the layout, choose **Test Again**, then **Open Surface**.
6. In Companion, open **Surfaces → Configured Surfaces** and select **In.Companion**. Configure the startup page and assignments in Companion. Repeat steps 1–6 once for each installation.

On return to a network, In.Companion reconnects automatically if one saved Bonjour server is available. If several saved servers are present, open **Settings → Saved Servers** to choose. The iPhone identifies servers by the ID in their Bonjour advertisements and uses the currently advertised address and port. Each server retains its own surface setup via the iPhone's persistent Satellite ID. A saved manual address can be selected from the same list.

### Announce an older Companion host

On the Mac running Companion, open Terminal and run:

```sh
dns-sd -R "Studio Companion" _comp-sat-ws._tcp local 16623 id=studio-companion
```

On a Linux host with Avahi, the equivalent is:

```sh
avahi-publish-service "Studio Companion" _comp-sat-ws._tcp 16623 id=studio-companion
```

Use an ID unique to each Companion computer, keep it the same between visits, and use the actual **Satellite WebSocket Listen Port**. Leave the command running while you need discovery. If an older host has no Bonjour announcement, **Manual Address** in the connection wizard accepts a hostname or IPv4 address. Manual profiles are opened by tapping them in **Saved Servers**.

Setup verifies the WebSocket, Satellite API 1.10 or later within major version 1, surface registration, and actual bitmap delivery from both the surface and a read-only button subscription. The subscription uses an absolute page location. The registered surface follows Companion’s own page, lock and button handling. See the [Bitfocus Satellite API](https://companion.free/for-developers/Satellite-API/).

Settings includes connection diagnostics and a copyable protocol log. The operating grid uses Companion’s original bitmaps. During a disconnect, the app clears the artwork and disables input. Planned disconnects release held buttons before closing. An abrupt network failure can prevent a release from reaching Companion, and the app never replays button input after reconnecting.

## Build and test

On macOS with Xcode and XcodeGen installed:

```sh
swiftc Sources/SatelliteProtocol.swift Tests/SatelliteProtocolTests.swift -o /tmp/incompanion-protocol-tests
/tmp/incompanion-protocol-tests
swift scripts/icon.swift
xcodegen generate
open In.Companion.xcodeproj
```

GitHub Actions checks the protocol, saved-server matching and iOS Simulator compilation. Physical iPhone and iPad testing against a live Companion instance is required to verify Local Network permission, touch handling and end-to-end operation.

Codemagic uses the `ios-release` workflow, App Store Connect integration `In.Sync`, Apple ID `6839444405` and bundle ID `au.h-v.in.companion`. Main branch pushes trigger builds. The workflow sets the build number, signs the IPA and uploads it to App Store Connect. Public review submission is disabled.
