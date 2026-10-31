import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Human-facing app name.
const String appName = 'MGS';
const String appTagline = 'Offline mesh messenger';
const String appVersion = '0.2.0';

/// Wire protocol version. Bump when the frame or envelope layout changes.
///
/// Version 2 replaced the JSON envelope with a compact binary format and added
/// passphrase encryption plus file/voice blob transfer.
const int protocolVersion = 2;

/// Local state-file format. The loader still accepts version 1.
const int storageVersion = 2;

/// Flooding defaults.
const int defaultTtl = 5;
const int minTtl = 1;
const int maxTtl = 8;

/// Longest accepted message body, in UTF-16 code units.
const int maxMessageLength = 2000;

/// Longest accepted display name.
const int maxDisplayNameLength = 32;

/// Broadcast pseudo-recipient.
const String broadcastRecipient = '*';

/// Attachments.
/// The maximum file size is bounded by the 16-bit blob chunk index in the
/// wire protocol: 65,535 chunks * 4,096 bytes per chunk ≈ 256 MiB.
const int maxBlobChunks = 65535;
const int blobChunkPayloadBytes = 4096;
const int maxBlobCipherBytes = maxBlobChunks * blobChunkPayloadBytes;
const int maxFileBytes = maxBlobCipherBytes - 28;
const int maxVoiceSeconds = 300;
const int maxFileNameLength = 120;
const int maxMimeTypeLength = 80;
const int maxPassphraseLength = 128;
const int minPassphraseLength = 8;
const int maxIncomingBlobs = 32;
const int blobSendHighWaterBytes = 64 * 1024;

/// GATT identifiers. The leading bytes spell "mgs-mesh-v1" in ASCII; the last
/// byte keeps the service and its two characteristics distinct.
final UUID mgsServiceUuid = UUID.fromString(
  '6d67732d-6d65-7368-2d76-310000000001',
);
final UUID mgsRxUuid = UUID.fromString('6d67732d-6d65-7368-2d76-310000000002');
final UUID mgsTxUuid = UUID.fromString('6d67732d-6d65-7368-2d76-310000000003');

/// Upper bounds for the radio layer.
const int maxOutboundLinks = 4;
const int maxStoredMessages = 2000;
