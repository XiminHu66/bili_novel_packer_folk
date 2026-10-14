import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:test/test.dart';
import 'package:bili_novel_packer/interceptor/retry_interceptor.dart';
import 'package:bili_novel_packer/interceptor/redirect_interceptor.dart';

class Adapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions) respond;
  int calls = 0;
  Adapter(this.respond);
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? stream,
      Future<void>? cancel) async {
    calls++;
    return respond(options);
  }
  @override
  void close({bool force = false}) {}
}
void main() {
  for (final status in [401, 403, 429]) {
    test('HTTP $status is not retried', () async {
      final adapter = Adapter((_) => ResponseBody.fromString('blocked', status));
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(RetryInterceptor(dio: dio));
      await expectLater(dio.get('https://example.test')
          .timeout(const Duration(seconds: 2)), throwsA(isA<DioException>()));
      expect(adapter.calls, 1);
      dio.close();
    });
  }
  test('exhausted transient retries reject rather than hang', () async {
    final adapter = Adapter((_) => ResponseBody.fromString('error', 503));
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(RetryInterceptor(dio: dio, maxRetries: 2));
    await expectLater(dio.get('https://example.test')
        .timeout(const Duration(seconds: 2)), throwsA(isA<DioException>()));
    expect(adapter.calls, 3);
    dio.close();
  });
  test('transient retry can recover', () async {
    var n = 0;
    final adapter = Adapter((_) => ResponseBody.fromString(
      ++n < 2 ? 'error' : 'ok', n < 2 ? 503 : 200));
    final dio = Dio()..httpClientAdapter = adapter;
    dio.interceptors.add(RetryInterceptor(dio: dio));
    expect((await dio.get('https://example.test')).data, 'ok');
    dio.close();
  });
  test('relative redirects resolve, external redirects strip credentials', () async {
    final seen = <RequestOptions>[];
    final adapter = Adapter((options) {
      seen.add(options);
      if (options.uri.path == '/first') {
        return ResponseBody.fromString('', 302, headers: {'location': ['/second']});
      }
      if (options.uri.path == '/second') {
        return ResponseBody.fromString('', 302,
            headers: {'location': ['https://other.test/final']});
      }
      return ResponseBody.fromString('ok', 200);
    });
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 400,
      headers: {'Cookie':'secret=local', 'Authorization':'Bearer private'}))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(RedirectInterceptor(dio));
    await dio.get('https://example.test/first');
    expect(seen[1].uri.toString(), 'https://example.test/second');
    expect(seen[1].headers['Cookie'], 'secret=local');
    expect(seen[2].headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
    expect(seen[2].headers.keys.map((k) => k.toLowerCase()), isNot(contains('authorization')));
    dio.close();
  });
  test('redirect cycles reject', () async {
    final adapter = Adapter((_) => ResponseBody.fromString('', 302,
      headers: {'location': ['/first']}));
    final dio = Dio(BaseOptions(validateStatus: (s) => s != null && s < 400))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(RedirectInterceptor(dio));
    await expectLater(dio.get('https://example.test/first')
      .timeout(const Duration(seconds: 2)), throwsA(isA<DioException>()));
    expect(adapter.calls, lessThanOrEqualTo(2));
    dio.close();
  });
}
