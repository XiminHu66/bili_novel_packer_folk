import 'dart:io';
import 'package:dio/dio.dart';

class RedirectInterceptor extends Interceptor {
  final Dio dio;
  static const String redirectKey = "redirect";
  RedirectInterceptor(this.dio);
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.followRedirects = false;
    handler.next(options);
  }
  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) async {
    if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
      handler.next(response);
      return;
    }
    final location = response.headers[HttpHeaders.locationHeader]?.firstOrNull;
    if (location == null) { handler.next(response); return; }
    final current = response.requestOptions.uri;
    final next = current.resolve(location);
    final history = List<String>.from(response.requestOptions.extra[redirectKey] ?? []);
    if (history.length >= 5 || history.contains(next.toString())) {
      handler.reject(DioException(requestOptions: response.requestOptions,
          error: StateError('重定向循环或超过 5 次。')));
      return;
    }
    if (!['https', 'http'].contains(next.scheme)) {
      handler.reject(DioException(requestOptions: response.requestOptions,
          error: StateError('不支持的重定向地址。')));
      return;
    }
    final options = response.requestOptions.copyWith(path: next.toString(),
        headers: Map<String, dynamic>.from(response.requestOptions.headers),
        extra: {...response.requestOptions.extra,
          redirectKey: [...history, current.toString()]});
    if (current.origin != next.origin) {
      options.headers.removeWhere((key, _) => ['cookie', 'authorization', 'proxy-authorization']
          .contains(key.toLowerCase()));
    }
    try { handler.resolve(await dio.fetch<dynamic>(options)); }
    on DioException catch (error) { handler.reject(error); }
    catch (error, stack) {
      handler.reject(DioException(requestOptions: options, error: error, stackTrace: stack));
    }
  }
}
