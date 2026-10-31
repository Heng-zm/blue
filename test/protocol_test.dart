import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/core/constants.dart';
import 'package:mgs/models/message.dart';
import 'package:mgs/protocol/binary.dart';
import 'package:mgs/protocol/message_codec.dart';

const alice = '1111111111111111';
const bob = '2222222222222222';
const msgId = 'aaaaaaaaaaaaaaaa';

void main() {
  group('ByteWriter and ByteReader', () {
    test('round-trips integers and strings', () {
      final writer = ByteWriter()
        ..u8(0x12)
        ..u16(0x3456)
        ..u32(0x789abcde)
        ..u64(1700000000123)
        ..bytes(<int>[1, 2, 3])
        ..hex8(msgId)
        ..bytes(utf8.encode('mesh'));
      final reader = ByteReader(writer.takeBytes());

      expect(reader.u8(), 0x12);
      expect(reader.u16(), 0x3456);
      expect(reader.u32(), 0x789abcde);
      expect(reader.u64(), 1700000000123);
      expect(reader.take(3), [1, 2, 3]);
      expect(reader.hex8(), msgId);
      expect(reader.utf8String(4), 'mesh');
      expect(reader.isAtEnd, isTrue);
      reader.expectEnd();
    });

    test('rejects truncated payloads', () {
      final reader = ByteReader(Uint8List.fromList([1, 2]));
      expect(() => reader.u32(), throwsFormatException);
      expect(reader.u8(), 1);
      expect(reader.remaining, 1);
      expect(() => reader.take(2), throwsFormatException);
    });

    test('validates integer ranges', () {
      expect(() => ByteWriter().u8(256), throwsArgumentError);
      expect(() => ByteWriter().u16(-1), throwsArgumentError);
      expect(() => ByteWriter().u32(0x100000000), throwsArgumentError);
      expect(() => ByteWriter().u64(-1), throwsArgumentError);
    });
  });

  group('hex helpers', () {
    test('round-trips bytes', () {
      final bytes = Uint8List.fromList([0, 15, 16, 255]);
      expect(hexFromBytes(bytes), '000f10ff');
      expect(bytesFromHex('000f10ff'), bytes);
      expect(bytesFromHex('00ff', byteLength: 2), [0, 255]);
    });

    test('rejects malformed hex', () {
      expect(() => bytesFromHex('abc'), throwsFormatException);
      expect(() => bytesFromHex('zz'), throwsFormatException);
      expect(() => bytesFromHex('00', byteLength: 2), throwsFormatException);
    });

    test('truncates UTF-8 without splitting code points', () {
      expect(truncateUtf8('hello', 10), 'hello');
      expect(truncateUtf8('héllo', 2), 'h');
      expect(truncateUtf8('a😀b', 4), 'a');
      expect(truncateUtf8('a😀b', 5), 'a😀');
    });
  });

  group('MessageEnvelope', () {
    MessageHeader header({
      String to = broadcastRecipient,
      int ttl = 3,
      int hops = 0,
      MessageKind kind = MessageKind.text,
      bool encrypted = false,
    }) => MessageHeader(
      id: msgId,
      from: alice,
      to: to,
      fromName: 'Alice',
      timestampMs: 1700000000000,
      ttl: ttl,
      hops: hops,
      kind: kind,
      encrypted: encrypted,
    );

    test('round-trips text, encryption flags, and broadcast addressing', () {
      final content = Uint8List.fromList(utf8.encode('hello mesh'));
      final envelope = MessageEnvelope.build(
        header(encrypted: true, kind: MessageKind.file),
        content,
      );
      final decoded = MessageEnvelope.decode(envelope.raw);

      expect(decoded.raw[0], protocolVersion);
      expect(decoded.header.id, msgId);
      expect(decoded.header.from, alice);
      expect(decoded.header.to, broadcastRecipient);
      expect(decoded.header.fromName, 'Alice');
      expect(decoded.header.timestampMs, 1700000000000);
      expect(decoded.header.ttl, 3);
      expect(decoded.header.hops, 0);
      expect(decoded.header.kind, MessageKind.file);
      expect(decoded.header.encrypted, isTrue);
      expect(decoded.content, content);
    });

    test('encodes a direct recipient and rejects bad versions', () {
      final envelope = MessageEnvelope.build(
        header(to: bob),
        Uint8List.fromList([1]),
      );
      expect(MessageEnvelope.decode(envelope.raw).header.to, bob);

      final badVersion = Uint8List.fromList(envelope.raw)..[0] = 1;
      expect(() => MessageEnvelope.decode(badVersion), throwsFormatException);

      final trailing = Uint8List.fromList([...envelope.raw, 0]);
      expect(() => MessageEnvelope.decode(trailing), throwsFormatException);
    });

    test('AAD excludes the mutable TTL and hop count', () {
      final first = MessageEnvelope.build(
        header(ttl: 3, hops: 0),
        Uint8List.fromList([9, 9]),
      );
      final second = MessageEnvelope.build(
        header(ttl: 7, hops: 2),
        Uint8List.fromList([9, 9]),
      );
      expect(first.aad, second.aad);
      expect(first.aad, messageAadFor(first.header, first.content.length));
    });

    test('withRouting patches only the counters', () {
      final envelope = MessageEnvelope.build(
        header(ttl: 5, hops: 1),
        Uint8List.fromList(utf8.encode('payload')),
      );
      final patched = MessageEnvelope.decode(
        envelope.withRouting(ttl: 4, hops: 2),
      );
      expect(patched.header.ttl, 4);
      expect(patched.header.hops, 2);
      expect(patched.header.id, msgId);
      expect(utf8.decode(patched.content), 'payload');
      expect(patched.aad, envelope.aad);
    });

    test('validates header fields', () {
      expect(
        () => header(ttl: 0).encode(contentLength: 1),
        throwsArgumentError,
      );
      expect(
        () => header(hops: maxTtl + 1).encode(contentLength: 1),
        throwsArgumentError,
      );
      expect(
        () => header(to: 'not-a-peer').encode(contentLength: 1),
        throwsArgumentError,
      );
    });
  });

  group('MeshHello', () {
    test('round-trips peer identity', () {
      final hello = MeshHello(peerId: alice, name: 'Alice');
      final decoded = MeshHello.decode(hello.encode());
      expect(decoded.peerId, alice);
      expect(decoded.name, 'Alice');
    });

    test('rejects unsupported versions and bad lengths', () {
      final encoded = MeshHello(peerId: alice, name: 'Alice').encode();
      final wrongVersion = Uint8List.fromList(encoded)..[0] = 1;
      expect(() => MeshHello.decode(wrongVersion), throwsFormatException);
      expect(
        () => MeshHello.decode(Uint8List.fromList([...encoded, 0])),
        throwsFormatException,
      );
      expect(
        () => MeshHello.decode(Uint8List.fromList([protocolVersion, 0, 1])),
        throwsFormatException,
      );
    });
  });
}
