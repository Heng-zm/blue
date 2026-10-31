import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/core/constants.dart';
import 'package:mgs/models/message.dart';
import 'package:mgs/protocol/blob_codec.dart';

const blobId = '0123456789abcdef';
const transferId = 'deadbeef';
const nonce = '000102030405060708090a0b';

void main() {
  group('BlobChunk', () {
    test('encodes and decodes a chunk', () {
      final data = Uint8List.fromList(List<int>.generate(64, (i) => i));
      final chunk = BlobChunk(
        blobId: blobId,
        transferId: transferId,
        to: broadcastRecipient,
        index: 3,
        count: 9,
        totalLength: 4096,
        ttl: 4,
        hops: 2,
        data: data,
      );
      final encoded = chunk.encode();
      expect(encoded.length, blobHeaderLength + data.length);
      expect(encoded[0], protocolVersion);

      final decoded = BlobChunk.decode(encoded);
      expect(decoded.blobId, blobId);
      expect(decoded.transferId, transferId);
      expect(decoded.to, broadcastRecipient);
      expect(decoded.index, 3);
      expect(decoded.count, 9);
      expect(decoded.totalLength, 4096);
      expect(decoded.ttl, 4);
      expect(decoded.hops, 2);
      expect(decoded.data, data);
      expect(decoded.key, '$blobId:$transferId');
    });

    test('encodes a direct recipient', () {
      final chunk = BlobChunk(
        blobId: blobId,
        transferId: transferId,
        to: '1111111111111111',
        index: 0,
        count: 1,
        totalLength: 10,
        ttl: 3,
        hops: 0,
        data: Uint8List(10),
      );
      expect(BlobChunk.decode(chunk.encode()).to, '1111111111111111');
    });

    test('withRouting patches the counters and preserves data', () {
      final chunk = BlobChunk(
        blobId: blobId,
        transferId: transferId,
        to: broadcastRecipient,
        index: 0,
        count: 1,
        totalLength: 4,
        ttl: 5,
        hops: 1,
        data: Uint8List.fromList([1, 2, 3, 4]),
      );
      final patched = BlobChunk.decode(chunk.withRouting(ttl: 4, hops: 2));
      expect(patched.ttl, 4);
      expect(patched.hops, 2);
      expect(patched.data, [1, 2, 3, 4]);
    });

    test('rejects damaged chunks', () {
      final chunk = BlobChunk(
        blobId: blobId,
        transferId: transferId,
        to: broadcastRecipient,
        index: 0,
        count: 1,
        totalLength: 4,
        ttl: 3,
        hops: 0,
        data: Uint8List(4),
      );
      final encoded = chunk.encode();

      final wrongVersion = Uint8List.fromList(encoded)..[0] = 1;
      expect(BlobChunk.tryDecode(wrongVersion), isNull);

      final wrongFlags = Uint8List.fromList(encoded)..[1] = 1;
      expect(BlobChunk.tryDecode(wrongFlags), isNull);

      expect(BlobChunk.tryDecode(Uint8List.fromList([1, 2, 3])), isNull);
      expect(BlobChunk.tryDecode(Uint8List(blobHeaderLength)), isNull);
    });

    test('validates chunk ranges and sizes', () {
      expect(
        () => BlobChunk(
          blobId: blobId,
          transferId: transferId,
          to: broadcastRecipient,
          index: 2,
          count: 2,
          totalLength: 4,
          ttl: 3,
          hops: 0,
          data: Uint8List(4),
        ).encode(),
        throwsArgumentError,
      );
      expect(
        () => BlobChunk(
          blobId: blobId,
          transferId: transferId,
          to: broadcastRecipient,
          index: 0,
          count: 1,
          totalLength: 4,
          ttl: 3,
          hops: 0,
          data: Uint8List(blobChunkPayloadBytes + 1),
        ).encode(),
        throwsArgumentError,
      );
    });
  });

  group('BlobMetadata', () {
    BlobMetadata metadata({int durationMs = 0}) => BlobMetadata(
      kind: durationMs > 0 ? MessageKind.voice : MessageKind.file,
      blobId: blobId,
      transferId: transferId,
      blobNonce: nonce,
      name: 'clip.m4a',
      mimeType: 'audio/mp4',
      size: 1000,
      cipherBytes: 1028,
      chunkCount: 1,
      digest: 'c' * 64,
      durationMs: durationMs,
    );

    test('round-trips a file descriptor', () {
      final decoded = BlobMetadata.decode(metadata().encode());
      expect(decoded.kind, MessageKind.file);
      expect(decoded.blobId, blobId);
      expect(decoded.transferId, transferId);
      expect(decoded.blobNonce, nonce);
      expect(decoded.name, 'clip.m4a');
      expect(decoded.mimeType, 'audio/mp4');
      expect(decoded.size, 1000);
      expect(decoded.cipherBytes, 1028);
      expect(decoded.chunkCount, 1);
      expect(decoded.digest, 'c' * 64);
      expect(decoded.durationMs, 0);
    });

    test('round-trips a voice duration', () {
      final decoded = BlobMetadata.decode(metadata(durationMs: 4200).encode());
      expect(decoded.kind, MessageKind.voice);
      expect(decoded.durationMs, 4200);
    });

    test('converts to an attachment', () {
      final attachment = metadata().toAttachment(path: '/tmp/clip.m4a');
      expect(attachment.blobId, blobId);
      expect(attachment.blobNonce, nonce);
      expect(attachment.path, '/tmp/clip.m4a');
      expect(attachment.available, isTrue);
    });

    test('rejects invalid metadata', () {
      expect(
        () => BlobMetadata(
          kind: MessageKind.text,
          blobId: blobId,
          transferId: transferId,
          blobNonce: nonce,
          name: 'x',
          mimeType: 'text/plain',
          size: 1,
          cipherBytes: 1,
          chunkCount: 1,
          digest: 'd' * 64,
        ).encode(),
        throwsArgumentError,
      );
      expect(() => metadata().toAttachment().copyWith(), returnsNormally);
      expect(
        () => BlobMetadata.decode(Uint8List.fromList([3])),
        throwsFormatException,
      );
    });
  });

  group('blob helpers', () {
    test('AAD binds the blob and transfer ids', () {
      final aad = blobAad(blobId, transferId);
      expect(aad, blobAad(blobId, transferId));
      expect(aad, isNot(blobAad(blobId, 'cafebabe')));
      expect(aad, isNot(blobAad('fedcba9876543210', transferId)));
    });

    test('chunk count covers the ciphertext exactly', () {
      expect(blobChunkCount(1), 1);
      expect(blobChunkCount(blobChunkPayloadBytes), 1);
      expect(blobChunkCount(blobChunkPayloadBytes + 1), 2);
      expect(blobChunkCount(maxBlobCipherBytes), maxBlobChunks);
    });
  });
}
