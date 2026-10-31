import 'dart:convert';
import 'dart:typed_data';

/// Small helpers for the hand-rolled wire formats.
///
/// Every codec in `lib/protocol` uses these instead of `jsonEncode`, which
/// keeps messages compact on a 20-byte BLE chunk.

class ByteWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);

  int get length => _builder.length;

  void u8(int value) {
    if (value < 0 || value > 0xff) {
      throw ArgumentError.value(value, 'value', 'Does not fit in uint8');
    }
    _builder.addByte(value);
  }

  void u16(int value) {
    if (value < 0 || value > 0xffff) {
      throw ArgumentError.value(value, 'value', 'Does not fit in uint16');
    }
    _builder.add(<int>[(value >> 8) & 0xff, value & 0xff]);
  }

  void u32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError.value(value, 'value', 'Does not fit in uint32');
    }
    _builder.add(<int>[
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
  }

  void u64(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'Negative uint64');
    }
    for (var shift = 56; shift >= 0; shift -= 8) {
      _builder.addByte((value >> shift) & 0xff);
    }
  }

  void bytes(List<int> value) => _builder.add(value);

  void hex8(String hex) => bytes(bytesFromHex(hex, byteLength: 8));

  Uint8List takeBytes() => _builder.takeBytes();
}

class ByteReader {
  ByteReader(this.bytes, [this.offset = 0]);

  final Uint8List bytes;
  int offset;

  int get remaining => bytes.length - offset;
  bool get isAtEnd => offset >= bytes.length;

  int u8() {
    _require(1);
    return bytes[offset++];
  }

  int u16() {
    _require(2);
    final value = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    return value;
  }

  int u32() {
    _require(4);
    final value =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;
    return value;
  }

  int u64() {
    _require(8);
    var value = 0;
    for (var index = 0; index < 8; index++) {
      value = (value << 8) | bytes[offset + index];
    }
    offset += 8;
    return value;
  }

  Uint8List take(int length) {
    if (length < 0) throw ArgumentError.value(length, 'length');
    _require(length);
    final value = Uint8List.fromList(bytes.sublist(offset, offset + length));
    offset += length;
    return value;
  }

  String utf8String(int length) {
    final raw = take(length);
    return utf8.decode(raw);
  }

  String hex8() => hexFromBytes(take(8));

  void expectEnd() {
    if (!isAtEnd) {
      throw FormatException('Unexpected trailing bytes ($remaining).');
    }
  }

  void _require(int length) {
    if (offset + length > bytes.length) {
      throw const FormatException('Truncated payload.');
    }
  }
}

Uint8List bytesFromHex(String hex, {int? byteLength}) {
  if (hex.length.isOdd) {
    throw const FormatException('Hex value has an odd length.');
  }
  if (byteLength != null && hex.length != byteLength * 2) {
    throw FormatException('Expected ${byteLength * 2} hex characters.');
  }
  final output = Uint8List(hex.length ~/ 2);
  for (var index = 0; index < output.length; index++) {
    final pair = hex.substring(index * 2, index * 2 + 2);
    final value = int.tryParse(pair, radix: 16);
    if (value == null) throw const FormatException('Invalid hex value.');
    output[index] = value;
  }
  return output;
}

String hexFromBytes(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Cuts [value] so its UTF-8 encoding fits in [maxBytes] without splitting a
/// code point.
String truncateUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) return value;
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final encodedLength = utf8.encode(String.fromCharCode(rune)).length;
    if (used + encodedLength > maxBytes) break;
    buffer.writeCharCode(rune);
    used += encodedLength;
  }
  return buffer.toString();
}
