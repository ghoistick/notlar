import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/text/search_text.dart';
import 'package:notlar/ui/editor/markdown_controller.dart';

// Satırlar:     0      1    2       3    4      5
const doc = '# A\na1\n## B\nb1\n# C\nc1';

MarkdownEditingController ctl(int caret) => MarkdownEditingController(text: doc)
  ..selection = TextSelection.collapsed(offset: caret);

void main() {
  group('başlıklar', () {
    test('seviye, satır ve bölüm sonu', () {
      final refs = ctl(0).headingRefs();
      expect(refs.map((r) => r.title), ['A', 'B', 'C']);
      expect(refs.map((r) => r.lineIndex), [0, 2, 4]);
      expect(refs.map((r) => r.sectionEnd), [4, 4, 6]);
      expect(refs.every((r) => r.foldable), isTrue);
    });

    test('aynı başlık iki kez geçerse anahtarlar ayrışır', () {
      final c = MarkdownEditingController(text: '# X\na\n# X\nb');
      expect(c.headingRefs().map((r) => r.key), ['1|X|1', '1|X|2']);
    });
  });

  group('katlama', () {
    test('üst başlık katlanınca alt bölümler de gizlenir', () {
      final c = ctl(0)..toggleFold('1|A|1');
      expect(c.hiddenLineIndices(), {1, 2, 3});
      c.toggleFold('1|A|1');
      expect(c.hiddenLineIndices(), isEmpty);
    });

    test('imleç katlanan bölümdeyse başlık satırına taşınır', () {
      final c = ctl(13)..toggleFold('1|A|1'); // imleç "b1" satırında
      expect(c.isFolded('1|A|1'), isTrue);
      expect(c.selection.baseOffset, 3);
    });

    test('seçim gizli satıra girerse bölüm otomatik açılır', () {
      final c = ctl(0)..toggleFold('1|A|1');
      c.selection = const TextSelection.collapsed(offset: 5); // "a1"
      expect(c.isFolded('1|A|1'), isFalse);
    });

    test('Ctrl+. en içteki bölümü katlar', () {
      final c = ctl(13)..toggleFoldAtCaret();
      expect(c.isFolded('2|B|1'), isTrue);
      expect(c.hiddenLineIndices(), {3});
      expect(c.selection.baseOffset, 11);
    });

    test('tümünü daralt / genişlet', () {
      final c = ctl(0)..foldAll();
      expect(c.hiddenLineIndices(), {1, 2, 3, 5});
      c.unfoldAll();
      expect(c.hiddenLineIndices(), isEmpty);
    });
  });

  group('not içi arama', () {
    test('Türkçe karakter ve büyük/küçük harf duyarsız', () {
      final m = MarkdownEditingController.findAll(
          'Şifre ve ŞİFRE, sifre', 'şifre');
      expect(m.map((r) => r.start), [0, 9, 16]);
      expect(m.every((r) => r.end - r.start == 5), isTrue);
    });

    test('boş sorgu sonuç vermez', () {
      expect(MarkdownEditingController.findAll('abc', ''), isEmpty);
    });

    test('sadeleştirme metin uzunluğunu korur', () {
      const s = 'İstanbul ŞEHRİ ılık';
      expect(foldSameLength(s).length, s.length);
      expect(foldSameLength(s), 'istanbul sehri ilik');
    });
  });
}
