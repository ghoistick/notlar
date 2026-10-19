import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Veri anahtarından türetilen alt anahtarların amaçları.
///
/// Her amaç için ayrı anahtar kullanmak, bir alanda yapılan hatanın diğerini
/// etkilemesini önler. Veri anahtarı hiçbir yerde doğrudan kullanılmaz.
abstract final class KeyPurpose {
  static const localDatabase = 'local-db';
  static const sync = 'sync';
  static const backup = 'backup';
}

Future<Uint8List> deriveSubkey(SecretKey dataKey, String purpose) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await hkdf.deriveKey(
    secretKey: dataKey,
    nonce: const <int>[],
    info: utf8.encode('notlar/subkey/$purpose/v1'),
  );
  return Uint8List.fromList(await key.extractBytes());
}
