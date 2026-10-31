import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/core/constants.dart';
import 'package:mgs/models/message.dart';
import 'package:mgs/protocol/mesh_router.dart';

const alice = '1111111111111111';
const bob = '2222222222222222';
const carol = '3333333333333333';
const msgId = 'aaaaaaaaaaaaaaaa';

Map<String, dynamic> wire({
  String id = msgId,
  String from = bob,
  String name = 'Bob',
  String to = broadcastRecipient,
  int ttl = 4,
  int hops = 0,
  String text = 'hello mesh',
}) {
  return Message(
    id: id,
    from: from,
    fromName: name,
    to: to,
    text: text,
    timestampMs: 1700000000000,
    ttl: ttl,
    hops: hops,
    outgoing: false,
    status: MessageStatus.received,
  ).toWire();
}

void main() {
  group('createOutgoing', () {
    test('trims text, clamps ttl, and remembers the id', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final message = router.createOutgoing(
        to: broadcastRecipient,
        text: '  hi  ',
        ttl: 99,
      );

      expect(message.text, 'hi');
      expect(message.ttl, maxTtl);
      expect(message.outgoing, isTrue);
      expect(message.status, MessageStatus.queued);
      expect(router.seen.contains(message.id), isTrue);
    });

    test('rejects empty or oversized messages and bad recipients', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');

      expect(
        () =>
            router.createOutgoing(to: broadcastRecipient, text: '   ', ttl: 3),
        throwsArgumentError,
      );
      expect(
        () => router.createOutgoing(
          to: broadcastRecipient,
          text: 'x' * (maxMessageLength + 1),
          ttl: 3,
        ),
        throwsArgumentError,
      );
      expect(
        () => router.createOutgoing(to: 'not-a-peer', text: 'hi', ttl: 3),
        throwsArgumentError,
      );
    });
  });

  group('receive', () {
    test('displays a broadcast and relays it with decremented ttl', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(wire(ttl: 4, hops: 1), viaPeerId: bob);

      expect(result.error, isNull);
      expect(result.duplicate, isFalse);
      expect(result.display?.text, 'hello mesh');
      expect(result.relay, isNotNull);
      expect(result.relay!['ttl'], 3);
      expect(result.relay!['hops'], 2);
      expect(result.ackMessageId, isNull);
    });

    test('acknowledges a direct message only on the sender link', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(wire(to: alice), viaPeerId: bob);

      expect(result.display?.to, alice);
      expect(result.ackMessageId, msgId);
      expect(result.relay, isNull);
    });

    test('does not ack a direct message that arrived through a relay', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(
        wire(id: 'bbbbbbbbbbbbbbbb', to: alice),
        viaPeerId: carol,
      );

      expect(result.display, isNotNull);
      expect(result.ackMessageId, isNull);
    });

    test('does not relay at the ttl floor', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(wire(ttl: minTtl), viaPeerId: bob);

      expect(result.display, isNotNull);
      expect(result.relay, isNull);
    });

    test('drops duplicates and own echoes', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final first = router.receive(wire(), viaPeerId: bob);
      final second = router.receive(wire(), viaPeerId: carol);

      expect(first.duplicate, isFalse);
      expect(second.duplicate, isTrue);
      expect(second.display, isNull);

      final echo = router.receive(
        wire(id: 'cccccccccccccccc', from: alice),
        viaPeerId: bob,
      );
      expect(echo.duplicate, isTrue);
    });

    test('re-acknowledges duplicate direct messages', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      router.receive(wire(to: alice), viaPeerId: bob);
      final retry = router.receive(wire(to: alice), viaPeerId: bob);

      expect(retry.duplicate, isTrue);
      expect(retry.display, isNull);
      expect(retry.ackMessageId, msgId);
    });

    test('rejects malformed envelopes', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive({'v': 1});

      expect(result.error, isNotNull);
      expect(result.display, isNull);
      expect(result.relay, isNull);
    });

    test('relays a direct message addressed to someone else', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(
        wire(id: 'dddddddddddddddd', to: carol),
        viaPeerId: bob,
      );

      expect(result.display, isNull);
      expect(result.relay, isNotNull);
      expect(result.ackMessageId, isNull);
    });
  });
}
