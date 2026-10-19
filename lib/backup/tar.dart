import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Yedekler için küçük bir tar yazıcı/okuyucu.
///
/// Her girdi için PAX başlığı yazılır; böylece Türkçe karakterli ve uzun
/// dosya yolları 7-Zip ve diğer arşiv programlarında doğru görünür.
class TarWriter {
  final _out = BytesBuilder(copy: false);

  void addDirectory(String path, {int mtime = 0}) {
    final p = path.endsWith('/') ? path : '$path/';
    _pax(p, mtime);
    _header(p, 0, 0x35 /* '5' */, mtime, mode: 493 /* 0755 */);
  }

  void addFile(String path, List<int> data, {int mtime = 0}) {
    _pax(path, mtime);
    _header(path, data.length, 0x30 /* '0' */, mtime, mode: 420 /* 0644 */);
    _out.add(data);
    _pad(data.length);
  }

  /// Arşivi kapatır (iki boş blok) ve baytları döner.
  Uint8List finish() {
    _out.add(Uint8List(1024));
    return _out.toBytes();
  }

  void _pax(String path, int mtime) {
    final data = utf8.encode(_paxRecord('path', path));
    _header('PaxHeader/${_asciiName(path)}', data.length, 0x78 /* 'x' */,
        mtime,
        mode: 420);
    _out.add(data);
    _pad(data.length);
  }

  /// "uzunluk anahtar=değer\n"; uzunluk kendi hanelerini de içerir.
  static String _paxRecord(String key, String value) {
    final bodyLen = utf8.encode(' $key=$value\n').length;
    var len = bodyLen + 1;
    while ('$len'.length + bodyLen != len) {
      len = '$len'.length + bodyLen;
    }
    return '$len $key=$value\n';
  }

  void _header(String name, int size, int type, int mtime, {required int mode}) {
    final h = Uint8List(512);
    void put(int off, int len, List<int> v) {
      for (var i = 0; i < min(v.length, len); i++) {
        h[off + i] = v[i];
      }
    }

    void octal(int off, int len, int value) {
      put(off, len - 1, ascii.encode(value.toRadixString(8).padLeft(len - 1, '0')));
    }

    put(0, 100, ascii.encode(_asciiName(name)));
    octal(100, 8, mode);
    octal(108, 8, 0); // uid
    octal(116, 8, 0); // gid
    octal(124, 12, size);
    octal(136, 12, mtime);
    for (var i = 148; i < 156; i++) {
      h[i] = 0x20; // sağlama hesabında boşluk sayılır
    }
    h[156] = type;
    put(257, 6, ascii.encode('ustar\u0000'));
    put(263, 2, ascii.encode('00'));

    final sum = h.fold<int>(0, (a, b) => a + b);
    put(148, 6, ascii.encode(sum.toRadixString(8).padLeft(6, '0')));
    h[154] = 0;
    h[155] = 0x20;
    _out.add(h);
  }

  void _pad(int size) {
    final rem = size % 512;
    if (rem != 0) _out.add(Uint8List(512 - rem));
  }

  /// Eski tar okuyucular için ASCII yedek ad (asıl ad PAX başlığında).
  static String _asciiName(String s) {
    final cleaned = String.fromCharCodes(
        s.codeUnits.map((c) => c < 32 || c > 126 ? 0x5F : c));
    return cleaned.length > 99 ? cleaned.substring(cleaned.length - 99) : cleaned;
  }
}

class TarEntry {
  final String path;
  final bool isDirectory;
  final Uint8List data;
  const TarEntry(this.path, this.isDirectory, this.data);
}

/// [TarWriter] ile ya da standart araçlarla yazılmış tar arşivini okur.
List<TarEntry> readTar(Uint8List bytes) {
  final out = <TarEntry>[];
  var off = 0;
  String? paxPath;
  String? longName;

  String cstr(Uint8List h, int start, int len) {
    var end = start;
    while (end < start + len && h[end] != 0) {
      end++;
    }
    return utf8.decode(h.sublist(start, end), allowMalformed: true);
  }

  int octal(Uint8List h, int start, int len) {
    final s = ascii
        .decode(h.sublist(start, start + len), allowInvalid: true)
        .replaceAll('\u0000', '')
        .trim();
    return s.isEmpty ? 0 : int.parse(s, radix: 8);
  }

  while (off + 512 <= bytes.length) {
    final h = Uint8List.sublistView(bytes, off, off + 512);
    if (h.every((b) => b == 0)) break;

    final name = cstr(h, 0, 100);
    final size = octal(h, 124, 12);
    final type = h[156];
    final prefix = cstr(h, 345, 155);
    off += 512;
    final data = Uint8List.fromList(bytes.sublist(off, off + size));
    off += ((size + 511) ~/ 512) * 512;

    if (type == 0x78 /* x */) {
      paxPath = _parsePax(data)['path'];
      continue;
    }
    if (type == 0x4C /* L, GNU uzun ad */) {
      longName = utf8.decode(data, allowMalformed: true).replaceAll('\u0000', '');
      continue;
    }

    var path = paxPath ?? longName ?? (prefix.isEmpty ? name : '$prefix/$name');
    paxPath = null;
    longName = null;
    final isDir = type == 0x35 || path.endsWith('/');
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    out.add(TarEntry(path, isDir, data));
  }
  return out;
}

Map<String, String> _parsePax(Uint8List data) {
  final result = <String, String>{};
  final text = utf8.decode(data, allowMalformed: true);
  var i = 0;
  while (i < text.length) {
    final space = text.indexOf(' ', i);
    if (space < 0) break;
    final eq = text.indexOf('=', space);
    final nl = text.indexOf('\n', eq);
    if (eq < 0 || nl < 0) break;
    result[text.substring(space + 1, eq)] = text.substring(eq + 1, nl);
    i = nl + 1;
  }
  return result;
}
