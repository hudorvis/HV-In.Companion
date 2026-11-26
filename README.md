# In.Companion v26.11.26.04

Native iPhone/iPad Bitfocus Companion Satellite surface. No demo mode. Companion supplies key artwork. TCP port 16622 by default. Configure host and grid using the settings cog.

## Build

On macOS with Xcode and XcodeGen installed, run `swift scripts/icon.swift` and `xcodegen generate`, then open `In.Companion.xcodeproj`. GitHub Actions performs an unsigned simulator compile check.

## Codemagic

Use the `ios-release` workflow, existing App Store Connect integration named `In.Sync`, App Store signing for `au.h-v.in.companion`, and environment group `in_companion` containing numeric `APP_STORE_APPLE_ID`. Main branch pushes trigger signed builds and upload to App Store Connect. Public review submission is disabled.

## Testing

Compilation, physical-device tests and live Companion protocol interoperability must be verified before App Store submission. Use harmless test buttons initially. Repository is public; never commit signing credentials or private keys.

## Revision 04

Preserve artwork corners, validate incoming key coordinates, restrict key input while settings are open, and start keepalive only after TCP readiness. Minimum release build number 4. The Apple integration remains In.Sync; the app ID remains In.Companion.
