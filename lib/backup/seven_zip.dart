import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class SevenZipException implements Exception {
  final String message;
  const SevenZipException(this.message);

  @override
  String toString() => message;
}

/// Bilgisayarda kurulu 7-Zip'in komut satırı aracı.
///
/// Yedek içeriği 7-Zip'e standart girdi üzerinden verilir; notlar hiçbir an
/// diske şifresiz yazılmaz. Arşiv AES-256 ile şifrelenir ve dosya adları da
/// (-mhe=on) gizlenir.
class SevenZip {
  final String executable;
  const SevenZip(this.executable);

  static Future<String?> locate() async {
    try {
      if (Platform.isWindows) {
        for (final c in const [
          r'C:\Program Files\7-Zip\7z.exe',
          r'C:\Program Files (x86)\7-Zip\7z.exe',
        ]) {
          if (await File(c).exists()) return c;
        }
        return await _which('where', ['7z']);
      }
      return await _which('which', ['7zz']) ?? await _which('which', ['7z']);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _which(String cmd, List<String> args) async {
    final r = await Process.run(cmd, args);
    if (r.exitCode != 0) return null;
    final first = (r.stdout as String)
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return first.isEmpty ? null : first;
  }

  /// [data]'yı [innerName] adıyla şifreli bir 7z arşivine yazar.
  Future<void> createFromBytes({
    required String archivePath,
    required String innerName,
    required List<int> data,
    required String password,
  }) async {
    final p = await Process.start(executable, [
      'a',
      '-t7z',
      '-mx=5',
      '-mhe=on',
      '-p$password',
      '-si$innerName',
      '-y',
      '-bso0',
      '-bsp0',
      archivePath,
    ]);
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    unawaited(p.stdout.drain<void>());
    p.stdin.add(data);
    await p.stdin.flush();
    await p.stdin.close();

    final code = await p.exitCode;
    if (code != 0) {
      throw SevenZipException(
          '7-Zip arşivi oluşturamadı (kod $code). ${(await err).trim()}');
    }
  }

  /// Arşivi parolayla açıp bütünlüğünü doğrular.
  Future<void> test(String archivePath, String password) async {
    final r = await Process.run(
      executable,
      ['t', '-p$password', '-bso0', '-bsp0', archivePath],
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    if (r.exitCode != 0) {
      throw SevenZipException(
          'Yedek doğrulanamadı (kod ${r.exitCode}). ${(r.stderr as String).trim()}');
    }
  }

  /// Arşivden tek bir dosyayı belleğe çıkarır (geri yükleme için).
  Future<Uint8List> extractSingle(
    String archivePath,
    String innerName,
    String password,
  ) async {
    final p = await Process.start(
        executable, ['e', '-so', '-p$password', '-bsp0', archivePath, innerName]);
    final err = p.stderr.transform(const Utf8Decoder(allowMalformed: true)).join();
    final out = BytesBuilder(copy: false);
    await p.stdout.forEach(out.add);
    final code = await p.exitCode;
    if (code != 0) {
      throw SevenZipException(
          'Yedek açılamadı (kod $code). Parola yanlış olabilir. ${(await err).trim()}');
    }
    return out.toBytes();
  }
}
