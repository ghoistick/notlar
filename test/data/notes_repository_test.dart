import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/data/db/database.dart';
import 'package:notlar/data/repository/notes_repository.dart';

void main() {
  late AppDatabase db;
  late NotesRepository repo;
  var clock = 0;

  setUp(() async {
    clock = 1000000;
    db = AppDatabase(NativeDatabase.memory());
    repo = await NotesRepository.open(db, now: () => clock);
  });
  tearDown(() => db.close());

  Future<Set<String>> ids(NoteQuery q) async =>
      (await repo.listNotes(q)).map((n) => n.id).toSet();

  group('notlar', () {
    test('oluşturma: change_log, başlıklar ve arama indeksi', () async {
      final id = await repo.createNote(
          title: 'Şifre notu', body: '# Giriş\nparola bilgisi');

      final log = await db.select(db.changeLog).get();
      expect(log.where((e) => e.entityId == id).map((e) => e.field),
          containsAll(['title', 'body', 'kind', 'folder_id']));

      expect(await ids(const NoteQuery(search: 'sifre')), {id});
      expect(await ids(const NoteQuery(search: 'giris')), {id});

      final headings = await repo.getHeadings(id);
      expect(headings.single.content, 'Giriş');
    });

    test('yalnızca değişen alanlar yazılır, değişiklik yoksa hiçbir şey',
        () async {
      final id = await repo.createNote(title: 'A', body: 'x');
      final before = (await db.select(db.changeLog).get()).length;

      await repo.updateNote(id, const NoteChanges(title: Value('A')));
      expect((await db.select(db.changeLog).get()).length, before);

      clock += 1000;
      await repo.updateNote(
          id, const NoteChanges(title: Value('A'), body: Value('yeni')));
      final after = await db.select(db.changeLog).get();
      expect(after.length, before + 1);
      expect(
        after.where((e) => e.field == 'body' && e.value == jsonEncode('yeni')),
        hasLength(1),
      );
    });

    test('sabitleme değiştirme tarihini değiştirmez, içerik değiştirir',
        () async {
      final id = await repo.createNote(title: 'A');
      final created = (await repo.getNote(id))!.updatedAt;

      clock += 5000;
      await repo.updateNote(id, const NoteChanges(pinned: Value(true)));
      expect((await repo.getNote(id))!.updatedAt, created);

      clock += 5000;
      await repo.updateNote(id, const NoteChanges(body: Value('içerik')));
      expect((await repo.getNote(id))!.updatedAt, clock);
    });

    test('gövde değişince başlıklar ve boyut güncellenir', () async {
      final id = await repo.createNote(body: '# Bir');
      await repo.updateNote(
          id, const NoteChanges(body: Value('# Bir\n## İki\n### Üç')));
      final h = await repo.getHeadings(id);
      expect(h.map((e) => e.content), ['Bir', 'İki', 'Üç']);
      expect((await repo.getNote(id))!.sizeBytes,
          utf8.encode('# Bir\n## İki\n### Üç').length);
    });

    test('sürüm geçmişi: oturum başına bir sürüm', () async {
      final id = await repo.createNote(body: 'v1');

      clock += 1000;
      await repo.updateNote(id, const NoteChanges(body: Value('v2')));
      expect((await repo.listRevisions(id)).map((r) => r.body), ['v1']);

      clock += 60 * 1000; // 1 dk sonra: aynı oturum
      await repo.updateNote(id, const NoteChanges(body: Value('v3')));
      expect(await repo.listRevisions(id), hasLength(1));

      clock += 11 * 60 * 1000; // 11 dk sonra: yeni oturum
      await repo.updateNote(id, const NoteChanges(body: Value('v4')));
      expect((await repo.listRevisions(id)).map((r) => r.body), ['v3', 'v1']);
    });

    test('sürüm geri yükleme', () async {
      final id = await repo.createNote(body: 'eski');
      clock += 1000;
      await repo.updateNote(id, const NoteChanges(body: Value('yeni')));
      final rev = (await repo.listRevisions(id)).single;

      clock += 11 * 60 * 1000;
      await repo.restoreRevision(id, rev.id);
      expect((await repo.getNote(id))!.body, 'eski');
    });

    test('kısa not ↔ not geçişi', () async {
      final s =
          await repo.createNote(kind: NoteKind.snippet, title: 'Port 5432');
      expect(await ids(const NoteQuery(kind: NoteKind.snippet)), {s});

      await repo.updateNote(s, const NoteChanges(kind: Value(NoteKind.note)));
      expect(await ids(const NoteQuery(kind: NoteKind.snippet)), isEmpty);
      expect(await ids(const NoteQuery(kind: NoteKind.note)), {s});
    });

    test('arşiv ve çöp kutusu kapsamları', () async {
      final a = await repo.createNote(title: 'a');
      final b = await repo.createNote(title: 'b');
      final c = await repo.createNote(title: 'c');
      await repo.updateNote(b, const NoteChanges(archived: Value(true)));
      await repo.trashNote(c);

      expect(await ids(const NoteQuery()), {a});
      expect(await ids(const NoteQuery(scope: NoteScope.archived)), {b});
      expect(await ids(const NoteQuery(scope: NoteScope.trash)), {c});

      await repo.restoreNote(c);
      expect(await ids(const NoteQuery()), {a, c});
    });
  });

  group('arama', () {
    test('başlık eşleşmesi gövdeden önce gelir, çöptekiler çıkmaz', () async {
      final inBody = await repo.createNote(
          title: 'Günlük', body: 'postgres yedek alındı');
      final inTitle = await repo.createNote(
          title: 'Postgres yedekleme', body: 'pg_basebackup');

      final hits = await repo.listNotes(
          const NoteQuery(search: 'postgres', sort: NoteSort.relevance));
      expect(hits.map((n) => n.id), [inTitle, inBody]);

      await repo.trashNote(inTitle);
      expect(await ids(const NoteQuery(search: 'postgres')), {inBody});
    });
  });

  group('sıralama', () {
    test('başlık Türk alfabesine göre, sabitlenmiş en üstte', () async {
      for (final t in ['Zeytin', 'çay', 'Cam', 'Işık', 'ilaç']) {
        await repo.createNote(title: t);
      }
      Future<List<String>> titles() async => (await repo.listNotes(
              const NoteQuery(sort: NoteSort.title, descending: false)))
          .map((n) => n.title)
          .toList();

      expect(await titles(), ['Cam', 'çay', 'Işık', 'ilaç', 'Zeytin']);

      final z = (await repo.listNotes(const NoteQuery()))
          .firstWhere((n) => n.title == 'Zeytin');
      await repo.updateNote(z.id, const NoteChanges(pinned: Value(true)));
      expect((await titles()).first, 'Zeytin');
    });

    test('boyuta göre', () async {
      await repo.createNote(title: 'kısa');
      await repo.createNote(title: 'çok daha uzun bir başlık');
      final list = await repo.listNotes(
          const NoteQuery(sort: NoteSort.size, descending: true));
      expect(list.first.title, 'çok daha uzun bir başlık');
    });

    test('etikete göre: etiketsizler sonda', () async {
      final b = await repo.createTag(name: 'beta');
      final a = await repo.createTag(name: 'alfa');
      final n1 = await repo.createNote(title: '1');
      final n2 = await repo.createNote(title: '2');
      final n3 = await repo.createNote(title: '3');
      await repo.setNoteTags(n1, {b});
      await repo.setNoteTags(n2, {a});

      final list = await repo.listNotes(
          const NoteQuery(sort: NoteSort.tag, descending: false));
      expect(list.map((n) => n.id), [n2, n1, n3]);
    });
  });

  group('klasörler', () {
    test('alt klasörler dahil/hariç ve kök filtresi', () async {
      final proje = await repo.createFolder(name: 'Projeler');
      final alt =
          await repo.createFolder(name: 'Not Uygulaması', parentId: proje);
      final n1 = await repo.createNote(folderId: proje, title: 'üst');
      final n2 = await repo.createNote(folderId: alt, title: 'alt');
      final n3 = await repo.createNote(title: 'kök');

      expect(await ids(NoteQuery(folderId: proje)), {n1, n2});
      expect(await ids(NoteQuery(folderId: proje, includeSubfolders: false)),
          {n1});
      expect(await ids(const NoteQuery(rootOnly: true)), {n3});
    });

    test('klasör çöpe: alt klasör ve notlar gider, geri yükleme geri getirir',
        () async {
      final proje = await repo.createFolder(name: 'Projeler');
      final alt = await repo.createFolder(name: 'Alt', parentId: proje);
      final n1 = await repo.createNote(folderId: proje);
      final n2 = await repo.createNote(folderId: alt);
      final onceSilinen = await repo.createNote(folderId: alt);
      final kok = await repo.createNote();

      await repo.trashNote(onceSilinen);
      clock += 1000;
      await repo.trashFolder(proje);

      expect(await ids(const NoteQuery()), {kok});
      expect((await repo.listFolders()), isEmpty);

      clock += 1000;
      await repo.restoreFolder(proje);
      expect(await ids(const NoteQuery()), {kok, n1, n2});
      expect((await repo.listFolders()).map((f) => f.id).toSet(),
          {proje, alt});
      expect(await ids(const NoteQuery(scope: NoteScope.trash)),
          {onceSilinen});
    });

    test('klasör kendi alt klasörüne taşınamaz', () async {
      final a = await repo.createFolder(name: 'A');
      final b = await repo.createFolder(name: 'B', parentId: a);
      await expectLater(
          repo.moveFolder(a, b), throwsA(isA<FolderCycleException>()));
      await repo.moveFolder(b, null);
      expect((await repo.listFolders()).firstWhere((f) => f.id == b).parentId,
          isNull);
    });
  });

  group('etiketler', () {
    test('etiket filtresi, etiketle arama ve yeniden adlandırma', () async {
      final tag = await repo.createTag(name: 'Güvenlik');
      final n = await repo.createNote(title: 'Firewall kuralları');
      await repo.createNote(title: 'Başka not');
      await repo.setNoteTags(n, {tag});

      expect(await ids(NoteQuery(tagId: tag)), {n});
      expect(await ids(const NoteQuery(search: 'guvenlik')), {n});

      await repo.updateTag(tag, name: const Value('Emniyet'));
      expect(await ids(const NoteQuery(search: 'emniyet')), {n});
      expect(await ids(const NoteQuery(search: 'guvenlik')), isEmpty);

      await repo.setNoteTags(n, {});
      expect(await ids(NoteQuery(tagId: tag)), isEmpty);

      // Kaldırılan etiket yeniden eklenebilir.
      await repo.setNoteTags(n, {tag});
      expect(await ids(NoteQuery(tagId: tag)), {n});
    });
  });

  test('HLC yeniden açılışta en büyük damgadan devam eder', () async {
    await repo.createNote(title: 'a');
    final maxBefore = (await db.select(db.changeLog).get())
        .map((e) => e.hlc)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);

    clock -= 500000; // cihaz saati geri alındı
    final reopened = await NotesRepository.open(db, now: () => clock);
    await reopened.createNote(title: 'b');

    final newest = (await db.select(db.changeLog).get())
        .map((e) => e.hlc)
        .reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    expect(newest.compareTo(maxBefore) > 0, isTrue);
    expect(reopened.deviceId, repo.deviceId);
  });
}
