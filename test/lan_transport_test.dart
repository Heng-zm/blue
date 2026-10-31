import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/protocol/frame.dart';
import 'package:mgs/services/lan_transport.dart';

void main() {
  test(
    'two LanTransport nodes connect and exchange frames over localhost',
    () async {
      final alice = LanTransport(
        selfId: '1111111111111111',
        selfName: 'Alice',
        port: 52530,
        autoProbe: false,
      );
      final bob = LanTransport(
        selfId: '2222222222222222',
        selfName: 'Bob',
        port: 52531,
        autoProbe: false,
      );

      final aliceUp = Completer<LanPeerUpEvent>();
      final bobUp = Completer<LanPeerUpEvent>();
      final bobData = Completer<LanDataEvent>();

      alice.events.listen((e) {
        if (e is LanPeerUpEvent && !aliceUp.isCompleted) {
          aliceUp.complete(e);
        }
      });

      bob.events.listen((e) {
        if (e is LanPeerUpEvent && !bobUp.isCompleted) {
          bobUp.complete(e);
        }
        if (e is LanDataEvent && !bobData.isCompleted) {
          bobData.complete(e);
        }
      });

      await alice.start();
      await bob.start();

      // Alice connects directly to Bob's port on loopback
      final connected = await alice.connectTo('127.0.0.1', port: 52531);
      expect(connected, isTrue);

      final aliceEvent = await aliceUp.future.timeout(
        const Duration(seconds: 5),
      );
      final bobEvent = await bobUp.future.timeout(const Duration(seconds: 5));

      expect(aliceEvent.peerId, '2222222222222222');
      expect(aliceEvent.name, 'Bob');
      expect(bobEvent.peerId, '1111111111111111');
      expect(bobEvent.name, 'Alice');

      expect(alice.hasReadyLinks, isTrue);
      expect(bob.hasReadyLinks, isTrue);

      // Alice sends a message payload to Bob
      final testPayload = Uint8List.fromList([42, 43, 44, 45, 46]);
      final sent = alice.sendToPeer(
        '2222222222222222',
        FrameType.message,
        testPayload,
      );
      expect(sent, isTrue);

      final dataEvent = await bobData.future.timeout(
        const Duration(seconds: 5),
      );
      expect(dataEvent.peerId, '1111111111111111');
      expect(dataEvent.type, FrameType.message);
      expect(dataEvent.payload, testPayload);

      await alice.dispose();
      await bob.dispose();

      expect(alice.hasReadyLinks, isFalse);
      expect(bob.hasReadyLinks, isFalse);
    },
  );
}
