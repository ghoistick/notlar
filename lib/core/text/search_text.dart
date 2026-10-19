/// Arama için metni sadeleştirir: küçük harf, Türkçe karakterler ASCII karşılığı.
///
///   "Şifre İŞLEMLERİ"  ->  "sifre islemleri"
///   "ılık / Işık / iş" ->  "ilik / isik / is"
///
/// Hem indekslenen metin hem arama sorgusu bu işlemden geçer; böylece
/// "sifre" yazınca "şifre" bulunur. Noktalı ve noktasız i ayrımı da kalktığı
/// için Türkçe büyük/küçük harf sorunları (I→ı, İ→i) ortadan kalkar.
String foldForSearch(String input) {
  final out = StringBuffer();
  for (final rune in input.runes) {
    // Ayrışık yazılmış aksan işaretlerini (ör. i + U+0307) at.
    if (rune >= 0x0300 && rune <= 0x036F) continue;
    final mapped = _fold[rune];
    if (mapped != null) {
      out.write(mapped);
    } else {
      out.write(String.fromCharCode(rune).toLowerCase());
    }
  }
  return out.toString();
}

/// [foldForSearch] gibi sadeleştirir ama metnin uzunluğunu ve karakter
/// konumlarını korur. Not içi aramada bulunan konumların orijinal metinle
/// birebir eşleşmesi için kullanılır.
String foldSameLength(String input) {
  final out = StringBuffer();
  for (final c in input.codeUnits) {
    final mapped = _fold[c];
    if (mapped != null) {
      out.write(mapped);
      continue;
    }
    final lower = String.fromCharCode(c).toLowerCase();
    out.write(lower.length == 1 ? lower : String.fromCharCode(c));
  }
  return out.toString();
}

const Map<int, String> _fold = {
  0x0130: 'i', // İ
  0x0049: 'i', // I
  0x0131: 'i', // ı
  0x015E: 's', 0x015F: 's', // Ş ş
  0x011E: 'g', 0x011F: 'g', // Ğ ğ
  0x00C7: 'c', 0x00E7: 'c', // Ç ç
  0x00D6: 'o', 0x00F6: 'o', // Ö ö
  0x00DC: 'u', 0x00FC: 'u', // Ü ü
  0x00C2: 'a', 0x00E2: 'a', // Â â
  0x00CE: 'i', 0x00EE: 'i', // Î î
  0x00DB: 'u', 0x00FB: 'u', // Û û
};

final _tokenSplit = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Kullanıcının yazdığı aramayı FTS5 sorgusuna çevirir.
///
/// Her kelime önek araması olur ve hepsi aranır (VE):
///   "Şifre yön" -> "sifre"* "yon"*
///
/// Özel karakterler kelime ayırıcı sayıldığı için kullanıcı girdisi FTS5
/// sözdizimini bozamaz. Aranacak kelime yoksa null döner.
String? buildFtsQuery(String userInput) {
  final tokens = foldForSearch(userInput)
      .split(_tokenSplit)
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return null;
  return tokens.map((t) => '"$t"*').join(' ');
}

final _inlineColor = RegExp(r'\{(?:!?\p{L}+|/)\}', unicode: true);

/// Not içi renk ve vurgu işaretlerini kaldırır:
/// "{kırmızı}önemli{/}" -> "önemli", "{!sarı}dikkat{/}" -> "dikkat".
/// İndeksleme ve başlık çıkarımında kullanılır; not gövdesi değişmez.
String stripInlineMarkup(String input) => input.replaceAll(_inlineColor, '');
