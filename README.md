# In.Companion v26.11.26.05

Native iPhone and iPad control surface for Bitfocus Companion 4.3 or later.

## Connect

1. On the Companion computer, open **Settings → Protocols**, enable **Button Subscriptions API**, and note the **Satellite WebSocket Listen Port** (default **16623**).
2. Open **Settings → Connection Setup** in In.Companion. Enter your Companion computer’s hostname or IPv4 address and the WebSocket port. Allow iOS Local Network access when prompted.
3. Test the connection. In.Companion registers its own surface with a stable identifier. Look for **In.Companion** in Companion’s **Surfaces** tab.
4. Select the grid size, retest if you change it, and choose **Open Surface**. Configure the starting page, actions, artwork and navigation in Companion.

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

GitHub Actions runs the protocol checks and an unsigned iOS Simulator compile. Physical iPhone and iPad testing against a live Companion instance is required to verify Local Network permission, touch handling and end-to-end operation.

Codemagic uses the `ios-release` workflow, App Store Connect integration `In.Sync`, Apple ID `6839444405` and bundle ID `au.h-v.in.companion`. Main branch pushes trigger builds. The workflow sets the build number, signs the IPA and uploads it to App Store Connect. Public review submission is disabled.
