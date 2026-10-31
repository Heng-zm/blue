import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/models/message.dart';
import 'package:mgs/ui/theme.dart';
import 'package:mgs/ui/widgets/chat_widgets.dart';

const sender = '1111111111111111';

Message message({
  MessageKind kind = MessageKind.text,
  String text = 'hello',
  MessageAttachment? attachment,
  bool decryptionFailed = false,
  bool encrypted = false,
}) => Message(
  id: 'aaaaaaaaaaaaaaaa',
  from: sender,
  fromName: 'Ada',
  to: '*',
  text: text,
  timestampMs: 1700000000000,
  ttl: 3,
  hops: 0,
  outgoing: false,
  status: MessageStatus.received,
  kind: kind,
  attachment: attachment,
  decryptionFailed: decryptionFailed,
  encrypted: encrypted,
  transferProgress: attachment?.available == true ? 1 : 0,
);

MessageAttachment attachment({
  String name = 'photo.jpg',
  String mimeType = 'image/jpeg',
  String? path,
  int durationMs = 0,
}) => MessageAttachment(
  blobId: '0123456789abcdef',
  transferId: 'deadbeef',
  blobNonce: '000102030405060708090a0b',
  name: name,
  mimeType: mimeType,
  size: 1024,
  cipherBytes: 1052,
  chunkCount: 1,
  digest: 'a' * 64,
  durationMs: durationMs,
  path: path,
);

Widget wrap(Widget child) => MaterialApp(
  theme: buildMgsTheme(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('renders a text message with an encryption lock', (tester) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(message: message(text: 'hello mesh', encrypted: true)),
      ),
    );

    expect(find.text('hello mesh'), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsOneWidget);
  });

  testWidgets('renders a locked placeholder', (tester) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: message(text: '', encrypted: true, decryptionFailed: true),
        ),
      ),
    );

    expect(find.text('Encrypted message'), findsOneWidget);
    expect(
      find.text('Set the same mesh passphrase, then ask for a resend.'),
      findsOneWidget,
    );
    expect(find.text('hello'), findsNothing);
  });

  testWidgets('renders a file with its size and pending transfer', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: message(
            kind: MessageKind.file,
            text: '',
            attachment: attachment(),
          ),
        ),
      ),
    );

    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.text('1.0 KB'), findsOneWidget);
    expect(find.text('Waiting for transfer…'), findsOneWidget);
  });

  testWidgets('renders an unavailable voice note without a player', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: message(
            kind: MessageKind.voice,
            text: '',
            attachment: attachment(
              name: 'clip.m4a',
              mimeType: 'audio/mp4',
              durationMs: 4200,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Voice note · 0:04'), findsOneWidget);
  });
}
