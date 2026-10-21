import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;

class RemoteFile {
  final String id;
  final String name;
  const RemoteFile(this.id, this.name);
}

/// Senkronizasyon dosyalarının tutulduğu yer. Motor yalnızca bunu bilir;
/// Google Drive ileride kendi sunucu ile değiştirilebilir.
abstract class SyncStore {
  /// Adı [prefix] ile başlayan dosyalar.
  Future<List<RemoteFile>> list(String prefix);
  Future<Uint8List> read(String fileId);
  Future<String> create(String name, Uint8List data);
  Future<void> update(String fileId, Uint8List data);
}

/// Testler için bellek içi depo.
class MemorySyncStore implements SyncStore {
  final files = <String, (String, Uint8List)>{};
  var _next = 0;

  @override
  Future<List<RemoteFile>> list(String prefix) async => [
        for (final e in files.entries)
          if (e.value.$1.startsWith(prefix)) RemoteFile(e.key, e.value.$1),
      ];

  @override
  Future<Uint8List> read(String fileId) async => files[fileId]!.$2;

  @override
  Future<String> create(String name, Uint8List data) async {
    final id = 'f${_next++}';
    files[id] = (name, data);
    return id;
  }

  @override
  Future<void> update(String fileId, Uint8List data) async {
    files[fileId] = (files[fileId]!.$1, data);
  }
}

/// Google Drive'ın uygulamaya özel gizli klasörü (appDataFolder).
class DriveSyncStore implements SyncStore {
  final drive.DriveApi api;
  DriveSyncStore(this.api);

  @override
  Future<List<RemoteFile>> list(String prefix) async {
    final out = <RemoteFile>[];
    String? page;
    do {
      final res = await api.files.list(
        spaces: 'appDataFolder',
        q: "name contains '${prefix.replaceAll("'", r"\'")}' and trashed = false",
        $fields: 'nextPageToken, files(id, name)',
        pageSize: 1000,
        pageToken: page,
      );
      for (final f in res.files ?? const <drive.File>[]) {
        final name = f.name ?? '';
        if (f.id != null && name.startsWith(prefix)) out.add(RemoteFile(f.id!, name));
      }
      page = res.nextPageToken;
    } while (page != null);
    return out;
  }

  @override
  Future<Uint8List> read(String fileId) async {
    final media = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final b = BytesBuilder(copy: false);
    await media.stream.forEach(b.add);
    return b.toBytes();
  }

  @override
  Future<String> create(String name, Uint8List data) async {
    final f = await api.files.create(
      drive.File()
        ..name = name
        ..parents = ['appDataFolder'],
      uploadMedia: drive.Media(Stream.value(data), data.length),
      $fields: 'id',
    );
    return f.id!;
  }

  @override
  Future<void> update(String fileId, Uint8List data) async {
    await api.files.update(
      drive.File(),
      fileId,
      uploadMedia: drive.Media(Stream.value(data), data.length),
    );
  }
}
