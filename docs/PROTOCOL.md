# MGS wire protocol — version 2

Status: implemented by MGS app `0.2.0`. This document describes the on-air
contract; all multi-byte integers are big-endian unless stated otherwise.

MGS is an offline, Bluetooth Low Energy mesh messenger. Every node runs both
BLE roles at once: it advertises a GATT service (peripheral) and scans for the
same service (central). There is no server, no internet path, and no account
system.

Version 2 replaces the version 1 JSON envelopes with compact binary payloads
and adds passphrase encryption plus file and voice-note transfer. **Version 1
and version 2 nodes do not interoperate**: a version 1 `HELLO` is rejected and
the link closes.

## 1. Goals and non-goals

Goals:

- Work entirely offline over BLE.
- Let every node relay traffic without knowing the mesh passphrase.
- Encrypt message bodies, files, and voice notes with one shared passphrase.
- Keep the wire format compact enough for low-bandwidth BLE links.
- Bound memory, bandwidth, and loops.

Non-goals for v2:

- Identity authentication or forward secrecy.
- Store-and-forward across time.
- Multi-hop delivery acknowledgements.
- Optimal routing. MGS floods; it does not build routes.
- Resumable partial file transfers. A failed blob is retried from chunk 0.

## 2. Identifiers

| Name | Size | Description |
| --- | --- | --- |
| Peer ID | 8 random bytes, 16 lowercase hex chars | Stable local identity. Generated on first run, persisted. |
| Message ID | 8 random bytes, 16 lowercase hex chars | Dedupe key and ACK key. |
| Blob ID | 8 random bytes, 16 lowercase hex chars | Identifies a stored attachment. |
| Transfer ID | 4 random bytes, 8 lowercase hex chars | Distinguishes retries of the same blob. |
| Packet ID | `uint32` | Groups all frames of one logical payload; reassembly only. |
| Thread ID | string | `*` for the public channel, otherwise the other peer's ID. |

Peer, message, and blob IDs are validated with `^[0-9a-f]{16}$`. Transfer IDs
match `^[0-9a-f]{8}$`. IDs are random rather than derived from hardware
addresses. They are not cryptographically authenticated; with a passphrase set,
the ciphertext is authentic but the visible header fields can still be spoofed
by a malicious relay.

## 3. Advertising and discovery

- Service UUID: `6d67732d-6d65-7368-2d76-310000000001`.
  The leading bytes spell `mgs-mesh-v1` in ASCII. The UUID is unchanged in
  protocol v2 so the same radio filter keeps working; it is not a version
  marker.
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

The central writes each frame to the peripheral's TX characteristic. The
peripheral sends frames to the central by notifying the RX characteristic.
Notifications are enabled before either side sends its `HELLO`.

Both roles can transmit and receive; "RX" and "TX" are named from the GATT
server's point of view.

### Chunk sizing

- Android centrals request an ATT MTU of 517.
- The usable value length is obtained from the platform
  (`getMaximumWriteLength` / `getMaximumNotifyLength`).
- Chunk payload size = usable length − 10-byte frame header, clamped to
  1–240 bytes.
- If the platform cannot report a length, the conservative default is a
  20-byte write, giving 10-byte chunks.

## 5. Frame format

Each GATT write or notification carries exactly one frame:

```
offset  size  field
0       1     protocol version (2)
1       1     frame type
2       4     packet id (uint32)
6       2     chunk index (uint16, 0-based)
8       2     chunk count (uint16, 1..65535)
10..    n     chunk payload, at most 240 bytes
```

Version 2 widened the chunk index and count from one byte to two. A 4 KiB blob
chunk sent over a 20-byte BLE link needs 413 frames, which does not fit the
version 1 limit of 255.

Frame types:

| Code | Name | Payload |
| --- | --- | --- |
| 1 | `HELLO` | Binary peer identity |
| 2 | `MESSAGE` | Binary message envelope |
| 3 | `ACK` | 8 raw bytes: the acknowledged message ID |
| 4 | `PING` | Empty |
| 5 | `BLOB` | Binary blob-chunk envelope |

Frames with an unknown version or type, a zero chunk count, an out-of-range
chunk index, or a chunk over 240 bytes are dropped.

### Reassembly

- Chunks are identified by `(packet id, type)`, which must agree across the
  set. All chunks must have the same `chunk count`.
- Chunks may arrive in any order. Duplicate indices are ignored.
- A set is complete when every index `0..chunkCount-1` is present; the payload
  is concatenated in index order.
- At most 32 assemblies are tracked per link. The oldest is evicted when the
  limit is reached.
- Incomplete assemblies expire after 25 seconds.
- A single assembled payload is capped at 24 KiB. A payload over the cap
  discards the assembly.
- `buildFrames` also rejects logical payloads larger than 24 KiB.

## 6. HELLO

Sent immediately after a link is subscribed/connected, in both directions:

```
offset  size  field
0       1     protocol version (2)
1       1     display-name length in bytes
2..9    peer id (8 bytes)
10..    display name, UTF-8
```

Rules:

- Byte 0 must equal 2. A version 1 JSON `HELLO` is rejected, and the link is
  closed.
- The peer ID must be valid and must not equal the receiver's own ID.
- The name is trimmed to at most 32 characters. Empty names become
  `MGS user`.
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

Sent as a `MESSAGE` frame. The fixed header is 40 bytes, followed by the
display name and the body:

```
offset  size  field
0       1     protocol version (2)
1       1     kind (0 text, 1 file, 2 voice)
2       1     flags (bit 0: body is AES-256-GCM encrypted)
3       1     display-name length in bytes
4..11   message id (8)
12..19  sender peer id (8)
20..27  recipient peer id (8, all zero for broadcast)
28..35  sender timestamp, milliseconds since Unix epoch (uint64)
36      ttl
37      hops
38..39  body length in bytes (uint16)
40..    display name (UTF-8), then body
```

The body is:

- For `kind = text`: UTF-8 text, trimmed, non-empty, at most 2,000 UTF-16 code
  units.
- For `kind = file` or `kind = voice`: a binary attachment descriptor
  (section 9), which is encrypted together with the rest of the body whenever
  the message is encrypted.

Broadcast addresses are encoded as eight zero bytes and decoded back to `*`.
The `ttl` field is 1–8 and `hops` is 0–8. The body length must match the
remaining bytes exactly; trailing data is rejected.

Unknown versions or kinds, unsupported flag bits, malformed IDs, invalid
addresses, out-of-range TTL/hops, a bad timestamp, and a body length mismatch
are rejected. A malformed envelope is never relayed.

### Header fields stay visible

When encryption is enabled, the following fields remain in the clear so relays
can forward a message without the passphrase:

- message ID, sender ID, recipient ID, sender display name
- timestamp, kind, encrypted flag, TTL, hop count
- body length

Only the body (text or attachment descriptor) is encrypted. The `encrypted`
flag tells the receiver whether to decrypt; it is covered by the authentication
tag, as are the IDs, name, timestamp, kind, and body length.

## 8. Encryption

Encryption is optional. When the user has not set a mesh passphrase, bodies and
blobs travel in plaintext and the `encrypted` flag is 0.

When a passphrase is set:

- Key derivation: PBKDF2-HMAC-SHA256, 120,000 iterations, 256-bit output, with
  the fixed UTF-8 salt `MGS mesh encryption v2 / PBKDF2-HMAC-SHA256`.
- Cipher: AES-256-GCM with a 96-bit nonce and a 128-bit tag.
- Serialized ciphertext: `nonce (12) || ciphertext || tag (16)`. The overhead
  is 28 bytes.

Everyone in the mesh uses the same passphrase. The derived key is the same on
every device, so any device holding the passphrase can read and produce traffic.
There is no per-peer key exchange and no forward secrecy.

### Message AAD

The additional authenticated data for a message is the encoded header with the
TTL and hop bytes (offsets 36–37) removed:

```
header[0..35] || header[38..40+nameLength)
```

This lets a relay decrement `ttl` and increment `hops` in place without
invalidating the tag. The encrypted body length (offsets 38–39) is authenticated,
so a relay cannot truncate or extend the ciphertext.

The sender encrypts the body with a fresh random nonce for every message. The
receiver rebuilds the AAD from the received header and decrypts.

### Blob AAD

Each attachment is encrypted as a whole before it is split into chunks. Its AAD
is:

```
"MGSBLOB2" || blobId (8) || transferId (4)
```

and the AES nonce is generated once when the attachment is created, carried in
the descriptor, and reused on retry. That keeps an interrupted transfer
resumable from chunk 0 with identical ciphertext, so chunks from different
attempts are interchangeable.

### Failure handling

- If an encrypted message arrives without a local passphrase, or the tag does
  not verify, the receiver stores a locked placeholder. The chat shows
  `Encrypted message` / `Encrypted file` / `Encrypted voice note` instead of
  dropping it silently. Setting the passphrase afterwards does not
  retroactively decrypt the placeholder; the sender must resend.
- A locked placeholder is not relayed differently; relaying happens before
  decryption and only needs the header.
- Turning encryption off only affects new traffic. Messages already stored with
  the `encrypted` flag stay encrypted.

See section 12 for the security limitations of this scheme.

## 9. Files and voice notes

### Attachment descriptor

A file or voice message carries this binary descriptor as its body:

```
offset  size  field
0       1     kind (1 file, 2 voice)
1       1     file-name length in bytes
2..     name (UTF-8)
...     1     MIME-type length in bytes
...     MIME type (UTF-8)
...     8     blob id
...     4     transfer id
...     12    AES nonce
...     4     plaintext size (uint32)
...     4     ciphertext size (uint32)
...     2     chunk count (uint16)
...     4     voice duration in milliseconds (uint32, 0 for files)
...     32    SHA-256 of the plaintext
```

Limits:

| Item | Limit |
| --- | --- |
| File size | 5 MiB (5,242,880 bytes) |
| File name | 120 UTF-8 bytes |
| MIME type | 80 UTF-8 bytes |
| Voice note | 60 seconds; minimum 500 ms |
| Ciphertext | 5,242,908 bytes (plaintext + 28-byte AES-GCM overhead) |
| Chunks | 1,281 |
| Blob chunk data | 4,096 bytes |

With encryption enabled, the descriptor is inside the encrypted message body,
so relays and devices without the passphrase cannot read file names or MIME
types. The descriptor is sent before the blob chunks.

Voice notes are recorded as AAC-LC (`.m4a`, 22.05 kHz mono, 32 kbps) on Android
and iOS, and as 16-bit PCM WAV (16 kHz mono) on Windows. The MIME type is
`audio/mp4` or `audio/wav` respectively. Playback uses the platform audio
stack.

### Blob chunk envelope

Sent as a `BLOB` frame, one logical chunk per `BLOB` payload (which is then
split into transport frames):

```
offset  size  field
0       1     protocol version (2)
1       1     flags (reserved, must be 0)
2..9    blob id (8)
10..13  transfer id (4)
14..21  recipient peer id (8, all zero for broadcast)
22..23  chunk index (uint16, 0-based)
24..25  chunk count (uint16)
26..29  total ciphertext length (uint32)
30      ttl
31      hops
32..    chunk data, at most 4,096 bytes
```

A blob chunk is relayed by copying bytes 30–31 with the decremented TTL and
incremented hop count, exactly like a message envelope. The chunk data is
already encrypted (or plaintext when no passphrase is set); relays never need
the key.

### Transfer flow

1. The sender stores a local copy of the file, picks a blob ID / transfer ID /
   nonce, encrypts the whole blob once, computes the chunk count and SHA-256,
   and sends the descriptor message.
2. After the descriptor is handed to at least one link, the sender sends chunks
   in order. It prefers the direct link for a direct thread and broadcasts
   otherwise. Unacknowledged chunks are not retried individually; a failed
   transfer restarts from chunk 0.
3. A receiver registers the descriptor and buffers chunks in a bounded map of
   at most 8 incoming transfers. A transfer expires after 10 minutes.
4. Chunks must match the descriptor's `count` and `totalLength`. Duplicates are
   ignored. When every chunk has arrived, the receiver concatenates them,
   decrypts if needed, checks the plaintext size, verifies SHA-256, and stores
   the file locally.
5. Attachment chunks are never ACKed. Only the descriptor message gets the
   normal direct-delivery ACK.
6. Unfinished outgoing attachments are retried every 20 seconds while a link is
   ready, with a separate budget of 8 attempts or 5 minutes from the original
   send time. A completed incoming transfer is matched to an existing local
   blob by blob ID and file name, so a duplicate descriptor does not download
   the file again.

A transfer cannot resume mid-file: a retry resends every chunk. With the 5 MiB
cap this is intentional; the protocol keeps the state machine small and the
descriptor authenticated.

## 10. Routing

For every valid `MESSAGE` received on a ready link:

1. If `from` equals the local peer ID, drop it (the message came back around).
2. If `id` is in the seen cache, drop it (but still ACK a direct duplicate).
3. Add `id` to the seen cache.
4. If `to` equals the local peer ID or `*`, deliver it to the UI and persist it.
5. If `ttl > 1` **and** `to` is not the local peer ID, patch the envelope to
   `ttl - 1` and `hops + 1`, and flood it to every ready link except the ingress
   peer.
6. If `to` equals the local peer ID, the ingress peer equals `from`, and the
   message arrived on a direct link, send an `ACK` on that same link.
7. Broadcasts are never acknowledged.

Notes:

- Direct messages are not relayed further once they reach their destination.
- Intermediate nodes relay both broadcast and direct messages.
- A sender uses the direct link when one exists; otherwise the envelope is
  flooded with its TTL.
- Relaying only inspects the binary header. A node without the passphrase still
  forwards the ciphertext.
- Duplicates are dropped even if they arrive over a different path.

For every valid `BLOB` received:

1. Decode and validate the chunk envelope.
2. Dedupe on `(blob id, transfer id, chunk index)`.
3. Relay with `ttl - 1` / `hops + 1` when `ttl > 1` and the chunk is not
   addressed to the local peer.
4. If the chunk is addressed to the local peer (or broadcast), hand it to the
   matching incoming transfer. Chunks for unknown descriptors are ignored after
   relaying. Transfers are kept in memory; if the receiver restarts mid-transfer,
   subsequent chunks for that descriptor are ignored until the sender resends.

### Seen caches

| Cache | Capacity | Lifetime |
| --- | --- | --- |
| Messages | 4,096 IDs | 24 hours |
| Blob chunks | 32,768 keys | 30 minutes |

At startup, the message cache is seeded with the IDs of stored messages so a
restart does not replay old traffic. Own outbound messages are added before
transmission so an echo is ignored.

### Outbox and retries

- Direct messages stay in the outbox until an `ACK` arrives.
- At startup, the outbox is rebuilt from stored outgoing messages whose status
  is `queued` or `sent`.
- Pending messages are retried every 20 seconds, up to 8 attempts or 5 minutes.
- A broadcast leaves the outbox once it has been handed to at least one ready
  link. It is never retried after that.
- If no link is available, both kinds wait in the outbox.
- Outgoing attachments keep retrying separately after their descriptor leaves
  the outbox, as described in section 9.

## 11. ACK

- Frame type 3, payload: the 8 raw bytes of the acknowledged message ID.
- Sent only on the direct ingress link when the message's `to` field equals the
  local peer and the ingress peer is the author.
- A direct duplicate is acknowledged again. This lets a retry recover an ACK
  that was lost on the first delivery.
- Delivery through a relay produces no ACK. The sender may mark the message
  failed after its retry window even if it was delivered.
- Attachment chunks are not acknowledged individually.

## 12. Persistence

- Location: application-support directory, file `mgs_state.json`.
- Format: JSON object with `version` (currently 2), `peerId`, `displayName`,
  `passphrase`, `ttl`, `relayEnabled`, `radioEnabled`, and `messages`.
- Messages keep their wire fields plus local-only `dir` (`out`/`in`) and
  `status` (`queued`, `sent`, `delivered`, `failed`, `received`). Attachment
  paths and transfer progress are local-only.
- Version 1 state files are migrated on load. They have no passphrase, kind, or
  attachment fields, so those default to text / plaintext.
- Writes use a temporary file and rename, with a direct-write fallback.
- A corrupt file is renamed to `mgs_state.json.corrupt-<timestamp>` and the app
  starts with a fresh identity so it never crashes on load.
- At most 2,000 messages are retained (oldest dropped first).
- Attachment data is stored as separate files under the application-support
  `blobs/` directory. Deleting a message also deletes its stored blob when the
  message is trimmed.
- **The passphrase is stored in plaintext in `mgs_state.json`.** It is not
  encrypted at rest. Anyone who can read the app's private storage can read the
  passphrase. OS sandboxing is the only protection.

## 13. Security and privacy

Encryption protects message bodies, attachment descriptors, and attachment
bytes from relays and from devices that do not know the passphrase. It does
**not** provide:

- **Identity authentication.** `from`, `name`, recipient IDs, timestamps, and
  ACKs are not signed. A malicious node can spoof them or tamper with the
  visible header. The AES-GCM tag binds the body to the header fields it covers,
  but only proves that *someone with the passphrase* produced the message.
- **Forward secrecy.** All traffic uses one long-lived key derived from the
  shared passphrase. Compromising the passphrase decrypts past captures.
- **Protection against offline guessing.** The KDF salt is a fixed protocol
  constant, and the passphrase is the only secret. Anyone who captures traffic
  can try passphrases offline. Use a long, random passphrase.
- **Anonymity from relays.** Relays see peer IDs, display names, message sizes,
  timing, and the social graph, even though they cannot read bodies.
- **Replay protection across restarts.** Dedupe is an in-memory seen cache;
  there is no persistent nonce ledger or signature.

Operational privacy:

- Android declares no `INTERNET` permission. Release builds cannot open a
  socket. Flutter debug builds add `INTERNET` for the Dart VM service only.
- No analytics, crash reporting, or third-party SDKs are included.
- BLE advertisements contain only the service UUID and the name `MGS`; peer IDs
  are exchanged after connecting.
- The Nearby channel is encrypted with the same passphrase as direct messages,
  but it remains public to every device that knows the passphrase.

Future work could add per-peer session keys, signed identities, passphrase
rotation, and encrypted storage at rest. Those changes require a protocol
version bump.

## 14. Versioning and compatibility

- Frame byte 0 is the framing version (`2`).
- `HELLO` byte 0, the message envelope byte 0, and the blob envelope byte 0 are
  the protocol version (`2`).
- There is no negotiation: a `HELLO` with the wrong version closes the link; a
  message or blob with the wrong version is dropped.
- Version 2 is **not backward compatible with version 1**. The frame header is
  wider, envelopes are binary instead of JSON, and v1 has no encryption or
  attachment support. Upgrade every device in a mesh together.
- The GATT service UUID still contains the string `mgs-mesh-v1`; it was not
  renamed, to avoid a second discovery filter. Protocol compatibility is
  determined by the version bytes, not the UUID.
- Adding optional fields is not possible without changing the fixed layouts;
  changing any header size, field meaning, or limit requires a new protocol
  version.
