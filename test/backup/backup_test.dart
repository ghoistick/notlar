import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/backup/backup_format.dart';
import 'package:notlar/backup/retention.dart';
import 'package:notlar/backup/seven_zip.dart';
import 'package:notlar/backup/tar.dart';
import 'package:notlar/data/db/database.dart';
import 'package:notlar/data/repository/notes_repository.dart';

Future<void> main() async {
  final sevenZip = await SevenZip.locate();

  group('tar', () {
    test('Türkçe ve uzun yollar birebir geri okunur', () {
      final long = 'notlar/${'Çok uzun klasör adı ' * 8}/dosya.md';
      final w = TarWriter()
        ..addDirectory('notlar/Şifre Notları')
        ..addFile('notlar/Şifre Notları/ılık su.md', utf8.encode('İçerik ğüşöç'))
        ..addFile(long, Uint8List(1000));
      final entries = readTar(w.finish());

      expect(entries.map((e) => e.path),
          ['notlar/Şifre Notları', 'notlar/Şifre Notları/ılık su.md', long]);
      expect(entries[0].isDirectory, isTrue);
      expect(utf8.decode(entries[1].data), 'İçerik ğüşöç');
      expect(entries[2].data.length, 1000);
    });
  });

  group('yedek formatı', () {
    late AppDatabase db;
    late NotesRepository repo;
    var clock = 0;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      clock = DateTime(2026, 10, 15, 9).millisecondsSinceEpoch;
      // Her işlemde saat bir saniye ilerler; notların sırası belirli olur.
      repo = await NotesRepository.open(db, now: () => clock += 1000);
    });
    tearDown(() => db.close());

    test('klasör yapısı, ön bilgi ve manifest', () async {
      final proje = await repo.createFolder(name: 'Projeler');
      final alt = await repo.createFolder(name: 'Not: Uygulaması', parentId: proje);
      final tag = await repo.createTag(name: 'postgres');
      final n1 = await repo.createNote(
          folderId: alt, title: 'Mimari', body: '# Başlık\nİçerik');
      await repo.setNoteTags(n1, {tag});
      await repo.createNote(title: 'Mimari', folderId: alt); // aynı ad
      await repo.createNote(kind: NoteKind.snippet, body: 'port 5432');
      final silinen = await repo.createNote(title: 'Silinen');
      await repo.trashNote(silinen);

      final snapshot = await BackupSnapshot.fromRepository(repo,
          now: DateTime(2026, 10, 15, 10));
      final entries = {for (final e in readTar(await buildBackupTar(snapshot))) e.path: e};

      expect(entries.keys, containsAll([
        'notlar',
        'notlar/Projeler',
        'notlar/Projeler/Not_ Uygulaması',
        'notlar/Projeler/Not_ Uygulaması/2026-10-15 Mimari.md',
        'notlar/Projeler/Not_ Uygulaması/2026-10-15 Mimari (2).md',
        'notlar/2026-10-15 Kısa not.md',
        'notlar/manifest.json',
      ]));
      expect(entries.keys.any((k) => k.contains('Silinen')), isFalse,
          reason: 'Çöp kutusundaki notlar yedeğe girmez');

      final md = utf8.decode(
          entries['notlar/Projeler/Not_ Uygulaması/2026-10-15 Mimari.md']!.data);
      expect(md, startsWith('---\n'));
      expect(md, contains('title: "Mimari"'));
      expect(md, contains('tags: ["postgres"]'));
      expect(md, contains('folder: "Projeler/Not_ Uygulaması"'));
      expect(md, endsWith('# Başlık\nİçerik\n'));

      final manifest =
          jsonDecode(utf8.decode(entries['notlar/manifest.json']!.data)) as Map;
      expect(manifest['format'], backupFormatName);
      expect(manifest['counts'], {'notes': 3, 'folders': 2, 'tags': 1});
      expect((manifest['files'] as List).length, 3);
    });

    test('dosya adı temizleme', () {
      expect(sanitizePathSegment('a/b:c*d?'), 'a_b_c_d_');
      expect(sanitizePathSegment('  son nokta... '), 'son nokta');
      expect(sanitizePathSegment('CON'), 'CON_');
      expect(sanitizePathSegment(''), '_');
    });
  });

  group('saklama politikası', () {
    final now = DateTime(2026, 10, 15, 12);
    String f(DateTime t) => backupFileName(t);

    test('son 24 saat tamamı, sonrası günde bir, 30 günden eskiler silinir', () {
      final keepRecent1 = f(DateTime(2026, 10, 15, 11));
      final keepRecent2 = f(DateTime(2026, 10, 14, 13));
      final dayNewest = f(DateTime(2026, 10, 13, 18));
      final dayOlder = f(DateTime(2026, 10, 13, 9));
      final tooOld = f(DateTime(2026, 9, 10, 9));
      final foreign = 'baska-dosya.7z';

      final del = backupsToDelete(
          [keepRecent1, keepRecent2, dayNewest, dayOlder, tooOld, foreign], now);
      expect(del.toSet(), {dayOlder, tooOld});
    });

    test('dosya adı tarih olarak geri okunur', () {
      final t = DateTime(2026, 1, 2, 3, 4, 5);
      expect(parseBackupTime(backupFileName(t)), t);
      expect(parseBackupTime('notlar.7z'), isNull);
    });
  });

  group('7-Zip', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('notlar_7z'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('şifreli arşiv oluşturur, doğrular ve açar', () async {
      final zip = SevenZip(sevenZip!);
      final path = '${dir.path}${Platform.pathSeparator}deneme.7z';
      final data = utf8.encode('gizli içerik ' * 100);

      await zip.createFromBytes(
          archivePath: path, innerName: 'notlar.tar', data: data, password: 'p@ss 1');
      await zip.test(path, 'p@ss 1');
      expect(await zip.extractSingle(path, 'notlar.tar', 'p@ss 1'), data);

      await expectLater(
          zip.test(path, 'yanlis'), throwsA(isA<SevenZipException>()));
    }, skip: sevenZip == null ? '7-Zip kurulu değil' : false);
  });
}
