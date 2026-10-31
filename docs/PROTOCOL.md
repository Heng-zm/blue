# MGS wire protocol — version 1

Status: implemented by MGS app `0.1.0`. This document describes the on-air
contract; all multi-byte integers are big-endian unless stated otherwise.

MGS is an offline, Bluetooth Low Energy mesh messenger. Every node runs both
BLE roles at once: it advertises a GATT service (peripheral) and scans for the
same service (central). There is no server, no internet path, and no account
system.

## 1. Goals and non-goals

Goals:

- Work entirely offline over BLE.
- Let every node act as a relay without configuration.
- Keep the frame format simple enough to reimplement.
- Bound memory, bandwidth, and loops.

Non-goals for v1:

- End-to-end encryption or authenticated identities.
- Store-and-forward across time.
- Multi-hop delivery acknowledgements.
- Optimal routing. MGS floods; it does not build routes.
- File or media transfer.

## 2. Identifiers

| Name | Size | Description |
| --- | --- | --- |
| Peer ID | 8 random bytes, 16 lowercase hex chars | Stable local identity. Generated on first run, persisted. |
| Message ID | 8 random bytes, 16 lowercase hex chars | Dedupe key and ACK key. |
| Packet ID | `uint32` | Groups all chunks of one logical payload; reassembly only. |
| Thread ID | string | `*` for the public channel, otherwise the other peer's ID. |

Peer and message IDs are validated with `^[0-9a-f]{16}$`. They are random, not
derived from hardware addresses, and are not cryptographically authenticated in
v1.

## 3. Advertising and discovery

- Service UUID: `6d67732d-6d65-7368-2d76-310000000001`
  (leading bytes spell `mgs-mesh-v1` in ASCII).
- Advertised name: `MGS` on Android/iOS. Windows cannot include a name in a BLE
  advertisement, so the name is omitted there.
- Only the service UUID and short name are advertised. This fits the 31-byte
  legacy advertisement limit.
- Centrals scan filtered on the service UUID.
- Identity and display name are **not** in the advertisement; they are learned
  from `HELLO`.

## 4. GATT layout

| Attribute | UUID | Properties | Used for |
| --- | --- | --- | --- |
| MGS service | `…0001` | Primary | Discovery filter |
| RX characteristic | `…0002` | Read, Notify | Server → client frames |
| TX characteristic | `…0003` | Write, Write Without Response | Client → server frames |

Full UUIDs:

```
service  6d67732d-6d65-7368-2d76-310000000001
RX       6d67732d-6d65-7368-2d76-310000000002
TX       6d67732d-6d65-7368-2d76-310000000003
```

The central writes each frame to the peripheral's TX characteristic using
*write with response*. The peripheral sends frames to the central by notifying
the RX characteristic. Notifications are enabled before either side sends its
`HELLO`.

Both roles can transmit and receive; "RX" and "TX" are named from the GATT
server's point of view.

### Chunk sizing

- Android centrals request an ATT MTU of 517.
- The usable value length is obtained from the platform
  (`getMaximumWriteLength` / `getMaximumNotifyLength`).
- Chunk payload size = usable length − 8-byte frame header, clamped to
  8–240 bytes.
- If the platform cannot report a length, the conservative default is 20 bytes,
  giving 12-byte chunks.

## 5. Frame format

Each GATT write or notification carries exactly one frame:

```
offset  size  field
0       1     protocol version (1)
1       1     frame type
2       4     packet id (uint32)
6       1     chunk index (0-based)
7       1     chunk count (1..255)
8..     n     chunk payload, at most 240 bytes
```

Frame types:

| Code | Name | Payload |
| --- | --- | --- |
| 1 | `HELLO` | UTF-8 JSON object |
| 2 | `MESSAGE` | UTF-8 JSON envelope |
| 3 | `ACK` | 16 ASCII bytes: the message ID |
| 4 | `PING` | Empty |

Frames with an unknown version or type, a zero/oversized chunk count, an
out-of-range chunk index, or a chunk over 240 bytes are dropped.

### Reassembly

- Chunks are identified by `(packet id, type)`, which must agree across the
  set. All chunks must have the same `chunk count`.
- Chunks may arrive in any order. Duplicate indices are ignored.
- A set is complete when every index `0..chunkCount-1` is present; the payload
  is concatenated in index order.
- At most 16 assemblies are tracked per link. The oldest is evicted when the
  limit is reached.
- Incomplete assemblies expire after 25 seconds.
- A single assembled payload is capped at 24 KiB. A payload over the cap
  discards the assembly.
- `buildFrames` also rejects logical payloads larger than 24 KiB or requiring
  more than 255 frames.

## 6. HELLO

Sent immediately after a link is subscribed/connected, in both directions:

```json
{
  "v": 1,
  "id": "0123456789abcdef",
  "name": "Ada",
  "os": "android"
}
```

Rules:

- `v` must equal 1.
- `id` must be a valid peer ID and must not equal the receiver's own ID.
- `name` is trimmed to at most 32 characters. Empty names become
  `MGS <first 6 chars of id>`.
- A link is **not ready** for messages until a valid `HELLO` has been received.
- If the peer ID equals the local ID, the link is assumed to be a loopback
  (a device hearing its own advertisement) and is closed.

After `HELLO`, the link is announced to the app with the peer's ID and name.
Links that have not completed a handshake within 20 seconds are closed.

### Duplicate links

Two devices can connect to each other simultaneously (A→B and B→A). Both sides
must agree on which physical link survives. The rule is:

> Keep the link **opened by the peer with the lexicographically smaller peer
> ID**.

Consequences:

- On the smaller-ID device, its own outbound link is preferred.
- On the larger-ID device, the inbound link from the smaller-ID device is
  preferred.
- The other link is closed locally without a disconnect notification event.

This converges regardless of which link handshakes first.

### Heartbeat

- A `PING` frame is sent on every ready link every 12 seconds.
- Any received frame refreshes link activity.
- A ready link with no traffic for 60 seconds is closed. Scanning continues, so
  the peer is normally rediscovered and reconnected.

## 7. Message envelope

Sent as a `MESSAGE` frame, UTF-8 JSON:

```json
{
  "v": 1,
  "id": "aaaaaaaaaaaaaaaa",
  "from": "1111111111111111",
  "name": "Ada",
  "to": "*",
  "ts": 1700000000000,
  "ttl": 5,
  "hops": 0,
  "kind": "text",
  "text": "hello mesh"
}
```

| Field | Type | Rules |
| --- | --- | --- |
| `v` | int | Must be 1. |
| `id` | string | 16 lowercase hex chars. |
| `from` | string | Sender peer ID. |
| `name` | string | Sender display name, ≤ 32 chars. Empty becomes `MGS user`. |
| `to` | string | `*` for broadcast, or a peer ID. |
| `ts` | int | Sender wall clock, milliseconds since Unix epoch, > 0. Informational; not trusted. |
| `ttl` | int | Remaining hop budget, 1–8. |
| `hops` | int | Hops already travelled, 0–8. |
| `kind` | string | Only `text` in v1. |
| `text` | string | Trimmed, non-empty, ≤ 2,000 UTF-16 code units. |

Unknown `v` or `kind`, malformed IDs, out-of-range TTL/hops, and empty bodies
are rejected. A malformed envelope is never relayed.

The same envelope is used on disk. Storage adds two local-only fields:
`dir` (`out`/`in`) and `status` (`queued`, `sent`, `delivered`, `failed`,
`received`). These are never sent on air.

## 8. Routing

For every valid `MESSAGE` received on a ready link:

1. If `from` equals the local peer ID, drop it (the message came back around).
2. If `id` is in the seen cache, drop it.
3. Add `id` to the seen cache.
4. If `to` equals the local peer ID or `*`, deliver it to the UI and persist it.
5. If `ttl > 1` **and** `to` is not the local peer ID, build a relay envelope
   with `ttl - 1` and `hops + 1`, and flood it to every ready link except the
   ingress peer.
6. If `to` equals the local peer ID, the ingress peer equals `from`, and the
   message arrived on a direct link, send an `ACK` on that same link.
7. Broadcasts are never acknowledged.

Notes:

- Direct messages are not relayed further once they reach their destination.
- Intermediate nodes relay both broadcast and direct messages.
- A sender uses the direct link when one exists; otherwise the envelope is
  flooded with its TTL.
- Duplicates are dropped even if they arrive over a different path.

### Seen cache

- Capacity: 4,096 message IDs.
- Entry lifetime: 24 hours.
- At startup, the cache is seeded with the IDs of stored messages so a restart
  does not replay old traffic.
- Own outbound messages are added before transmission so an echo is ignored.

### Outbox

- Direct messages stay in the outbox until an `ACK` arrives.
- At startup, the outbox is rebuilt from stored outgoing messages whose status
  is `queued` or `sent`.
- Pending messages are retried every 20 seconds, up to 8 attempts or 5 minutes.
- A broadcast leaves the outbox once it has been handed to at least one ready
  link. It is never retried after that.
- If no link is available, both kinds wait in the outbox.

## 9. ACK

- Frame type `ACK`.
- Payload: the 16 ASCII bytes of the acknowledged message ID. No JSON.
- Sent only on the direct ingress link when the message's `to` field equals the
  local peer and the ingress peer is the author.
- A direct duplicate is acknowledged again. This lets a retry recover an ACK
  that was lost on the first delivery.
- Delivery through a relay produces no ACK in v1; the sender may mark the
  message failed after its retry window even if it was delivered.

## 10. Persistence

- Location: application-support directory, file `mgs_state.json`.
- Format: JSON object with `version`, `peerId`, `displayName`, `ttl`,
  `relayEnabled`, `radioEnabled`, and `messages`.
- Writes use a temporary file and rename, with a direct-write fallback.
- A corrupt file is renamed to `mgs_state.json.corrupt-<timestamp>` and the app
  starts with a fresh identity so it never crashes on load.
- At most 2,000 messages are retained (oldest dropped first).
- No encryption at rest.

## 11. Security and privacy

v1 deliberately ships without cryptographic protection:

- Any device relaying a message can read its full envelope and text.
- `from`, `name`, and ACKs are unauthenticated; a malicious node can spoof
  them.
- The Nearby channel is public by definition.
- The seed data (`peerId`, display name, history) is stored in plaintext.
- Replay protection is the in-memory seen cache only; there is no persistent
  signature or nonce ledger.

Operational privacy:

- Android declares no `INTERNET` permission. Release builds cannot open a
  socket. Flutter debug builds add `INTERNET` for the Dart VM service only.
- No analytics, crash reporting, or third-party SDKs are included.
- BLE advertisements contain only the service UUID and the name `MGS`; peer IDs
  are exchanged after connecting.

Future work should add per-peer session keys (e.g. X25519 + ChaCha20-Poly1305),
identity fingerprints, message expiry, and store rotation. Those changes
require a protocol version bump.

## 12. Versioning

- Frame byte 0 is the framing version (`1`).
- `HELLO.v` and message `v` are the envelope version (`1`).
- There is no negotiation in v1: a `HELLO` with the wrong version closes the
  link; a message with the wrong version is dropped.
- Adding optional envelope fields is backward-compatible. Changing meaning,
  identifiers, or required fields requires `v = 2`.
