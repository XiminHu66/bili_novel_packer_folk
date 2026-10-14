import 'package:dio/dio.dart';

const _retryInfoKey = "retry_count";
class RetryInterceptor extends Interceptor {
  final Dio dio;
  final int maxRetries;
  final Duration delay;
  RetryInterceptor({required this.dio, this.maxRetries = 3,
      this.delay = Duration.zero});

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final count = (err.requestOptions.extra[_retryInfoKey] as int?) ?? 0;
    final status = err.response?.statusCode;
    final transient = [DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout, DioExceptionType.receiveTimeout,
      DioExceptionType.sendTimeout].contains(err.type) ||
      (status != null && status >= 500 && status <= 599);
    // Login errors, verification, rate limits and cancellation require user action.
    if (!transient || err.type == DioExceptionType.cancel || count >= maxRetries) {
      handler.next(err);
      return;
    }
    err.requestOptions.extra[_retryInfoKey] = count + 1;
    await Future<void>.delayed(delay * (1 << count));
    try {
      handler.resolve(await dio.fetch<dynamic>(err.requestOptions));
    } on DioException catch (retryError) {
      handler.reject(retryError);
    } catch (error, stack) {
      handler.reject(DioException(requestOptions: err.requestOptions,
          error: error, stackTrace: stack));
    }
  }
}
