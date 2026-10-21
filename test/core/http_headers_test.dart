import 'package:flutter_test/flutter_test.dart';
import 'package:notlar/core/net/http_client.dart';

void main() {
  test('proxy tüneli ve yönlendirmeden sonra asıl yanıt alınır', () {
    const raw = 'HTTP/1.0 200 Connection Established\r\n'
        'Vary: Accept-Encoding\r\n'
        '\r\n'
        'HTTP/1.1 302 Found\r\n'
        'Location: https://objects.githubusercontent.com/x\r\n'
        '\r\n'
        'HTTP/1.0 200 Connection Established\r\n'
        '\r\n'
        'HTTP/2 401\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n'
        'WWW-Authenticate: Bearer realm="https://accounts.google.com/"\r\n'
        'Vary: Origin\r\n'
        'Vary: X-Origin\r\n'
        '\r\n';
    final (status, headers) = parseCurlHeaders(raw);
    expect(status, 401);
    expect(headers['content-type'], 'application/json; charset=UTF-8');
    expect(headers['vary'], 'Origin, X-Origin');
    expect(headers.containsKey('location'), isFalse);
  });

  test('tek blok', () {
    final (status, headers) =
        parseCurlHeaders('HTTP/1.1 200 OK\nContent-Length: 5\n\n');
    expect(status, 200);
    expect(headers['content-length'], '5');
  });
}
