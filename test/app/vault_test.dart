import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/app/vault.dart';
import 'package:notlar/core/crypto/key_manager.dart';
import 'package:notlar/core/crypto/keyring.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('vault_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  Vault newVault() => Vault(baseDir: dir, kdfSettings: KdfSettings.fastForTests);

  test('kurulum, kilitleme ve yeniden açma; notlar kalıcı', () async {
    final v = newVault();
    expect(await v.isInitialized(), isFalse);

    final recoveryKey = await v.create('parola-123');
    expect(recoveryKey, isNotEmpty);
    final id = await v.repository.createNote(title: 'kalıcı not');
    await v.lock();
    expect(v.isUnlocked, isFalse);

    // Uygulama yeniden başlatılmış gibi yeni bir kasa nesnesiyle aç.
    final v2 = newVault();
    expect(await v2.isInitialized(), isTrue);
    await v2.unlock('parola-123');
    expect((await v2.repository.getNote(id))!.title, 'kalıcı not');
    await v2.lock();
  });

  test('yanlış parola reddedilir', () async {
    final v = newVault();
    await v.create('dogru-parola');
    await v.lock();

    await expectLater(
        v.unlock('yanlis-parola'), throwsA(isA<WrongPasswordException>()));
    expect(v.isUnlocked, isFalse);
  });

  test('kurtarma anahtarıyla parola sıfırlama', () async {
    final v = newVault();
    final recoveryKey = await v.create('eski-parola');
    final id = await v.repository.createNote(title: 'kaybolmasın');
    await v.lock();

    await v.resetPasswordWithRecoveryKey(recoveryKey, 'yeni-parola');
    expect(await v.repository.getNote(id), isNotNull);
    await v.lock();

    await expectLater(
        v.unlock('eski-parola'), throwsA(isA<WrongPasswordException>()));
    await v.unlock('yeni-parola');
    expect(await v.repository.getNote(id), isNotNull);
    await v.lock();
  });

  group('başka cihazdaki kasaya katılma', () {
    late Directory dir2;
    setUp(() => dir2 = Directory.systemTemp.createTempSync('vault_test2'));
    tearDown(() => dir2.deleteSync(recursive: true));

    Vault secondDevice() =>
        Vault(baseDir: dir2, kdfSettings: KdfSettings.fastForTests);

    test('aynı anahtar dosyası ve parolayla aynı veri anahtarına ulaşılır',
        () async {
      final first = newVault();
      await first.create('ortak-parola');
      final keyring = await first.keyringBytes();
      final idFirst = await first.subkey('vault-id');

      final second = secondDevice();
      await second.join(keyring, 'ortak-parola');
      expect(await second.subkey('vault-id'), idFirst);
      expect(await second.isInitialized(), isTrue);

      // Katıldıktan sonra kendi başına da aynı parolayla açılır.
      await second.lock();
      await second.unlock('ortak-parola');
      expect(second.isUnlocked, isTrue);
      await second.lock();
      await first.lock();
    });

    test('yanlış parolada diske hiçbir şey yazılmaz', () async {
      final first = newVault();
      await first.create('ortak-parola');
      final keyring = await first.keyringBytes();
      await first.lock();

      final second = secondDevice();
      await expectLater(
          second.join(keyring, 'yanlis-parola'), throwsA(isA<WrongPasswordException>()));
      expect(await second.isInitialized(), isFalse);
    });

    test('kasası olan cihaz katılamaz', () async {
      final first = newVault();
      await first.create('ortak-parola');
      final keyring = await first.keyringBytes();
      await first.lock();

      await expectLater(first.join(keyring, 'ortak-parola'), throwsStateError);
    });
  });

  test('geçersiz kurtarma anahtarı reddedilir', () async {
    final v = newVault();
    await v.create('parola-123');
    await v.lock();

    await expectLater(
      v.resetPasswordWithRecoveryKey('AAAA-BBBB', 'yeni-parola'),
      throwsA(isA<InvalidRecoveryKeyException>()),
    );
  });
}
