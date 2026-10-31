import 'dart:convert';

import 'package:characters/characters.dart';

import '../core/constants.dart';
import '../core/ids.dart';

enum MessageStatus { queued, sent, delivered, failed, received }

enum MessageKind { text, file, voice }

/// A file or voice note carried by a message.
///
/// The bytes themselves travel in [FrameType.blob] chunks; this descriptor
/// rides inside the encrypted message body.
class MessageAttachment {
  MessageAttachment({
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
    this.path,
  });

  final String blobId;
  final String transferId;

  /// 12-byte AES-GCM nonce, stored so a retried transfer reuses the exact
  /// same ciphertext instead of mixing chunks from two encryptions.
  final String blobNonce;
  final String name;
  final String mimeType;

  /// Plaintext size in bytes.
  final int size;

  /// Size of the encrypted blob in bytes.
  final int cipherBytes;
  final int chunkCount;

  /// Lowercase SHA-256 of the plaintext.
  final String digest;
  final int durationMs;

  /// Local path once the file has been written or imported.
  String? path;

  bool get available => path != null;

  bool get isVoice => durationMs > 0;

  String get key => '$blobId:$transferId';

  MessageAttachment copyWith({String? path}) => MessageAttachment(
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
    path: path ?? this.path,
  );
}

/// A message in the mesh.
///
/// The same model is used for local storage and the UI. The wire form is
/// produced by `MessageEnvelope` after the body has been encrypted.
class Message {
  Message({
    required this.id,
    required this.from,
    required this.fromName,
    required this.to,
    required this.text,
    required this.timestampMs,
    required this.ttl,
    required this.hops,
    required this.outgoing,
    required this.status,
    this.kind = MessageKind.text,
    this.attachment,
    this.encrypted = false,
    this.decryptionFailed = false,
    this.transferProgress = 0,
    this.transferError,
  });

  final String id;
  final String from;
  final String fromName;
  final String to;
  final String text;
  final int timestampMs;
  final int ttl;
  final int hops;
  final bool outgoing;
  MessageStatus status;
  final MessageKind kind;
  final MessageAttachment? attachment;
  final bool encrypted;
  final bool decryptionFailed;

  /// 0..1 for attachment transfers.
  double transferProgress;
  String? transferError;

  bool get isBroadcast => to == broadcastRecipient;

  bool get isAttachment =>
      kind == MessageKind.file || kind == MessageKind.voice;

  bool get isComplete =>
      decryptionFailed || !isAttachment || attachment?.available == true;

  /// Thread key: the broadcast channel, or the other party's peer id.
  String get threadId =>
      isBroadcast ? broadcastRecipient : (outgoing ? to : from);

  DateTime get timestamp => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  String get preview {
    if (decryptionFailed) return 'Encrypted message';
    if (kind == MessageKind.voice) {
      return 'Voice message · ${_durationLabel(attachment?.durationMs ?? 0)}';
    }
    if (kind == MessageKind.file) {
      return 'File · ${attachment?.name ?? 'attachment'}';
    }
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final characters = collapsed.characters;
    if (characters.length <= 90) return collapsed;
    return '${characters.take(90)}…';
  }

  Map<String, dynamic> toStorage() => <String, dynamic>{
    'storageVersion': storageVersion,
    'v': protocolVersion,
    'id': id,
    'from': from,
    'name': fromName,
    'to': to,
    'ts': timestampMs,
    'ttl': ttl,
    'hops': hops,
    'kind': kind.name,
    'text': text,
    'encrypted': encrypted,
    'decryptFailed': decryptionFailed,
    'progress': transferProgress,
    if (transferError != null) 'transferError': transferError,
    if (attachment != null)
      'attachment': <String, dynamic>{
        'blobId': attachment!.blobId,
        'transferId': attachment!.transferId,
        'blobNonce': attachment!.blobNonce,
        'name': attachment!.name,
        'mime': attachment!.mimeType,
        'size': attachment!.size,
        'cipherBytes': attachment!.cipherBytes,
        'chunks': attachment!.chunkCount,
        'digest': attachment!.digest,
        'durationMs': attachment!.durationMs,
        if (attachment!.path != null) 'path': attachment!.path,
      },
    'dir': outgoing ? 'out' : 'in',
    'status': status.name,
  };

  factory Message.fromStorage(Map<String, dynamic> json) {
    final version = json['v'];
    if (version == null || version == 1) {
      return Message._fromLegacyStorage(json);
    }
    if (version != protocolVersion) {
      throw const FormatException('Unsupported protocol version.');
    }

    final kind = MessageKind.values.firstWhere(
      (value) => value.name == json['kind'],
      orElse: () => throw const FormatException('Unsupported message kind.'),
    );
    final decryptionFailed = json['decryptFailed'] == true;
    final text = _readString(json['text'] ?? '', 'text', max: maxMessageLength);
    if (kind == MessageKind.text && text.trim().isEmpty && !decryptionFailed) {
      throw const FormatException('Message body is empty.');
    }

    MessageAttachment? attachment;
    final rawAttachment = json['attachment'];
    if (kind != MessageKind.text && !decryptionFailed) {
      if (rawAttachment is! Map) {
        throw const FormatException('Missing attachment.');
      }
      attachment = _attachmentFromJson(
        Map<String, dynamic>.from(rawAttachment),
      );
    }

    final outgoing = json['dir'] == 'out';
    final status = MessageStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => outgoing ? MessageStatus.sent : MessageStatus.received,
    );
    final rawProgress = json['progress'];
    final progress = rawProgress is num
        ? rawProgress.toDouble().clamp(0.0, 1.0)
        : (attachment?.available == true ? 1.0 : 0.0);
    final rawError = json['transferError'];

    return Message(
      id: _readPeerId(json['id'], 'id'),
      from: _readPeerId(json['from'], 'from'),
      fromName: _readName(json['name']),
      to: _readRecipient(json['to']),
      text: text.trim(),
      timestampMs: _readTimestamp(json['ts']),
      ttl: _readTtl(json['ttl']),
      hops: _readHops(json['hops']),
      outgoing: outgoing,
      status: status,
      kind: kind,
      attachment: attachment,
      encrypted: json['encrypted'] == true,
      decryptionFailed: decryptionFailed,
      transferProgress: progress,
      transferError: rawError is String ? rawError : null,
    );
  }

  factory Message._fromLegacyStorage(Map<String, dynamic> json) {
    final text = _readString(
      json['text'],
      'text',
      max: maxMessageLength,
    ).trim();
    if (text.isEmpty) {
      throw const FormatException('Message body is empty.');
    }
    final outgoing = json['dir'] == 'out';
    final status = MessageStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => outgoing ? MessageStatus.sent : MessageStatus.received,
    );
    return Message(
      id: _readPeerId(json['id'], 'id'),
      from: _readPeerId(json['from'], 'from'),
      fromName: _readName(json['name']),
      to: _readRecipient(json['to']),
      text: text,
      timestampMs: _readTimestamp(json['ts']),
      ttl: _readTtl(json['ttl']),
      hops: _readHops(json['hops']),
      outgoing: outgoing,
      status: status,
    );
  }

  Message copyWith({
    int? ttl,
    int? hops,
    bool? outgoing,
    MessageStatus? status,
    MessageAttachment? attachment,
    double? transferProgress,
    String? transferError,
  }) {
    return Message(
      id: id,
      from: from,
      fromName: fromName,
      to: to,
      text: text,
      timestampMs: timestampMs,
      ttl: ttl ?? this.ttl,
      hops: hops ?? this.hops,
      outgoing: outgoing ?? this.outgoing,
      status: status ?? this.status,
      kind: kind,
      attachment: attachment ?? this.attachment,
      encrypted: encrypted,
      decryptionFailed: decryptionFailed,
      transferProgress: transferProgress ?? this.transferProgress,
      transferError: transferError ?? this.transferError,
    );
  }
}

MessageAttachment _attachmentFromJson(Map<String, dynamic> json) {
  String idField(Object? value, String field, int bytes) {
    if (value is! String ||
        !RegExp('^[0-9a-f]{${bytes * 2}}\$').hasMatch(value)) {
      throw FormatException('Invalid $field.');
    }
    return value;
  }

  final size = _readInt(json['size'], 'size');
  if (size < 0 || size > maxFileBytes) {
    throw const FormatException('Attachment is too large.');
  }
  final cipherBytes = _readInt(json['cipherBytes'], 'cipherBytes');
  if (cipherBytes < size || cipherBytes > maxBlobCipherBytes) {
    throw const FormatException('Invalid attachment size.');
  }
  final chunks = _readInt(json['chunks'], 'chunks');
  if (chunks < 1 || chunks > maxBlobChunks) {
    throw const FormatException('Invalid chunk count.');
  }
  final durationMs = _readInt(json['durationMs'] ?? 0, 'durationMs');
  if (durationMs < 0 || durationMs > maxVoiceSeconds * 1000) {
    throw const FormatException('Invalid voice duration.');
  }
  final name = _readString(json['name'], 'name', max: maxFileNameLength);
  if (name.trim().isEmpty) {
    throw const FormatException('Invalid file name.');
  }
  final mime = _readString(json['mime'], 'mime', max: maxMimeTypeLength);
  final digest = _readString(json['digest'], 'digest', max: 64);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const FormatException('Invalid digest.');
  }
  final rawPath = json['path'];
  final path = rawPath is String && rawPath.isNotEmpty ? rawPath : null;

  final blobNonce = idField(json['blobNonce'], 'blobNonce', 12);

  return MessageAttachment(
    blobId: idField(json['blobId'], 'blobId', 8),
    transferId: idField(json['transferId'], 'transferId', 4),
    blobNonce: blobNonce,
    name: name,
    mimeType: mime,
    size: size,
    cipherBytes: cipherBytes,
    chunkCount: chunks,
    digest: digest,
    durationMs: durationMs,
    path: path,
  );
}

String _durationLabel(int milliseconds) {
  final totalSeconds = (milliseconds / 1000).round().clamp(0, 9999);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

String _readPeerId(Object? value, String field) {
  if (value is! String || !isPeerId(value)) {
    throw FormatException('Invalid $field.');
  }
  return value;
}

String _readRecipient(Object? value) {
  if (value == broadcastRecipient) return broadcastRecipient;
  return _readPeerId(value, 'to');
}

String _readName(Object? value) {
  final raw = _readString(value, 'name', max: maxDisplayNameLength);
  final trimmed = raw.trim();
  return trimmed.isEmpty ? 'MGS user' : trimmed;
}

String _readString(Object? value, String field, {required int max}) {
  if (value is! String) throw FormatException('Invalid $field.');
  if (value.length > max) throw FormatException('$field is too long.');
  return value;
}

int _readInt(Object? value, String field) {
  if (value is! int) throw FormatException('Invalid $field.');
  return value;
}

int _readTimestamp(Object? value) {
  final timestamp = _readInt(value, 'ts');
  if (timestamp <= 0) {
    throw const FormatException('Timestamp must be positive.');
  }
  return timestamp;
}

int _readTtl(Object? value) {
  final ttl = _readInt(value, 'ttl');
  if (ttl < minTtl || ttl > maxTtl) {
    throw const FormatException('TTL out of range.');
  }
  return ttl;
}

int _readHops(Object? value) {
  final hops = _readInt(value, 'hops');
  if (hops < 0 || hops > maxTtl) {
    throw const FormatException('Hop count out of range.');
  }
  return hops;
}

/// Ensures a display name is safe to put on the wire and in storage.
String normalizeDisplayName(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return 'MGS user';
  return trimmed.length > maxDisplayNameLength
      ? trimmed.substring(0, maxDisplayNameLength)
      : trimmed;
}

/// Sanitizes a picked file name while keeping a useful extension.
String normalizeFileName(String value) {
  final base = value.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  final name = base.isEmpty ? 'attachment' : base;
  return truncateFileNameUtf8(name, maxFileNameLength);
}

String truncateFileNameUtf8(String value, int maxBytes) {
  if (utf8.encode(value).length <= maxBytes) return value;
  final buffer = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final encodedLength = utf8.encode(String.fromCharCode(rune)).length;
    if (used + encodedLength > maxBytes) break;
    buffer.writeCharCode(rune);
    used += encodedLength;
  }
  final truncated = buffer.toString();
  return truncated.isEmpty ? 'attachment' : truncated;
}
