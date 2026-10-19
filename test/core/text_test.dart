import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/text/headings.dart';
import 'package:notlar/core/text/search_text.dart';

void main() {
  group('foldForSearch', () {
    test('Türkçe karakterleri sadeleştirir', () {
      expect(foldForSearch('Şifre İŞLEMLERİ'), 'sifre islemleri');
      expect(foldForSearch('Güçlü Öğün Çay'), 'guclu ogun cay');
    });

    test('noktalı ve noktasız i farkı kalkar', () {
      expect(foldForSearch('ıIiİ'), 'iiii');
      expect(foldForSearch('IŞIK'), foldForSearch('ışık'));
    });

    test('ayrışık yazılmış aksanlar temizlenir', () {
      expect(foldForSearch('i\u0307stanbul'), 'istanbul');
    });
  });

  group('buildFtsQuery', () {
    test('her kelime önek araması olur', () {
      expect(buildFtsQuery('Şifre yön'), '"sifre"* "yon"*');
    });

    test('özel karakterler sorguyu bozamaz', () {
      expect(buildFtsQuery('pg_hba.conf "OR" *'), '"pg"* "hba"* "conf"* "or"*');
    });

    test('boş arama null döner', () {
      expect(buildFtsQuery('  -- ** '), isNull);
    });
  });

  test('renk işaretleri temizlenir', () {
    expect(stripInlineMarkup('{kırmızı}önemli{/} not'), 'önemli not');
  });

  group('extractHeadings', () {
    const md = '''
# Kurulum
Giriş metni
## {mavi}Windows{/} adımları ##
```bash
# bu bir yorum, başlık değil
```
### Android
#etiket başlık değil
''';

    test('başlıkları seviye ve satırıyla çıkarır', () {
      final h = extractHeadings(md);
      expect(h.map((e) => e.content), ['Kurulum', 'Windows adımları', 'Android']);
      expect(h.map((e) => e.level), [1, 2, 3]);
      expect(h.map((e) => e.line), [0, 2, 6]);
      expect(h.map((e) => e.position), [0, 1, 2]);
    });
  });
}
