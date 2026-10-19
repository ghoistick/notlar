import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// Veritabanı anahtarı yanlış ya da dosya bozuk.
class DatabaseKeyException implements Exception {
  const DatabaseKeyException();

  @override
  String toString() =>
      'DatabaseKeyException: Veritabanı açılamadı (anahtar yanlış veya dosya bozuk).';
}

/// Şifreleme destekli SQLite yüklenmemiş; veriyi şifresiz yazmamak için durulur.
class EncryptionUnavailableException implements Exception {
  const EncryptionUnavailableException();

  @override
  String toString() => 'EncryptionUnavailableException: Şifreleme destekli '
      'SQLite (sqlite3mc) yüklenmedi. pubspec.yaml içindeki hooks ayarını kontrol edin.';
}

/// Şifreli veritabanı bağlantısı açar.
///
/// [key], veri anahtarından türetilen 32 baytlık yerel veritabanı anahtarıdır
/// (bkz. deriveSubkey / KeyPurpose.localDatabase).
///
/// Uygulamada [inBackground] true kalır; sorgular ayrı bir isolate'te çalışır
/// ve arayüz donmaz. Testlerde false kullanılır.
QueryExecutor openEncryptedDatabase(
  File file,
  List<int> key, {
  bool inBackground = true,
}) {
  final hexKey = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void setup(sqlite.Database db) => applyEncryptionKey(db, hexKey);

  return inBackground
      ? NativeDatabase.createInBackground(file, setup: setup)
      : NativeDatabase(file, setup: setup);
}

/// Bağlantı açıldığı anda, başka hiçbir sorgudan önce çalışır.
void applyEncryptionKey(sqlite.Database db, String hexKey) {
  // Düz SQLite bu pragmayı tanımaz ve boş sonuç döner. Bu durumda dosyaya
  // şifresiz yazmak yerine hata veriyoruz.
  if (db.select('PRAGMA cipher').isEmpty) {
    throw const EncryptionUnavailableException();
  }

  db.execute("PRAGMA hexkey = '$hexKey'");

  // Anahtar yanlışsa ilk okuma burada başarısız olur.
  try {
    db.select('SELECT count(*) FROM sqlite_master');
  } on sqlite.SqliteException {
    throw const DatabaseKeyException();
  }

  db.execute('PRAGMA journal_mode = WAL');
}

/// Uygulamanın veritabanı dosyası. Kullanıcının belgeler klasörü yerine
/// uygulamaya ayrılmış destek klasöründe durur.
Future<File> defaultDatabaseFile() async {
  final dir = await getApplicationSupportDirectory();
  return File(p.join(dir.path, 'notlar.db'));
}
