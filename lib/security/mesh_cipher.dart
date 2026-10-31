import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM with a key derived from the shared mesh passphrase.
///
/// The KDF salt is a fixed protocol constant. It does not need to be secret;
/// using a fixed salt lets both sides derive the same key without putting a
/// new salt in every packet. The passphrase must still be strong: anyone who
/// captures traffic can mount an offline guessing attack against it.
class MeshCipher {
  MeshCipher._(this._key, this.passphrase);

  static const int nonceLength = 12;
  static const int macLength = 16;
  static const int overhead = nonceLength + macLength;
  static const int kdfIterations = 120000;

  static final AesGcm _aes = AesGcm.with256bits();
  static final Uint8List _salt = Uint8List.fromList(
    utf8.encode('MGS mesh encryption v2 / PBKDF2-HMAC-SHA256'),
  );

  final SecretKey _key;
  final String passphrase;

  static Future<MeshCipher> derive(String passphrase) async {
    if (passphrase.trim().isEmpty) {
      throw ArgumentError('The mesh passphrase is empty.');
    }
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: kdfIterations,
      bits: 256,
    );

    final key = await kdf.deriveKeyFromPassword(
      password: passphrase,
      nonce: _salt,
    );
    return MeshCipher._(key, passphrase);
  }

  Future<Uint8List> encrypt(
    Uint8List plaintext, {
    required Uint8List aad,
    Uint8List? nonce,
  }) async {
    if (nonce != null && nonce.length != nonceLength) {
      throw ArgumentError.value(nonce, 'nonce', 'Expected $nonceLength bytes');
    }
    final box = await _aes.encrypt(
      plaintext,
      secretKey: _key,
      nonce: nonce ?? _aes.newNonce(),
      aad: aad,
    );
    return box.concatenation();
  }

  Future<Uint8List> decrypt(Uint8List payload, {required Uint8List aad}) async {
    if (payload.length < overhead) {
      throw const MeshDecryptionException('Encrypted payload is truncated.');
    }
    try {
      final box = SecretBox.fromConcatenation(
        payload,
        nonceLength: nonceLength,
        macLength: macLength,
      );
      final clear = await _aes.decrypt(box, secretKey: _key, aad: aad);
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const MeshDecryptionException(
        'Wrong mesh passphrase or corrupted payload.',
      );
    } on FormatException {
      throw const MeshDecryptionException('Encrypted payload is malformed.');
    }
  }
}

class MeshDecryptionException implements Exception {
  const MeshDecryptionException(this.message);

  final String message;

  @override
  String toString() => message;
}
