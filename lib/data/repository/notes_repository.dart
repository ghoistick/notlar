import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../../core/hlc/hlc.dart';
import '../../core/ids.dart';
import '../../core/text/headings.dart';
import '../../core/text/search_text.dart';
import '../../core/text/turkish_collation.dart';
import '../db/database.dart';
import 'import_records.dart';
import 'note_query.dart';
import 'sync_records.dart';

export 'import_records.dart';
export 'note_query.dart';
export 'sync_records.dart';

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
    return _db.transaction(() => _insertNote(
          folderId: folderId,
          kind: kind,
          type: type,
          title: title,
          body: body,
          color: color,
        ));
  }

  /// İşlem (transaction) açmadan not ekler; açık bir işlemin içinden çağrılır.
  Future<String> _insertNote({
    String? folderId,
    NoteKind kind = NoteKind.note,
    NoteType type = NoteType.text,
    String title = '',
    String body = '',
    String? color,
  }) async {
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

  // --------------------------------------------------- Senkronizasyon

  /// Bu cihazda yapılmış, henüz gönderilmemiş değişiklikler (HLC sırasıyla).
  Future<List<ChangeLogData>> pendingOps({int limit = 2000}) =>
      (_db.select(_db.changeLog)
            ..where((c) => c.synced.equals(false) & c.deviceId.equals(deviceId))
            ..orderBy([
              (c) => OrderingTerm.asc(c.hlc),
              (c) => OrderingTerm.asc(c.opId),
            ])
            ..limit(limit))
          .get();

  Future<void> markSynced(List<String> opIds) async {
    for (var i = 0; i < opIds.length; i += 500) {
      final chunk = opIds.sublist(i, min(i + 500, opIds.length));
      await (_db.update(_db.changeLog)..where((c) => c.opId.isIn(chunk)))
          .write(const ChangeLogCompanion(synced: Value(true)));
    }
  }

  /// Başka bir cihazın değişikliklerini uygular.
  ///
  /// Her alan için en yeni HLC kazanır (alan bazında "son yazan kazanır").
  /// Not gövdesi iki cihazda birbirinden habersiz değiştirildiyse, kaybeden
  /// metin silinmez; "(çakışan kopya)" adıyla ayrı bir not olarak saklanır.
  /// Habersizlik, yerel değişikliğin henüz gönderilmemiş olmasından anlaşılır:
  /// eşitleme her zaman önce alıp sonra gönderdiği için, karşı cihaz o
  /// değişikliği henüz görmüş olamaz.
  Future<ApplyResult> applyRemoteOps(String fromDevice, List<RemoteOp> ops) {
    return _db.transaction(() async {
      final r = ApplyResult();
      final touchedNotes = <String>{};
      final bodyNotes = <String>{};
      final touchedTags = <String>{};

      final sorted = [...ops]..sort((a, b) => a.hlc.compareTo(b.hlc));
      for (final op in sorted) {
        final dup = await (_db.select(_db.changeLog)
              ..where((c) => c.opId.equals(op.opId)))
            .getSingleOrNull();
        if (dup != null) {
          r.duplicates++;
          continue;
        }

        final latest = await _db.customSelect(
          'SELECT hlc, synced, value FROM change_log '
          'WHERE entity = ? AND entity_id = ? AND field = ? '
          'ORDER BY hlc DESC LIMIT 1',
          variables: [
            Variable.withString(op.entity),
            Variable.withString(op.entityId),
            Variable.withString(op.field),
          ],
        ).getSingleOrNull();

        await _db.into(_db.changeLog).insert(ChangeLogCompanion.insert(
              opId: op.opId,
              entity: op.entity,
              entityId: op.entityId,
              field: op.field,
              value: Value(op.value),
              hlc: op.hlc,
              deviceId: fromDevice,
              synced: const Value(true),
            ));
        _clock.receive(Hlc.parse(op.hlc));

        final localHlc = latest?.read<String>('hlc');
        final localUnsynced = latest != null && !latest.read<bool>('synced');
        final localValue = latest?.read<String?>('value');
        final bodyConflict = op.entity == 'note' &&
            op.field == 'body' &&
            localUnsynced &&
            localValue != op.value;

        if (localHlc != null && localHlc.compareTo(op.hlc) > 0) {
          // Yerel değişiklik daha yeni: uzaktaki kaybeder.
          if (bodyConflict) {
            await _conflictCopy(op.entityId, op.value);
            r.conflicts++;
          }
          r.ignored++;
          continue;
        }
        if (bodyConflict) {
          // Uzaktaki kazanır; gönderilmemiş yerel metin kopya olarak kalır.
          await _conflictCopy(op.entityId, localValue);
          r.conflicts++;
        }
        await _applyRemoteField(op, touchedNotes, bodyNotes, touchedTags);
        r.applied++;
      }

      for (final tagId in touchedTags) {
        touchedNotes.addAll(await _notesWithTag(tagId));
      }
      for (final id in touchedNotes) {
        final n = await getNote(id);
        if (n == null) continue;
        await (_db.update(_db.notes)..where((x) => x.id.equals(id)))
            .write(NotesCompanion(sizeBytes: Value(_size(n.title, n.body))));
        if (bodyNotes.contains(id)) await _rebuildHeadings(id, n.body);
        await _reindex(id);
      }
      return r;
    });
  }

  Future<void> _conflictCopy(String noteId, String? bodyJson) async {
    final n = await getNote(noteId);
    final body = bodyJson == null ? '' : jsonDecode(bodyJson) as String? ?? '';
    final title = n == null || n.title.trim().isEmpty
        ? 'Çakışan kopya'
        : '${n.title} (çakışan kopya)';
    await _insertNote(
      folderId: n?.folderId,
      kind: n?.kind ?? NoteKind.note,
      type: n?.type ?? NoteType.text,
      title: title,
      body: body,
      color: n?.color,
    );
  }

  Future<void> _applyRemoteField(
    RemoteOp op,
    Set<String> touchedNotes,
    Set<String> bodyNotes,
    Set<String> touchedTags,
  ) async {
    final v = op.value == null ? null : jsonDecode(op.value!);
    final millis = Hlc.parse(op.hlc).millis;
    final id = op.entityId;

    switch (op.entity) {
      case 'note':
        await _db.customStatement(
          'INSERT OR IGNORE INTO notes (id, created_at, updated_at, hlc) '
          'VALUES (?, ?, ?, ?)',
          [id, millis, millis, op.hlc],
        );
        final NotesCompanion? c = switch (op.field) {
          'title' => NotesCompanion(title: Value(v as String)),
          'body' => NotesCompanion(body: Value(v as String)),
          'folder_id' => NotesCompanion(folderId: Value(v as String?)),
          'color' => NotesCompanion(color: Value(v as String?)),
          'kind' => NotesCompanion(kind: Value(NoteKind.values.byName(v as String))),
          'type' => NotesCompanion(type: Value(NoteType.values.byName(v as String))),
          'pinned' => NotesCompanion(pinned: Value(v as bool)),
          'archived' => NotesCompanion(archived: Value(v as bool)),
          'locked' => NotesCompanion(locked: Value(v as bool)),
          'created_at' => NotesCompanion(createdAt: Value(v as int)),
          'deleted_at' => NotesCompanion(deletedAt: Value(v as int?)),
          _ => null,
        };
        if (c == null) return;
        await (_db.update(_db.notes)..where((n) => n.id.equals(id))).write(c);
        if (const {'title', 'body', 'type'}.contains(op.field)) {
          await _db.customStatement(
              'UPDATE notes SET updated_at = MAX(updated_at, ?) WHERE id = ?',
              [millis, id]);
        }
        touchedNotes.add(id);
        if (op.field == 'body') bodyNotes.add(id);

      case 'folder':
        await _db.customStatement(
          'INSERT OR IGNORE INTO folders (id, name, created_at, updated_at, hlc) '
          "VALUES (?, '', ?, ?, ?)",
          [id, millis, millis, op.hlc],
        );
        final FoldersCompanion? c = switch (op.field) {
          'parent_id' => FoldersCompanion(parentId: Value(v as String?)),
          'name' => FoldersCompanion(name: Value(v as String)),
          'color' => FoldersCompanion(color: Value(v as String?)),
          'position' => FoldersCompanion(position: Value(v as int)),
          'created_at' => FoldersCompanion(createdAt: Value(v as int)),
          'deleted_at' => FoldersCompanion(deletedAt: Value(v as int?)),
          _ => null,
        };
        if (c == null) return;
        await (_db.update(_db.folders)..where((f) => f.id.equals(id))).write(c);

      case 'tag':
        await _db.customStatement(
          'INSERT OR IGNORE INTO tags (id, name, created_at, updated_at, hlc) '
          "VALUES (?, '', ?, ?, ?)",
          [id, millis, millis, op.hlc],
        );
        final TagsCompanion? c = switch (op.field) {
          'name' => TagsCompanion(name: Value(v as String)),
          'color' => TagsCompanion(color: Value(v as String?)),
          'parent_id' => TagsCompanion(parentId: Value(v as String?)),
          'created_at' => TagsCompanion(createdAt: Value(v as int)),
          'deleted_at' => TagsCompanion(deletedAt: Value(v as int?)),
          _ => null,
        };
        if (c == null) return;
        await (_db.update(_db.tags)..where((t) => t.id.equals(id))).write(c);
        if (op.field == 'name' || op.field == 'deleted_at') touchedTags.add(id);

      case 'note_tag':
        final parts = id.split('|');
        if (parts.length != 2 || op.field != 'deleted_at') return;
        await _db.customStatement(
          'INSERT OR IGNORE INTO note_tags (note_id, tag_id, created_at, updated_at, hlc) '
          'VALUES (?, ?, ?, ?, ?)',
          [parts[0], parts[1], millis, millis, op.hlc],
        );
        await (_db.update(_db.noteTags)
              ..where((nt) => nt.noteId.equals(parts[0]) & nt.tagId.equals(parts[1])))
            .write(NoteTagsCompanion(deletedAt: Value(v as int?)));
        touchedNotes.add(parts[0]);
    }
  }

  // ----------------------------------------------------- İçe aktarma

  /// Dışarıdan gelen veriyi ekler. Mevcut kayıtların üzerine asla yazmaz:
  ///  - kimliği zaten bulunan not ve klasörler atlanır,
  ///  - etiketler önce kimliğe, sonra ada göre eşleştirilir.
  /// Notlar orijinal kimlik ve tarihleriyle eklenir ve change_log'a yazılır
  /// (senkronizasyonda diğer cihazlara da gider).
  ///
  /// [dryRun] true ise hiçbir şey yazılmaz; yalnızca ne ekleneceği hesaplanır.
  Future<ImportResult> importBatch(ImportBatch b, {bool dryRun = false}) {
    Future<ImportResult> run() async {
      final result = ImportResult();
      final now = _now();
      final hlc = dryRun ? '' : _clock.tick().pack();

      // ---- Klasörler (önce üst klasörler)
      final folderIds =
          (await _db.select(_db.folders).get()).map((f) => f.id).toSet();
      for (final f in _parentFirst(b.folders)) {
        if (folderIds.contains(f.id)) continue;
        final parent =
            f.parentId != null && folderIds.contains(f.parentId) ? f.parentId : null;
        if (!dryRun) {
          await _db.into(_db.folders).insert(FoldersCompanion.insert(
                id: f.id,
                parentId: Value(parent),
                name: f.name,
                color: Value(f.color),
                position: Value(f.position),
                createdAt: now,
                updatedAt: now,
                hlc: hlc,
              ));
          await _log('folder', f.id, {
            'parent_id': parent,
            'name': f.name,
            'color': f.color,
            'position': f.position,
            'created_at': now,
          }, hlc);
        }
        folderIds.add(f.id);
        result.foldersAdded++;
      }

      // ---- Etiketler
      final allTags = await _db.select(_db.tags).get();
      final tagIds = allTags.map((t) => t.id).toSet();
      final byName = {
        for (final t in allTags)
          if (t.deletedAt == null) t.name.toLowerCase(): t.id,
      };

      Future<String> ensureTag(String name, {String? id, String? color}) async {
        if (id != null && tagIds.contains(id)) {
          byName.putIfAbsent(name.toLowerCase(), () => id);
          return id;
        }
        final existing = byName[name.toLowerCase()];
        if (existing != null) return existing;

        final newId = id ?? uuidV7(millis: now);
        if (!dryRun) {
          await _db.into(_db.tags).insert(TagsCompanion.insert(
                id: newId,
                name: name,
                color: Value(color),
                createdAt: now,
                updatedAt: now,
                hlc: hlc,
              ));
          await _log('tag', newId,
              {'name': name, 'color': color, 'parent_id': null, 'created_at': now},
              hlc);
        }
        tagIds.add(newId);
        byName[name.toLowerCase()] = newId;
        result.tagsAdded++;
        return newId;
      }

      for (final t in b.tags) {
        await ensureTag(t.name, id: t.id, color: t.color);
      }

      // ---- Notlar
      final noteIds = (await (_db.selectOnly(_db.notes)
                    ..addColumns([_db.notes.id]))
                  .map((r) => r.read(_db.notes.id)!)
                  .get())
          .toSet();

      for (final n in b.notes) {
        if (noteIds.contains(n.id)) {
          result.notesSkipped++;
          continue;
        }
        final folderId =
            n.folderId != null && folderIds.contains(n.folderId) ? n.folderId : null;
        final noteTagIds = <String>{};
        for (final name in n.tagNames) {
          if (name.trim().isEmpty) continue;
          noteTagIds.add(await ensureTag(name.trim()));
        }

        if (!dryRun) {
          await _db.into(_db.notes).insert(NotesCompanion.insert(
                id: n.id,
                folderId: Value(folderId),
                kind: Value(n.kind),
                type: Value(n.type),
                title: Value(n.title),
                body: Value(n.body),
                color: Value(n.color),
                pinned: Value(n.pinned),
                archived: Value(n.archived),
                sizeBytes: Value(_size(n.title, n.body)),
                createdAt: n.createdAt,
                updatedAt: n.updatedAt,
                hlc: hlc,
              ));
          await _log('note', n.id, {
            'folder_id': folderId,
            'kind': n.kind.name,
            'type': n.type.name,
            'title': n.title,
            'body': n.body,
            'color': n.color,
            'pinned': n.pinned,
            'archived': n.archived,
            'locked': false,
            'created_at': n.createdAt,
          }, hlc);
          for (final tagId in noteTagIds) {
            await _db.into(_db.noteTags).insertOnConflictUpdate(
                  NoteTagsCompanion.insert(
                    noteId: n.id,
                    tagId: tagId,
                    createdAt: now,
                    updatedAt: now,
                    deletedAt: const Value(null),
                    hlc: hlc,
                  ),
                );
            await _log('note_tag', '${n.id}|$tagId', {'deleted_at': null}, hlc);
          }
          await _rebuildHeadings(n.id, n.body);
          await _reindex(n.id);
        }
        noteIds.add(n.id);
        result.notesAdded++;
      }
      return result;
    }

    return dryRun ? run() : _db.transaction(run);
  }

  /// Üst klasörler alt klasörlerden önce gelecek şekilde sıralar.
  static List<ImportFolder> _parentFirst(List<ImportFolder> folders) {
    final ids = {for (final f in folders) f.id};
    final placed = <String>{};
    final out = <ImportFolder>[];
    var remaining = [...folders];
    var progress = true;
    while (remaining.isNotEmpty && progress) {
      progress = false;
      final next = <ImportFolder>[];
      for (final f in remaining) {
        final p = f.parentId;
        if (p == null || !ids.contains(p) || placed.contains(p)) {
          out.add(f);
          placed.add(f.id);
          progress = true;
        } else {
          next.add(f);
        }
      }
      remaining = next;
    }
    return out..addAll(remaining); // döngü varsa kalanlar köke düşer
  }

  // ------------------------------------------- Cihaz ayarları ve yedekleme

  /// Cihaza özel ayar (yedek klasörü, son yedek bilgisi vb.).
  Future<String?> getMeta(String key) async =>
      (await (_db.select(_db.localMeta)..where((m) => m.key.equals(key)))
              .getSingleOrNull())
          ?.value;

  /// [value] null ise ayar silinir.
  Future<void> setMeta(String key, String? value) async {
    if (value == null) {
      await (_db.delete(_db.localMeta)..where((m) => m.key.equals(key))).go();
    } else {
      await _db.into(_db.localMeta).insertOnConflictUpdate(
          LocalMetaCompanion.insert(key: key, value: value));
    }
  }

  /// En son değişikliğin damgası; hiç değişiklik yoksa null.
  Future<String?> latestChangeHlc() async {
    final row = await _db
        .customSelect('SELECT MAX(hlc) AS h FROM change_log')
        .getSingle();
    return row.read<String?>('h');
  }

  /// Çöp kutusundakiler hariç tüm notlar (arşivdekiler dahil).
  Future<List<Note>> notesForBackup() => (_db.select(_db.notes)
        ..where((n) => n.deletedAt.isNull())
        ..orderBy([
          (n) => OrderingTerm.asc(n.createdAt),
          (n) => OrderingTerm.asc(n.id),
        ]))
      .get();

  /// Not kimliği -> etiket adları (tek sorguda).
  Future<Map<String, List<String>>> tagNamesByNote() async {
    final rows = await _db.customSelect(
      'SELECT nt.note_id, t.name FROM note_tags nt '
      'JOIN tags t ON t.id = nt.tag_id '
      'WHERE nt.deleted_at IS NULL AND t.deleted_at IS NULL '
      'ORDER BY t.name',
    ).get();
    final map = <String, List<String>>{};
    for (final r in rows) {
      map.putIfAbsent(r.read<String>('note_id'), () => []).add(r.read<String>('name'));
    }
    return map;
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
