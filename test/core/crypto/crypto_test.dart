import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/crypto/blob_cipher.dart';
import 'package:notlar/core/crypto/key_manager.dart';
import 'package:notlar/core/crypto/keyring.dart';

void main() {
  group('BlobCipher', () {
    final cipher = BlobCipher();
    final key = SecretKey(List.generate(32, (i) => i));
    final plain = utf8.encode('Gizli not: şifre ğüşıöç');

    test('şifreleyip geri çözer', () async {
      final blob = await cipher.encrypt(key, plain);
      final back = await cipher.decrypt(key, blob);
      expect(utf8.decode(back), 'Gizli not: şifre ğüşıöç');
    });

    test('aynı veri her seferinde farklı şifrelenir', () async {
      final a = await cipher.encrypt(key, plain);
      final b = await cipher.encrypt(key, plain);
      expect(a, isNot(equals(b)));
    });

    test('değiştirilmiş veri reddedilir', () async {
      final blob = await cipher.encrypt(key, plain);
      blob[blob.length ~/ 2] ^= 0x01;
      expect(
        () => cipher.decrypt(key, blob),
        throwsA(isA<DecryptionFailedException>()),
      );
    });

    test('yanlış anahtar reddedilir', () async {
      final blob = await cipher.encrypt(key, plain);
      final other = SecretKey(List.filled(32, 7));
      expect(
        () => cipher.decrypt(other, blob),
        throwsA(isA<DecryptionFailedException>()),
      );
    });

    test('farklı AAD ile çözülemez (not yer değiştirme koruması)', () async {
      final blob =
          await cipher.encrypt(key, plain, aad: utf8.encode('note:1'));
      expect(
        () => cipher.decrypt(key, blob, aad: utf8.encode('note:2')),
        throwsA(isA<DecryptionFailedException>()),
      );
    });
  });

  group('KeyManager', () {
    final km = KeyManager(kdfSettings: KdfSettings.fastForTests);

    test('kurulum sonrası parola ile aynı veri anahtarı açılır', () async {
      final setup = await km.setup('Güçlü-Parola-123');
      final unlocked =
          await km.unlockWithPassword(setup.keyring, 'Güçlü-Parola-123');
      expect(
        await unlocked.extractBytes(),
        await setup.dataKey.extractBytes(),
      );
    });

    test('yanlış parola reddedilir', () async {
      final setup = await km.setup('dogru');
      expect(
        () => km.unlockWithPassword(setup.keyring, 'yanlis'),
        throwsA(isA<WrongPasswordException>()),
      );
    });

    test('kurtarma anahtarı formatı: 8 grup x 4 karakter', () async {
      final setup = await km.setup('parola');
      expect(
        setup.recoveryKey,
        matches(RegExp(r'^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$')),
      );
    });

    test('kurtarma anahtarı küçük harf ve tiresiz de çalışır', () async {
      final setup = await km.setup('parola');
      final loose = setup.recoveryKey.replaceAll('-', '').toLowerCase();
      final unlocked = await km.unlockWithRecoveryKey(setup.keyring, loose);
      expect(
        await unlocked.extractBytes(),
        await setup.dataKey.extractBytes(),
      );
    });

    test('yanlış kurtarma anahtarı reddedilir', () async {
      final setup = await km.setup('parola');
      final other = await km.setup('parola');
      expect(
        () => km.unlockWithRecoveryKey(setup.keyring, other.recoveryKey),
        throwsA(isA<InvalidRecoveryKeyException>()),
      );
      expect(
        () => km.unlockWithRecoveryKey(setup.keyring, 'kisa'),
        throwsA(isA<InvalidRecoveryKeyException>()),
      );
    });

    test('parola değişimi: eski reddedilir, yeni çalışır, veri anahtarı aynı',
        () async {
      final setup = await km.setup('eski-parola');
      final updated =
          await km.changePassword(setup.keyring, setup.dataKey, 'yeni-parola');

      expect(
        () => km.unlockWithPassword(updated, 'eski-parola'),
        throwsA(isA<WrongPasswordException>()),
      );
      final unlocked = await km.unlockWithPassword(updated, 'yeni-parola');
      expect(
        await unlocked.extractBytes(),
        await setup.dataKey.extractBytes(),
      );

      // Kurtarma anahtarı parola değişiminden etkilenmez.
      final viaRecovery =
          await km.unlockWithRecoveryKey(updated, setup.recoveryKey);
      expect(
        await viaRecovery.extractBytes(),
        await setup.dataKey.extractBytes(),
      );
    });

    test('keyring dosyaya yazılıp okunduktan sonra da açılır', () async {
      final setup = await km.setup('parola');
      final restored = Keyring.decode(setup.keyring.encode());
      final unlocked = await km.unlockWithPassword(restored, 'parola');
      expect(
        await unlocked.extractBytes(),
        await setup.dataKey.extractBytes(),
      );
    });
  });

  test(
    'ÖLÇÜM: üretim ayarlarıyla Argon2id süresi',
    () async {
      final km = KeyManager();
      final sw = Stopwatch()..start();
      final setup = await km.setup('olcum-parolasi');
      final setupMs = sw.elapsedMilliseconds;
      sw.reset();
      await km.unlockWithPassword(setup.keyring, 'olcum-parolasi');
      // ignore: avoid_print
      print('Kurulum: $setupMs ms, kilit açma: ${sw.elapsedMilliseconds} ms');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
