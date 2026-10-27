import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/app/quick_unlock.dart';
import 'package:notlar/core/crypto/keyring.dart';

void main() {
  late Directory dir;
  late MemorySecretStore store;
  var now = DateTime(2026, 10, 22, 9);
  final dataKey = Uint8List.fromList(List.generate(32, (i) => i * 3));

  QuickUnlock quick() => QuickUnlock(
        store: store,
        baseDir: dir,
        kdf: KdfSettings.fastForTests,
        now: () => now,
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('quick_test');
    store = MemorySecretStore();
    now = DateTime(2026, 10, 22, 9);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('doğru PIN veri anahtarını açar', () async {
    final q = quick();
    await q.enable(dataKey: dataKey, pin: '482916');
    expect(await q.unlockWithPin('482916'), dataKey);
  });

  test('yanlış PIN sayılır; doğru PIN sayacı sıfırlar', () async {
    final q = quick();
    await q.enable(dataKey: dataKey, pin: '482916');

    await expectLater(q.unlockWithPin('111111'),
        throwsA(isA<WrongPinException>().having((e) => e.attemptsLeft, 'kalan', 4)));
    await expectLater(q.unlockWithPin('222222'),
        throwsA(isA<WrongPinException>().having((e) => e.attemptsLeft, 'kalan', 3)));

    await q.unlockWithPin('482916');
    expect((await q.state())!.attemptsLeft, QuickUnlock.maxAttempts);
  });

  test('beşinci yanlış denemede hızlı kilit açma tamamen silinir', () async {
    final q = quick();
    await q.enable(dataKey: dataKey, pin: '482916');
    for (var i = 0; i < QuickUnlock.maxAttempts - 1; i++) {
      await expectLater(q.unlockWithPin('000000'), throwsA(isA<WrongPinException>()));
    }
    await expectLater(q.unlockWithPin('000000'),
        throwsA(isA<WrongPinException>().having((e) => e.attemptsLeft, 'kalan', 0)));

    expect(await q.state(), isNull);
    expect(store.values, isEmpty, reason: 'Cihaz sırrı da silinmeli');
    await expectLater(q.unlockWithPin('482916'), throwsA(isA<QuickUnlockUnavailable>()));
  });

  test('cihaz sırrı olmadan dosya tek başına işe yaramaz', () async {
    final q = quick();
    await q.enable(dataKey: dataKey, pin: '482916');
    store.values.clear(); // ör. dosya başka bir cihaza kopyalandı

    await expectLater(q.unlockWithPin('482916'), throwsA(isA<QuickUnlockUnavailable>()));
    expect(await q.state(), isNull);
  });

  test('parmak izi yolu ayrı açılıp kapatılabilir', () async {
    final q = quick();
    await q.enable(dataKey: dataKey, pin: '482916');
    await expectLater(q.unlockWithBiometric(), throwsA(isA<QuickUnlockUnavailable>()));

    await q.setBiometric(true, dataKey);
    expect((await q.state())!.biometric, isTrue);
    expect(await q.unlockWithBiometric(), dataKey);

    await q.setBiometric(false, dataKey);
    await expectLater(q.unlockWithBiometric(), throwsA(isA<QuickUnlockUnavailable>()));
    expect(await q.unlockWithPin('482916'), dataKey, reason: 'PIN etkilenmez');
  });

  test('14 gün sonra ana parola istenir; parola kullanılınca süre yenilenir', () async {
    final q = quick();
    await q.enable(dataKey: dataKey, pin: '482916');
    expect((await q.state())!.passwordDue(now), isFalse);

    now = now.add(const Duration(days: 14));
    expect((await q.state())!.passwordDue(now), isTrue);

    await q.notePasswordUsed();
    expect((await q.state())!.passwordDue(now), isFalse);
  });

  test('PIN kuralları', () {
    expect(QuickUnlock.isValidPin('1234'), isTrue);
    expect(QuickUnlock.isValidPin('12345678'), isTrue);
    expect(QuickUnlock.isValidPin('123'), isFalse);
    expect(QuickUnlock.isValidPin('123456789'), isFalse);
    expect(QuickUnlock.isValidPin('12a4'), isFalse);
  });
}
