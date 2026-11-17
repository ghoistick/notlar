import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/backup/restore.dart';
import 'package:notlar/data/db/tables.dart';
import 'package:notlar/importers/text_files.dart';

final _modified = DateTime(2025, 1, 2, 3, 4);

TextSourceFile src(String path, String text) => TextSourceFile(
    path, Uint8List.fromList(utf8.encode(text)),
    modified: _modified);

void main() {
  group('splitFrontMatter (genişletilmiş)', () {
    test('tek tırnak, alt alta liste, tırnaksız liste, boş değer', () {
      final (fm, body) = splitFrontMatter(
          "---\ntitle: 'Ali''nin notu'\ntags:\n  - iş\n  - \"ev\"\n"
          'keywords: [a, b]\nempty:\n---\n\nGövde\n');
      expect(fm['title'], "Ali'nin notu");
      expect(fm['tags'], ['iş', 'ev']);
      expect(fm['keywords'], ['a', 'b']);
      expect(fm['empty'], isNull);
      expect(body, 'Gövde');
    });

    test('dosya sonunda biten ön bilgi ve BOM', () {
      final (fm, body) = splitFrontMatter('\uFEFF---\ntitle: x\n---');
      expect(fm['title'], 'x');
      expect(body, '');
    });

    test('Müsvedde biçimi eskisi gibi okunur', () {
      final (fm, body) = splitFrontMatter('---\nid: "a1"\ntitle: "Başlık: alt"\n'
          'tags: ["iş", "ev"]\npinned: true\n---\n\nsatır 1\n\nsatır 2\n');
      expect(fm['id'], 'a1');
      expect(fm['title'], 'Başlık: alt');
      expect(fm['tags'], ['iş', 'ev']);
      expect(fm['pinned'], true);
      expect(body, 'satır 1\n\nsatır 2');
    });

    test('iç içe yapılar yok sayılır', () {
      final (fm, _) = splitFrontMatter(
          '---\nmeta:\n  author: biri\ntitle: T\n---\n');
      expect(fm.containsKey('author'), isFalse);
      expect(fm['title'], 'T');
    });
  });

  group('başlık ve alanlar', () {
    int ms(DateTime d) => d.millisecondsSinceEpoch;

    test('ön bilgideki title önce gelir', () {
      final n = TextFilesImporter.noteFromText(
          '---\ntitle: Ön bilgi\n---\n# Başlık satırı\nmetin',
          fileName: 'dosya.md',
          modified: 0);
      expect(n.title, 'Ön bilgi');
    });

    test('ilk satırdaki # başlık alınır ve gövdede kalır', () {
      final n = TextFilesImporter.noteFromText('\n# Toplantı #\n\nmetin\n',
          fileName: 'dosya.md', modified: 0);
      expect(n.title, 'Toplantı');
      expect(n.body, '\n# Toplantı #\n\nmetin');
    });

    test('## başlık sayılmaz; dosya adı kullanılır', () {
      final n = TextFilesImporter.noteFromText('## Alt başlık',
          fileName: 'Notum.markdown', modified: 0);
      expect(n.title, 'Notum');
    });

    test('.txt dosyasında başlık her zaman dosya adıdır', () {
      final n = TextFilesImporter.noteFromText('# değil\r\nikinci\r\n',
          fileName: 'liste.txt', modified: 5);
      expect(n.title, 'liste');
      expect(n.body, '# değil\nikinci');
      expect(n.createdAt, 5);
      expect(n.updatedAt, 5);
    });

    test('etiketler ve tarihler', () {
      final n = TextFilesImporter.noteFromText(
          '---\ntags: "#iş, ev, Ev"\ndate: 2024-03-05\n---\nmetin',
          fileName: 'a.md',
          modified: ms(_modified));
      expect(n.tagNames, ['iş', 'ev']);
      expect(n.createdAt, ms(DateTime(2024, 3, 5)));
      expect(n.updatedAt, ms(_modified));
    });

    test('Müsvedde dosyası kimliği ve alanlarıyla alınır', () {
      final n = TextFilesImporter.noteFromText(
          '---\nid: "abc"\nkind: snippet\ntype: checklist\ntitle: "Liste"\n'
          'tags: ["iş"]\npinned: true\n'
          'created: 2026-10-15T10:00:00+03:00\n'
          'updated: 2026-10-16T10:00:00+03:00\n---\n\n- [ ] süt\n',
          fileName: '2026-10-15 Liste.md',
          folderId: 'f1',
          modified: 0);
      expect(n.id, 'abc');
      expect(n.kind, NoteKind.snippet);
      expect(n.type, NoteType.checklist);
      expect(n.title, 'Liste');
      expect(n.body, '- [ ] süt');
      expect(n.tagNames, ['iş']);
      expect(n.pinned, isTrue);
      expect(n.folderId, 'f1');
      expect(n.createdAt,
          DateTime.parse('2026-10-15T10:00:00+03:00').millisecondsSinceEpoch);
    });

    test('kind/type geçersizse Müsvedde dosyası sayılmaz', () {
      final n = TextFilesImporter.noteFromText(
          '---\nid: "5"\nkind: post\ntype: blog\n---\nmetin',
          fileName: 'a.md',
          modified: 0);
      expect(n.id, startsWith('md-'));
    });
  });

  group('kimlik', () {
    test('aynı içerik aynı kimliği, farklı içerik farklı kimliği verir', () {
      final a = TextFilesImporter.noteFromText('metin',
          fileName: 'a.md', modified: 1);
      final b = TextFilesImporter.noteFromText('metin',
          fileName: 'a.md', modified: 999);
      final c = TextFilesImporter.noteFromText('metin!',
          fileName: 'a.md', modified: 1);
      expect(a.id, startsWith('md-'));
      expect(a.id.length, 3 + 32);
      expect(a.id, b.id);
      expect(a.id, isNot(c.id));
    });
  });

  group('kodlama', () {
    test('UTF-8 BOM atılır', () {
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('ğü')]);
      expect(TextFilesImporter.decodeText(bytes), 'ğü');
    });

    test('geçersiz UTF-8 Windows-1254 olarak okunur', () {
      final bytes = Uint8List.fromList(
          [0xF0, 0xFC, 0xFE, 0xFD, 0xF6, 0xE7, 0xDD, 0xD0, 0xDE, 0x80]);
      expect(TextFilesImporter.decodeText(bytes), 'ğüşıöçİĞŞ€');
    });

    test('UTF-16 LE ve BE (BOM ile)', () {
      expect(
          TextFilesImporter.decodeText(
              Uint8List.fromList([0xFF, 0xFE, 0x41, 0x00, 0x1F, 0x01])),
          'Ağ');
      expect(
          TextFilesImporter.decodeText(
              Uint8List.fromList([0xFE, 0xFF, 0x00, 0x41, 0x01, 0x1F])),
          'Ağ');
    });

    test('NUL içeren dosya ikili sayılır', () {
      expect(
          TextFilesImporter.decodeText(Uint8List.fromList([0x41, 0x00, 0x42])),
          isNull);
    });
  });

  group('paket kurma', () {
    test('dosya seçiminde tek klasör', () {
      final r = TextFilesImporter.build([src('a.md', 'A'), src('b.txt', 'B')]);
      expect(r.batch.folders.single.id, TextFilesImporter.folderId);
      expect(r.batch.folders.single.name, TextFilesImporter.folderName);
      expect(r.batch.notes.map((n) => n.folderId).toSet(),
          {TextFilesImporter.folderId});
    });

    test('klasör seçiminde ağaç kurulur, kopyalar bir kez alınır', () {
      List<TextSourceFile> files() => [
            src('Proje/Alt/c.txt', 'C'),
            src('a.md', 'A'),
            src('Proje/b.md', 'B'),
            // a.md ile aynı içerik; sıralamada sonra geldiği için atlanır.
            src('z-kopya/a.md', 'A'),
          ];
      final r = TextFilesImporter.build(files(), rootName: 'Kasa');

      final byName = {for (final f in r.batch.folders) f.name: f};
      expect(byName.keys.toSet(), {'Kasa', 'Proje', 'Alt'});
      expect(byName['Kasa']!.parentId, isNull);
      expect(byName['Proje']!.parentId, byName['Kasa']!.id);
      expect(byName['Alt']!.parentId, byName['Proje']!.id);

      final notes = {for (final n in r.batch.notes) n.title: n};
      expect(notes.length, 3);
      expect(r.duplicates, 1);
      expect(notes['a']!.folderId, byName['Kasa']!.id);
      expect(notes['b']!.folderId, byName['Proje']!.id);
      expect(notes['c']!.folderId, byName['Alt']!.id);

      // Aynı klasörü tekrar okumak aynı kimlikleri üretir.
      final again = TextFilesImporter.build(files(), rootName: 'Kasa');
      expect(again.batch.folders.map((f) => f.id).toSet(),
          r.batch.folders.map((f) => f.id).toSet());
      expect(again.batch.notes.map((n) => n.id).toSet(),
          r.batch.notes.map((n) => n.id).toSet());
    });

    test('okunamayan dosya sayılır, desteklenen uzantılar', () {
      final r = TextFilesImporter.build([
        TextSourceFile('x.md', Uint8List.fromList([0, 1, 2])),
      ]);
      expect(r.batch.notes, isEmpty);
      expect(r.skippedUnreadable, 1);

      expect(TextFilesImporter.isSupported('Not.MD'), isTrue);
      expect(TextFilesImporter.isSupported('a.markdown'), isTrue);
      expect(TextFilesImporter.isSupported('resim.png'), isFalse);
      expect(TextFilesImporter.isSupported('.md'), isFalse);
    });
  });
}
