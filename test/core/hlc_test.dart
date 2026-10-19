import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/hlc/hlc.dart';

void main() {
  test('aynı milisaniyede ardışık damgalar sayaçla artar', () {
    final clock = HlcClock('a', now: () => 1000);
    final h1 = clock.tick();
    final h2 = clock.tick();
    expect(h1.millis, 1000);
    expect(h2.millis, 1000);
    expect(h2.counter, h1.counter + 1);
    expect(h2 > h1, isTrue);
  });

  test('cihaz saati geri gitse bile damgalar ileri gider', () {
    var physical = 5000;
    final clock = HlcClock('a', now: () => physical);
    final h1 = clock.tick();
    physical = 3000; // saat geri alındı
    final h2 = clock.tick();
    expect(h2 > h1, isTrue);
  });

  test('ileride olan cihazdan gelen damga yerel saati ileri alır', () {
    final local = HlcClock('a', now: () => 1000);
    final remote = Hlc(9000, 3, 'b');
    local.receive(remote);
    final next = local.tick();
    expect(next > remote, isTrue);
  });

  test('metin hali ile damga sıralaması aynıdır', () {
    final stamps = [
      Hlc(1000, 2, 'b'),
      Hlc(999, 50, 'z'),
      Hlc(1000, 2, 'a'),
      Hlc(1000, 10, 'a'),
      Hlc(20000, 0, 'a'),
    ];
    final byValue = [...stamps]..sort();
    final byText = stamps.map((h) => h.pack()).toList()..sort();
    expect(byText, byValue.map((h) => h.pack()).toList());
  });

  test('pack/parse birebir döner', () {
    final h = Hlc(1760000000000, 1234, 'k7m2x9qa4b');
    expect(Hlc.parse(h.pack()), h);
  });

  test('cihaz kimliği 10 karakter ve ":" içermez', () {
    final id = generateNodeId();
    expect(id.length, 10);
    expect(id.contains(':'), isFalse);
  });
}
