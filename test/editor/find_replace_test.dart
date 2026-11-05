import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/ui/editor/markdown_controller.dart';

List<String> _found(String text, String query, [FindOptions o = const FindOptions()]) =>
    [
      for (final r in MarkdownEditingController.findAll(text, query, o))
        text.substring(r.start, r.end),
    ];

void main() {
  group('findAll seçenekleri', () {
    test('seçeneksiz: harf ve Türkçe karakter farkı gözetilmez', () {
      expect(_found('Şifre şifre', 'şifre'), ['Şifre', 'şifre']);
    });

    test('Aa: harf duyarlı', () {
      expect(_found('Şifre şifre', 'şifre', const FindOptions(matchCase: true)),
          ['şifre']);
    });

    test('ab: tam kelime, Türkçe harfler kelimenin parçası sayılır', () {
      const o = FindOptions(wholeWord: true);
      final text = 'şifre şifreli öşifre (şifre)';
      final r = MarkdownEditingController.findAll(text, 'şifre', o);
      expect(r.map((m) => m.start), [0, 22]);
    });

    test('.*: düzenli ifade, harf duyarsız varsayılan', () {
      expect(_found('Ad1 ad2 x', r'ad\d', const FindOptions(regex: true)),
          ['Ad1', 'ad2']);
      expect(
          _found('Ad1 ad2', r'ad\d',
              const FindOptions(regex: true, matchCase: true)),
          ['ad2']);
    });

    test('.*: boş eşleşmeler atlanır', () {
      expect(_found('bab', 'a*', const FindOptions(regex: true)), ['a']);
    });

    test('.*: geçersiz ifade FormatException fırlatır', () {
      expect(
          () => MarkdownEditingController.findAll(
              'a', '(', const FindOptions(regex: true)),
          throwsFormatException);
    });

    test('.* + ab birlikte', () {
      expect(
          _found('kod kodlar kod', 'ko.',
              const FindOptions(regex: true, wholeWord: true)),
          ['kod', 'kod']);
    });
  });

  group('değiştirme metni', () {
    test(r'gruplar, $& ve $$', () {
      const o = FindOptions(regex: true);
      const text = 'ad_1, soyad_2';
      final ranges =
          MarkdownEditingController.findAll(text, r'(\w+)_(\d)', o);
      expect(
          MarkdownEditingController.replacementsFor(
              text, ranges, r'(\w+)_(\d)', r'$2-$1 [$&] $$', o),
          ['1-ad [ad_1] \$', '2-soyad [soyad_2] \$']);
    });

    test('olmayan grup olduğu gibi kalır', () {
      final m = RegExp(r'(a)').firstMatch('a')!;
      expect(MarkdownEditingController.expandReplacement(m, r'$1$5$'),
          r'a$5$');
    });

    test('düz aramada değiştirme metni yorumlanmaz', () {
      const text = 'a a';
      final ranges = MarkdownEditingController.findAll(text, 'a');
      expect(
          MarkdownEditingController.replacementsFor(
              text, ranges, 'a', r'$1', const FindOptions()),
          [r'$1', r'$1']);
    });
  });

  group('replaceRanges', () {
    test('hepsi tek düzenlemede, imleç son değişikliğin sonunda', () {
      final c = MarkdownEditingController(text: 'a b a c');
      final ranges = MarkdownEditingController.findAll(c.text, 'a');
      var notified = 0;
      c.addListener(() => notified++);
      c.replaceRanges(ranges, ['xy', 'xy']);
      expect(c.text, 'xy b xy c');
      expect(c.selection, const TextSelection.collapsed(offset: 7));
      expect(notified, 1);
    });

    test('tek eşleşme', () {
      final c = MarkdownEditingController(text: 'bir iki üç');
      c.replaceRanges([const TextRange(start: 4, end: 7)], ['İKİ']);
      expect(c.text, 'bir İKİ üç');
    });
  });
}
