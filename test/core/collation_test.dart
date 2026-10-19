import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/ids.dart';
import 'package:notlar/core/text/turkish_collation.dart';

void main() {
  test('Türk alfabesine göre sıralar', () {
    final words = [
      'Zeytin', 'şeker', 'Su', 'ödev', 'Oda', 'İnce', 'ışık', 'Ilık',
      'çay', 'Cam',
    ]..sort(compareTurkish);
    expect(words, [
      'Cam', 'çay', 'Ilık', 'ışık', 'İnce', 'Oda', 'ödev', 'Su', 'şeker',
      'Zeytin',
    ]);
  });

  test('rakamlar harflerden önce gelir', () {
    final words = ['abc', '2. madde', '10 numara']..sort(compareTurkish);
    expect(words, ['10 numara', '2. madde', 'abc']);
  });

  test('UUIDv7 zaman sırasına göre sıralanır', () {
    final a = uuidV7(millis: 1000);
    final b = uuidV7(millis: 2000);
    expect(a.compareTo(b) < 0, isTrue);
    expect(a[14], '7'); // sürüm hanesi
    expect(RegExp(r'^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$').hasMatch(a),
        isTrue);
  });
}
