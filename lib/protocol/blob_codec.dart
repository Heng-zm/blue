import 'dart:convert';
import 'dart:typed_data';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/message.dart';
import 'binary.dart';

/// Binary blob-chunk envelope. The chunk bytes are the encrypted (or plain)
/// file segment; the header is small enough for a relay to patch and forward
/// without decrypting anything.
///
///   0      protocol version (2)
///   1      flags (reserved, must be 0)
///   2..9   blob id (8)
///   10..13 transfer id (4)
///   14..21 recipient peer id (8, all zero for broadcast)
///   22..23 chunk index (uint16)
///   24..25 chunk count (uint16)
///   26..29 total ciphertext length (uint32)
///   30     ttl
///   31     hops
///   32..   chunk data
const int blobWireVersion = protocolVersion;
const int blobHeaderLength = 32;

class BlobChunk {
  const BlobChunk({
    required this.blobId,
    required this.transferId,
    required this.to,
    required this.index,
    required this.count,
    required this.totalLength,
    required this.ttl,
    required this.hops,
    required this.data,
  });

  final String blobId;
  final String transferId;
  final String to;
  final int index;
  final int count;
  final int totalLength;
  final int ttl;
  final int hops;
  final Uint8List data;

  bool get isBroadcast => to == broadcastRecipient;

  String get key => '$blobId:$transferId';

  Uint8List encode() {
    if (!isPeerId(blobId)) throw ArgumentError('Invalid blob id.');
    if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(transferId)) {
      throw ArgumentError('Invalid transfer id.');
    }
    if (!isBroadcast && !isPeerId(to)) {
      throw ArgumentError('Invalid recipient.');
    }
    if (count < 1 || count > maxBlobChunks) {
      throw ArgumentError('Invalid chunk count.');
    }
    if (index < 0 || index >= count) {
      throw ArgumentError('Invalid chunk index.');
    }
    if (totalLength < 1 || totalLength > maxBlobCipherBytes) {
      throw ArgumentError('Invalid blob length.');
    }
    if (ttl < minTtl || ttl > maxTtl) {
      throw ArgumentError('TTL out of range.');
    }
    if (hops < 0 || hops > maxTtl) {
      throw ArgumentError('Hop count out of range.');
    }
    if (data.length > blobChunkPayloadBytes) {
      throw ArgumentError('Blob chunk is too large.');
    }

    final writer = ByteWriter()
      ..u8(blobWireVersion)
      ..u8(0)
      ..hex8(blobId)
      ..bytes(bytesFromHex(transferId, byteLength: 4))
      ..bytes(isBroadcast ? Uint8List(8) : bytesFromHex(to, byteLength: 8))
      ..u16(index)
      ..u16(count)
      ..u32(totalLength)
      ..u8(ttl)
      ..u8(hops)
      ..bytes(data);
    return writer.takeBytes();
  }

  /// Returns `null` for anything malformed instead of throwing.
  static BlobChunk? tryDecode(Uint8List raw) {
    try {
      return decode(raw);
    } catch (_) {
      return null;
    }
  }

  static BlobChunk decode(Uint8List raw) {
    if (raw.length < blobHeaderLength) {
      throw const FormatException('Blob chunk is truncated.');
    }
    if (raw[0] != blobWireVersion) {
      throw const FormatException('Unsupported protocol version.');
    }
    if (raw[1] != 0) {
      throw const FormatException('Unsupported blob flags.');
    }

    final reader = ByteReader(raw, 2);
    final blobId = reader.hex8();
    final transferId = hexFromBytes(reader.take(4));
    final toBytes = reader.take(8);
    final to = toBytes.every((byte) => byte == 0)
        ? broadcastRecipient
        : hexFromBytes(toBytes);
    final index = reader.u16();
    final count = reader.u16();
    final totalLength = reader.u32();
    final ttl = reader.u8();
    final hops = reader.u8();

    if (!isPeerId(blobId)) {
      throw const FormatException('Invalid blob id.');
    }
    if (to != broadcastRecipient && !isPeerId(to)) {
      throw const FormatException('Invalid recipient.');
    }
    if (count < 1 || count > maxBlobChunks || index >= count) {
      throw const FormatException('Invalid chunk range.');
    }
    if (totalLength < 1 || totalLength > maxBlobCipherBytes) {
      throw const FormatException('Invalid blob length.');
    }
    if (ttl < minTtl || ttl > maxTtl || hops > maxTtl) {
      throw const FormatException('Invalid routing counters.');
    }
    if (raw.length - blobHeaderLength > blobChunkPayloadBytes) {
      throw const FormatException('Blob chunk is too large.');
    }

    return BlobChunk(
      blobId: blobId,
      transferId: transferId,
      to: to,
      index: index,
      count: count,
      totalLength: totalLength,
      ttl: ttl,
      hops: hops,
      data: Uint8List.fromList(raw.sublist(blobHeaderLength)),
    );
  }

  /// Returns a copy of the encoded chunk with new routing counters.
  Uint8List withRouting({required int ttl, required int hops}) {
    if (ttl < minTtl || ttl > maxTtl) {
      throw ArgumentError('TTL out of range.');
    }
    if (hops < 0 || hops > maxTtl) {
      throw ArgumentError('Hop count out of range.');
    }
    final copy = Uint8List.fromList(encode());
    copy[30] = ttl;
    copy[31] = hops;
    return copy;
  }
}

/// Plaintext attachment descriptor carried inside an encrypted message body.
///
///   0      message kind (1 file, 2 voice)
///   1      name length
///   2..    name
///   ...    mime length (uint8), mime
///   ...    blob id (8), transfer id (4), AES nonce (12)
///   ...    plaintext size (uint32), ciphertext size (uint32)
///   ...    chunk count (uint16), duration ms (uint32)
///   ...    plaintext SHA-256 (32)
class BlobMetadata {
  const BlobMetadata({
    required this.kind,
    required this.blobId,
    required this.transferId,
    required this.blobNonce,
    required this.name,
    required this.mimeType,
    required this.size,
    required this.cipherBytes,
    required this.chunkCount,
    required this.digest,
    this.durationMs = 0,
  });

  final MessageKind kind;
  final String blobId;
  final String transferId;
  final String blobNonce;
  final String name;
  final String mimeType;
  final int size;
  final int cipherBytes;
  final int chunkCount;
  final String digest;
  final int durationMs;

  Uint8List encode() {
    if (kind != MessageKind.file && kind != MessageKind.voice) {
      throw ArgumentError('Blob metadata must describe a file or voice note.');
    }
    if (!isPeerId(blobId)) throw ArgumentError('Invalid blob id.');
    if (!RegExp(r'^[0-9a-f]{8}$').hasMatch(transferId)) {
      throw ArgumentError('Invalid transfer id.');
    }
    if (!RegExp(r'^[0-9a-f]{24}$').hasMatch(blobNonce)) {
      throw ArgumentError('Invalid blob nonce.');
    }
    if (size < 0 || size > maxFileBytes) {
      throw ArgumentError('Attachment is too large.');
    }
    if (cipherBytes < size || cipherBytes > maxBlobCipherBytes) {
      throw ArgumentError('Invalid ciphertext length.');
    }
    if (chunkCount < 1 || chunkCount > maxBlobChunks) {
      throw ArgumentError('Invalid chunk count.');
    }
    if (durationMs < 0 || durationMs > maxVoiceSeconds * 1000) {
      throw ArgumentError('Invalid voice duration.');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw ArgumentError('Invalid digest.');
    }

    final nameBytes = utf8.encode(name.trim());
    final mimeBytes = utf8.encode(mimeType.trim());
    if (nameBytes.isEmpty || nameBytes.length > maxFileNameLength) {
      throw ArgumentError('Invalid file name.');
    }
    if (mimeBytes.isEmpty || mimeBytes.length > maxMimeTypeLength) {
      throw ArgumentError('Invalid MIME type.');
    }

    final writer = ByteWriter()
      ..u8(kind == MessageKind.file ? 1 : 2)
      ..u8(nameBytes.length)
      ..bytes(nameBytes)
      ..u8(mimeBytes.length)
      ..bytes(mimeBytes)
      ..hex8(blobId)
      ..bytes(bytesFromHex(transferId, byteLength: 4))
      ..bytes(bytesFromHex(blobNonce, byteLength: 12))
      ..u32(size)
      ..u32(cipherBytes)
      ..u16(chunkCount)
      ..u32(durationMs)
      ..bytes(bytesFromHex(digest, byteLength: 32));
    return writer.takeBytes();
  }

  static BlobMetadata decode(Uint8List raw) {
    if (raw.length < 2) {
      throw const FormatException('Attachment metadata is truncated.');
    }
    final kindCode = raw[0];
    final kind = switch (kindCode) {
      1 => MessageKind.file,
      2 => MessageKind.voice,
      _ => throw const FormatException('Unsupported attachment kind.'),
    };

    final reader = ByteReader(raw, 1);
    final nameLength = reader.u8();
    final name = reader.utf8String(nameLength).trim();
    final mimeLength = reader.u8();
    final mime = reader.utf8String(mimeLength).trim();
    final blobId = reader.hex8();
    final transferId = hexFromBytes(reader.take(4));
    final blobNonce = hexFromBytes(reader.take(12));
    final size = reader.u32();
    final cipherBytes = reader.u32();
    final chunkCount = reader.u16();
    final durationMs = reader.u32();
    final digest = hexFromBytes(reader.take(32));
    reader.expectEnd();

    if (!isPeerId(blobId)) {
      throw const FormatException('Invalid blob id.');
    }
    if (!RegExp(r'^[0-9a-f]{24}$').hasMatch(blobNonce)) {
      throw const FormatException('Invalid blob nonce.');
    }
    if (name.isEmpty || utf8.encode(name).length > maxFileNameLength) {
      throw const FormatException('Invalid file name.');
    }
    if (mime.isEmpty || utf8.encode(mime).length > maxMimeTypeLength) {
      throw const FormatException('Invalid MIME type.');
    }
    if (size > maxFileBytes ||
        cipherBytes < size ||
        cipherBytes > maxBlobCipherBytes) {
      throw const FormatException('Invalid attachment size.');
    }
    if (chunkCount < 1 || chunkCount > maxBlobChunks) {
      throw const FormatException('Invalid chunk count.');
    }
    if (durationMs > maxVoiceSeconds * 1000) {
      throw const FormatException('Invalid voice duration.');
    }
    if (kind == MessageKind.file && durationMs != 0) {
      throw const FormatException('Files cannot carry a duration.');
    }
    if (kind == MessageKind.voice && durationMs < 500) {
      throw const FormatException('Voice note is too short.');
    }

    return BlobMetadata(
      kind: kind,
      blobId: blobId,
      transferId: transferId,
      blobNonce: blobNonce,
      name: name,
      mimeType: mime,
      size: size,
      cipherBytes: cipherBytes,
      chunkCount: chunkCount,
      digest: digest,
      durationMs: durationMs,
    );
  }

  MessageAttachment toAttachment({String? path}) => MessageAttachment(
    blobId: blobId,
    transferId: transferId,
    blobNonce: blobNonce,
    name: name,
    mimeType: mimeType,
    size: size,
    cipherBytes: cipherBytes,
    chunkCount: chunkCount,
    digest: digest,
    durationMs: durationMs,
    path: path,
  );
}

/// AES-GCM additional data binding a ciphertext to its blob and transfer.
Uint8List blobAad(String blobId, String transferId) {
  final writer = ByteWriter()
    ..bytes(utf8.encode('MGSBLOB2'))
    ..hex8(blobId)
    ..bytes(bytesFromHex(transferId, byteLength: 4));
  return writer.takeBytes();
}

int blobChunkCount(int cipherBytes) =>
    (cipherBytes + blobChunkPayloadBytes - 1) ~/ blobChunkPayloadBytes;
