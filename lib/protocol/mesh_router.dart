import 'dart:collection';
import 'dart:typed_data';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/message.dart';
import 'blob_codec.dart';
import 'message_codec.dart';

/// Bounded dedupe cache for message ids. Flooding is only safe if every node
/// remembers what it has already seen.
class SeenCache {
  SeenCache({this.capacity = 4096, this.ttl = const Duration(hours: 24)});

  final int capacity;
  final Duration ttl;
  final LinkedHashMap<String, DateTime> _entries = LinkedHashMap();

  int get length => _entries.length;

  bool contains(String id) {
    _prune();
    return _entries.containsKey(id);
  }

  void add(String id, {DateTime? now}) {
    _prune();
    _entries.remove(id);
    _entries[id] = now ?? DateTime.now();
    _prune();
  }

  void addAll(Iterable<String> ids, {DateTime? now}) {
    for (final id in ids) {
      add(id, now: now);
    }
  }

  void clear() => _entries.clear();

  void _prune() {
    final cutoff = DateTime.now().subtract(ttl);
    while (_entries.isNotEmpty) {
      final first = _entries.entries.first;
      if (first.value.isBefore(cutoff)) {
        _entries.remove(first.key);
      } else {
        break;
      }
    }
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }
}

class InboundResult {
  const InboundResult({
    this.envelope,
    this.relay,
    this.ackMessageId,
    this.duplicate = false,
    this.error,
  });

  /// Decoded message for local display.
  final MessageEnvelope? envelope;

  /// Re-encoded binary envelope with decremented TTL, to flood onward.
  final Uint8List? relay;

  /// Message id to acknowledge on the ingress link, when the sender is direct.
  final String? ackMessageId;

  final bool duplicate;
  final String? error;
}

class InboundBlobResult {
  const InboundBlobResult({
    this.chunk,
    this.relay,
    this.duplicate = false,
    this.error,
  });

  final BlobChunk? chunk;
  final Uint8List? relay;
  final bool duplicate;
  final String? error;
}

/// Protocol-level routing: create, validate, dedupe, display, and relay.
///
/// This class has no BLE or Flutter dependencies, which keeps the tricky part
/// of the mesh testable without hardware.
class MeshRouter {
  MeshRouter({
    required this.selfId,
    required this.selfName,
    SeenCache? seen,
    SeenCache? seenBlobs,
  }) : seen = seen ?? SeenCache(),
       seenBlobs =
           seenBlobs ??
           SeenCache(capacity: 32768, ttl: const Duration(minutes: 30));

  final String selfId;
  String selfName;
  final SeenCache seen;
  final SeenCache seenBlobs;

  void seedSeen(Iterable<String> messageIds) => seen.addAll(messageIds);

  Message createOutgoing({
    required String to,
    required String text,
    required int ttl,
    DateTime? now,
    MessageKind kind = MessageKind.text,
    MessageAttachment? attachment,
    bool encrypted = false,
  }) {
    final body = text.trim();
    if (kind == MessageKind.text) {
      if (body.isEmpty) throw ArgumentError('Message is empty.');
      if (body.length > maxMessageLength) {
        throw ArgumentError(
          'Messages are limited to $maxMessageLength characters.',
        );
      }
    } else if (attachment == null) {
      throw ArgumentError('Attachment metadata is required.');
    }
    if (to != broadcastRecipient && !isPeerId(to)) {
      throw ArgumentError('Invalid recipient.');
    }

    final message = Message(
      id: newMessageId(),
      from: selfId,
      fromName: normalizeDisplayName(selfName),
      to: to,
      text: body,
      timestampMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      ttl: ttl < minTtl ? minTtl : (ttl > maxTtl ? maxTtl : ttl),
      hops: 0,
      outgoing: true,
      status: MessageStatus.queued,
      kind: kind,
      attachment: attachment,
      encrypted: encrypted,
    );
    seen.add(message.id, now: now);
    return message;
  }

  InboundResult receive(Uint8List wire, {String? viaPeerId}) {
    MessageEnvelope envelope;
    try {
      envelope = MessageEnvelope.decode(wire);
    } catch (error) {
      return InboundResult(error: error.toString());
    }

    final header = envelope.header;

    // Our own message came back around the mesh.
    if (header.from == selfId) {
      return const InboundResult(duplicate: true);
    }

    // Direct messages are acknowledged even when they are duplicates. This
    // makes a lost ACK recoverable: the sender retries and gets a fresh one.
    final ack = header.to == selfId && viaPeerId == header.from
        ? header.id
        : null;

    if (seen.contains(header.id)) {
      return InboundResult(duplicate: true, ackMessageId: ack);
    }
    seen.add(header.id);

    final forMe = header.to == selfId || header.isBroadcast;

    Uint8List? relay;
    if (header.ttl > minTtl && header.to != selfId) {
      relay = envelope.withRouting(ttl: header.ttl - 1, hops: header.hops + 1);
    }

    return InboundResult(
      envelope: forMe ? envelope : null,
      relay: relay,
      ackMessageId: ack,
    );
  }

  InboundBlobResult receiveBlob(Uint8List wire) {
    BlobChunk chunk;
    try {
      chunk = BlobChunk.decode(wire);
    } catch (error) {
      return InboundBlobResult(error: error.toString());
    }

    final key = '${chunk.key}:${chunk.index}';
    if (seenBlobs.contains(key)) {
      return const InboundBlobResult(duplicate: true);
    }
    seenBlobs.add(key);

    Uint8List? relay;
    if (chunk.ttl > minTtl && chunk.to != selfId) {
      relay = chunk.withRouting(ttl: chunk.ttl - 1, hops: chunk.hops + 1);
    }

    return InboundBlobResult(chunk: chunk, relay: relay);
  }
}
