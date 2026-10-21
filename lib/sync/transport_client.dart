import 'package:http/http.dart' as http;

import '../core/net/http_client.dart';

/// Google'ın Dart kütüphanelerinin (giriş, token yenileme, Drive API)
/// bütün isteklerini uygulamanın ağ katmanından geçirir.
///
/// Windows'ta bu, curl ve Windows'un şifreleme altyapısı demektir: kurum
/// proxy'si ve SSL denetimiyle tarayıcı gibi çalışır.
class TransportClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    final res = await httpSend(
      request.method,
      request.url,
      headers: request.headers,
      body: body.isEmpty && (request.method == 'GET' || request.method == 'DELETE')
          ? null
          : body,
    );
    return http.StreamedResponse(
      Stream.value(res.body),
      res.status,
      contentLength: res.body.length,
      headers: res.headers,
      request: request,
    );
  }
}
