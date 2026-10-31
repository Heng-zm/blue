import 'dart:collection';

import '../core/constants.dart';
import '../core/ids.dart';
import '../models/message.dart';

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
    this.display,
    this.relay,
    this.ackMessageId,
    this.duplicate = false,
    this.error,
  });

  /// Message to show locally, if it is addressed to this device or broadcast.
  final Message? display;

  /// Re-encoded envelope with decremented TTL, to flood onward.
  final Map<String, dynamic>? relay;

  /// Message id to acknowledge on the ingress link, when the sender is direct.
  final String? ackMessageId;

  final bool duplicate;
  final String? error;
}

/// Protocol-level routing: create, validate, dedupe, display, and relay.
///
/// This class has no BLE or Flutter dependencies, which keeps the tricky part
/// of the mesh testable without hardware.
class MeshRouter {
  MeshRouter({required this.selfId, required this.selfName, SeenCache? seen})
    : seen = seen ?? SeenCache();

  final String selfId;
  String selfName;
  final SeenCache seen;

  void seedSeen(Iterable<String> messageIds) => seen.addAll(messageIds);

  Message createOutgoing({
    required String to,
    required String text,
    required int ttl,
    DateTime? now,
  }) {
    final body = text.trim();
    if (body.isEmpty) throw ArgumentError('Message is empty.');
    if (body.length > maxMessageLength) {
      throw ArgumentError(
        'Messages are limited to $maxMessageLength characters.',
      );
    }
    if (to != broadcastRecipient && !isPeerId(to)) {
      throw ArgumentError('Invalid recipient.');
    }

    final message = Message(
      id: newMessageId(),
      from: selfId,
      fromName: selfName,
      to: to,
      text: body,
      timestampMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      ttl: ttl < minTtl ? minTtl : (ttl > maxTtl ? maxTtl : ttl),
      hops: 0,
      outgoing: true,
      status: MessageStatus.queued,
    );
    seen.add(message.id, now: now);
    return message;
  }

  InboundResult receive(Map<String, dynamic> wire, {String? viaPeerId}) {
    Message message;
    try {
      message = Message.fromWire(wire);
    } catch (error) {
      return InboundResult(error: error.toString());
    }

    // Our own message came back around the mesh.
    if (message.from == selfId) {
      return const InboundResult(duplicate: true);
    }

    // Direct messages are acknowledged even when they are duplicates. This
    // makes a lost ACK recoverable: the sender retries and gets a fresh one.
    final ack = message.to == selfId && viaPeerId == message.from
        ? message.id
        : null;

    if (seen.contains(message.id)) {
      return InboundResult(duplicate: true, ackMessageId: ack);
    }
    seen.add(message.id);

    final forMe = message.to == selfId || message.to == broadcastRecipient;

    Map<String, dynamic>? relay;
    if (message.ttl > minTtl && message.to != selfId) {
      relay = message
          .copyWith(ttl: message.ttl - 1, hops: message.hops + 1)
          .toWire();
    }

    return InboundResult(
      display: forMe ? message : null,
      relay: relay,
      ackMessageId: ack,
    );
  }
}
