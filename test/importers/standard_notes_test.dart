import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/data/db/database.dart';
import 'package:notlar/data/repository/notes_repository.dart';
import 'package:notlar/importers/standard_notes.dart';
import 'package:notlar/importers/zip_reader.dart';

/// Python'un zipfile modülüyle (deflate) üretilmiş gerçek bir ZIP: Standard
/// Notes'un şifresiz dışa aktarımını taklit eder.
const _fixture = 'UEsDBBQAAAAIAMtIWl20Xbgg1wEAACAHAAApAAAAU3RhbmRhcmQgTm90ZXMgQmFja3VwIGFuZCBJbXBvcnQgRmlsZS50eHS9lMFO4zAQhl8lCldcmdZ0sz0i0N6g2mYPLIuQaQawGpzIcRG7Jed9i+2RK71w4pb0vchYNk1LVFAX8Sv6lRlPbM+naSf+DahMJNLveT6lzN/2fKHhOqvik4k/HosIV3asiDGGFrjQCT8dJlKD1Gf6dwr43WGiweQVcA3RGdeYbdN2l9AOobshDXqUVk+LUvoTK8dp1FTZDenXXmep0p5VlU18LXRsDpz/ExcKYuHJRGORhluz0Za3x+fTuJyNfsnyobgHJUZeOS2e5tNyVjwW91is4AIUyCGY7k+rDE/Tfa65OSNRl61McxlxFVW7Q9bKpFlIhZSAmLQaA14sFshgXSe1nvNK294CdduKGGNogQudNkDN3o26obIRdR3vuYWblbM/mEc+ob1YGnMhiancnDFXwytx80J5FVrHihhjaIELnTaAtvNuaA2VjdCKv8VjqmEk6vRuTaB4dlUfoxVSyw0zK7KwwL05rWs4ghj0Amd9610rYoyhBS50ato65JefirJ/NAi/fT8YvJ6qD/rf+rifZb4y5yvT27Uixhha4EKndcSb6BxDBKPPQfOfA/NywfpCmPR5ldRY8wa9L1bEGEMLXOjUdPzg8O5HBqpfA7QMM89P82dQSwMEFAAACAgAy0haXaKUlkMWAAAAEwAAACQAAABJdGVtcy9Ob3RlL8WeaWZyZWxpIG5vdC0xMTExMTExMS50eHRTVnBKPDo/58jGbK4jGw4vTy3KzAYAUEsBAhQDFAAAAAgAy0haXbRduCDXAQAAIAcAACkAAAAAAAAAAAAAAIABAAAAAFN0YW5kYXJkIE5vdGVzIEJhY2t1cCBhbmQgSW1wb3J0IEZpbGUudHh0UEsBAhQDFAAACAgAy0haXaKUlkMWAAAAEwAAACQAAAAAAAAAAAAAAIABHgIAAEl0ZW1zL05vdGUvxZ5pZnJlbGkgbm90LTExMTExMTExLnR4dFBLBQYAAAAAAgACAKkAAAB2AgAAAAA=';

void main() {
  final zipBytes = base64Decode(_fixture);
  const n1 = '11111111-1111-4111-8111-111111111111';
  const n2 = '22222222-2222-4222-8222-222222222222';

  group('ZIP okuyucu', () {
    test('Türkçe adlı girdileri listeler ve açar', () {
      final zip = SimpleZipReader(zipBytes);
      expect(zip.entries.map((e) => e.name), [
        StandardNotesImporter.backupFileName,
        'Items/Note/Şifreli not-11111111.txt',
      ]);
      final entry = zip.findByFileName('Şifreli not-11111111.txt')!;
      expect(utf8.decode(zip.read(entry)), '# Başlık\nİçerik');
    });

    test('ZIP olmayan veriyi tanır', () {
      expect(SimpleZipReader.looksLikeZip(zipBytes), isTrue);
      expect(SimpleZipReader.looksLikeZip(utf8.encode('{"items": []}')), isFalse);
    });
  });

  group('ayrıştırma', () {
    late StandardNotesResult r;
    setUp(() {
      final zip = SimpleZipReader(zipBytes);
      r = StandardNotesImporter.parse(utf8.decode(
          zip.read(zip.findByFileName(StandardNotesImporter.backupFileName)!)));
    });

    test('çöpteki ve silinmiş notlar alınmaz', () {
      expect(r.batch.notes.map((n) => n.id), [n1, n2]);
      expect(r.skippedTrashed, 1);
    });

    test('başlık, metin, sabitleme, arşiv ve tarihler', () {
      final a = r.batch.notes.firstWhere((n) => n.id == n1);
      expect(a.title, 'Şifreli not');
      expect(a.body, '# Başlık\nİçerik ğüşıöç');
      expect(a.pinned, isTrue);
      expect(a.archived, isFalse);
      expect(a.createdAt, DateTime.parse('2026-03-05T08:00:00Z').millisecondsSinceEpoch);
      expect(a.updatedAt, DateTime.parse('2026-03-06T09:00:00Z').millisecondsSinceEpoch,
          reason: 'Standard Notes\'un kendi düzenleme zamanı kullanılır');
      expect(a.folderId, StandardNotesImporter.folderId);

      final b = r.batch.notes.firstWhere((n) => n.id == n2);
      expect(b.title, '');
      expect(b.archived, isTrue);
    });

    test('etiketler notlara bağlanır', () {
      expect(r.batch.tags.map((t) => t.name), ['POSTGRES', 'Yedek']);
      expect(r.batch.notes.firstWhere((n) => n.id == n1).tagNames, ['POSTGRES', 'Yedek']);
      expect(r.batch.notes.firstWhere((n) => n.id == n2).tagNames, ['POSTGRES']);
    });

    test('şifreli yedek anlaşılır bir hatayla reddedilir', () {
      const encrypted = '{"version":"004","items":[{"uuid":"x","content_type":"Note",'
          '"content":"004:abcdef:..."}]}';
      expect(() => StandardNotesImporter.parse(encrypted),
          throwsA(isA<ImportFormatException>()));
      expect(() => StandardNotesImporter.parse('bu bir yedek değil'),
          throwsA(isA<ImportFormatException>()));
    });
  });

  group('dosyadan ve uçtan uca', () {
    late Directory dir;
    late AppDatabase db;
    late NotesRepository repo;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('sn_test');
      db = AppDatabase(NativeDatabase.memory());
      repo = await NotesRepository.open(db);
    });
    tearDown(() async {
      await db.close();
      dir.deleteSync(recursive: true);
    });

    test('ZIP de .txt de okunur', () async {
      final zipFile = File('${dir.path}/yedek.zip')..writeAsBytesSync(zipBytes);
      final fromZip = await StandardNotesImporter.readFile(zipFile.path);

      final zip = SimpleZipReader(zipBytes);
      final txtFile = File('${dir.path}/yedek.txt')
        ..writeAsBytesSync(zip.read(zip.findByFileName(StandardNotesImporter.backupFileName)!));
      final fromTxt = await StandardNotesImporter.readFile(txtFile.path);

      expect(fromZip.batch.notes.length, 2);
      expect(fromTxt.batch.notes.length, 2);
    });

    test('içe aktarılır; ikinci kez aktarmak çoğaltmaz; mevcut etiketle birleşir',
        () async {
      await repo.createTag(name: 'postgres'); // küçük harfle zaten var

      final r = await StandardNotesImporter.readFile(
          (File('${dir.path}/y.zip')..writeAsBytesSync(zipBytes)).path);
      final first = await repo.importBatch(r.batch);
      expect(first.notesAdded, 2);
      expect(first.foldersAdded, 1);
      expect(first.tagsAdded, 1, reason: 'yalnızca "Yedek" yeni');

      final folder = (await repo.listFolders()).single;
      expect(folder.name, StandardNotesImporter.folderName);
      expect((await repo.tagsOfNote(n1)).map((t) => t.name).toSet(), {'postgres', 'Yedek'});
      expect((await repo.getNote(n1))!.pinned, isTrue);
      expect((await repo.getNote(n2))!.archived, isTrue);
      expect((await repo.listNotes(const NoteQuery(search: 'iceri'))).single.id, n1);

      final again = await repo.importBatch(r.batch);
      expect(again.notesAdded, 0);
      expect(again.notesSkipped, 2);
    });
  });
}
