import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/text/search_text.dart';
import 'package:notlar/data/db/connection.dart';
import 'package:notlar/data/db/database.dart';

void main() {
  late Directory tempDir;
  final keyA = List.generate(32, (i) => i);
  final keyB = List.generate(32, (i) => 255 - i);

  setUp(() => tempDir = Directory.systemTemp.createTempSync('notlar_test'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  AppDatabase open(File file, List<int> key) =>
      AppDatabase(openEncryptedDatabase(file, key, inBackground: false));

  test('not yazılıp okunur', () async {
    final db = open(File('${tempDir.path}/a.db'), keyA);
    await db.into(db.notes).insert(NotesCompanion.insert(
          id: 'n1',
          title: const Value('İlk not'),
          kind: const Value(NoteKind.snippet),
          createdAt: 1,
          updatedAt: 1,
          hlc: 'h',
        ));
    final note = await (db.select(db.notes)..where((n) => n.id.equals('n1')))
        .getSingle();
    expect(note.title, 'İlk not');
    expect(note.kind, NoteKind.snippet);
    expect(note.pinned, isFalse);
    await db.close();
  });

  test('dosya diskte şifreli durur', () async {
    final file = File('${tempDir.path}/b.db');
    final db = open(file, keyA);
    await db.into(db.notes).insert(NotesCompanion.insert(
          id: 'n1',
          body: const Value('GIZLI-ICERIK-12345'),
          createdAt: 1,
          updatedAt: 1,
          hlc: 'h',
        ));
    await db.close();

    final raw = file.readAsBytesSync();
    final asText = latin1.decode(raw, allowInvalid: true);
    expect(asText.startsWith('SQLite format 3'), isFalse,
        reason: 'Düz SQLite başlığı görünmemeli');
    expect(asText.contains('GIZLI-ICERIK-12345'), isFalse,
        reason: 'Not içeriği dosyada açık metin olarak görünmemeli');
  });

  test('yanlış anahtarla açılmaz', () async {
    final file = File('${tempDir.path}/c.db');
    final db = open(file, keyA);
    await db.into(db.notes).insert(NotesCompanion.insert(
          id: 'n1',
          createdAt: 1,
          updatedAt: 1,
          hlc: 'h',
        ));
    await db.close();

    final wrong = open(file, keyB);
    await expectLater(wrong.select(wrong.notes).get(), throwsA(anything));
    await wrong.close();
  });

  test('FTS5: Türkçe karakterden bağımsız önek araması', () async {
    final db = open(File('${tempDir.path}/d.db'), keyA);
    await db.customStatement(
      'INSERT INTO notes_fts(note_id, title, body, tags, headings) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        'n1',
        foldForSearch('Şifre Yönetimi'),
        foldForSearch('Güçlü parola kullanımı'),
        foldForSearch('güvenlik'),
        '',
      ],
    );

    Future<List<String>> search(String input) async {
      final rows = await db.customSelect(
        'SELECT note_id FROM notes_fts WHERE notes_fts MATCH ?',
        variables: [Variable.withString(buildFtsQuery(input)!)],
      ).get();
      return rows.map((r) => r.read<String>('note_id')).toList();
    }

    expect(await search('sifre'), ['n1']);
    expect(await search('ŞİFRE yön'), ['n1']);
    expect(await search('parol'), ['n1']);
    expect(await search('guven'), ['n1']);
    expect(await search('bulunmayan'), isEmpty);
    await db.close();
  });
}
