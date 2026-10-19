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
