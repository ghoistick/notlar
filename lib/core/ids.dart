import 'dart:math';
import 'dart:typed_data';

final _rng = Random.secure();

/// Zaman sıralı UUID (sürüm 7).
///
/// İlk 48 bit milisaniye cinsinden zamandır; bu yüzden kimlikler oluşturulma
/// sırasına göre sıralanır ve veritabanı indekslerinde verimli çalışır.
/// Kalan bitler rastgeledir; farklı cihazlarda çakışma olasılığı yok sayılabilir.
String uuidV7({int? millis, Random? random}) {
  final r = random ?? _rng;
  final ms = millis ?? DateTime.now().millisecondsSinceEpoch;
  final b = Uint8List(16);

  for (var i = 0; i < 6; i++) {
    b[i] = (ms >> (8 * (5 - i))) & 0xFF;
  }
  for (var i = 6; i < 16; i++) {
    b[i] = r.nextInt(256);
  }
  b[6] = (b[6] & 0x0F) | 0x70; // sürüm 7
  b[8] = (b[8] & 0x3F) | 0x80; // varyant

  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
