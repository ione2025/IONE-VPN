# IONE VPN Mobile Build and Distribution Guide

This guide covers Android APK and iOS IPA workflows for this Flutter project using `wireguard_flutter_plus`.

## 1) Android Configuration

### Files already configured in this project
- [android/app/build.gradle.kts](android/app/build.gradle.kts)
- [android/app/src/main/AndroidManifest.xml](android/app/src/main/AndroidManifest.xml)
- [android/app/src/main/res/xml/network_security_config.xml](android/app/src/main/res/xml/network_security_config.xml)
- [android/key.properties.example](android/key.properties.example)

### Required permissions in AndroidManifest
The manifest includes:
- `INTERNET`
- `ACCESS_NETWORK_STATE`
- `FOREGROUND_SERVICE`
- `FOREGROUND_SERVICE_CONNECTED_DEVICE`
- `CHANGE_NETWORK_STATE`

### Why cleartext is configured
Your API URL is currently HTTP (`http://178.128.107.176:3000/api/v1`). Android 9+ blocks cleartext by default, so `network_security_config.xml` allows your backend IP.

## 2) Android Signing and Build

### Generate upload keystore (run once)
```powershell
keytool -genkey -v -keystore upload-keystore.jks -alias ione_vpn -keyalg RSA -keysize 2048 -validity 10000
```

### Create key.properties
```powershell
Copy-Item android/key.properties.example android/key.properties
```
Then edit values in `android/key.properties`.

### Build release APK (single universal)
```powershell
flutter build apk --release
```
Output:
- `build/app/outputs/flutter-apk/app-release.apk`

### Build split APKs (smaller per ABI)
```powershell
flutter build apk --release --split-per-abi
```
Output examples:
- `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`
- `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`
- `build/app/outputs/flutter-apk/app-x86_64-release.apk`

## 3) iOS Configuration (on macOS)

### Required files in this project
- [ios/Podfile](ios/Podfile)
- [ios/Runner/Info.plist](ios/Runner/Info.plist)
- [ios/ExportOptions-TestFlight.plist](ios/ExportOptions-TestFlight.plist)
- [ios/ExportOptions-AdHoc.plist](ios/ExportOptions-AdHoc.plist)

### Important: Network Extension target is required
For `wireguard_flutter_plus`, create a Packet Tunnel target in Xcode.

### GUI steps with expected screens
1. Open `ios/Runner.xcworkspace` in Xcode.
Expected screen: project navigator showing `Runner` target.

2. Go to File > New > Target > Network Extension.
Expected screen: template wizard with provider type options.

3. Choose Packet Tunnel Provider, set target name `WGExtension`.
Expected screen: new `WGExtension` target appears under Targets.

4. Runner target > Signing & Capabilities:
- Add `Network Extensions` (Packet Tunnel)
- Add `App Groups` with group ID (example `group.com.ione.vpn`)
Expected screen: capability chips visible under target settings.

5. WGExtension target > Signing & Capabilities:
- Add `Network Extensions` (Packet Tunnel)
- Add same `App Groups` value as Runner
Expected screen: both targets share the same App Group.

6. Update bundle IDs:
- Runner: `com.ione.vpn`
- WGExtension: `com.ione.vpn.WGExtension`
Expected screen: bundle identifier fields reflect these values.

## 4) Build IPA on macOS

### Prerequisites
- Apple Developer Team configured in Xcode
- Valid signing certificates/profiles
- CocoaPods installed (`sudo gem install cocoapods`)

### Commands
```bash
cd flutter_app
flutter clean
flutter pub get
cd ios
pod install
cd ..
flutter build ipa --release --export-options-plist=ios/ExportOptions-TestFlight.plist
```

### For App Store / TestFlight
Use `method=app-store` in export options plist.

### For ad-hoc distribution
Use [ios/ExportOptions-AdHoc.plist](ios/ExportOptions-AdHoc.plist).

## 5) Cross-platform VPN behavior in this app

Dart side now handles:
- VPN engine initialize on startup
- Connect/disconnect using native tunnel
- Permission checks before start
- Real-time stage and traffic updates

Primary files:
- [lib/services/wireguard_vpn_service.dart](lib/services/wireguard_vpn_service.dart)
- [lib/providers/vpn_provider.dart](lib/providers/vpn_provider.dart)
- [lib/constants/app_constants.dart](lib/constants/app_constants.dart)

## 6) Testing procedures

### Android real device
1. Enable Developer Options + USB Debugging.
2. Install APK:
```powershell
adb install -r build/app/outputs/flutter-apk/app-release.apk
```
3. Open app and tap Connect.
4. Approve Android VPN prompt.
5. Verify status changes to Connected.

### iOS TestFlight
1. Build IPA with app-store export.
2. Upload through Xcode Organizer or Transporter.
3. Add internal testers in App Store Connect.
4. Install via TestFlight and verify VPN permission prompt.

## 7) Troubleshooting

### Android VPN issues
- Problem: VPN prompt does not appear.
Fix: Ensure app reaches `checkVpnPermission()` and call connect again.

- Problem: Connects but no traffic.
Fix: Validate AllowedIPs, DNS, endpoint port 443, and server firewall.

- Problem: API calls fail on mobile only.
Fix: Ensure cleartext HTTP is allowed or migrate API to HTTPS.

### iOS VPN issues
- Problem: Permission denied / no tunnel start.
Fix: Verify Packet Tunnel target exists and `providerBundleIdentifier` matches extension bundle ID.

- Problem: Build/signing failure.
Fix: Verify Team, bundle IDs, profiles, and App Group capability in both targets.

- Problem: Connection starts then drops.
Fix: Verify `PersistentKeepalive = 25` and backend UDP accessibility.

## 8) API URL security note

Your app currently uses HTTP:
- `http://178.128.107.176:3000/api/v1`

For production iOS/App Store reliability, migrate to HTTPS and then remove ATS/cleartext exceptions.
