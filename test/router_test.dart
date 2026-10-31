import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/core/constants.dart';
import 'package:mgs/models/message.dart';
import 'package:mgs/protocol/blob_codec.dart';
import 'package:mgs/protocol/mesh_router.dart';
import 'package:mgs/protocol/message_codec.dart';

const alice = '1111111111111111';
const bob = '2222222222222222';
const carol = '3333333333333333';
const msgId = 'aaaaaaaaaaaaaaaa';

Uint8List wire({
  String id = msgId,
  String from = bob,
  String name = 'Bob',
  String to = broadcastRecipient,
  int ttl = 4,
  int hops = 0,
  String text = 'hello mesh',
  MessageKind kind = MessageKind.text,
  bool encrypted = false,
}) {
  final header = MessageHeader(
    id: id,
    from: from,
    to: to,
    fromName: name,
    timestampMs: 1700000000000,
    ttl: ttl,
    hops: hops,
    kind: kind,
    encrypted: encrypted,
  );
  return MessageEnvelope.build(
    header,
    Uint8List.fromList(utf8.encode(text)),
  ).raw;
}

BlobChunk chunk({
  String blobId = '0123456789abcdef',
  String transferId = 'deadbeef',
  String to = broadcastRecipient,
  int index = 0,
  int count = 1,
  int ttl = 4,
  int hops = 0,
  Uint8List? data,
}) {
  final bytes = data ?? Uint8List.fromList(List<int>.generate(10, (i) => i));
  return BlobChunk(
    blobId: blobId,
    transferId: transferId,
    to: to,
    index: index,
    count: count,
    totalLength: bytes.length,
    ttl: ttl,
    hops: hops,
    data: bytes,
  );
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
      expect(message.encrypted, isFalse);
      expect(router.seen.contains(message.id), isTrue);
    });

    test('creates attachments only with a descriptor', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      expect(
        () => router.createOutgoing(
          to: broadcastRecipient,
          text: '',
          ttl: 3,
          kind: MessageKind.file,
        ),
        throwsArgumentError,
      );

      final descriptor = MessageAttachment(
        blobId: '0123456789abcdef',
        transferId: 'deadbeef',
        blobNonce: '000102030405060708090a0b',
        name: 'notes.pdf',
        mimeType: 'application/pdf',
        size: 100,
        cipherBytes: 128,
        chunkCount: 1,
        digest: 'b' * 64,
      );
      final message = router.createOutgoing(
        to: bob,
        text: '',
        ttl: 3,
        kind: MessageKind.file,
        attachment: descriptor,
        encrypted: true,
      );
      expect(message.kind, MessageKind.file);
      expect(message.attachment, same(descriptor));
      expect(message.encrypted, isTrue);
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
      expect(result.envelope, isNotNull);
      expect(result.envelope!.header.kind, MessageKind.text);
      expect(utf8.decode(result.envelope!.content), 'hello mesh');
      expect(result.relay, isNotNull);
      final relayed = MessageEnvelope.decode(result.relay!);
      expect(relayed.header.ttl, 3);
      expect(relayed.header.hops, 2);
      expect(result.ackMessageId, isNull);
    });

    test('acknowledges a direct message only on the sender link', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(wire(to: alice), viaPeerId: bob);

      expect(result.envelope?.header.to, alice);
      expect(result.ackMessageId, msgId);
      expect(result.relay, isNull);
    });

    test('does not ack a direct message that arrived through a relay', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(
        wire(id: 'bbbbbbbbbbbbbbbb', to: alice),
        viaPeerId: carol,
      );

      expect(result.envelope, isNotNull);
      expect(result.ackMessageId, isNull);
    });

    test('does not relay at the ttl floor', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(wire(ttl: minTtl), viaPeerId: bob);

      expect(result.envelope, isNotNull);
      expect(result.relay, isNull);
    });

    test('drops duplicates and own echoes', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final first = router.receive(wire(), viaPeerId: bob);
      final second = router.receive(wire(), viaPeerId: carol);

      expect(first.duplicate, isFalse);
      expect(second.duplicate, isTrue);
      expect(second.envelope, isNull);

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
      expect(retry.envelope, isNull);
      expect(retry.ackMessageId, msgId);
    });

    test('rejects malformed envelopes', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(Uint8List.fromList([1, 2, 3]));

      expect(result.error, isNotNull);
      expect(result.envelope, isNull);
      expect(result.relay, isNull);
    });

    test('relays a direct message addressed to someone else', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receive(
        wire(id: 'dddddddddddddddd', to: carol),
        viaPeerId: bob,
      );

      expect(result.envelope, isNull);
      expect(result.relay, isNotNull);
      expect(result.ackMessageId, isNull);
    });
  });

  group('blobs', () {
    test('relays a blob chunk with decremented ttl', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final encoded = chunk(ttl: 4, hops: 1).encode();
      final result = router.receiveBlob(encoded);

      expect(result.error, isNull);
      expect(result.duplicate, isFalse);
      expect(result.chunk, isNotNull);
      expect(result.chunk!.key, '0123456789abcdef:deadbeef');
      expect(result.relay, isNotNull);
      final relayed = BlobChunk.decode(result.relay!);
      expect(relayed.ttl, 3);
      expect(relayed.hops, 2);
    });

    test('drops duplicate chunks and respects the ttl floor', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final encoded = chunk(ttl: minTtl).encode();

      final first = router.receiveBlob(encoded);
      final second = router.receiveBlob(encoded);
      expect(first.duplicate, isFalse);
      expect(first.relay, isNull);
      expect(second.duplicate, isTrue);
    });

    test('relays chunks for somebody else without displaying them', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receiveBlob(chunk(to: carol).encode());

      expect(result.chunk!.to, carol);
      expect(result.relay, isNotNull);
    });

    test('rejects damaged chunk envelopes', () {
      final router = MeshRouter(selfId: alice, selfName: 'Alice');
      final result = router.receiveBlob(Uint8List.fromList([1, 2, 3]));
      expect(result.error, isNotNull);
      expect(result.chunk, isNull);
    });
  });
}
