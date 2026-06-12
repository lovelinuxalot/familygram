// Maps thrown exceptions to short, friendly, user-facing strings so screens
// never render raw `DioException [...]` / `ApiException(...)` text. Returns a
// complete sentence that reads fine on its own (inline error labels) or after
// a short action prefix in a SnackBar (e.g. "Could not delete post.").
//
// Network failures come through as DioException (timeouts, no connectivity,
// 5xx) or — for 4xx responses the api_client unwraps — as ApiException. Keep
// the original exception in state/logs; only convert at the point of display.

import 'package:dio/dio.dart';

import '../api/api_client.dart';

String friendlyError(Object? error) {
  if (error is ApiException) return _apiMessage(error);
  if (error is DioException) return _dioMessage(error);
  return 'Something went wrong. Please try again.';
}

String _dioMessage(DioException e) {
  switch (e.type) {
    case DioExceptionType.sendTimeout:
      return 'The upload took too long. Try again, or share fewer photos at once.';
    case DioExceptionType.receiveTimeout:
    case DioExceptionType.connectionTimeout:
      return 'The connection timed out. Check your internet and try again.';
    case DioExceptionType.connectionError:
      return "Couldn't reach the server. Check your internet connection and try again.";
    case DioExceptionType.badCertificate:
      return "Couldn't establish a secure connection. Please try again.";
    case DioExceptionType.cancel:
      return 'The request was cancelled.';
    case DioExceptionType.badResponse:
      // 5xx lands here (api_client treats <500 as a normal response). Prefer a
      // structured server message if one came back.
      final data = e.response?.data;
      if (data is Map && data['message'] is String && (data['message'] as String).isNotEmpty) {
        return data['message'] as String;
      }
      return _statusMessage(e.response?.statusCode);
    case DioExceptionType.unknown:
      return 'Something went wrong. Please try again.';
  }
}

String _apiMessage(ApiException e) {
  switch (e.status) {
    case 401:
      return 'Your session has expired. Please sign in again.';
    case 403:
      return e.message.isNotEmpty ? e.message : "You don't have access to this.";
    case 413:
      return 'Those photos are too large to upload. Try fewer or smaller photos.';
    case 429:
      return "You're doing that a bit too fast. Wait a moment and try again.";
  }
  if (e.status >= 500) return 'The server ran into a problem. Please try again in a moment.';
  // 4xx with a server-provided message is usually already human-readable.
  return e.message.isNotEmpty ? e.message : 'Something went wrong. Please try again.';
}

String _statusMessage(int? status) {
  if (status == null) return 'Something went wrong. Please try again.';
  if (status == 401) return 'Your session has expired. Please sign in again.';
  if (status == 403) return "You don't have access to this.";
  if (status == 413) return 'Those photos are too large to upload.';
  if (status == 429) return "You're doing that a bit too fast. Wait a moment and try again.";
  if (status >= 500) return 'The server ran into a problem. Please try again in a moment.';
  return 'Something went wrong. Please try again.';
}
