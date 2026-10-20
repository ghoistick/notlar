/// Uygulama sürümü. Derleme betiği pubspec.yaml'daki sürümü
/// `--dart-define=APP_VERSION=1.0.0` ile verir. `flutter run` ile çalışan
/// geliştirme sürümünde 0.0.0 olur.
const appVersion = String.fromEnvironment('APP_VERSION', defaultValue: '0.0.0');

bool get isDevBuild => appVersion == '0.0.0';

/// "1.2.10" > "1.2.9". Eksik ya da sayısal olmayan parçalar 0 sayılır.
int compareVersions(String a, String b) {
  List<int> parts(String v) {
    final core = v.split(RegExp(r'[+-]')).first;
    final p = core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    while (p.length < 3) {
      p.add(0);
    }
    return p;
  }

  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final c = pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return 0;
}
