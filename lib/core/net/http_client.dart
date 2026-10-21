import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  /// Otomatik yapılandırma betiği (PAC) adresi; varsa yalnızca teşhis için
  /// tutulur, PAC betikleri çalıştırılmaz.
  final String? pacUrl;

  const SystemProxy({this.server, this.bypass = const [], this.pacUrl});

  static const none = SystemProxy();

  static Future<SystemProxy>? _cached;
  static String? _manual;

  /// Kullanıcının elle girdiği proxy ("sunucu:port"). Boşsa otomatik algılanır.
  static String? get manual => _manual;

  static void setManual(String? value) {
    final v = value?.trim();
    _manual = v == null || v.isEmpty ? null : stripScheme(v);
    _cached = null;
  }

  static Future<SystemProxy> load() => _cached ??= _load();

  static Future<SystemProxy> _load() async {
    final manual = _manual;
    if (manual != null) {
      return SystemProxy(server: manual, bypass: const ['<local>']);
    }
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
    final pac = values['AutoConfigURL'];
    if (!enabled || server == null || server.isEmpty) {
      return pac == null ? none : SystemProxy(pacUrl: pac);
    }
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
    // Proxy varsa doğrudan bağlantıya geri düşülmez: kurum ağında doğrudan
    // bağlantı zaten çalışmaz ve geri düşmek asıl hatayı gizler.
    return proxy == null ? 'DIRECT' : 'PROXY $proxy';
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

// ----------------------------------------------------------------- curl

/// Windows'ta Windows'un kendi curl aracı kullanılır.
///
/// curl, Windows'un şifreleme altyapısını (Schannel) ve sertifika deposunu
/// kullanır; kurum ağlarındaki SSL denetimiyle tarayıcı gibi çalışır. Dart'ın
/// kendi TLS kütüphanesi bazı kurumsal güvenlik duvarlarında el sıkışma
/// sırasında kesiliyor.
///
/// Güvenlik bağlantı katmanına bırakılmaz: indirilen her şey ayrıca imza ve
/// SHA-256 özetiyle doğrulanır.
class CurlException implements Exception {
  final int exitCode;
  final String stderr;
  const CurlException(this.exitCode, this.stderr);

  @override
  String toString() => 'curl $exitCode: $stderr';
}

String? get _curlPath {
  if (!Platform.isWindows) return null;
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final path = '$root\\System32\\curl.exe';
  return File(path).existsSync() ? path : null;
}

Future<List<String>> _curlProxyArgs(Uri uri) async {
  final r = (await SystemProxy.load()).resolve(uri);
  return r.startsWith('PROXY ') ? ['-x', 'http://${r.substring(6)}'] : ['--noproxy', '*'];
}

List<String> _curlCommon(Duration maxTime, {bool fail = true}) => [
      if (fail) '--fail', // 400 ve üzeri yanıtlar hata sayılır
      '--silent',
      '--show-error',
      '--location', // GitHub indirmeleri yönlendirme kullanır
      '--connect-timeout', '20',
      '--max-time', '${maxTime.inSeconds}',
      // Sertifika iptal listesine ulaşılamazsa (kurum ağlarında sık) bağlantı
      // reddedilmez; iptal edilmiş bir sertifika yine reddedilir.
      '--ssl-revoke-best-effort',
      '--user-agent', 'Musvedde/$appVersion',
    ];

Future<Uint8List> _curlGet(String curl, String url) async {
  final uri = Uri.parse(url);
  final p = await Process.start(curl, [
    ..._curlCommon(const Duration(seconds: 60)),
    ...await _curlProxyArgs(uri),
    url,
  ]);
  final err = p.stderr.transform(const SystemEncoding().decoder).join();
  final out = BytesBuilder(copy: false);
  await p.stdout.forEach(out.add);
  final code = await p.exitCode;
  if (code != 0) throw CurlException(code, (await err).trim());
  return out.toBytes();
}

Future<void> _curlDownload(
  String curl,
  String url,
  File target,
  void Function(int received)? onProgress,
) async {
  final uri = Uri.parse(url);
  final p = await Process.start(curl, [
    ..._curlCommon(const Duration(minutes: 30)),
    ...await _curlProxyArgs(uri),
    '--output', target.path,
    url,
  ]);
  final err = p.stderr.transform(const SystemEncoding().decoder).join();
  unawaited(p.stdout.drain<void>());

  // İlerlemeyi dosya boyutundan izle.
  final timer = Timer.periodic(const Duration(milliseconds: 300), (_) {
    if (onProgress != null && target.existsSync()) onProgress(target.lengthSync());
  });
  final code = await p.exitCode;
  timer.cancel();
  if (code != 0) throw CurlException(code, (await err).trim());
  if (onProgress != null && target.existsSync()) onProgress(target.lengthSync());
}

// ------------------------------------------------- Ortak indirme fonksiyonları

/// Adresin içeriğini belleğe indirir (küçük dosyalar için).
Future<Uint8List> httpGetBytes(String url) async {
  final curl = _curlPath;
  if (curl != null) return _curlGet(curl, url);

  final client = await createHttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url)))
        .close()
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}');
    }
    final out = BytesBuilder(copy: false);
    await res.forEach(out.add);
    return out.toBytes();
  } finally {
    client.close(force: true);
  }
}

/// Adresi dosyaya indirir; [onProgress] indirilen bayt sayısıyla çağrılır.
Future<void> httpDownload(
  String url,
  File target, {
  void Function(int received)? onProgress,
}) async {
  final curl = _curlPath;
  if (curl != null) return _curlDownload(curl, url, target, onProgress);

  final client = await createHttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received);
      }
    } finally {
      await sink.close();
    }
  } finally {
    client.close(force: true);
  }
}

// ------------------------------------------------------- Genel istekler

class HttpResult {
  final int status;
  final Map<String, String> headers; // anahtarlar küçük harf
  final Uint8List body;
  const HttpResult(this.status, this.headers, this.body);
}

/// Herhangi bir HTTP isteği. Windows'ta curl, diğer sistemlerde Dart'ın
/// istemcisi kullanılır. 4xx/5xx yanıtlar hata fırlatmaz; [HttpResult.status]
/// ile kontrol edilir.
///
/// Başlıklar curl'e geçici bir dosyadan verilir; erişim anahtarı gibi
/// değerler komut satırında (işlem listesinde) görünmez.
Future<HttpResult> httpSend(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  List<int>? body,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final curl = _curlPath;
  if (curl == null) return _dartSend(method, url, headers, body, timeout);

  final dir = await Directory.systemTemp.createTemp('musvedde_http');
  try {
    final sep = Platform.pathSeparator;
    final headerIn = File('${dir.path}${sep}istek.txt');
    final headerOut = File('${dir.path}${sep}yanit.txt');
    final lines = StringBuffer()..writeln('Expect:'); // 100-continue beklemesin
    headers.forEach((k, v) {
      final key = k.toLowerCase();
      if (key == 'content-length' || key == 'host') return;
      lines.writeln('$k: $v');
    });
    await headerIn.writeAsString(lines.toString(), flush: true);

    final p = await Process.start(curl, [
      ..._curlCommon(timeout, fail: false),
      ...await _curlProxyArgs(url),
      '--request', method,
      '--header', '@${headerIn.path}',
      '--dump-header', headerOut.path,
      if (body != null) ...['--data-binary', '@-'],
      url.toString(),
    ]);
    final err = p.stderr.transform(const SystemEncoding().decoder).join();
    final out = BytesBuilder(copy: false);
    final outDone = p.stdout.forEach(out.add);
    if (body != null) p.stdin.add(body);
    await p.stdin.close();
    await outDone;

    final code = await p.exitCode;
    if (code != 0) throw CurlException(code, (await err).trim());
    final (status, respHeaders) = parseCurlHeaders(await headerOut.readAsString());
    return HttpResult(status, respHeaders, out.toBytes());
  } finally {
    await dir.delete(recursive: true).catchError((_) => dir);
  }
}

/// curl --dump-header çıktısını çözümler. Proxy tüneli ("200 Connection
/// established") ve yönlendirmeler ayrı bloklar olarak gelir; son blok asıl
/// yanıttır.
(int, Map<String, String>) parseCurlHeaders(String raw) {
  final blocks = raw
      .replaceAll('\r\n', '\n')
      .split(RegExp(r'\n\s*\n'))
      .where((b) => b.trimLeft().startsWith('HTTP/'))
      .toList();
  if (blocks.isEmpty) throw const FormatException('Yanıt başlığı yok');

  final lines = blocks.last.trim().split('\n');
  final status = int.parse(lines.first.split(' ')[1]);
  final headers = <String, String>{};
  for (final l in lines.skip(1)) {
    final i = l.indexOf(':');
    if (i <= 0) continue;
    final k = l.substring(0, i).trim().toLowerCase();
    final v = l.substring(i + 1).trim();
    headers[k] = headers.containsKey(k) ? '${headers[k]}, $v' : v;
  }
  return (status, headers);
}

Future<HttpResult> _dartSend(
  String method,
  Uri url,
  Map<String, String> headers,
  List<int>? body,
  Duration timeout,
) async {
  final client = await createHttpClient();
  try {
    final req = await client.openUrl(method, url);
    headers.forEach(req.headers.set);
    if (body != null) req.add(body);
    final res = await req.close().timeout(timeout);
    final out = BytesBuilder(copy: false);
    await res.forEach(out.add);
    final h = <String, String>{};
    res.headers.forEach((k, v) => h[k.toLowerCase()] = v.join(', '));
    return HttpResult(res.statusCode, h, out.toBytes());
  } finally {
    client.close(force: true);
  }
}

/// Ağ hatasını kullanıcının (ve teşhisin) anlayacağı dile çevirir.
String describeNetworkError(Object e) {
  if (e is CurlException) {
    final reason = switch (e.exitCode) {
      5 => 'Proxy sunucusunun adı çözümlenemedi.',
      6 => 'Sunucu adı çözümlenemedi.',
      7 => 'Bağlantı kurulamadı.',
      22 => 'Sunucu dosyayı bulamadı ya da erişimi reddetti.',
      28 => 'Zaman aşımı.',
      35 => 'Güvenli bağlantı kurulamadı.',
      56 => 'Bağlantı yarıda kesildi.',
      60 => 'Sunucu sertifikası doğrulanamadı.',
      _ => 'İndirme başarısız (curl kodu ${e.exitCode}).',
    };
    return e.stderr.isEmpty ? reason : '$reason (${e.stderr})';
  }
  if (e is HandshakeException || e is TlsException) {
    return 'Sunucu sertifikası doğrulanamadı. Kurum ağındaki SSL denetimi '
        'buna yol açıyor olabilir. ($e)';
  }
  if (e is HttpException && e.message.contains('407')) {
    return 'Proxy kimlik doğrulaması istiyor (HTTP 407).';
  }
  if (e is HttpException) {
    return 'Sunucu beklenmeyen yanıt verdi (${e.message}).';
  }
  if (e is SocketException) {
    return 'Bağlantı kurulamadı. Proxy ayarı okunamamış ya da adrese erişim '
        'engelli olabilir. (${e.osError?.message ?? e.message}'
        '${e.address != null ? ', ${e.address!.host}' : ''})';
  }
  if (e is TimeoutException) return 'Zaman aşımı; bağlantı çok yavaş ya da engelli.';
  if (e is FormatException) return 'Sürüm bilgisi okunamadı (${e.message}).';
  return e.toString();
}

/// Teşhis için: uygulamanın hangi proxy'yi kullandığı.
Future<String> proxySummary() async {
  final p = await SystemProxy.load();
  final s = p.server;
  if (SystemProxy.manual != null) return 'Proxy (elle ayarlı): ${SystemProxy.manual}';
  if (s == null && p.pacUrl != null) {
    return 'Windows otomatik proxy betiği (PAC) kullanıyor: ${p.pacUrl}. '
        'Uygulama bu betiği okuyamıyor; doğrudan bağlanmaya çalışıyor.';
  }
  if (s == null) return 'Proxy kullanılmıyor (doğrudan bağlantı)';
  return 'Proxy: ${SystemProxy._proxyFor(s, 'https') ?? s}';
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
