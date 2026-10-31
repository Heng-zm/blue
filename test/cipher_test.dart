import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mgs/security/mesh_cipher.dart';

Uint8List bytesOf(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  late MeshCipher cipher;

  setUpAll(() async {
    cipher = await MeshCipher.derive('correct horse battery staple');
  });

  test('round-trips a payload with associated data', () async {
    final aad = bytesOf('header');
    final plain = bytesOf('hello encrypted mesh');
    final encrypted = await cipher.encrypt(plain, aad: aad);

    expect(encrypted.length, plain.length + MeshCipher.overhead);
    expect(encrypted, isNot(plain));
    expect(await cipher.decrypt(encrypted, aad: aad), plain);
  });

  test('rejects a tampered payload', () async {
    final aad = bytesOf('header');
    final encrypted = await cipher.encrypt(bytesOf('secret'), aad: aad);
    final tampered = Uint8List.fromList(encrypted);
    tampered[tampered.length - 1] ^= 0xff;

    expect(
      () => cipher.decrypt(tampered, aad: aad),
      throwsA(isA<MeshDecryptionException>()),
    );
  });

  test('rejects a mismatched associated data value', () async {
    final encrypted = await cipher.encrypt(
      bytesOf('secret'),
      aad: bytesOf('header-a'),
    );
    expect(
      () => cipher.decrypt(encrypted, aad: bytesOf('header-b')),
      throwsA(isA<MeshDecryptionException>()),
    );
  });

  test('rejects the wrong passphrase', () async {
    final other = await MeshCipher.derive('another passphrase entirely');
    final encrypted = await cipher.encrypt(
      bytesOf('secret'),
      aad: bytesOf('x'),
    );
    expect(
      () => other.decrypt(encrypted, aad: bytesOf('x')),
      throwsA(isA<MeshDecryptionException>()),
    );
  });

  test('reuses a supplied nonce deterministically', () async {
    final nonce = Uint8List.fromList(List<int>.generate(12, (i) => i));
    final plain = bytesOf('retry-safe');
    final aad = bytesOf('blob');

    final first = await cipher.encrypt(plain, aad: aad, nonce: nonce);
    final second = await cipher.encrypt(plain, aad: aad, nonce: nonce);
    expect(first, second);
    expect(await cipher.decrypt(second, aad: aad), plain);
  });

  test('rejects a malformed nonce', () async {
    expect(
      () =>
          cipher.encrypt(bytesOf('x'), aad: bytesOf('a'), nonce: Uint8List(8)),
      throwsArgumentError,
    );
  });

  test('rejects fit-for-purpose edge cases', () async {
    final aad = bytesOf('a');
    expect(
      () => cipher.decrypt(Uint8List(4), aad: aad),
      throwsA(isA<MeshDecryptionException>()),
    );
    expect(() => MeshCipher.derive('   '), throwsA(isA<ArgumentError>()));
  });
}
