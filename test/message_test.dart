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
  );
}

void main() {
  test('wire round-trip keeps the visible fields', () {
    final message = build(text: '  hello there  ');
    final wire = message.toWire();

    expect(wire['v'], protocolVersion);
    expect(wire['kind'], 'text');
    expect(wire.containsKey('dir'), isFalse);
    expect(wire.containsKey('status'), isFalse);

    final decoded = Message.fromWire(wire);
    expect(decoded.id, message.id);
    expect(decoded.text, 'hello there');
    expect(decoded.from, sender);
    expect(decoded.fromName, 'Ada');
    expect(decoded.to, broadcastRecipient);
    expect(decoded.ttl, 3);
    expect(decoded.outgoing, isFalse);
    expect(decoded.status, MessageStatus.received);
  });

  test('threads and previews are derived consistently', () {
    expect(build().threadId, broadcastRecipient);
    expect(build(to: recipient).threadId, recipient);
    expect(build(to: recipient, outgoing: false).threadId, sender);

    expect(build(text: 'a\n\n  b\t c').preview, 'a b c');
    final long = build(text: 'y' * 120);
    expect(long.preview.endsWith('…'), isTrue);
    expect(long.preview.length, 91);
  });

  test('storage round-trip restores direction and status', () {
    final sent = build(status: MessageStatus.delivered);
    final restored = Message.fromStorage(sent.toStorage());
    expect(restored.outgoing, isTrue);
    expect(restored.status, MessageStatus.delivered);

    final received = build(outgoing: false, status: MessageStatus.received);
    final restoredIn = Message.fromStorage(received.toStorage());
    expect(restoredIn.outgoing, isFalse);
    expect(restoredIn.status, MessageStatus.received);
  });

  test('rejects invalid envelopes', () {
    Map<String, dynamic> valid() => build().toWire();

    expect(() => Message.fromWire({...valid(), 'v': 2}), throwsFormatException);
    expect(
      () => Message.fromWire({...valid(), 'kind': 'image'}),
      throwsFormatException,
    );
    expect(
      () => Message.fromWire({...valid(), 'from': 'nope'}),
      throwsFormatException,
    );
    expect(
      () => Message.fromWire({...valid(), 'ttl': 0}),
      throwsFormatException,
    );
    expect(
      () => Message.fromWire({...valid(), 'ttl': maxTtl + 1}),
      throwsFormatException,
    );
    expect(
      () => Message.fromWire({...valid(), 'hops': -1}),
      throwsFormatException,
    );
    expect(
      () => Message.fromWire({...valid(), 'text': '   '}),
      throwsFormatException,
    );
    expect(
      () =>
          Message.fromWire({...valid(), 'text': 'x' * (maxMessageLength + 1)}),
      throwsFormatException,
    );
    expect(
      () => Message.fromWire({
        ...valid(),
        'name': 'n' * (maxDisplayNameLength + 1),
      }),
      throwsFormatException,
    );
  });

  test('accepts a maximum-length body', () {
    final text = 'z' * maxMessageLength;
    final decoded = Message.fromWire({...build().toWire(), 'text': text});
    expect(decoded.text.length, maxMessageLength);
  });
}
