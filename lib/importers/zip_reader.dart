import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class ZipEntry {
  final String name;
  final int flags;
  final int method;
  final int compressedSize;
  final int localHeaderOffset;

  const ZipEntry(this.name, this.flags, this.method, this.compressedSize,
      this.localHeaderOffset);

  bool get isDirectory => name.endsWith('/');
}

/// Başka uygulamaların dışa aktarım ZIP'lerini okumak için küçük bir okuyucu.
/// Sıkıştırmasız ve "deflate" yöntemli girdileri destekler (ZIP dosyalarının
/// neredeyse tamamı). Parola korumalı ZIP ve 4 GB üstü (ZIP64) desteklenmez.
class SimpleZipReader {
  final Uint8List _b;
  late final List<ZipEntry> entries = _readCentralDirectory();

  SimpleZipReader(this._b);

  static bool looksLikeZip(List<int> bytes) =>
      bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 3 && bytes[3] == 4;

  int _u16(int o) => _b[o] | (_b[o + 1] << 8);
  int _u32(int o) => _u16(o) | (_u16(o + 2) << 16);

  List<ZipEntry> _readCentralDirectory() {
    // Dosya sonundaki "merkezi dizin sonu" kaydı (yorum alanı olabilir).
    var i = _b.length - 22;
    final lowest = max(0, _b.length - 22 - 0xFFFF);
    while (i >= lowest && _u32(i) != 0x06054b50) {
      i--;
    }
    if (i < lowest) throw const FormatException('ZIP dosyası okunamadı.');

    final count = _u16(i + 10);
    final offset = _u32(i + 16);
    if (offset == 0xFFFFFFFF) {
      throw const FormatException('Çok büyük ZIP dosyaları (ZIP64) desteklenmiyor.');
    }

    final out = <ZipEntry>[];
    var p = offset;
    for (var k = 0; k < count; k++) {
      if (_u32(p) != 0x02014b50) throw const FormatException('ZIP dizini bozuk.');
      final flags = _u16(p + 8);
      final method = _u16(p + 10);
      final compressed = _u32(p + 20);
      final nameLen = _u16(p + 28);
      final extraLen = _u16(p + 30);
      final commentLen = _u16(p + 32);
      final local = _u32(p + 42);
      final name = utf8.decode(_b.sublist(p + 46, p + 46 + nameLen), allowMalformed: true);
      out.add(ZipEntry(name, flags, method, compressed, local));
      p += 46 + nameLen + extraLen + commentLen;
    }
    return out;
  }

  /// Adı (klasör yolu olmadan) [fileName] olan ilk girdi.
  ZipEntry? findByFileName(String fileName) {
    for (final e in entries) {
      if (e.name.split('/').last == fileName) return e;
    }
    return null;
  }

  Uint8List read(ZipEntry e) {
    if (e.flags & 1 != 0) throw const FormatException('Parola korumalı ZIP desteklenmiyor.');
    final h = e.localHeaderOffset;
    if (_u32(h) != 0x04034b50) throw const FormatException('ZIP girdisi bozuk.');
    final start = h + 30 + _u16(h + 26) + _u16(h + 28);
    final data = Uint8List.sublistView(_b, start, start + e.compressedSize);
    return switch (e.method) {
      0 => Uint8List.fromList(data),
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
      _ => throw FormatException('Desteklenmeyen sıkıştırma yöntemi (${e.method}).'),
    };
  }
}
