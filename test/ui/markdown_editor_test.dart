import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/text/search_text.dart';
import 'package:notlar/ui/editor/markdown_controller.dart';
import 'package:notlar/ui/editor/markdown_parser.dart';

/// Satırda [text] parçasının biçimi.
InlineStyle styleOf(ParsedLine line, String text) {
  for (final s in line.segments) {
    if (line.text.substring(s.start, s.end) == text) return s.style;
  }
  throw StateError('"$text" parçası bulunamadı: '
      '${line.segments.map((s) => '[${line.text.substring(s.start, s.end)}]').join()}');
}

void main() {
  group('blok ayrıştırma', () {
    test('başlık: işaret gizlenebilir, seviye doğru', () {
      final l = parseLine('## Kurulum');
      expect(l.block.type, BlockType.heading);
      expect(l.block.level, 2);
      expect(styleOf(l, '## ').hideable, isTrue);
      expect(styleOf(l, 'Kurulum').marker, isFalse);
    });

    test('yapılacak maddesi: kutucuk ve işaret durumu', () {
      final l = parseLine('- [x] Yedek alındı');
      expect(l.block.type, BlockType.task);
      expect(l.block.checked, isTrue);
      expect(styleOf(l, '[x]').checkbox, isTrue);
      expect(styleOf(l, '- ').hideable, isTrue);
    });

    test('madde işareti görünür kalır', () {
      final l = parseLine('- madde');
      expect(l.block.type, BlockType.bullet);
      expect(styleOf(l, '- ').marker, isTrue);
      expect(styleOf(l, '- ').hideable, isFalse);
    });

    test('kod bloğu içinde biçim uygulanmaz', () {
      final doc = parseDocument('```\n**kalın değil**\n```\n**kalın**');
      expect(doc[1].block.type, BlockType.code);
      expect(doc[1].segments.single.style.bold, isFalse);
      expect(styleOf(doc[3], 'kalın').bold, isTrue);
    });

    test('satır konumları belgeyle uyumlu', () {
      final doc = parseDocument('ab\n\ncde');
      expect(doc.map((l) => l.offset), [0, 3, 4]);
    });
  });

  group('satır içi ayrıştırma', () {
    test('kalın ve italik', () {
      final l = parseLine('a **kalın** ve *eğik* b');
      expect(styleOf(l, 'kalın').bold, isTrue);
      expect(styleOf(l, 'eğik').italic, isTrue);
      expect(styleOf(l, '**').hideable, isTrue);
    });

    test('**x** italik sayılmaz', () {
      final l = parseLine('**x**');
      expect(styleOf(l, 'x').bold, isTrue);
      expect(styleOf(l, 'x').italic, isFalse);
    });

    test('kelime içi alt çizgi italik değildir', () {
      final l = parseLine('değişken_adı_x');
      expect(l.segments.every((s) => !s.style.italic), isTrue);
    });

    test('satır içi kod içinde biçim yok', () {
      final l = parseLine('`**a**`');
      expect(styleOf(l, '**a**').code, isTrue);
      expect(styleOf(l, '**a**').bold, isFalse);
    });

    test('renk ve vurgu sözdizimi', () {
      final l = parseLine('{kırmızı}önemli{/} ve {!sarı}dikkat{/}');
      expect(styleOf(l, 'önemli').color, 'kirmizi');
      expect(styleOf(l, 'dikkat').highlight, 'sari');
      expect(styleOf(l, '{kırmızı}').hideable, isTrue);
    });

    test('büyük harf ve ASCII renk adları da çalışır', () {
      expect(styleOf(parseLine('{KIRMIZI}a{/}'), 'a').color, 'kirmizi');
      expect(styleOf(parseLine('{yesil}a{/}'), 'a').color, 'yesil');
    });

    test('bilinmeyen renk adı düz metin kalır', () {
      final l = parseLine('{xyz}a{/}');
      expect(l.segments.every((s) => s.style.color == null), isTrue);
    });

    test('bağlantı', () {
      final l = parseLine('[site](https://ornek.com)');
      expect(styleOf(l, 'site').link, isTrue);
      expect(styleOf(l, '](https://ornek.com)').hideable, isTrue);
    });

    test('parçalar satırı eksiksiz kaplar', () {
      const text = '# **Başlık** {mavi}renkli{/} `kod` _eğik_';
      final l = parseLine(text);
      expect(l.segments.map((s) => text.substring(s.start, s.end)).join(), text);
    });
  });

  group('düzenleme komutları', () {
    MarkdownEditingController ctl(String text, int start, [int? end]) =>
        MarkdownEditingController(text: text)
          ..selection = TextSelection(baseOffset: start, extentOffset: end ?? start);

    test('seçimi kalın yapar, tekrar basınca geri alır', () {
      final c = ctl('bir kelime', 4, 10);
      c.wrapSelection('**');
      expect(c.text, 'bir **kelime**');
      expect(c.selection, const TextSelection(baseOffset: 6, extentOffset: 12));
      c.wrapSelection('**');
      expect(c.text, 'bir kelime');
    });

    test('renk uygular', () {
      final c = ctl('çok önemli', 4, 10)..applyColor('kirmizi');
      expect(c.text, 'çok {kırmızı}önemli{/}');
      final h = ctl('dikkat', 0, 6)..applyColor('sari', highlight: true);
      expect(h.text, '{!sarı}dikkat{/}');
    });

    test('başlık seviyesi değiştirme ve kaldırma', () {
      final c = ctl('Kurulum', 3)..toggleHeading(2);
      expect(c.text, '## Kurulum');
      c.toggleHeading(1);
      expect(c.text, '# Kurulum');
      c.toggleHeading(1);
      expect(c.text, 'Kurulum');
    });

    test('çok satırı numaralı listeye, sonra yapılacaklara çevirir', () {
      final c = ctl('a\nb\nc', 0, 5)..toggleList(ListKind.ordered);
      expect(c.text, '1. a\n2. b\n3. c');
      c.toggleList(ListKind.task);
      expect(c.text, '- [ ] a\n- [ ] b\n- [ ] c');
    });

    test('kutucuğa tıklama işaretini değiştirir', () {
      final c = MarkdownEditingController(text: 'x\n- [ ] süt al');
      expect(c.toggleCheckboxAt(5), isTrue);
      expect(c.text, 'x\n- [x] süt al');
      expect(c.toggleCheckboxAt(10), isFalse); // metnin üzerine tıklama
    });

    test('Ctrl+Enter: madde değilse yapılacağa çevirir, sonra işaretler', () {
      final c = ctl('süt al', 2);
      c.toggleCheckboxOnCurrentLine();
      expect(c.text, '- [ ] süt al');
      c.toggleCheckboxOnCurrentLine();
      expect(c.text, '- [x] süt al');
    });
  });

  group('liste devamı', () {
    final f = ListContinuationFormatter();

    TextEditingValue enter(String before) {
      final old = TextEditingValue(
          text: before, selection: TextSelection.collapsed(offset: before.length));
      final typed = TextEditingValue(
          text: '$before\n',
          selection: TextSelection.collapsed(offset: before.length + 1));
      return f.formatEditUpdate(old, typed);
    }

    test('madde, yapılacak ve numaralı liste sürer', () {
      expect(enter('- süt').text, '- süt\n- ');
      expect(enter('  - [x] ekmek').text, '  - [x] ekmek\n  - [ ] ');
      expect(enter('9. dokuz').text, '9. dokuz\n10. ');
    });

    test('boş maddede Enter listeyi bitirir', () {
      final v = enter('- süt\n- ');
      expect(v.text, '- süt\n');
      expect(v.selection.baseOffset, 6);
    });

    test('düz satırda bir şey eklenmez', () {
      expect(enter('normal').text, 'normal\n');
    });
  });

  test('arama indeksinde vurgu işaretleri de temizlenir', () {
    expect(stripInlineMarkup('{!sarı}dikkat{/} et'), 'dikkat et');
  });
}
