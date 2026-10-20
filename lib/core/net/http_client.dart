import 'dart:io';

import '../version.dart';

/// Sistem proxy ayarı.
///
/// Dart'ın HTTP istemcisi Windows'un proxy ayarını kendiliğinden kullanmaz;
/// kurum ağlarında doğrudan bağlantı zaman aşımına düşer. Bu sınıf ayarı
/// sırasıyla ortam değişkenlerinden (HTTPS_PROXY / HTTP_PROXY) ve Windows
/// kayıt defterinden (Internet Seçenekleri) okur.
class SystemProxy {
  /// "host:port" ya da "http=host:port;https=host:port".
  final String? server;

  /// Proxy'siz gidilecek adresler: "<local>", "*.kurum.gov.tr", "10.*".
  final List<String> bypass;

  const SystemProxy({this.server, this.bypass = const []});

  static const none = SystemProxy();

  static Future<SystemProxy>? _cached;

  static Future<SystemProxy> load() => _cached ??= _load();

  static Future<SystemProxy> _load() async {
    final env = Platform.environment;
    final fromEnv = env['HTTPS_PROXY'] ?? env['https_proxy'] ??
        env['HTTP_PROXY'] ?? env['http_proxy'];
    if (fromEnv != null && fromEnv.trim().isNotEmpty) {
      final noProxy = env['NO_PROXY'] ?? env['no_proxy'] ?? '';
      return SystemProxy(
        server: stripScheme(fromEnv),
        bypass: noProxy.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
      );
    }
    if (!Platform.isWindows) return none;

    try {
      final r = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ]);
      if (r.exitCode != 0) return none;
      return fromRegistryOutput(r.stdout as String);
    } catch (_) {
      return none;
    }
  }

  /// `reg query` çıktısını çözümler (test edilebilsin diye ayrı).
  static SystemProxy fromRegistryOutput(String output) {
    final values = <String, String>{};
    final line = RegExp(r'^\s+(\w+)\s+REG_\w+\s+(.*)$');
    for (final l in output.split(RegExp(r'\r?\n'))) {
      final m = line.firstMatch(l);
      if (m != null) values[m.group(1)!] = m.group(2)!.trim();
    }
    final enabled = values['ProxyEnable'] == '0x1';
    final server = values['ProxyServer'];
    if (!enabled || server == null || server.isEmpty) return none;
    return SystemProxy(
      server: server,
      bypass: (values['ProxyOverride'] ?? '')
          .split(';')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    );
  }

  static String stripScheme(String s) {
    var v = s.trim().replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    if (v.endsWith('/')) v = v.substring(0, v.length - 1);
    return v;
  }

  /// HttpClient.findProxy için.
  String resolve(Uri uri) {
    final s = server;
    if (s == null || _bypassed(uri.host)) return 'DIRECT';
    final proxy = _proxyFor(s, uri.scheme);
    return proxy == null ? 'DIRECT' : 'PROXY $proxy; DIRECT';
  }

  static String? _proxyFor(String server, String scheme) {
    if (!server.contains('=')) return stripScheme(server);
    final map = <String, String>{};
    for (final part in server.split(';')) {
      final i = part.indexOf('=');
      if (i > 0) map[part.substring(0, i).trim().toLowerCase()] = part.substring(i + 1).trim();
    }
    final p = map[scheme] ?? map['https'] ?? map['http'];
    return p == null ? null : stripScheme(p);
  }

  bool _bypassed(String host) {
    final h = host.toLowerCase();
    for (final rule in bypass) {
      final r = rule.toLowerCase();
      if (r == '<local>') {
        if (!h.contains('.')) return true;
        continue;
      }
      final pattern = RegExp(
          '^${RegExp.escape(r).replaceAll(r'\*', '.*')}\$');
      if (pattern.hasMatch(h)) return true;
    }
    return h == 'localhost' || h == '127.0.0.1';
  }
}

/// Sistem proxy'sini kullanan HTTP istemcisi.
///
/// Not: Kurum ağındaki SSL denetimi sertifika hatası çıkarırsa (Gradle'da
/// yaşadığımız gibi), çözüm bu fonksiyonda kurum kök sertifikasını
/// tanıtmak olacak.
Future<HttpClient> createHttpClient() async {
  final proxy = await SystemProxy.load();
  return HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = 'Musvedde/$appVersion'
    ..findProxy = proxy.resolve;
}
