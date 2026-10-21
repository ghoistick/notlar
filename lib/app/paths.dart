import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Geliştirme ve test için: MUSVEDDE_DATA_DIR ortam değişkeni verilirse
/// uygulama bütün verilerini (kasa, ayarlar, varsayılan yedek klasörü) oraya
/// yazar. Böylece aynı bilgisayarda birbirinden bağımsız iki "cihaz"
/// çalıştırılabilir.
String? get dataDirOverride {
  final v = Platform.environment['MUSVEDDE_DATA_DIR'];
  return v == null || v.trim().isEmpty ? null : v.trim();
}

/// Uygulamanın veri klasörü (normalde %APPDATA%\Sahip\Musvedde).
Future<Directory> appDataDirectory() async {
  final override = dataDirOverride;
  final dir = override != null
      ? Directory(override)
      : await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return dir;
}
