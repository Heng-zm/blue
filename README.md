# MGS

[![CI](https://github.com/Heng-zm/blue/actions/workflows/ci.yml/badge.svg)](https://github.com/Heng-zm/blue/actions/workflows/ci.yml)

**Offline mesh messenger for Android, iOS, and Windows.**  
No internet. No servers. No accounts. Messages travel over Bluetooth Low Energy, device to device.

MGS turns every nearby phone or laptop into a node in a mesh. Each device advertises a small GATT service and scans for the same service. When two devices meet, they open a link, exchange identities, and can chat directly or relay messages for other people. Messages keep hopping until they reach their destination or their hop budget runs out.

Version 2 adds **file transfer, voice notes, passphrase encryption, and a compact binary wire protocol**.

---

## Features

- **Public Nearby channel** — broadcast to every MGS device within mesh range.
- **Direct conversations** — tap a device on the radar to open a 1:1 thread.
- **Files up to 5 MB** — pick any file and send it over the mesh in encrypted chunks.
- **Voice notes up to 60 seconds** — record, send, and play back without a network.
- **Mesh encryption** — set one shared passphrase to encrypt message bodies, file metadata, and file/voice bytes with AES-256-GCM. Relays forward ciphertext without being able to read it.
- **Binary protocol v2** — fixed-size binary frames and envelopes replace JSON on air for lower overhead and faster parsing.
- **Multi-hop relay** — messages flood through intermediate devices with a configurable TTL (1–8, default 5).
- **Duplicate suppression** — bounded seen caches stop messages and blobs looping forever.
- **Delivery states** — queued, sent, delivered (direct links), failed; ACKs only for direct delivery.
- **Local persistence** — chats and attachments survive restarts; the newest 2,000 messages are kept.
- **Restart-safe outbox** — undelivered messages resume retrying when the app reopens; unfinished attachments retry separately.
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
- `RECORD_AUDIO` for voice notes. The microphone is only opened while you are recording.
- `minSdk` is 24.
- No `INTERNET` permission is declared. Flutter's **debug** manifest adds it for the Dart VM service; release builds do not have it.

### iOS

`Info.plist` includes:

- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription`
- `NSMicrophoneUsageDescription`
- `UIBackgroundModes`: `bluetooth-central`, `bluetooth-peripheral`

App Store review may ask you to justify the background modes. Remove them if you only need foreground meshing.

### Windows

Windows may ask for Bluetooth access on first launch. If scanning fails, check **Settings → Privacy & security → Bluetooth**. Windows may also ask for microphone access the first time you record a voice note.

## How it works

1. Every node advertises the 128-bit MGS GATT service and scans for it at the same time.
2. Discovered devices are dialed as GATT centrals. Incoming centrals are accepted too, so the app is both central and peripheral.
3. Both sides exchange a binary `HELLO` carrying a random 16-hex peer ID and display name.
4. If two links form between the same pair, both sides deterministically keep the link opened by the lexicographically smaller peer ID.
5. Every logical payload is split into binary frames (10-byte header, up to 240 data bytes each) and written to the peer's TX characteristic; the peripheral notifies frames on RX.
6. When a passphrase is set, the sender encrypts the body before framing: text bodies and attachment descriptors are AES-256-GCM encrypted, and files are encrypted as a whole before being split into 4 KiB blob chunks.
7. On receipt the router validates, dedupes, displays if addressed, decrements TTL, and floods the envelope or chunk to every other ready link. Relaying only inspects the header, so no passphrase is needed to forward.
8. Direct messages get an ACK on the direct ingress link. Broadcasts are never ACKed.
9. Files and voice notes arrive as a metadata message followed by blob chunks; the receiver verifies the SHA-256 digest and stores the file locally.

The full wire format, frame layout, encryption construction, routing rules, and limits are in [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Settings

- **Mesh passphrase** — set, change, or turn off encryption. Use the same passphrase on every device that should read the mesh.
- **Radio** — stop/start advertising and scanning without quitting.
- **Relay messages** — opt out of forwarding other people's traffic.
- **Relay hops** — TTL from 1 (direct neighbours only) to 8 (wide crowds).
- **Clear history** — deletes local messages and stored attachments only.
- **Radio log** — BLE events for debugging; copyable.

## Encryption notes

- One shared passphrase encrypts every message body, file, and voice note, including Nearby broadcasts.
- Key derivation is PBKDF2-HMAC-SHA256 (120,000 iterations) to a 256-bit key; payloads use AES-256-GCM with a 12-byte nonce and 16-byte tag.
- The visible header (peer IDs, display name, timestamp, kind, TTL/hops) is **not** encrypted. Relays need it to forward traffic.
- There is no forward secrecy, no peer identity authentication, and no protection against offline passphrase guessing. Use a long, random passphrase and treat the passphrase as the security boundary.
- The passphrase is stored in plaintext in the app's private state file (`mgs_state.json`). It is not encrypted at rest.
- If you forget the passphrase, previously received encrypted messages cannot be recovered.

## Project layout

```
lib/
  core/       constants, random IDs, protocol limits
  models/     message, attachment, and peer models
  protocol/   binary primitives, frames, message/blob codecs, mesh router
  security/   PBKDF2 + AES-256-GCM mesh cipher
  services/   BLE transport, JSON storage, blob store, voice recorder
  state/      AppController: persistence, outbox, transfers, unread, UI state
  ui/         theme, onboarding, chats, radar, chat, settings, widgets
test/         frame, protocol, blob, cipher, router, message, widget, smoke tests
docs/         protocol specification, release notes
android/      Android host project
ios/          iOS host project
windows/      Windows host project
```

## Testing

```bash
flutter analyze   # zero issues
flutter test      # 68 tests
```

The protocol layer is pure Dart and covered by unit tests: frame encoding, chunking, reassembly (including more than 255 chunks), duplicate chunks, stale assemblies, TTL/ACK decisions, binary envelope and HELLO validation, blob metadata and chunk validation, AES-GCM round-trips and tamper rejection, dedupe, and storage migration.

## Releasing

Releases are built and published by GitHub Actions:

1. Bump `version` in `pubspec.yaml` (for example `0.2.1+4`).
2. Add `docs/release-notes/v0.2.1.md` with the release notes. This file is optional; without it, GitHub generates the notes.
3. Push to `main`.

The `CI` workflow builds Android, Windows, and unsigned iOS artifacts. When every job succeeds, the `release` job checks for the `v<version>` tag. If no release exists yet, it stages the four platform assets, writes `SHA256SUMS.txt`, and publishes the GitHub release automatically. Pushes that do not change the version are skipped, so the same version is never published twice.

Existing releases can also be published manually by running the workflow from the Actions tab.

## Known limitations (v2)

- **No identity authentication or forward secrecy.** Anyone with the passphrase can read and produce traffic. A malicious relay can spoof the visible sender fields.
- **The passphrase is stored in plaintext at rest.** OS app sandboxing is the only protection for the local state file.
- **Offline passphrase guessing is possible.** The KDF salt is a fixed protocol constant.
- **ACKs are direct-link only.** A message delivered through a relay may remain `sent` and eventually show `failed` even though it arrived.
- **Attachment retries restart from chunk 0.** There is no partial-range resume; the whole blob is resent.
- **Interrupted incoming attachments do not resume across restarts.** If the receiver restarts mid-transfer, ask the sender to resend.
- **Background BLE is best-effort.** iOS and Android may suspend scanning while the app is backgrounded. Keep MGS open for reliable meshing.
- **No store-and-forward.** If nobody is in range, a message waits in the outbox and is retried for up to 5 minutes.
- **No multi-hop ACK or routing table.** Flooding is simple and robust, not bandwidth-optimal.
- **Windows advertisements cannot carry a local name**; identity is always learned via `HELLO`.
- **Windows peripheral support depends on the adapter.** MGS advertises through its GATT service registration, which needs an adapter with peripheral-role support. Without it, scanning and direct connections may still work.
- **No signing or packaging setup yet.** The default Flutter launcher icons are still in place, and release signing must be configured per platform.

## Privacy

- Message history and attachment metadata are stored locally in `mgs_state.json` under the platform's application-support directory. Attachment bytes are stored in a sibling `blobs/` directory.
- The mesh passphrase is stored in plaintext in that state file. Protect the device account and app data.
- No analytics, telemetry, crash reporting, or network calls.
- Peer IDs are random and not tied to a device identifier.
- Android backups are disabled for the app so the message store is not copied off-device by default.

## License

No license has been chosen yet. Add one before distributing or publishing the app.
