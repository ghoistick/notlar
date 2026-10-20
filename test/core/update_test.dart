import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/net/http_client.dart';
import 'package:notlar/core/update/update_manifest.dart';
import 'package:notlar/core/version.dart';

void main() {
  test('sürüm karşılaştırma', () {
    expect(compareVersions('1.0.1', '1.0.0'), greaterThan(0));
    expect(compareVersions('1.2.10', '1.2.9'), greaterThan(0));
    expect(compareVersions('2.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('1.0.0+5', '1.0.0+1'), 0);
    expect(compareVersions('0.9.0', '1.0.0'), lessThan(0));
  });

  group('imzalı sürüm bilgisi', () {
    late SimpleKeyPair kp;
    late List<int> pub;
    late UpdateManifest signed;

    setUp(() async {
      kp = await Ed25519().newKeyPair();
      pub = (await kp.extractPublicKey()).bytes;
      signed = await UpdateManifest(
        version: '1.0.1',
        publishedAt: '2026-10-20T10:00:00Z',
        notes: 'Düzeltmeler',
        url: releaseAssetUrl('1.0.1', 'MusveddeKurulum-1.0.1.exe'),
        sha256: 'ab' * 32,
        size: 1234,
      ).signedWith(kp);
    });

    test('doğru anahtarla doğrulanır, JSON üzerinden de', () async {
      expect(await signed.verify(pub), isTrue);
      final roundTrip = UpdateManifest.fromJson(
          jsonDecode(jsonEncode(signed.toJson())) as Map<String, dynamic>);
      expect(await roundTrip.verify(pub), isTrue);
    });

    test('başka bir anahtarla imzalanmış bilgi reddedilir', () async {
      final other = await Ed25519().newKeyPair();
      final otherPub = (await other.extractPublicKey()).bytes;
      expect(await signed.verify(otherPub), isFalse);
    });

    test('herhangi bir alan değiştirilirse imza geçersiz olur', () async {
      final j = signed.toJson();
      for (final tamper in <void Function(Map<String, dynamic>)>[
        (m) => m['version'] = '9.9.9',
        (m) => m['notes'] = 'sahte not',
        (m) => (m['windows'] as Map)['url'] = 'https://example.com/kotu.exe',
        (m) => (m['windows'] as Map)['sha256'] = 'cd' * 32,
        (m) => (m['windows'] as Map)['size'] = 99,
      ]) {
        final copy = jsonDecode(jsonEncode(j)) as Map<String, dynamic>;
        tamper(copy);
        expect(await UpdateManifest.fromJson(copy).verify(pub), isFalse);
      }
    });

    test('imzasız bilgi reddedilir', () async {
      expect(await signed.withSignature('').verify(pub), isFalse);
    });
  });

  group('sistem proxy', () {
    test('Windows kayıt defteri çıktısı', () {
      const out = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    http=p1.kurum:80;https=p2.kurum:8080
    ProxyOverride    REG_SZ    <local>;*.kurum.gov.tr;10.*
''';
      final p = SystemProxy.fromRegistryOutput(out);
      expect(p.resolve(Uri.parse('https://github.com/x')), 'PROXY p2.kurum:8080; DIRECT');
      expect(p.resolve(Uri.parse('http://ornek.com')), 'PROXY p1.kurum:80; DIRECT');
      expect(p.resolve(Uri.parse('https://intranet/')), 'DIRECT');
      expect(p.resolve(Uri.parse('https://atlas.kurum.gov.tr')), 'DIRECT');
      expect(p.resolve(Uri.parse('http://10.1.2.3')), 'DIRECT');
    });

    test('proxy kapalıysa doğrudan bağlanır', () {
      const out = '    ProxyEnable    REG_DWORD    0x0\n'
          '    ProxyServer    REG_SZ    p:80\n';
      expect(SystemProxy.fromRegistryOutput(out).resolve(Uri.parse('https://a.com')),
          'DIRECT');
    });

    test('ortam değişkeni biçimi', () {
      expect(SystemProxy.stripScheme('http://proxy.kurum:3128/'), 'proxy.kurum:3128');
      const p = SystemProxy(server: 'proxy.kurum:3128');
      expect(p.resolve(Uri.parse('https://github.com')), 'PROXY proxy.kurum:3128; DIRECT');
    });
  });
}
