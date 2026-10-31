import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/core/constants.dart';
import 'package:mgs/models/message.dart';

const sender = '1111111111111111';
const recipient = '2222222222222222';
const msgId = 'aaaaaaaaaaaaaaaa';

Message build({
  String id = msgId,
  String from = sender,
  String fromName = 'Ada',
  String to = broadcastRecipient,
  String text = 'hello',
  int ttl = 3,
  int hops = 0,
  bool outgoing = true,
  MessageStatus status = MessageStatus.queued,
  MessageKind kind = MessageKind.text,
  MessageAttachment? attachment,
  bool encrypted = false,
  bool decryptionFailed = false,
}) {
  return Message(
    id: id,
    from: from,
    fromName: fromName,
    to: to,
    text: text,
    timestampMs: 1700000000000,
    ttl: ttl,
    hops: hops,
    outgoing: outgoing,
    status: status,
    kind: kind,
    attachment: attachment,
    encrypted: encrypted,
    decryptionFailed: decryptionFailed,
  );
}

MessageAttachment attachment({String? path}) => MessageAttachment(
  blobId: '0123456789abcdef',
  transferId: 'deadbeef',
  blobNonce: '000102030405060708090a0b',
  name: 'photo.jpg',
  mimeType: 'image/jpeg',
  size: 1024,
  cipherBytes: 1024 + 28,
  chunkCount: 1,
  digest: 'a' * 64,
  durationMs: 0,
  path: path,
);

void main() {
  test('storage round-trip keeps direction, status, and encryption', () {
    final sent = build(
      status: MessageStatus.delivered,
      encrypted: true,
      text: '  hello there  ',
    );
    final restored = Message.fromStorage(sent.toStorage());
    expect(restored.outgoing, isTrue);
    expect(restored.status, MessageStatus.delivered);
    expect(restored.encrypted, isTrue);
    expect(restored.text, 'hello there');
    expect(restored.kind, MessageKind.text);

    final received = build(outgoing: false, status: MessageStatus.received);
    final restoredIn = Message.fromStorage(received.toStorage());
    expect(restoredIn.outgoing, isFalse);
    expect(restoredIn.status, MessageStatus.received);
  });

  test('storage round-trip keeps attachment descriptors', () {
    final message = build(
      kind: MessageKind.voice,
      text: '',
      attachment: attachment(path: '/tmp/voice.m4a'),
    );
    final restored = Message.fromStorage(message.toStorage());
    expect(restored.kind, MessageKind.voice);
    expect(restored.attachment, isNotNull);
    expect(restored.attachment!.blobId, '0123456789abcdef');
    expect(restored.attachment!.transferId, 'deadbeef');
    expect(restored.attachment!.blobNonce, '000102030405060708090a0b');
    expect(restored.attachment!.path, '/tmp/voice.m4a');
    expect(restored.attachment!.available, isTrue);
    expect(restored.isComplete, isTrue);
  });

  test('legacy v1 storage is migrated', () {
    final legacy = <String, dynamic>{
      'id': msgId,
      'from': sender,
      'name': 'Ada',
      'to': broadcastRecipient,
      'ts': 1700000000000,
      'ttl': 3,
      'hops': 1,
      'text': 'old message',
      'dir': 'in',
      'status': 'received',
    };
    final restored = Message.fromStorage(legacy);
    expect(restored.text, 'old message');
    expect(restored.kind, MessageKind.text);
    expect(restored.outgoing, isFalse);
    expect(restored.encrypted, isFalse);
  });

  test('threads and previews are derived consistently', () {
    expect(build().threadId, broadcastRecipient);
    expect(build(to: recipient).threadId, recipient);
    expect(build(to: recipient, outgoing: false).threadId, sender);

    expect(build(text: 'a\n\n  b\t c').preview, 'a b c');
    final long = build(text: 'y' * 120);
    expect(long.preview.endsWith('…'), isTrue);
    expect(long.preview.length, 91);

    expect(
      build(kind: MessageKind.file, text: '', attachment: attachment()).preview,
      'Photo · photo.jpg',
    );
    expect(
      build(
        kind: MessageKind.file,
        text: '',
        attachment: MessageAttachment(
          blobId: '0123456789abcdef',
          transferId: 'deadbeef',
          blobNonce: '000102030405060708090a0b',
          name: 'doc.pdf',
          mimeType: 'application/pdf',
          size: 1024,
          cipherBytes: 1024 + 28,
          chunkCount: 1,
          digest: 'a' * 64,
        ),
      ).preview,
      'File · doc.pdf',
    );
    expect(
      build(
        kind: MessageKind.voice,
        text: '',
        attachment: attachment(),
      ).preview,
      contains('Voice message'),
    );
  });

  test('locked placeholders stay readable after storage', () {
    final locked = build(
      kind: MessageKind.file,
      text: '',
      encrypted: true,
      decryptionFailed: true,
      outgoing: false,
      status: MessageStatus.received,
    );
    final restored = Message.fromStorage(locked.toStorage());
    expect(restored.decryptionFailed, isTrue);
    expect(restored.attachment, isNull);
    expect(restored.isComplete, isTrue);
    expect(restored.preview, 'Encrypted message');
  });

  test('rejects invalid stored messages', () {
    final valid = build().toStorage();
    expect(
      () => Message.fromStorage({...valid, 'v': protocolVersion + 1}),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({...valid, 'kind': 'image'}),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({...valid, 'from': 'nope'}),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({...valid, 'ttl': 0}),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({...valid, 'ttl': maxTtl + 1}),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({...valid, 'hops': -1}),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({...valid, 'text': '   '}),
      throwsFormatException,
    );
    expect(
      () =>
          Message.fromStorage({...valid, 'text': 'x' * (maxMessageLength + 1)}),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({
        ...valid,
        'name': 'n' * (maxDisplayNameLength + 1),
      }),
      throwsFormatException,
    );
  });

  test('rejects damaged attachment descriptors', () {
    final message = build(
      kind: MessageKind.file,
      text: '',
      attachment: attachment(),
    );
    final storage = message.toStorage();
    final raw = Map<String, dynamic>.from(storage['attachment'] as Map);
    expect(
      () => Message.fromStorage({...storage, 'attachment': raw}),
      returnsNormally,
    );
    expect(
      () => Message.fromStorage({
        ...storage,
        'attachment': {...raw, 'blobId': 'nope'},
      }),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({
        ...storage,
        'attachment': {...raw, 'digest': 'nope'},
      }),
      throwsFormatException,
    );
    expect(
      () => Message.fromStorage({...storage, 'attachment': null}),
      throwsFormatException,
    );
  });

  test('accepts a maximum-length body', () {
    final text = 'z' * maxMessageLength;
    final restored = Message.fromStorage({
      ...build().toStorage(),
      'text': text,
    });
    expect(restored.text.length, maxMessageLength);
  });
}
