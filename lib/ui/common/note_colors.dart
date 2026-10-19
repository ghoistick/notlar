import 'package:flutter/material.dart';

/// Not, kısa not, klasör ve etiketlerde kullanılan renkler.
///
/// Veritabanında yalnızca [key] saklanır; renk değerleri burada durur. Böylece
/// paleti ileride değiştirmek eski notları bozmaz.
class NoteColor {
  final String key;
  final String label;
  final Color swatch; // nokta, şerit, ikon
  final Color lightTint; // açık temada kart zemini
  final Color darkTint; // koyu temada kart zemini

  const NoteColor(this.key, this.label, this.swatch, this.lightTint, this.darkTint);

  Color tint(Brightness b) => b == Brightness.dark ? darkTint : lightTint;
}

const noteColors = <NoteColor>[
  NoteColor('kirmizi', 'Kırmızı', Color(0xFFD1495B), Color(0xFFFBE7EA), Color(0xFF3A2228)),
  NoteColor('turuncu', 'Turuncu', Color(0xFFE08A2E), Color(0xFFFCEFDF), Color(0xFF3A2C1C)),
  NoteColor('sari', 'Sarı', Color(0xFFD9B531), Color(0xFFFBF5DA), Color(0xFF37321C)),
  NoteColor('yesil', 'Yeşil', Color(0xFF3E9B6A), Color(0xFFE3F3EA), Color(0xFF1D3328)),
  NoteColor('turkuaz', 'Turkuaz', Color(0xFF2A9BA6), Color(0xFFDFF2F4), Color(0xFF1B3236)),
  NoteColor('mavi', 'Mavi', Color(0xFF1E5AA8), Color(0xFFE2EBF7), Color(0xFF1F3350)),
  NoteColor('mor', 'Mor', Color(0xFF7A56B5), Color(0xFFEEE7F7), Color(0xFF2C2440)),
  NoteColor('gri', 'Gri', Color(0xFF7B8794), Color(0xFFECEFF2), Color(0xFF262D35)),
];

NoteColor? noteColorFor(String? key) {
  if (key == null) return null;
  for (final c in noteColors) {
    if (c.key == key) return c;
  }
  return null;
}

/// Kart zemini; renk yoksa null.
Color? tintFor(BuildContext context, String? key) =>
    noteColorFor(key)?.tint(Theme.of(context).brightness);
