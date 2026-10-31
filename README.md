# MGS

[![CI](https://github.com/Heng-zm/blue/actions/workflows/ci.yml/badge.svg)](https://github.com/Heng-zm/blue/actions/workflows/ci.yml)

**Offline mesh messenger for Android, iOS, and Windows.**  
No internet. No servers. No accounts. Messages travel over Bluetooth Low Energy, device to device.

MGS turns every nearby phone or laptop into a node in a mesh. Each device advertises a small GATT service and scans for the same service. When two devices meet, they open a link, exchange identities, and can chat directly or relay messages for other people. Messages keep hopping until they reach their destination or their hop budget runs out.

---

## Features

- **Public Nearby channel** — broadcast to every MGS device within mesh range.
- **Direct conversations** — tap a device on the radar to open a 1:1 thread.
- **Multi-hop relay** — messages flood through intermediate devices with a configurable TTL (1–8, default 5).
- **Duplicate suppression** — a bounded seen cache stops messages looping forever.
- **Delivery states** — queued, sent, delivered (direct links), failed; ACKs only for direct delivery.
- **Local persistence** — chats survive restarts; the newest 2,000 messages are kept.
- **Restart-safe outbox** — undelivered messages resume retrying when the app reopens.
- **Live radar** — signal-strength display of nearby devices.
- **Radio diagnostics** — a copyable log of BLE events inside Settings.
- **No network access** — the app declares no `INTERNET` permission.

## Requirements

| Item | Requirement |
| --- | --- |
| Flutter | 3.47 or newer (built with 3.47.9 / Dart 3.13.7) |
| Android | 7.0 (API 24)+ with BLE |
| iOS | 15+ with BLE |
| Windows | Windows 10+ with a BLE adapter |
| Hardware | **Physical devices.** BLE does not work in emulators or simulators. |
| Devices | At least two to see a mesh (three or more to test relaying). |

## Quick start

```bash
flutter pub get
flutter analyze
flutter test
flutter devices
flutter run -d windows        # or an Android/iOS device id
```

On Windows, plugin builds require **Developer Mode** (or symlink support) once:

```powershell
start ms-settings:developers
```

The built application itself does not need Developer Mode.

## Permissions

### Android

- API 31+: `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`.
- API 24–30: legacy `BLUETOOTH`, `BLUETOOTH_ADMIN`, and `ACCESS_COARSE_LOCATION` + `ACCESS_FINE_LOCATION` (BLE scanning requirement).
- `minSdk` is 24.
- No `INTERNET` permission is declared. Flutter's **debug** manifest adds it for the Dart VM service; release builds do not have it.

### iOS

`Info.plist` includes:

- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription`
- `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral`

App Store review may ask you to justify the background modes. Remove them if you only need foreground meshing.

### Windows

Windows may ask for Bluetooth access on first launch. If scanning fails, check **Settings → Privacy & security → Bluetooth**.

## How it works

1. Every node advertises the 128-bit MGS GATT service and scans for it at the same time.
2. Discovered devices are dialed as GATT centrals. Incoming centrals are accepted too, so the app is both central and peripheral.
3. Both sides exchange a `HELLO` frame carrying a random 16-hex peer ID and display name.
4. If two links form between the same pair, both sides deterministically keep the link opened by the lexicographically smaller peer ID.
5. Messages are JSON envelopes split into binary frames and written to the peer's TX characteristic; the peripheral notifies frames on RX.
6. On receipt the router validates, dedupes, displays if addressed, decrements TTL, and floods the envelope to every other ready link.
7. Direct messages get an ACK on the direct ingress link. Broadcasts are never ACKed.

The full wire format, frame layout, routing rules, and limits are in [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Settings

- **Radio** — stop/start advertising and scanning without quitting.
- **Relay messages** — opt out of forwarding other people's traffic.
- **Relay hops** — TTL from 1 (direct neighbours only) to 8 (wide crowds).
- **Clear history** — deletes local messages only.
- **Radio log** — BLE events for debugging; copyable.

## Project layout

```
lib/
  core/       constants, random IDs, protocol limits
  models/     message and peer models
  protocol/   frame chunking/assembly, JSON wire helpers, mesh router
  services/   BLE transport (central + peripheral), JSON storage
  state/      AppController: persistence, outbox, unread, UI state
  ui/         theme, onboarding, chats, radar, chat, settings, widgets
test/         frame, router, message, and app smoke tests
docs/         protocol specification, release notes
android/      Android host project
ios/          iOS host project
windows/      Windows host project
```

## Testing

```bash
flutter analyze   # zero issues
flutter test      # 23 tests
```

The protocol layer is pure Dart and covered by unit tests: frame encoding, chunking, reassembly, duplicate chunks, stale assemblies, TTL, ACK decisions, dedupe, envelope validation, and storage round-trips.

## Releasing

Releases are built and published by GitHub Actions:

1. Bump `version` in `pubspec.yaml` (for example `0.1.2+3`).
2. Add `docs/release-notes/v0.1.2.md` with the release notes. This file is optional; without it, GitHub generates the notes.
3. Push to `main`.

The `CI` workflow builds Android, Windows, and unsigned iOS artifacts. When every job succeeds, the `release` job checks for the `v<version>` tag. If no release exists yet, it stages the four platform assets, writes `SHA256SUMS.txt`, and publishes the GitHub release automatically. Pushes that do not change the version are skipped, so the same version is never published twice.

Existing releases can also be published manually by running the workflow from the Actions tab.

## Known limitations (v1)

- **No end-to-end encryption.** Relays can read messages. Treat Nearby as public. Do not use MGS for secrets yet.
- **ACKs are direct-link only.** A message delivered through a relay may remain `sent` and eventually show `failed` even though it arrived.
- **Background BLE is best-effort.** iOS and Android may suspend scanning while the app is backgrounded. Keep MGS open for reliable meshing.
- **No store-and-forward.** If nobody is in range, a message waits in the outbox and is retried for up to 5 minutes.
- **No attachments.** Text only, 2,000 characters.
- **No multi-hop ACK or routing table.** Flooding is simple and robust, not bandwidth-optimal.
- **Windows advertisements cannot carry a local name**; identity is always learned via `HELLO`.
- **Windows peripheral support depends on the adapter.** MGS advertises through its GATT service registration, which needs an adapter with peripheral-role support. Without it, scanning and direct connections may still work.
- **No signing or packaging setup yet.** The default Flutter launcher icons are still in place, and release signing must be configured per platform.

## Privacy

- Message history is stored locally in `mgs_state.json` under the platform's application-support directory.
- No analytics, telemetry, crash reporting, or network calls.
- Peer IDs are random and not tied to a device identifier.
- Android backups are disabled for the app so the message store is not copied off-device by default.

## License

No license has been chosen yet. Add one before distributing or publishing the app.
