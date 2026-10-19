/// Türk alfabesine göre sıralama.
///
/// SQLite'ın varsayılan sıralaması bayt sırasına göredir; "Çay" "Zeytin"den
/// sonra gelir, "ı" ile "i" ayrımını bilmez. Bu fonksiyonlar başlık sıralamasını
/// Türk alfabesine göre yapar:
///   a b c ç d e f g ğ h ı i j k l m n o ö p (q) r s ş t u ü v (w x) y z
/// Rakam ve noktalama harflerden önce gelir; büyük/küçük harf fark etmez.
const _order = 'abcçdefgğhıijklmnoöpqrsştuüvwxyz';

final Map<int, int> _rank = {
  for (var i = 0; i < _order.length; i++) _order.codeUnitAt(i): i,
  'â'.codeUnitAt(0): _order.indexOf('a'),
  'î'.codeUnitAt(0): _order.indexOf('i'),
  'û'.codeUnitAt(0): _order.indexOf('u'),
};

/// Karşılaştırma için anahtar üretir. Çok sayıda öğe sıralanırken anahtarı
/// her öğe için bir kez hesaplayıp [compareSortKeys] ile karşılaştırmak hızlıdır.
List<int> turkishSortKey(String s) {
  final lower = s.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase();
  final key = <int>[];
  for (final r in lower.runes) {
    if (r >= 0x0300 && r <= 0x036F) continue; // ayrışık aksan işaretleri
    final rank = _rank[r];
    if (rank != null) {
      key.add(1000 + rank);
    } else if (r < 128) {
      key.add(r); // boşluk, rakam, noktalama: harflerden önce
    } else {
      key.add(2000 + r); // diğer alfabeler: Türkçe harflerden sonra
    }
  }
  return key;
}

int compareSortKeys(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return a.length.compareTo(b.length);
}

int compareTurkish(String a, String b) =>
    compareSortKeys(turkishSortKey(a), turkishSortKey(b));
