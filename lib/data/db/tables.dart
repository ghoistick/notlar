import 'package:drift/drift.dart';

enum NoteKind { note, snippet }

enum NoteType { text, checklist }

/// Senkronize edilen tabloların ortak alanları.
///
/// Silme her zaman yumuşak silmedir ([deletedAt]); kayıt hemen silinmez ki
/// silme bilgisi diğer cihazlara da ulaşsın. [hlc] son değişikliğin damgasıdır.
///
/// Tablolar arasında yabancı anahtar (foreign key) kısıtı bilinçli olarak yok:
/// senkronizasyonda bir not, ait olduğu klasörden önce gelebilir.
mixin SyncedColumns on Table {
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get deletedAt => integer().nullable()();
  TextColumn get hlc => text()();
}

class Folders extends Table with SyncedColumns {
  TextColumn get id => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  IntColumn get position => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_notes_folder', columns: {#folderId})
@TableIndex(name: 'idx_notes_updated', columns: {#updatedAt})
class Notes extends Table with SyncedColumns {
  TextColumn get id => text()();
  TextColumn get folderId => text().nullable()();
  TextColumn get kind =>
      textEnum<NoteKind>().withDefault(const Constant('note'))();
  TextColumn get type =>
      textEnum<NoteType>().withDefault(const Constant('text'))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get body => text().withDefault(const Constant(''))();
  TextColumn get color => text().nullable()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  IntColumn get sizeBytes => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

class Tags extends Table with SyncedColumns {
  TextColumn get id => text()();
  TextColumn get parentId => text().nullable()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'idx_note_tags_tag', columns: {#tagId})
class NoteTags extends Table with SyncedColumns {
  TextColumn get noteId => text()();
  TextColumn get tagId => text()();

  @override
  Set<Column> get primaryKey => {noteId, tagId};
}

/// Not gövdesinden türetilir, senkronize edilmez; her cihaz kendi hesaplar.
class NoteHeadings extends Table {
  TextColumn get noteId => text()();
  IntColumn get position => integer()();
  IntColumn get level => integer()();
  TextColumn get content => text()();
  IntColumn get line => integer()();

  @override
  Set<Column> get primaryKey => {noteId, position};
}

@TableIndex(name: 'idx_revisions_note', columns: {#noteId})
class Revisions extends Table {
  TextColumn get id => text()();
  TextColumn get noteId => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  IntColumn get createdAt => integer()();
  TextColumn get hlc => text()();

  @override
  Set<Column> get primaryKey => {id};
}

class Attachments extends Table with SyncedColumns {
  TextColumn get id => text()();
  TextColumn get noteId => text()();
  TextColumn get mime => text()();
  IntColumn get size => integer()();
  TextColumn get sha256 => text()();
  TextColumn get localPath => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

class SavedSearches extends Table with SyncedColumns {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get query => text()();
  TextColumn get filtersJson => text().withDefault(const Constant('{}'))();
  TextColumn get sort => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Görünüm bazlı tercih (klasör, etiket, kısa notlar...). Cihaza özel.
class ViewSettings extends Table {
  TextColumn get viewKey => text()();
  TextColumn get sort => text().nullable()();
  TextColumn get layout => text().nullable()();

  @override
  Set<Column> get primaryKey => {viewKey};
}

/// Senkronizasyonun temeli: her değişiklik alan düzeyinde bir işlem olarak
/// burada kayıt altına alınır ve diğer cihazlara bu kayıtlar gönderilir.
@TableIndex(name: 'idx_change_log_synced', columns: {#synced, #hlc})
class ChangeLog extends Table {
  TextColumn get opId => text()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get field => text()();

  /// JSON olarak kodlanmış yeni değer.
  TextColumn get value => text().nullable()();
  TextColumn get hlc => text()();
  TextColumn get deviceId => text()();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {opId};
}

/// Cihaza özel küçük ayarlar: cihaz kimliği, son HLC vb.
class LocalMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}
