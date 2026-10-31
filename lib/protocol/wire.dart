import 'dart:convert';
import 'dart:typed_data';

/// Encodes a JSON object as compact UTF-8 bytes for the wire.
Uint8List encodeJson(Map<String, dynamic> value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// Decodes UTF-8 JSON and validates that the root is an object.
Map<String, dynamic> decodeJson(Uint8List bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw const FormatException('Expected a JSON object.');
  }
  return Map<String, dynamic>.from(decoded);
}
