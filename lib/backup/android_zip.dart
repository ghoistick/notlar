import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AndroidZipException implements Exception {
  final String message;
  final bool wrongPassword;
  const AndroidZipException(this.message, {this.wrongPassword = false});

  @override
  String toString() => message;
}

/// Android'de AES-256 şifreli standart ZIP üretir/okur (zip4j, MainActivity).
/// Çıkan dosyayı 7-Zip, WinZip vb. araçlar da açar.
///
/// Not: ZIP biçiminde dosya adları şifrelenmez; bu yedekte tek dosya var
/// ("notlar.tar"), notların adları o dosyanın içinde ve şifrelidir.
class AndroidZip {
  static const _channel = MethodChannel('musvedde/zip');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  Future<void> createFromBytes({
    required String archivePath,
    required String innerName,
    required Uint8List data,
    required String password,
  }) {
    return _withTemp((dir) async {
      final src = File(p.join(dir.path, innerName));
      await src.writeAsBytes(data, flush: true);
      await _invoke('create', {
        'source': src.path,
        'archive': archivePath,
        'innerName': innerName,
        'password': password,
      });
    });
  }

  Future<Uint8List> extractSingle(
    String archivePath,
    String innerName,
    String password,
  ) {
    return _withTemp((dir) async {
      final out = File(p.join(dir.path, 'out.bin'));
      await _invoke('extract', {
        'archive': archivePath,
        'innerName': innerName,
        'dest': out.path,
        'password': password,
      });
      return out.readAsBytes();
    });
  }

  /// Yazılan arşivi geri açıp özgün veriyle karşılaştırır.
  Future<void> verify(
    String archivePath,
    String innerName,
    String password,
    Uint8List expected,
  ) async {
    final back = await extractSingle(archivePath, innerName, password);
    if (!listEquals(back, expected)) {
      throw const AndroidZipException(
          'Yedek doğrulanamadı: açılan içerik yazılanla aynı değil.');
    }
  }

  Future<void> _invoke(String method, Map<String, String> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      if (e.code == 'WRONG_PASSWORD') {
        throw const AndroidZipException(
            'Parola yanlış ya da dosya bozuk.', wrongPassword: true);
      }
      throw AndroidZipException('ZIP işlemi başarısız: ${e.message ?? e.code}');
    }
  }

  /// Geçici klasör (uygulamaya özel önbellek); iş bitince silinir.
  Future<T> _withTemp<T>(Future<T> Function(Directory dir) body) async {
    final base = await getTemporaryDirectory();
    final dir = await base.createTemp('musvedde_zip_');
    try {
      return await body(dir);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }
}
