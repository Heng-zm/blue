import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/protocol/frame.dart';

Uint8List bytesOf(List<int> values) => Uint8List.fromList(values);

void main() {
  group('Frame', () {
    test('encodes and decodes header fields', () {
      final frame = Frame(
        type: FrameType.message,
        packetId: 0xDEADBEEF,
        chunkIndex: 2,
        chunkCount: 5,
        payload: bytesOf([9, 8, 7]),
      );
      final encoded = frame.encode();
      expect(encoded.length, frameHeaderLength + 3);
      expect(encoded[0], frameVersion);
      expect(encoded[1], FrameType.message.code);
      final view = ByteData.sublistView(encoded);
      expect(view.getUint32(2, Endian.big), 0xDEADBEEF);
      expect(encoded[6], 2);
      expect(encoded[7], 5);

      final decoded = Frame.tryDecode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.type, FrameType.message);
      expect(decoded.packetId, 0xDEADBEEF);
      expect(decoded.chunkIndex, 2);
      expect(decoded.chunkCount, 5);
      expect(decoded.payload, [9, 8, 7]);
    });

    test('rejects malformed frames', () {
      expect(Frame.tryDecode(Uint8List(4)), isNull);

      final good = Frame(
        type: FrameType.ping,
        packetId: 1,
        chunkIndex: 0,
        chunkCount: 1,
        payload: Uint8List(0),
      ).encode();

      final badVersion = Uint8List.fromList(good)..[0] = 2;
      expect(Frame.tryDecode(badVersion), isNull);

      final badType = Uint8List.fromList(good)..[1] = 99;
      expect(Frame.tryDecode(badType), isNull);

      final zeroChunks = Uint8List.fromList(good)..[7] = 0;
      expect(Frame.tryDecode(zeroChunks), isNull);

      final badIndex = Uint8List.fromList(good)..[6] = 1;
      expect(Frame.tryDecode(badIndex), isNull);
    });
  });

  group('buildFrames', () {
    test('chunks payloads and shares one packet id', () {
      final payload = Uint8List.fromList(
        List<int>.generate(55, (index) => index),
      );
      final frames = buildFrames(
        type: FrameType.message,
        payload: payload,
        maxChunkSize: 20,
        random: Random(7),
      );

      expect(frames.length, 3);
      expect(
        frames.every((frame) => frame.packetId == frames.first.packetId),
        isTrue,
      );
      expect(frames.every((frame) => frame.chunkCount == 3), isTrue);
      expect(frames.map((frame) => frame.chunkIndex), [0, 1, 2]);
      expect(frames.every((frame) => frame.payload.length <= 20), isTrue);
    });

    test('reassembles chunks delivered out of order', () {
      final payload = Uint8List.fromList(
        List<int>.generate(95, (index) => (index * 3) % 256),
      );
      final frames = buildFrames(
        type: FrameType.ack,
        payload: payload,
        maxChunkSize: 24,
        random: Random(3),
      );
      final assembler = FrameAssembler();
      Frame? assembled;
      for (final frame in frames.reversed) {
        assembled = assembler.add(frame);
      }

      expect(assembled, isNotNull);
      expect(assembled!.type, FrameType.ack);
      expect(assembled.chunkCount, 1);
      expect(assembled.payload, payload);
      expect(assembler.activeAssemblies, 0);
    });

    test('ignores duplicate chunks', () {
      final payload = Uint8List.fromList(
        List<int>.generate(30, (index) => index),
      );
      final frames = buildFrames(
        type: FrameType.message,
        payload: payload,
        maxChunkSize: 10,
        random: Random(11),
      );
      final assembler = FrameAssembler();

      expect(assembler.add(frames[0]), isNull);
      expect(assembler.add(frames[0]), isNull);
      expect(assembler.add(frames[1]), isNull);
      final assembled = assembler.add(frames[2]);
      expect(assembled?.payload, payload);
    });

    test('rejects payloads beyond protocol limits', () {
      expect(
        () => buildFrames(
          type: FrameType.message,
          payload: Uint8List(maxFramePayloadBytes + 1),
          maxChunkSize: maxChunkPayloadBytes,
        ),
        throwsArgumentError,
      );
      // 300 one-byte chunks exceed the 255-frame ceiling.
      expect(
        () => buildFrames(
          type: FrameType.message,
          payload: Uint8List(300),
          maxChunkSize: 1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('FrameAssembler', () {
    test('drops stale partial assemblies', () {
      final start = DateTime(2026, 1, 1, 12);
      final assembler = FrameAssembler();
      final first = Frame(
        type: FrameType.message,
        packetId: 42,
        chunkIndex: 0,
        chunkCount: 2,
        payload: bytesOf([1]),
      );
      final second = Frame(
        type: FrameType.message,
        packetId: 42,
        chunkIndex: 1,
        chunkCount: 2,
        payload: bytesOf([2]),
      );

      expect(assembler.add(first, now: start), isNull);
      expect(
        assembler.add(second, now: start.add(const Duration(seconds: 26))),
        isNull,
      );
      expect(assembler.activeAssemblies, 1);
    });
  });
}
