import 'package:characters/characters.dart';

import '../core/constants.dart';
import '../core/ids.dart';

enum MessageStatus { queued, sent, delivered, failed, received }

/// A text message in the mesh.
///
/// The same model is used for the wire, local storage, and the UI. Only
/// [toWire] is ever sent to other devices; storage adds local-only flags.
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

  bool get isBroadcast => to == broadcastRecipient;

  /// Thread key: the broadcast channel, or the other party's peer id.
  String get threadId =>
      isBroadcast ? broadcastRecipient : (outgoing ? to : from);

  DateTime get timestamp => DateTime.fromMillisecondsSinceEpoch(timestampMs);

  String get preview {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final characters = collapsed.characters;
    if (characters.length <= 90) return collapsed;
    return '${characters.take(90)}…';
  }

  Map<String, dynamic> toWire() => <String, dynamic>{
    'v': protocolVersion,
    'id': id,
    'from': from,
    'name': fromName,
    'to': to,
    'ts': timestampMs,
    'ttl': ttl,
    'hops': hops,
    'kind': 'text',
    'text': text,
  };

  Map<String, dynamic> toStorage() => <String, dynamic>{
    ...toWire(),
    'dir': outgoing ? 'out' : 'in',
    'status': status.name,
  };

  factory Message.fromWire(Map<String, dynamic> json) {
    if (json['v'] != protocolVersion) {
      throw const FormatException('Unsupported protocol version.');
    }
    if (json['kind'] != 'text') {
      throw const FormatException('Unsupported message kind.');
    }

    final id = _readPeerId(json['id'], 'id');
    final from = _readPeerId(json['from'], 'from');
    final toRaw = json['to'];
    final to = toRaw == broadcastRecipient
        ? broadcastRecipient
        : _readPeerId(toRaw, 'to');

    final rawName = _readString(
      json['name'],
      'name',
      max: maxDisplayNameLength,
    );
    final name = rawName.trim().isEmpty ? 'MGS user' : rawName.trim();
    final timestampMs = _readInt(json['ts'], 'ts');
    if (timestampMs <= 0) {
      throw const FormatException('Timestamp must be positive.');
    }
    final ttl = _readInt(json['ttl'], 'ttl');
    if (ttl < minTtl || ttl > maxTtl) {
      throw const FormatException('TTL out of range.');
    }
    final hops = _readInt(json['hops'], 'hops');
    if (hops < 0 || hops > maxTtl) {
      throw const FormatException('Hop count out of range.');
    }
    final text = _readString(
      json['text'],
      'text',
      max: maxMessageLength,
    ).trim();
    if (text.isEmpty) {
      throw const FormatException('Message body is empty.');
    }

    return Message(
      id: id,
      from: from,
      fromName: name,
      to: to,
      text: text,
      timestampMs: timestampMs,
      ttl: ttl,
      hops: hops,
      outgoing: false,
      status: MessageStatus.received,
    );
  }

  factory Message.fromStorage(Map<String, dynamic> json) {
    final message = Message.fromWire(json);
    final outgoing = json['dir'] == 'out';
    final status = MessageStatus.values.firstWhere(
      (value) => value.name == json['status'],
      orElse: () => outgoing ? MessageStatus.sent : MessageStatus.received,
    );
    return message.copyWith(outgoing: outgoing, status: status);
  }

  Message copyWith({
    int? ttl,
    int? hops,
    bool? outgoing,
    MessageStatus? status,
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
    );
  }
}

String _readPeerId(Object? value, String field) {
  if (value is! String || !isPeerId(value)) {
    throw FormatException('Invalid $field.');
  }
  return value;
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
