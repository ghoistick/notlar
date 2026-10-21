import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/backup/backup_format.dart';
import 'package:notlar/backup/restore.dart';
import 'package:notlar/backup/tar.dart';
import 'package:notlar/data/db/database.dart';
import 'package:notlar/data/repository/notes_repository.dart';

void main() {
  // Bu testler iki ayrı cihazı taklit etmek için bilerek iki bağımsız
  // veritabanı açar; drift'in "aynı veritabanı iki kez açıldı" uyarısı
  // burada geçerli değil.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase dbA;
  late AppDatabase dbB;
  late NotesRepository a;
  late NotesRepository b;
  var clock = 0;

  setUp(() async {
    clock = DateTime(2026, 10, 15, 9).millisecondsSinceEpoch;
    dbA = AppDatabase(NativeDatabase.memory());
    dbB = AppDatabase(NativeDatabase.memory());
    a = await NotesRepository.open(dbA, now: () => clock += 1000);
    b = await NotesRepository.open(dbB, now: () => clock += 1000);
  });
  tearDown(() async {
    await dbA.close();
    await dbB.close();
  });

  Future<BackupContent> backupOf(NotesRepository repo) async =>
      parseBackupTar(await buildBackupTar(await BackupSnapshot.fromRepository(repo)));

  /// Karşılaştırma için notun anlamlı alanları; tarih saniye hassasiyetinde.
  Future<Map<String, String>> describe(NotesRepository repo) async {
    final folders = {for (final f in await repo.listFolders()) f.id: f};
    String folderPath(String? id) {
      final parts = <String>[];
      var cur = id == null ? null : folders[id];
      while (cur != null) {
        parts.insert(0, cur.name);
        cur = cur.parentId == null ? null : folders[cur.parentId];
      }
      return parts.join('/');
    }

    final tags = await repo.tagNamesByNote();
    return {
      for (final n in await repo.notesForBackup())
        n.id: jsonEncode([
          n.title, n.body, n.kind.name, n.type.name, n.color, n.pinned,
          n.archived, folderPath(n.folderId), tags[n.id] ?? [],
          n.createdAt ~/ 1000, n.updatedAt ~/ 1000,
        ]),
    };
  }

  Future<void> fill(NotesRepository repo) async {
    final proje = await repo.createFolder(name: 'Projeler', color: 'mavi');
    final alt = await repo.createFolder(name: 'Müsvedde', parentId: proje);
    final t1 = await repo.createTag(name: 'postgres', color: 'yesil');
    final t2 = await repo.createTag(name: 'yedek');

    final n1 = await repo.createNote(
        folderId: alt, title: 'Mimari', body: '# Giriş\n- [x] bitti\n', color: 'kirmizi');
    await repo.setNoteTags(n1, {t1, t2});
    final n2 = await repo.createNote(folderId: proje, title: 'Satır sonu yok', body: 'son');
    await repo.updateNote(n2, const NoteChanges(pinned: Value(true)));
    final n3 = await repo.createNote(kind: NoteKind.snippet, body: 'port 5432');
    await repo.updateNote(n3, const NoteChanges(archived: Value(true)));
    await repo.createNote(title: 'Boş gövde');
    await repo.createNote(title: 'Tırnak "ve" iki: nokta', body: '---\nyatay çizgi\n---');
  }

  test('boş uygulamaya geri yükleme her şeyi birebir getirir', () async {
    await fill(a);
    final content = await backupOf(a);

    final plan = await b.importBatch(content.batch, dryRun: true);
    expect(plan.notesAdded, 5);
    expect(plan.foldersAdded, 2);
    expect(plan.tagsAdded, 2);
    expect((await b.notesForBackup()), isEmpty, reason: 'Önizleme hiçbir şey yazmaz');

    final result = await b.importBatch(content.batch);
    expect(result.notesAdded, 5);
    expect(await describe(b), await describe(a));

    // Klasör ve etiket renkleri de gelir.
    expect((await b.listFolders()).firstWhere((f) => f.name == 'Projeler').color, 'mavi');
    expect((await b.listTags()).firstWhere((t) => t.name == 'postgres').color, 'yesil');

    // Arama indeksi ve içindekiler de kurulur.
    expect((await b.listNotes(const NoteQuery(search: 'giris'))).single.title, 'Mimari');
  });

  test('aynı yedeği tekrar geri yüklemek hiçbir şeyi çoğaltmaz', () async {
    await fill(a);
    final content = await backupOf(a);
    await b.importBatch(content.batch);

    final again = await b.importBatch(content.batch);
    expect(again.isEmpty, isTrue);
    expect(again.notesSkipped, 5);
    expect((await b.notesForBackup()).length, 5);
  });

  test('mevcut notların üzerine yazılmaz, yalnızca eksikler eklenir', () async {
    await fill(a);
    final content = await backupOf(a);
    await b.importBatch(content.batch);

    final notes = await b.notesForBackup();
    final degisen = notes.firstWhere((n) => n.title == 'Mimari');
    await b.updateNote(degisen.id, const NoteChanges(body: Value('güncel hali')));
    final silinen = notes.firstWhere((n) => n.title == 'Boş gövde');
    await dbB.customStatement('DELETE FROM notes WHERE id = ?', [silinen.id]);

    final result = await b.importBatch(content.batch);
    expect(result.notesAdded, 1);
    expect((await b.getNote(degisen.id))!.body, 'güncel hali');
    expect(await b.getNote(silinen.id), isNotNull);
  });

  test('aynı adlı mevcut etiketle eşleşir, kopya oluşturmaz', () async {
    await fill(a);
    await b.createTag(name: 'Postgres');
    final result = await b.importBatch((await backupOf(a)).batch);
    expect(result.tagsAdded, 1); // yalnızca "yedek"
    expect((await b.listTags()).length, 2);
  });

  group('ön bilgi', () {
    test('ön bilgisi olmayan Markdown dosyası', () {
      final n = noteFromMarkdown('# Düz not\nmetin', fallbackTitle: 'dosya adı');
      expect(n.title, 'dosya adı');
      expect(n.body, '# Düz not\nmetin');
    });

    test('Windows satır sonları da okunur', () {
      final (fm, body) =
          splitFrontMatter('---\r\ntitle: "A"\r\npinned: true\r\n---\r\n\r\nB\r\n');
      expect(fm['title'], 'A');
      expect(fm['pinned'], true);
      expect(body, 'B');
    });
  });

  test('Müsvedde yedeği olmayan arşiv reddedilir', () {
    final tar = (TarWriter()..addFile('baska/dosya.txt', utf8.encode('x'))).finish();
    expect(() => parseBackupTar(tar), throwsA(isA<InvalidBackupException>()));
  });
}
