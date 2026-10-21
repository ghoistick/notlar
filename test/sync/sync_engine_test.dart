import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/crypto/subkeys.dart';
import 'package:notlar/data/db/database.dart';
import 'package:notlar/data/repository/notes_repository.dart';
import 'package:notlar/sync/sync_engine.dart';
import 'package:notlar/sync/sync_store.dart';

/// Testte bir "cihaz": kendi veritabanı ve deposu, ortak Drive.
class Device {
  final AppDatabase db;
  final NotesRepository repo;
  final SyncEngine engine;
  Device(this.db, this.repo, this.engine);
}

void main() {
  // Bu testler iki ayrı cihazı taklit etmek için bilerek iki bağımsız
  // veritabanı açar; drift'in "aynı veritabanı iki kez açıldı" uyarısı
  // burada geçerli değil.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late MemorySyncStore drive;
  final opened = <AppDatabase>[];
  var clock = 0;

  Future<Uint8List> Function(String) keyOf(int seed) =>
      (purpose) => deriveSubkey(SecretKey(List.filled(32, seed)), purpose);

  Future<Device> device({int keySeed = 7}) async {
    final db = AppDatabase(NativeDatabase.memory());
    opened.add(db);
    final repo = await NotesRepository.open(db, now: () => clock += 1000);
    final engine = SyncEngine(
      repo: repo,
      store: drive,
      subkey: keyOf(keySeed),
      keyringBytes: () async => Uint8List.fromList(utf8.encode('{"v":1}')),
    );
    return Device(db, repo, engine);
  }

  setUp(() {
    drive = MemorySyncStore();
    clock = DateTime(2026, 10, 20, 9).millisecondsSinceEpoch;
  });
  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
  });

  Future<Note> only(Device d, String title) async =>
      (await d.repo.notesForBackup()).singleWhere((n) => n.title == title);

  test('notlar, klasörler ve etiketler diğer cihaza aynen geçer', () async {
    final a = await device();
    final b = await device();

    final proje = await a.repo.createFolder(name: 'Projeler', color: 'mavi');
    final alt = await a.repo.createFolder(name: 'Müsvedde', parentId: proje);
    final tag = await a.repo.createTag(name: 'postgres');
    final n = await a.repo.createNote(
        folderId: alt, title: 'Mimari', body: '# Giriş\nŞifreli eşitleme');
    await a.repo.setNoteTags(n, {tag});
    await a.repo.createNote(kind: NoteKind.snippet, body: 'port 5432');

    final pushed = await a.engine.syncOnce();
    expect(pushed.pushedOps, greaterThan(0));
    await b.engine.syncOnce();

    final got = await only(b, 'Mimari');
    expect(got.id, n);
    expect(got.body, '# Giriş\nŞifreli eşitleme');
    expect(got.folderId, alt);
    expect((await b.repo.listFolders()).map((f) => f.name).toSet(),
        {'Projeler', 'Müsvedde'});
    expect((await b.repo.listFolders()).firstWhere((f) => f.id == proje).color, 'mavi');
    expect((await b.repo.tagsOfNote(n)).single.name, 'postgres');
    expect((await b.repo.listNotes(const NoteQuery(kind: NoteKind.snippet))).single.body,
        'port 5432');

    // Arama indeksi ve içindekiler alan cihazda da kurulur.
    expect((await b.repo.listNotes(const NoteQuery(search: 'sifreli'))).single.id, n);
    expect((await b.repo.getHeadings(n)).single.content, 'Giriş');
  });

  test('farklı alanlardaki eş zamanlı değişiklikler birleşir', () async {
    final a = await device();
    final b = await device();
    final n = await a.repo.createNote(title: 'Eski başlık', body: 'gövde');
    await a.engine.syncOnce();
    await b.engine.syncOnce();

    await a.repo.updateNote(n, const NoteChanges(pinned: Value(true)));
    await b.repo.updateNote(n, const NoteChanges(title: Value('Yeni başlık')));

    await a.engine.syncOnce();
    await b.engine.syncOnce();
    await a.engine.syncOnce();

    for (final d in [a, b]) {
      final got = (await d.repo.getNote(n))!;
      expect(got.pinned, isTrue);
      expect(got.title, 'Yeni başlık');
    }
  });

  test('aynı notun gövdesi iki cihazda değişirse kaybeden kopya olarak kalır',
      () async {
    final a = await device();
    final b = await device();
    final n = await a.repo.createNote(title: 'Plan', body: 'ilk hali');
    await a.engine.syncOnce();
    await b.engine.syncOnce();

    await a.repo.updateNote(n, const NoteChanges(body: Value('A cihazındaki hali')));
    await b.repo.updateNote(n, const NoteChanges(body: Value('B cihazındaki hali')));

    await b.engine.syncOnce();
    final r = await a.engine.syncOnce();
    expect(r.applied.conflicts, 1);
    await b.engine.syncOnce();

    Future<Set<String>> contents(Device d) async => {
          for (final x in await d.repo.notesForBackup()) '${x.title} → ${x.body}',
        };
    final expected = {
      'Plan → B cihazındaki hali',
      'Plan (çakışan kopya) → A cihazındaki hali',
    };
    expect(await contents(a), expected);
    expect(await contents(b), expected);
  });

  test('silme ve etiket kaldırma diğer cihaza yayılır', () async {
    final a = await device();
    final b = await device();
    final tag = await a.repo.createTag(name: 'geçici');
    final n = await a.repo.createNote(title: 'Silinecek');
    await a.repo.setNoteTags(n, {tag});
    await a.engine.syncOnce();
    await b.engine.syncOnce();
    expect(await b.repo.tagsOfNote(n), hasLength(1));

    await a.repo.setNoteTags(n, {});
    await a.repo.trashNote(n);
    await a.engine.syncOnce();
    await b.engine.syncOnce();

    expect((await b.repo.getNote(n))!.deletedAt, isNotNull);
    expect(await b.repo.tagsOfNote(n), isEmpty);
  });

  test('tekrar eşitlemek bir şey göndermez, aynı paket iki kez uygulanmaz',
      () async {
    final a = await device();
    final b = await device();
    await a.repo.createNote(title: 'x');
    await a.engine.syncOnce();
    await b.engine.syncOnce();

    final again = await a.engine.syncOnce();
    expect(again.pushedOps, 0);
    final againB = await b.engine.syncOnce();
    expect(againB.pulledSegments, 0);
    expect((await b.repo.notesForBackup()).length, 1);
  });

  test('alan cihazın saati ileri alınır: sonraki yerel değişiklik daha yeni sayılır',
      () async {
    final a = await device();
    final b = await device();
    final n = await a.repo.createNote(title: 'Saat');
    await a.engine.syncOnce();

    clock -= 3600 * 1000; // B'nin saati bir saat geride
    await b.engine.syncOnce();
    await b.repo.updateNote(n, const NoteChanges(title: Value('B kazanmalı')));
    await b.engine.syncOnce();
    await a.engine.syncOnce();
    expect((await a.repo.getNote(n))!.title, 'B kazanmalı');
  });

  test('Drive\'daki dosyalar şifreli', () async {
    final a = await device();
    await a.repo.createNote(title: 'GİZLİ-BAŞLIK', body: 'gizli-icerik-12345');
    await a.engine.syncOnce();

    final segments = drive.files.values.where((f) => f.$1.startsWith('seg-'));
    expect(segments, isNotEmpty);
    for (final (_, data) in segments) {
      final asText = latin1.decode(data, allowInvalid: true);
      expect(asText.contains('gizli-icerik'), isFalse);
      expect(asText.contains('GİZLİ'), isFalse);
    }
    expect(drive.files.values.map((f) => f.$1), containsAll(['vault.json', 'keyring.json']));
  });

  test('başka bir kasa aynı Drive\'a bağlanırsa eşitleme hiçbir şey yazmadan durur',
      () async {
    final a = await device();
    await a.repo.createNote(title: 'A kasası');
    await a.engine.syncOnce();
    final before = drive.files.length;

    final yabanci = await device(keySeed: 99);
    await yabanci.repo.createNote(title: 'Başka kasa');
    await expectLater(
        yabanci.engine.syncOnce(), throwsA(isA<VaultMismatchException>()));
    expect(drive.files.length, before);
  });
}
