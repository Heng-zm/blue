import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Human-facing app name.
const String appName = 'MGS';
const String appTagline = 'Offline mesh messenger';

/// Wire protocol version. Bump when the frame or envelope layout changes.
const int protocolVersion = 1;

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
