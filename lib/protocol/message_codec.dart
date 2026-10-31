import 'dart:convert';
import 'dart:typed_data';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/message.dart';
import 'binary.dart';

/// Binary version-2 message envelope.
///
/// Layout (big endian):
///
///   0      protocol version (2)
///   1      kind (0 text, 1 file, 2 voice)
///   2      flags (bit 0: body is AES-256-GCM encrypted)
///   3      display-name length in bytes
///   4..11  message id (8)
///   12..19 sender peer id (8)
///   20..27 recipient peer id (8, all zero for broadcast)
///   28..35 sender timestamp, milliseconds (uint64)
///   36     ttl
///   37     hops
///   38..39 encrypted body length (uint16)
///   40..   display name, then body
///
/// The authenticated header excludes bytes 36-37 so a relay can decrement
/// the TTL and increment the hop count without invalidating the tag.
const int messageWireVersion = protocolVersion;
const int messageWireHeaderLength = 40;
const int messageFlagEncrypted = 1;

class MessageHeader {
  const MessageHeader({
    required this.id,
    required this.from,
    required this.to,
    required this.fromName,
    required this.timestampMs,
    required this.ttl,
    required this.hops,
    required this.kind,
    required this.encrypted,
  });

  final String id;
  final String from;
  final String to;
  final String fromName;
  final int timestampMs;
  final int ttl;
  final int hops;
  final MessageKind kind;
  final bool encrypted;

  bool get isBroadcast => to == broadcastRecipient;

  Uint8List encode({required int contentLength}) {
    if (contentLength < 0 || contentLength > 0xffff) {
      throw ArgumentError.value(
        contentLength,
        'contentLength',
        'Does not fit in uint16',
      );
    }
    if (!isPeerId(id) || !isPeerId(from)) {
      throw ArgumentError('Invalid peer or message id.');
    }
    if (!isBroadcast && !isPeerId(to)) {
      throw ArgumentError('Invalid recipient.');
    }
    if (timestampMs <= 0) {
      throw ArgumentError('Timestamp must be positive.');
    }
    if (ttl < minTtl || ttl > maxTtl) {
      throw ArgumentError('TTL out of range.');
    }
    if (hops < 0 || hops > maxTtl) {
      throw ArgumentError('Hop count out of range.');
    }

    final nameBytes = utf8.encode(fromName.trim());
    if (nameBytes.length > 0xff) {
      throw ArgumentError('Display name is too long.');
    }
    if (fromName.trim().isNotEmpty &&
        fromName.trim().length > maxDisplayNameLength) {
      throw ArgumentError('Display name is too long.');
    }

    final writer = ByteWriter()
      ..u8(messageWireVersion)
      ..u8(_kindCode(kind))
      ..u8(encrypted ? messageFlagEncrypted : 0)
      ..u8(nameBytes.length)
      ..hex8(id)
      ..hex8(from)
      ..bytes(isBroadcast ? Uint8List(8) : bytesFromHex(to, byteLength: 8))
      ..u64(timestampMs)
      ..u8(ttl)
      ..u8(hops)
      ..u16(contentLength)
      ..bytes(nameBytes);
    return writer.takeBytes();
  }
}

class MessageEnvelope {
  MessageEnvelope._({
    required this.header,
    required this.content,
    required this.raw,
  });

  final MessageHeader header;

  /// Encrypted bytes when [MessageHeader.encrypted] is set, otherwise the
  /// plaintext body.
  final Uint8List content;
  final Uint8List raw;

  /// Additional authenticated data for AES-GCM. TTL and hop count are skipped.
  Uint8List get aad {
    final nameLength = raw[3];
    final builder = BytesBuilder(copy: false)
      ..add(raw.sublist(0, 36))
      ..add(raw.sublist(38, messageWireHeaderLength + nameLength));
    return builder.takeBytes();
  }

  static MessageEnvelope build(MessageHeader header, Uint8List content) {
    final headerBytes = header.encode(contentLength: content.length);
    final raw = Uint8List(headerBytes.length + content.length)
      ..setRange(0, headerBytes.length, headerBytes)
      ..setRange(
        headerBytes.length,
        headerBytes.length + content.length,
        content,
      );
    return MessageEnvelope._(
      header: header,
      content: Uint8List.fromList(content),
      raw: raw,
    );
  }

  static MessageEnvelope decode(Uint8List raw) {
    if (raw.length < messageWireHeaderLength) {
      throw const FormatException('Message envelope is truncated.');
    }
    if (raw[0] != messageWireVersion) {
      throw const FormatException('Unsupported protocol version.');
    }

    final kind = _kindFromCode(raw[1]);
    final flags = raw[2];
    if (flags & ~messageFlagEncrypted != 0) {
      throw const FormatException('Unsupported message flags.');
    }
    final nameLength = raw[3];
    final bodyStart = messageWireHeaderLength + nameLength;
    if (raw.length < bodyStart) {
      throw const FormatException('Message envelope is truncated.');
    }

    final reader = ByteReader(raw, 4);
    final id = reader.hex8();
    final from = reader.hex8();
    final toBytes = reader.take(8);
    final to = toBytes.every((byte) => byte == 0)
        ? broadcastRecipient
        : hexFromBytes(toBytes);
    final timestampMs = reader.u64();
    if (timestampMs <= 0) {
      throw const FormatException('Timestamp must be positive.');
    }
    final ttl = reader.u8();
    if (ttl < minTtl || ttl > maxTtl) {
      throw const FormatException('TTL out of range.');
    }
    final hops = reader.u8();
    if (hops > maxTtl) {
      throw const FormatException('Hop count out of range.');
    }
    final contentLength = reader.u16();

    if (raw.length != bodyStart + contentLength) {
      throw const FormatException('Message body length does not match.');
    }
    if (!isPeerId(id) || !isPeerId(from)) {
      throw const FormatException('Invalid peer or message id.');
    }
    if (to != broadcastRecipient && !isPeerId(to)) {
      throw const FormatException('Invalid recipient.');
    }

    String name;
    try {
      name = utf8
          .decode(raw.sublist(messageWireHeaderLength, bodyStart))
          .trim();
    } on FormatException {
      throw const FormatException('Invalid display name.');
    }
    if (name.length > maxDisplayNameLength) {
      throw const FormatException('Display name is too long.');
    }
    if (name.isEmpty) name = 'MGS user';

    final content = Uint8List.fromList(raw.sublist(bodyStart));
    return MessageEnvelope._(
      header: MessageHeader(
        id: id,
        from: from,
        to: to,
        fromName: name,
        timestampMs: timestampMs,
        ttl: ttl,
        hops: hops,
        kind: kind,
        encrypted: flags & messageFlagEncrypted != 0,
      ),
      content: content,
      raw: Uint8List.fromList(raw),
    );
  }

  /// Returns a copy of the encoded envelope with new routing counters.
  Uint8List withRouting({required int ttl, required int hops}) {
    if (ttl < minTtl || ttl > maxTtl) {
      throw ArgumentError('TTL out of range.');
    }
    if (hops < 0 || hops > maxTtl) {
      throw ArgumentError('Hop count out of range.');
    }
    final copy = Uint8List.fromList(raw);
    copy[36] = ttl;
    copy[37] = hops;
    return copy;
  }
}

/// Additional authenticated data for [header] with [contentLength] bytes.
Uint8List messageAadFor(MessageHeader header, int contentLength) {
  final encoded = header.encode(contentLength: contentLength);
  final nameLength = encoded[3];
  final builder = BytesBuilder(copy: false)
    ..add(encoded.sublist(0, 36))
    ..add(encoded.sublist(38, messageWireHeaderLength + nameLength));
  return builder.takeBytes();
}

int _kindCode(MessageKind kind) => switch (kind) {
  MessageKind.text => 0,
  MessageKind.file => 1,
  MessageKind.voice => 2,
};

MessageKind _kindFromCode(int code) => switch (code) {
  0 => MessageKind.text,
  1 => MessageKind.file,
  2 => MessageKind.voice,
  _ => throw const FormatException('Unsupported message kind.'),
};

/// Binary HELLO payload.
///
///   0      protocol version (2)
///   1      name length
///   2..9   peer id (8)
///   10..   display name
class MeshHello {
  const MeshHello({required this.peerId, required this.name});

  final String peerId;
  final String name;

  Uint8List encode() {
    if (!isPeerId(peerId)) throw ArgumentError('Invalid peer id.');
    final nameBytes = utf8.encode(name.trim());
    if (nameBytes.length > 0xff) throw ArgumentError('Name is too long.');
    final writer = ByteWriter()
      ..u8(protocolVersion)
      ..u8(nameBytes.length)
      ..hex8(peerId)
      ..bytes(nameBytes);
    return writer.takeBytes();
  }

  static MeshHello decode(Uint8List payload) {
    if (payload.length < 10) {
      throw const FormatException('HELLO is truncated.');
    }
    if (payload[0] != protocolVersion) {
      throw const FormatException('Unsupported protocol version.');
    }
    final nameLength = payload[1];
    if (payload.length != 10 + nameLength) {
      throw const FormatException('HELLO length does not match.');
    }
    final peerId = hexFromBytes(payload.sublist(2, 10));
    if (!isPeerId(peerId)) {
      throw const FormatException('Invalid peer id.');
    }
    String name;
    try {
      name = utf8.decode(payload.sublist(10)).trim();
    } on FormatException {
      throw const FormatException('Invalid display name.');
    }
    if (name.length > maxDisplayNameLength) {
      throw const FormatException('Display name is too long.');
    }
    return MeshHello(peerId: peerId, name: name.isEmpty ? 'MGS user' : name);
  }
}
