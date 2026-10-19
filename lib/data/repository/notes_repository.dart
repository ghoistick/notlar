import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/hlc/hlc.dart';
import '../../core/ids.dart';
import '../../core/text/headings.dart';
import '../../core/text/search_text.dart';
import '../../core/text/turkish_collation.dart';
import '../db/database.dart';
import 'note_query.dart';

export 'note_query.dart';

class NotFoundException implements Exception {
  final String what;
  const NotFoundException(this.what);

  @override
  String toString() => 'NotFoundException: $what bulunamadı.';
}

/// Bir klasörü kendi alt klasörünün içine taşımaya çalışıldı.
class FolderCycleException implements Exception {
  const FolderCycleException();

  @override
  String toString() =>
      'FolderCycleException: Klasör kendi alt klasörüne taşınamaz.';
}

/// Bir notta değiştirilecek alanlar. Verilmeyen alanlar olduğu gibi kalır.
///
///   repo.updateNote(id, const NoteChanges(pinned: Value(true)));
class NoteChanges {
  final Value<String> title;
  final Value<String> body;
  final Value<String?> folderId;
  final Value<String?> color;
  final Value<NoteKind> kind;
  final Value<NoteType> type;
  final Value<bool> pinned;
  final Value<bool> archived;
  final Value<bool> locked;

  const NoteChanges({
    this.title = const Value.absent(),
    this.body = const Value.absent(),
    this.folderId = const Value.absent(),
    this.color = const Value.absent(),
    this.kind = const Value.absent(),
    this.type = const Value.absent(),
    this.pinned = const Value.absent(),
    this.archived = const Value.absent(),
    this.locked = const Value.absent(),
  });
}

/// Uygulamanın notlara, klasörlere ve etiketlere eriştiği tek kapı.
///
/// Her yazma işlemi tek bir veritabanı işlemi (transaction) içinde:
///  - değişen alanları HLC damgasıyla change_log'a yazar (senkronizasyon için),
///  - başlıkları ve arama indeksini günceller,
///  - gerektiğinde sürüm geçmişine kayıt düşer.
/// Arayüz tabloları asla doğrudan değiştirmez; aksi halde bu tutarlılık bozulur.
class NotesRepository {
  /// Aynı not üzerinde bu süre içindeki düzenlemeler tek sürüm sayılır.
  static const revisionInterval = Duration(minutes: 10);

  final AppDatabase _db;
  final HlcClock _clock;
  final int Function() _now;

  NotesRepository._(this._db, this._clock, this._now);

  static Future<NotesRepository> open(
    AppDatabase db, {
    int Function()? now,
  }) async {
    final clockNow = now ?? () => DateTime.now().millisecondsSinceEpoch;
    final deviceId = await _ensureDeviceId(db);

    // Saat, şimdiye kadar görülmüş en büyük damgadan devam eder. Böylece cihaz
    // saati geri alınmış olsa bile yeni değişiklikler eskilerden "yeni" sayılır.
    final row =
        await db.customSelect('SELECT MAX(hlc) AS h FROM change_log').getSingle();
    final last = row.read<String?>('h');

    return NotesRepository._(
      db,
      HlcClock(deviceId,
          now: clockNow, last: last == null ? null : Hlc.parse(last)),
      clockNow,
    );
  }

  String get deviceId => _clock.nodeId;

  // ---------------------------------------------------------------- Notlar

  Future<String> createNote({
    String? folderId,
    NoteKind kind = NoteKind.note,
    NoteType type = NoteType.text,
    String title = '',
    String body = '',
    String? color,
  }) {
    return _db.transaction(() async {
      final now = _now();
      final hlc = _clock.tick().pack();
      final id = uuidV7(millis: now);

      await _db.into(_db.notes).insert(NotesCompanion.insert(
            id: id,
            folderId: Value(folderId),
            kind: Value(kind),
            type: Value(type),
            title: Value(title),
            body: Value(body),
            color: Value(color),
            sizeBytes: Value(_size(title, body)),
            createdAt: now,
            updatedAt: now,
            hlc: hlc,
          ));

      await _log('note', id, {
        'folder_id': folderId,
        'kind': kind.name,
        'type': type.name,
        'title': title,
        'body': body,
        'color': color,
        'pinned': false,
        'archived': false,
        'locked': false,
        'created_at': now,
      }, hlc);

      await _rebuildHeadings(id, body);
      await _reindex(id);
      return id;
    });
  }

  Future<Note?> getNote(String id) =>
      (_db.select(_db.notes)..where((n) => n.id.equals(id))).getSingleOrNull();

  /// Notun güncel halini yayınlar (sabitleme, renk, klasör değişince arayüz
  /// kendini günceller).
  Stream<Note?> watchNote(String id) =>
      (_db.select(_db.notes)..where((n) => n.id.equals(id)))
          .watchSingleOrNull();

  /// Not listesindeki "içindekiler" özeti için her notun ilk birkaç
  /// üst düzey başlığı (# ve ##).
  Stream<Map<String, List<String>>> watchHeadingSummaries({int perNote = 4}) {
    return _db
        .customSelect(
          'SELECT note_id, content FROM note_headings '
          'WHERE level <= 2 ORDER BY note_id, position',
          readsFrom: {_db.noteHeadings},
        )
        .watch()
        .map((rows) {
      final map = <String, List<String>>{};
      for (final r in rows) {
        final list = map.putIfAbsent(r.read<String>('note_id'), () => []);
        if (list.length < perNote) list.add(r.read<String>('content'));
      }
      return map;
    });
  }

  /// Yalnızca gerçekten değişen alanlar yazılır. Hiçbir şey değişmediyse
  /// veritabanına dokunulmaz; otomatik kaydetme sık çağırsa da sorun olmaz.
  ///
  /// "Değiştirme tarihi" yalnızca içerik (başlık, gövde, tür) değişince
  /// güncellenir. Sabitleme, renk veya klasör değişikliği notu tarih
  /// sıralamasında yukarı taşımaz.
  Future<void> updateNote(String id, NoteChanges c) {
    return _db.transaction(() async {
      final cur = await _requireNote(id);

      final diff = <String, Object?>{};
      if (c.title.present && c.title.value != cur.title) {
        diff['title'] = c.title.value;
      }
      if (c.body.present && c.body.value != cur.body) {
        diff['body'] = c.body.value;
      }
      if (c.folderId.present && c.folderId.value != cur.folderId) {
        diff['folder_id'] = c.folderId.value;
      }
      if (c.color.present && c.color.value != cur.color) {
        diff['color'] = c.color.value;
      }
      if (c.kind.present && c.kind.value != cur.kind) {
        diff['kind'] = c.kind.value.name;
      }
      if (c.type.present && c.type.value != cur.type) {
        diff['type'] = c.type.value.name;
      }
      if (c.pinned.present && c.pinned.value != cur.pinned) {
        diff['pinned'] = c.pinned.value;
      }
      if (c.archived.present && c.archived.value != cur.archived) {
        diff['archived'] = c.archived.value;
      }
      if (c.locked.present && c.locked.value != cur.locked) {
        diff['locked'] = c.locked.value;
      }
      if (diff.isEmpty) return;

      final now = _now();
      final hlc = _clock.tick().pack();
      final textChanged = diff.containsKey('title') || diff.containsKey('body');
      final contentChanged = textChanged || diff.containsKey('type');
      final newTitle = c.title.present ? c.title.value : cur.title;
      final newBody = c.body.present ? c.body.value : cur.body;

      if (textChanged) await _maybeSaveRevision(cur, now, hlc);

      await (_db.update(_db.notes)..where((n) => n.id.equals(id)))
          .write(NotesCompanion(
        title: c.title,
        body: c.body,
        folderId: c.folderId,
        color: c.color,
        kind: c.kind,
        type: c.type,
        pinned: c.pinned,
        archived: c.archived,
        locked: c.locked,
        sizeBytes: Value(_size(newTitle, newBody)),
        updatedAt: contentChanged ? Value(now) : const Value.absent(),
        hlc: Value(hlc),
      ));

      await _log('note', id, diff, hlc);
      if (diff.containsKey('body')) await _rebuildHeadings(id, newBody);
      if (textChanged) await _reindex(id);
    });
  }

  Future<void> trashNote(String id) => _setNoteDeleted(id, _now());

  Future<void> restoreNote(String id) => _setNoteDeleted(id, null);

  Future<void> _setNoteDeleted(String id, int? deletedAt) {
    return _db.transaction(() async {
      final cur = await _requireNote(id);
      if (cur.deletedAt == deletedAt) return;
      final hlc = _clock.tick().pack();
      await (_db.update(_db.notes)..where((n) => n.id.equals(id))).write(
          NotesCompanion(deletedAt: Value(deletedAt), hlc: Value(hlc)));
      await _log('note', id, {'deleted_at': deletedAt}, hlc);
    });
  }

  Future<List<NoteHeading>> getHeadings(String noteId) =>
      (_db.select(_db.noteHeadings)
            ..where((h) => h.noteId.equals(noteId))
            ..orderBy([(h) => OrderingTerm.asc(h.position)]))
          .get();

  // ---------------------------------------------------------- Sürüm geçmişi

  Future<List<Revision>> listRevisions(String noteId) =>
      (_db.select(_db.revisions)
            ..where((r) => r.noteId.equals(noteId))
            ..orderBy([(r) => OrderingTerm.desc(r.createdAt)]))
          .get();

  /// Eski bir sürümü geri yükler. Mevcut hal de sürüm geçmişine düşer,
  /// yani geri yükleme işlemi de geri alınabilir.
  Future<void> restoreRevision(String noteId, String revisionId) async {
    final rev = await (_db.select(_db.revisions)
          ..where((r) => r.id.equals(revisionId) & r.noteId.equals(noteId)))
        .getSingleOrNull();
    if (rev == null) throw const NotFoundException('Sürüm');
    await updateNote(
        noteId, NoteChanges(title: Value(rev.title), body: Value(rev.body)));
  }

  /// Değişiklikten önceki hali saklar; ancak son sürümden bu yana
  /// [revisionInterval] geçmişse. Böylece her tuş vuruşu sürüm oluşturmaz,
  /// her düzenleme oturumunun başlangıç hali saklanır.
  Future<void> _maybeSaveRevision(Note cur, int now, String hlc) async {
    if (cur.title.isEmpty && cur.body.isEmpty) return;
    final row = await _db.customSelect(
      'SELECT MAX(created_at) AS t FROM revisions WHERE note_id = ?',
      variables: [Variable.withString(cur.id)],
    ).getSingle();
    final last = row.read<int?>('t');
    if (last != null && now - last < revisionInterval.inMilliseconds) return;

    await _db.into(_db.revisions).insert(RevisionsCompanion.insert(
          id: uuidV7(millis: now),
          noteId: cur.id,
          title: cur.title,
          body: cur.body,
          createdAt: now,
          hlc: hlc,
        ));
  }

  // ------------------------------------------------------------- Listeleme

  Future<List<Note>> listNotes(NoteQuery q) async =>
      _postSort(q, await _selectNotes(q).get());

  /// Veritabanı değiştikçe güncel listeyi yayınlar; arayüz bunu dinler.
  Stream<List<Note>> watchNotes(NoteQuery q) =>
      _selectNotes(q).watch().map((list) => _postSort(q, list));

  Selectable<Note> _selectNotes(NoteQuery q) {
    final cte = StringBuffer();
    final cteVars = <Variable>[];
    final joins = StringBuffer();
    final joinVars = <Variable>[];
    final extraCols = StringBuffer();
    final where = <String>[];
    final whereVars = <Variable>[];

    switch (q.scope) {
      case NoteScope.active:
        where.add('n.deleted_at IS NULL AND n.archived = 0');
      case NoteScope.archived:
        where.add('n.deleted_at IS NULL AND n.archived = 1');
      case NoteScope.trash:
        where.add('n.deleted_at IS NOT NULL');
    }

    if (q.folderId != null) {
      if (q.includeSubfolders) {
        cte.write('WITH RECURSIVE sub(id) AS ('
            'SELECT ? UNION ALL '
            'SELECT f.id FROM folders f JOIN sub s ON f.parent_id = s.id '
            'WHERE f.deleted_at IS NULL) ');
        cteVars.add(Variable.withString(q.folderId!));
        where.add('n.folder_id IN (SELECT id FROM sub)');
      } else {
        where.add('n.folder_id = ?');
        whereVars.add(Variable.withString(q.folderId!));
      }
    } else if (q.rootOnly) {
      where.add('n.folder_id IS NULL');
    }

    if (q.tagId != null) {
      where.add('EXISTS (SELECT 1 FROM note_tags nt WHERE nt.note_id = n.id '
          'AND nt.tag_id = ? AND nt.deleted_at IS NULL)');
      whereVars.add(Variable.withString(q.tagId!));
    }
    if (q.kind != null) {
      where.add('n.kind = ?');
      whereVars.add(Variable.withString(q.kind!.name));
    }
    if (q.color != null) {
      where.add('n.color = ?');
      whereVars.add(Variable.withString(q.color!));
    }

    final dateCol =
        q.dateField == DateField.createdAt ? 'n.created_at' : 'n.updated_at';
    if (q.from != null) {
      where.add('$dateCol >= ?');
      whereVars.add(Variable.withInt(q.from!));
    }
    if (q.to != null) {
      where.add('$dateCol <= ?');
      whereVars.add(Variable.withInt(q.to!));
    }

    final fts = q.search == null ? null : buildFtsQuery(q.search!);
    if (fts != null) {
      // Sütun ağırlıkları: başlık > içindekiler > etiket > gövde.
      joins.write(' JOIN (SELECT note_id, '
          'bm25(notes_fts, 0.0, 10.0, 1.0, 3.0, 5.0) AS rank '
          'FROM notes_fts WHERE notes_fts MATCH ?) f ON f.note_id = n.id');
      joinVars.add(Variable.withString(fts));
    }

    final dir = q.descending ? 'DESC' : 'ASC';
    final order = <String>[];
    if (q.scope != NoteScope.trash) order.add('n.pinned DESC');

    switch (q.sort) {
      case NoteSort.updatedAt:
        order.add('n.updated_at $dir');
      case NoteSort.createdAt:
        order.add('n.created_at $dir');
      case NoteSort.size:
        order.add('n.size_bytes $dir');
      case NoteSort.title:
        order.add('n.title $dir'); // _postSort Türk alfabesine göre düzeltir
      case NoteSort.color:
        order
          ..add('(n.color IS NULL) ASC')
          ..add('n.color $dir');
      case NoteSort.tag:
        extraCols.write(', (SELECT MIN(t.name) FROM note_tags nt '
            'JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id '
            'AND nt.deleted_at IS NULL AND t.deleted_at IS NULL) AS tag_key');
        order
          ..add('(tag_key IS NULL) ASC')
          ..add('tag_key $dir');
      case NoteSort.relevance:
        order.add(fts != null ? 'f.rank ASC' : 'n.updated_at DESC');
    }
    order.add('n.id');

    final sql = '${cte}SELECT n.*$extraCols FROM notes n$joins '
        'WHERE ${where.join(' AND ')} ORDER BY ${order.join(', ')}';

    return _db.customSelect(
      sql,
      variables: [...cteVars, ...joinVars, ...whereVars],
      readsFrom: {_db.notes, _db.noteTags, _db.tags, _db.folders},
    ).asyncMap(_db.notes.mapFromRow);
  }

  List<Note> _postSort(NoteQuery q, List<Note> notes) {
    if (q.sort != NoteSort.title) return notes;
    final keys = {for (final n in notes) n.id: turkishSortKey(n.title)};
    final pinnedFirst = q.scope != NoteScope.trash;
    final sign = q.descending ? -1 : 1;
    return [...notes]..sort((a, b) {
        if (pinnedFirst && a.pinned != b.pinned) return a.pinned ? -1 : 1;
        final c = compareSortKeys(keys[a.id]!, keys[b.id]!);
        return c != 0 ? c * sign : a.id.compareTo(b.id);
      });
  }

  // ------------------------------------------------------------- Klasörler

  Future<String> createFolder({
    required String name,
    String? parentId,
    String? color,
  }) {
    return _db.transaction(() async {
      final now = _now();
      final hlc = _clock.tick().pack();
      final id = uuidV7(millis: now);

      final row = await _db.customSelect(
        'SELECT COALESCE(MAX(position), -1) + 1 AS p FROM folders '
        'WHERE parent_id IS ? AND deleted_at IS NULL',
        variables: [Variable<String>(parentId)],
      ).getSingle();
      final position = row.read<int>('p');

      await _db.into(_db.folders).insert(FoldersCompanion.insert(
            id: id,
            parentId: Value(parentId),
            name: name,
            color: Value(color),
            position: Value(position),
            createdAt: now,
            updatedAt: now,
            hlc: hlc,
          ));
      await _log('folder', id, {
        'parent_id': parentId,
        'name': name,
        'color': color,
        'position': position,
        'created_at': now,
      }, hlc);
      return id;
    });
  }

  Future<List<Folder>> listFolders() => (_db.select(_db.folders)
        ..where((f) => f.deletedAt.isNull())
        ..orderBy([
          (f) => OrderingTerm.asc(f.position),
          (f) => OrderingTerm.asc(f.name),
        ]))
      .get();

  Stream<List<Folder>> watchFolders() => (_db.select(_db.folders)
        ..where((f) => f.deletedAt.isNull())
        ..orderBy([
          (f) => OrderingTerm.asc(f.position),
          (f) => OrderingTerm.asc(f.name),
        ]))
      .watch();

  Future<void> updateFolder(
    String id, {
    Value<String> name = const Value.absent(),
    Value<String?> color = const Value.absent(),
  }) {
    return _db.transaction(() async {
      final cur = await _requireFolder(id);
      final diff = <String, Object?>{};
      if (name.present && name.value != cur.name) diff['name'] = name.value;
      if (color.present && color.value != cur.color) diff['color'] = color.value;
      if (diff.isEmpty) return;

      final hlc = _clock.tick().pack();
      await (_db.update(_db.folders)..where((f) => f.id.equals(id))).write(
          FoldersCompanion(
              name: name,
              color: color,
              updatedAt: Value(_now()),
              hlc: Value(hlc)));
      await _log('folder', id, diff, hlc);
    });
  }

  /// Klasörü başka bir klasörün altına (ya da [newParentId] null ise köke) taşır.
  Future<void> moveFolder(String id, String? newParentId) {
    return _db.transaction(() async {
      final cur = await _requireFolder(id);
      if (cur.parentId == newParentId) return;
      if (newParentId != null) {
        final subtree = await _subtreeIds(id);
        if (subtree.contains(newParentId)) throw const FolderCycleException();
      }
      final hlc = _clock.tick().pack();
      await (_db.update(_db.folders)..where((f) => f.id.equals(id))).write(
          FoldersCompanion(
              parentId: Value(newParentId),
              updatedAt: Value(_now()),
              hlc: Value(hlc)));
      await _log('folder', id, {'parent_id': newParentId}, hlc);
    });
  }

  /// Klasörü, tüm alt klasörlerini ve içlerindeki notları çöp kutusuna taşır.
  /// Hepsine aynı silinme zamanı yazılır; geri yükleme bunu kullanır.
  Future<void> trashFolder(String id) {
    return _db.transaction(() async {
      await _requireFolder(id);
      final now = _now();
      final hlc = _clock.tick().pack();
      final folderIds = await _subtreeIds(id);

      final noteIds = await (_db.selectOnly(_db.notes)
            ..addColumns([_db.notes.id])
            ..where(_db.notes.folderId.isIn(folderIds) &
                _db.notes.deletedAt.isNull()))
          .map((r) => r.read(_db.notes.id)!)
          .get();

      await (_db.update(_db.folders)..where((f) => f.id.isIn(folderIds)))
          .write(FoldersCompanion(deletedAt: Value(now), hlc: Value(hlc)));
      await (_db.update(_db.notes)..where((n) => n.id.isIn(noteIds)))
          .write(NotesCompanion(deletedAt: Value(now), hlc: Value(hlc)));

      for (final f in folderIds) {
        await _log('folder', f, {'deleted_at': now}, hlc);
      }
      for (final n in noteIds) {
        await _log('note', n, {'deleted_at': now}, hlc);
      }
    });
  }

  /// [trashFolder] ile birlikte silinenleri geri getirir. Klasör silinmeden
  /// önce ayrıca çöpe atılmış notlar çöp kutusunda kalır.
  Future<void> restoreFolder(String id) {
    return _db.transaction(() async {
      final cur = await _requireFolder(id);
      final ts = cur.deletedAt;
      if (ts == null) return;
      final hlc = _clock.tick().pack();

      final folderIds = (await _subtreeIds(id, includeDeleted: true))
          .toList();
      final restoredFolders = await (_db.select(_db.folders)
            ..where((f) => f.id.isIn(folderIds) & f.deletedAt.equals(ts)))
          .map((f) => f.id)
          .get();
      final noteIds = await (_db.selectOnly(_db.notes)
            ..addColumns([_db.notes.id])
            ..where(_db.notes.folderId.isIn(restoredFolders) &
                _db.notes.deletedAt.equals(ts)))
          .map((r) => r.read(_db.notes.id)!)
          .get();

      await (_db.update(_db.folders)..where((f) => f.id.isIn(restoredFolders)))
          .write(FoldersCompanion(deletedAt: const Value(null), hlc: Value(hlc)));
      await (_db.update(_db.notes)..where((n) => n.id.isIn(noteIds)))
          .write(NotesCompanion(deletedAt: const Value(null), hlc: Value(hlc)));

      for (final f in restoredFolders) {
        await _log('folder', f, {'deleted_at': null}, hlc);
      }
      for (final n in noteIds) {
        await _log('note', n, {'deleted_at': null}, hlc);
      }

      // Üst klasör hâlâ çöpteyse geri gelen klasör köke taşınır.
      if (cur.parentId != null) {
        final parent = await (_db.select(_db.folders)
              ..where((f) => f.id.equals(cur.parentId!)))
            .getSingleOrNull();
        if (parent == null || parent.deletedAt != null) {
          await (_db.update(_db.folders)..where((f) => f.id.equals(id)))
              .write(FoldersCompanion(
                  parentId: const Value(null), hlc: Value(hlc)));
          await _log('folder', id, {'parent_id': null}, hlc);
        }
      }
    });
  }

  Future<Set<String>> _subtreeIds(String rootId,
      {bool includeDeleted = false}) async {
    final filter = includeDeleted ? '' : 'WHERE f.deleted_at IS NULL';
    final rows = await _db.customSelect(
      'WITH RECURSIVE sub(id) AS ('
      'SELECT ? UNION ALL '
      'SELECT f.id FROM folders f JOIN sub s ON f.parent_id = s.id $filter) '
      'SELECT id FROM sub',
      variables: [Variable.withString(rootId)],
    ).get();
    return rows.map((r) => r.read<String>('id')).toSet();
  }

  // -------------------------------------------------------------- Etiketler

  Future<String> createTag({
    required String name,
    String? color,
    String? parentId,
  }) {
    return _db.transaction(() async {
      final now = _now();
      final hlc = _clock.tick().pack();
      final id = uuidV7(millis: now);
      await _db.into(_db.tags).insert(TagsCompanion.insert(
            id: id,
            name: name,
            color: Value(color),
            parentId: Value(parentId),
            createdAt: now,
            updatedAt: now,
            hlc: hlc,
          ));
      await _log('tag', id, {
        'name': name,
        'color': color,
        'parent_id': parentId,
        'created_at': now,
      }, hlc);
      return id;
    });
  }

  Future<List<Tag>> listTags() => (_db.select(_db.tags)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .get();

  Future<void> updateTag(
    String id, {
    Value<String> name = const Value.absent(),
    Value<String?> color = const Value.absent(),
  }) {
    return _db.transaction(() async {
      final cur = await (_db.select(_db.tags)..where((t) => t.id.equals(id)))
          .getSingleOrNull();
      if (cur == null) throw const NotFoundException('Etiket');

      final diff = <String, Object?>{};
      if (name.present && name.value != cur.name) diff['name'] = name.value;
      if (color.present && color.value != cur.color) diff['color'] = color.value;
      if (diff.isEmpty) return;

      final hlc = _clock.tick().pack();
      await (_db.update(_db.tags)..where((t) => t.id.equals(id))).write(
          TagsCompanion(
              name: name,
              color: color,
              updatedAt: Value(_now()),
              hlc: Value(hlc)));
      await _log('tag', id, diff, hlc);

      // Etiket adı arama indeksinde geçtiği için ilgili notlar yeniden indekslenir.
      if (diff.containsKey('name')) {
        for (final noteId in await _notesWithTag(id)) {
          await _reindex(noteId);
        }
      }
    });
  }

  Future<void> trashTag(String id) {
    return _db.transaction(() async {
      final now = _now();
      final hlc = _clock.tick().pack();
      final affected = await _notesWithTag(id);

      await (_db.update(_db.tags)..where((t) => t.id.equals(id)))
          .write(TagsCompanion(deletedAt: Value(now), hlc: Value(hlc)));
      await _log('tag', id, {'deleted_at': now}, hlc);

      for (final noteId in affected) {
        await _removeTagLink(noteId, id, now, hlc);
        await _reindex(noteId);
      }
    });
  }

  /// Notun etiketlerini verilen kümeyle eşitler.
  Future<void> setNoteTags(String noteId, Set<String> tagIds) {
    return _db.transaction(() async {
      await _requireNote(noteId);
      final current = (await (_db.select(_db.noteTags)
                ..where((nt) => nt.noteId.equals(noteId) & nt.deletedAt.isNull()))
              .get())
          .map((nt) => nt.tagId)
          .toSet();

      final toAdd = tagIds.difference(current);
      final toRemove = current.difference(tagIds);
      if (toAdd.isEmpty && toRemove.isEmpty) return;

      final now = _now();
      final hlc = _clock.tick().pack();

      for (final tagId in toAdd) {
        await _db.into(_db.noteTags).insertOnConflictUpdate(
              NoteTagsCompanion.insert(
                noteId: noteId,
                tagId: tagId,
                createdAt: now,
                updatedAt: now,
                deletedAt: const Value(null),
                hlc: hlc,
              ),
            );
        await _log('note_tag', '$noteId|$tagId', {'deleted_at': null}, hlc);
      }
      for (final tagId in toRemove) {
        await _removeTagLink(noteId, tagId, now, hlc);
      }
      await _reindex(noteId);
    });
  }

  Stream<List<Tag>> watchTags() => (_db.select(_db.tags)
        ..where((t) => t.deletedAt.isNull())
        ..orderBy([(t) => OrderingTerm.asc(t.name)]))
      .watch();

  Future<List<Tag>> tagsOfNote(String noteId) => _tagsOfNoteQuery(noteId).get();

  Stream<List<Tag>> watchTagsOfNote(String noteId) =>
      _tagsOfNoteQuery(noteId).watch();

  Selectable<Tag> _tagsOfNoteQuery(String noteId) {
    final q = _db.select(_db.tags).join([
      innerJoin(_db.noteTags, _db.noteTags.tagId.equalsExp(_db.tags.id)),
    ])
      ..where(_db.noteTags.noteId.equals(noteId) &
          _db.noteTags.deletedAt.isNull() &
          _db.tags.deletedAt.isNull())
      ..orderBy([OrderingTerm.asc(_db.tags.name)]);
    return q.map((row) => row.readTable(_db.tags));
  }

  Future<void> _removeTagLink(
      String noteId, String tagId, int now, String hlc) async {
    await (_db.update(_db.noteTags)
          ..where((nt) => nt.noteId.equals(noteId) & nt.tagId.equals(tagId)))
        .write(NoteTagsCompanion(
            deletedAt: Value(now), updatedAt: Value(now), hlc: Value(hlc)));
    await _log('note_tag', '$noteId|$tagId', {'deleted_at': now}, hlc);
  }

  Future<List<String>> _notesWithTag(String tagId) async {
    final rows = await (_db.select(_db.noteTags)
          ..where((nt) => nt.tagId.equals(tagId) & nt.deletedAt.isNull()))
        .get();
    return rows.map((r) => r.noteId).toList();
  }

  // -------------------------------------------------------------- Yardımcılar

  /// Her alan değişikliği ayrı bir işlem olarak kaydedilir. Senkronizasyonda
  /// iki cihaz aynı notun farklı alanlarını değiştirirse ikisi de korunur.
  Future<void> _log(
    String entity,
    String entityId,
    Map<String, Object?> fields,
    String hlc,
  ) async {
    for (final e in fields.entries) {
      await _db.into(_db.changeLog).insert(ChangeLogCompanion.insert(
            opId: uuidV7(millis: _now()),
            entity: entity,
            entityId: entityId,
            field: e.key,
            value: Value(jsonEncode(e.value)),
            hlc: hlc,
            deviceId: deviceId,
          ));
    }
  }

  Future<void> _rebuildHeadings(String noteId, String body) async {
    await (_db.delete(_db.noteHeadings)..where((h) => h.noteId.equals(noteId)))
        .go();
    for (final h in extractHeadings(body)) {
      await _db.into(_db.noteHeadings).insert(NoteHeadingsCompanion.insert(
            noteId: noteId,
            position: h.position,
            level: h.level,
            content: h.content,
            line: h.line,
          ));
    }
  }

  /// Notun arama indeksindeki satırını yeniler.
  Future<void> _reindex(String noteId) async {
    final note = await _requireNote(noteId);
    final tagNames = (await tagsOfNote(noteId)).map((t) => t.name).join(' ');
    final headingText =
        (await getHeadings(noteId)).map((h) => h.content).join(' ');

    await _db.customStatement(
        'DELETE FROM notes_fts WHERE note_id = ?', [noteId]);
    await _db.customStatement(
      'INSERT INTO notes_fts(note_id, title, body, tags, headings) '
      'VALUES (?, ?, ?, ?, ?)',
      [
        noteId,
        foldForSearch(stripInlineMarkup(note.title)),
        foldForSearch(stripInlineMarkup(note.body)),
        foldForSearch(tagNames),
        foldForSearch(headingText),
      ],
    );
  }

  Future<Note> _requireNote(String id) async {
    final n = await getNote(id);
    if (n == null) throw const NotFoundException('Not');
    return n;
  }

  Future<Folder> _requireFolder(String id) async {
    final f = await (_db.select(_db.folders)..where((f) => f.id.equals(id)))
        .getSingleOrNull();
    if (f == null) throw const NotFoundException('Klasör');
    return f;
  }

  static int _size(String title, String body) =>
      utf8.encode(title).length + utf8.encode(body).length;

  static Future<String> _ensureDeviceId(AppDatabase db) async {
    final existing = await (db.select(db.localMeta)
          ..where((m) => m.key.equals('device_id')))
        .getSingleOrNull();
    if (existing != null) return existing.value;

    final id = generateNodeId();
    await db.into(db.localMeta).insert(
        LocalMetaCompanion.insert(key: 'device_id', value: id));
    return id;
  }
}
