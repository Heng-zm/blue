import 'dart:math';

final RegExp _hexIdPattern = RegExp(r'^[0-9a-f]{16}$');
final Random _secureRandom = Random.secure();

/// Returns [byteLength] cryptographically random bytes encoded as lowercase hex.
String randomHex(int byteLength, [Random? random]) {
  final rng = random ?? _secureRandom;
  final buffer = StringBuffer();
  for (var i = 0; i < byteLength; i++) {
    buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 8 random bytes, used as a peer identity.
String newPeerId([Random? random]) => randomHex(8, random);

/// 8 random bytes, used as a message id (also the dedupe key).
String newMessageId([Random? random]) => randomHex(8, random);

bool isPeerId(String value) => _hexIdPattern.hasMatch(value);

/// Short, human-readable form of a peer id.
String shortPeerId(String id, [int length = 6]) {
  if (id.length <= length) return id;
  return id.substring(0, length);
}
