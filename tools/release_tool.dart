// Müsvedde sürüm aracı.
//
//   dart run tools/release_tool.dart keygen
//       İmza anahtar çiftini üretir. Özel anahtar parolayla şifrelenip
//       %USERPROFILE%\.musvedde\release_key.json dosyasına yazılır.
//       Açık anahtar ekrana yazılır; lib/core/update/release_key.dart'a konur.
//
//   dart run tools/release_tool.dart sign <kurulum.exe> <sürüm> [--notes "..."]
//       Kurulum dosyasını imzalar ve yanına latest.json yazar.
//
//   dart run tools/release_tool.dart pubkey
//       Kayıtlı anahtarın açık anahtarını yazar.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:notlar/core/crypto/blob_cipher.dart';
import 'package:notlar/core/update/update_manifest.dart';

final _aad = utf8.encode('musvedde/release-key/v1');

File get _keyFile {
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  return File('$home${Platform.pathSeparator}.musvedde${Platform.pathSeparator}release_key.json');
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) return _usage();
  try {
    switch (args.first) {
      case 'keygen':
        await _keygen();
      case 'sign':
        if (args.length < 3) return _usage();
        final notesAt = args.indexOf('--notes');
        final notes = notesAt >= 0 && notesAt + 1 < args.length ? args[notesAt + 1] : '';
        await _sign(args[1], args[2], notes);
      case 'pubkey':
        final j = jsonDecode(await _keyFile.readAsString()) as Map<String, dynamic>;
        stdout.writeln(j['publicKey']);
      default:
        _usage();
    }
  } on _ToolError catch (e) {
    stderr.writeln('HATA: ${e.message}');
    exitCode = 1;
  }
}

void _usage() {
  stdout.writeln('Kullanım:\n'
      '  dart run tools/release_tool.dart keygen\n'
      '  dart run tools/release_tool.dart sign <kurulum.exe> <sürüm> [--notes "..."]\n'
      '  dart run tools/release_tool.dart pubkey');
  exitCode = 64;
}

class _ToolError implements Exception {
  final String message;
  _ToolError(this.message);
}

String _readSecret(String prompt) {
  stdout.write(prompt);
  var hidden = false;
  try {
    stdin.echoMode = false;
    hidden = true;
  } catch (_) {}
  final s = stdin.readLineSync(encoding: utf8) ?? '';
  if (hidden) {
    stdin.echoMode = true;
    stdout.writeln();
  }
  return s;
}

Argon2id get _argon =>
    Argon2id(memory: 65536, iterations: 3, parallelism: 1, hashLength: 32);

Future<void> _keygen() async {
  if (await _keyFile.exists()) {
    throw _ToolError('Anahtar zaten var: ${_keyFile.path}\n'
        'Yeni anahtar üretmek, eski sürümlerin güncellemeyi reddetmesine yol açar. '
        'Gerçekten istiyorsan önce bu dosyayı kendin taşı.');
  }
  final p1 = _readSecret('İmza anahtarı parolası (en az 12 karakter): ');
  if (p1.length < 12) throw _ToolError('Parola en az 12 karakter olmalı.');
  final p2 = _readSecret('Parolayı tekrar yaz: ');
  if (p1 != p2) throw _ToolError('Parolalar aynı değil.');

  final kp = await Ed25519().newKeyPair();
  final seed = await kp.extractPrivateKeyBytes();
  final pub = (await kp.extractPublicKey()).bytes;

  final rnd = Random.secure();
  final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
  final key = await _argon.deriveKeyFromPassword(password: p1, nonce: salt);
  final blob = await BlobCipher().encrypt(key, seed, aad: _aad);

  await _keyFile.parent.create(recursive: true);
  await _keyFile.writeAsString(const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'publicKey': base64Encode(pub),
    'kdf': {'alg': 'argon2id', 'm': 65536, 't': 3, 'p': 1, 'salt': base64Encode(salt)},
    'encryptedSeed': base64Encode(blob),
  }));

  stdout.writeln('\nAnahtar üretildi: ${_keyFile.path}');
  stdout.writeln('Bu dosyanın ve parolasının bir yedeğini çevrim dışı bir yerde sakla.');
  stdout.writeln('\nAçık anahtar (lib/core/update/release_key.dart dosyasına koy):\n');
  stdout.writeln(base64Encode(pub));
}

Future<SimpleKeyPair> _loadKeyPair() async {
  if (!await _keyFile.exists()) {
    throw _ToolError('İmza anahtarı bulunamadı. Önce "keygen" çalıştır.');
  }
  final j = jsonDecode(await _keyFile.readAsString()) as Map<String, dynamic>;
  final kdf = j['kdf'] as Map<String, dynamic>;
  final password = _readSecret('İmza anahtarı parolası: ');

  final key = await Argon2id(
    memory: kdf['m'] as int,
    iterations: kdf['t'] as int,
    parallelism: kdf['p'] as int,
    hashLength: 32,
  ).deriveKeyFromPassword(
      password: password, nonce: base64Decode(kdf['salt'] as String));

  final List<int> seed;
  try {
    seed = await BlobCipher()
        .decrypt(key, base64Decode(j['encryptedSeed'] as String), aad: _aad);
  } on DecryptionFailedException {
    throw _ToolError('Parola yanlış.');
  }
  final kp = await Ed25519().newKeyPairFromSeed(seed);
  final pub = base64Encode((await kp.extractPublicKey()).bytes);
  if (pub != j['publicKey']) throw _ToolError('Anahtar dosyası tutarsız.');
  return kp;
}

Future<void> _sign(String installerPath, String version, String notes) async {
  final file = File(installerPath);
  if (!await file.exists()) throw _ToolError('Dosya bulunamadı: $installerPath');

  final bytes = await file.readAsBytes();
  final hash = (await Sha256().hash(bytes))
      .bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final name = file.uri.pathSegments.last;

  final kp = await _loadKeyPair();
  final manifest = await UpdateManifest(
    version: version,
    publishedAt: DateTime.now().toUtc().toIso8601String(),
    notes: notes,
    url: releaseAssetUrl(version, name),
    sha256: hash,
    size: bytes.length,
  ).signedWith(kp);

  final out = File('${file.parent.path}${Platform.pathSeparator}latest.json');
  await out.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()));
  stdout.writeln('İmzalandı: ${out.path}');
}
