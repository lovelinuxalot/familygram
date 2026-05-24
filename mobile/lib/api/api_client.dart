import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../config.dart';
import '../models/models.dart';

class ApiException implements Exception {
  final int status;
  final String? code;
  final String message;
  ApiException(this.status, this.message, {this.code});
  @override
  String toString() => 'ApiException($status${code != null ? "/$code" : ""}): $message';
}

// Thin Dio wrapper that:
//   - prefixes API_BASE
//   - injects Authorization: Bearer <ory session token>
//   - surfaces the special needs_invite signal so the router can route to onboarding
class ApiClient {
  final Dio _dio;
  String? _token;

  ApiClient() : _dio = Dio(BaseOptions(
          baseUrl: AppConfig.apiBase,
          headers: {'Accept': 'application/json'},
          validateStatus: (s) => s != null && s < 500,
          connectTimeout: const Duration(seconds: 15),
          sendTimeout: const Duration(seconds: 60),
          receiveTimeout: const Duration(seconds: 30),
        )) {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: (opts, h) {
      if (_token != null) opts.headers['Authorization'] = 'Bearer $_token';
      h.next(opts);
    }));
  }

  void setToken(String? t) => _token = t;

  // Public, unauthenticated. The login screen calls this on mount to decide
  // whether to render the demo email/password form. The flag is sourced from
  // the backend env var DEMO_USERS — flipping it off both 404s /auth/demo and
  // hides the UI.
  Future<bool> isDemoMode() async {
    final r = await _dio.get('/config');
    _ensureOk(r);
    return (r.data as Map<String, dynamic>)['demo_mode'] == true;
  }

  // Trade fixed demo credentials for a Bearer token that oryAuth accepts.
  // 404 → demo mode disabled. 401 → wrong credentials.
  Future<String> demoSignIn(String email, String password) async {
    final r = await _dio.post('/auth/demo', data: {'email': email, 'password': password});
    _ensureOk(r);
    return (r.data as Map<String, dynamic>)['session_token'] as String;
  }

  Future<Me> me() async {
    final r = await _dio.get('/me');
    _ensureOk(r);
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> deleteAccount() async {
    final r = await _dio.delete('/me');
    _ensureOk(r);
  }

  // Completes signup. Returns Me on success, or throws ApiException with
  // status 403 + code 'not_allowed' if the email isn't on the allowlist.
  Future<Me> finalize() async {
    final r = await _dio.post('/me/finalize');
    _ensureOk(r);
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  // ─── Admin ──────────────────────────────────────────────────────────────
  Future<List<AllowlistEntry>> adminListAllowlist() async {
    final r = await _dio.get('/admin/allowlist');
    _ensureOk(r);
    return ((r.data as Map<String, dynamic>)['items'] as List)
        .map((j) => AllowlistEntry.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<void> adminAddAllowlist(String email) async {
    final r = await _dio.post('/admin/allowlist', data: {'email': email});
    _ensureOk(r);
  }

  Future<void> adminRemoveAllowlist(String email) async {
    final r = await _dio.delete('/admin/allowlist/${Uri.encodeComponent(email)}');
    _ensureOk(r);
  }

  Future<List<AdminUser>> adminListUsers() async {
    final r = await _dio.get('/admin/users');
    _ensureOk(r);
    return ((r.data as Map<String, dynamic>)['items'] as List)
        .map((j) => AdminUser.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<AdminUser> adminSetUserAdmin(String userId, bool isAdmin) async {
    final r = await _dio.patch('/admin/users/$userId', data: {'is_admin': isAdmin});
    _ensureOk(r);
    return AdminUser.fromJson(r.data as Map<String, dynamic>);
  }

  Future<({List<Post> items, String? nextCursor})> feed({String? cursor}) async {
    final r = await _dio.get('/feed', queryParameters: {if (cursor != null) 'cursor': cursor});
    _ensureOk(r);
    final data = r.data as Map<String, dynamic>;
    return (
      items: (data['items'] as List).map((j) => Post.fromJson(j as Map<String, dynamic>)).toList(),
      nextCursor: data['next_cursor'] as String?,
    );
  }

  Future<UserProfile> getUser(String userId) async {
    final r = await _dio.get('/users/$userId');
    _ensureOk(r);
    return UserProfile.fromJson(r.data as Map<String, dynamic>);
  }

  Future<UserProfile> getUserByUsername(String username) async {
    final r = await _dio.get('/users/by-username/$username');
    _ensureOk(r);
    return UserProfile.fromJson(r.data as Map<String, dynamic>);
  }

  Future<List<UserProfile>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];
    final r = await _dio.get('/users/search', queryParameters: {'q': query});
    _ensureOk(r);
    return ((r.data as Map<String, dynamic>)['items'] as List)
        .map((j) => UserProfile.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<({List<PostThumb> items, String? nextCursor})> userPosts(String userId, {String? cursor}) async {
    final r = await _dio.get('/users/$userId/posts', queryParameters: {if (cursor != null) 'cursor': cursor});
    _ensureOk(r);
    final data = r.data as Map<String, dynamic>;
    return (
      items: (data['items'] as List).map((j) => PostThumb.fromJson(j as Map<String, dynamic>)).toList(),
      nextCursor: data['next_cursor'] as String?,
    );
  }

  Future<Post> getPost(String id) async {
    final r = await _dio.get('/posts/$id');
    _ensureOk(r);
    return Post.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> like(String id) async => _ensureOk(await _dio.post('/posts/$id/like'));
  Future<void> unlike(String id) async => _ensureOk(await _dio.delete('/posts/$id/like'));
  Future<void> deletePost(String id) async => _ensureOk(await _dio.delete('/posts/$id'));

  Future<List<Comment>> getComments(String postId) async {
    final r = await _dio.get('/posts/$postId/comments');
    _ensureOk(r);
    return ((r.data as Map<String, dynamic>)['items'] as List)
        .map((j) => Comment.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<Comment> addComment(String postId, String body) async {
    final r = await _dio.post('/posts/$postId/comments', data: {'body': body});
    _ensureOk(r);
    return Comment.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Me> uploadAvatar(Uint8List bytes) async {
    final form = FormData.fromMap({
      'avatar': MultipartFile.fromBytes(bytes, filename: 'avatar.jpg', contentType: _mediaType('image/jpeg')),
    });
    final r = await _dio.post('/me/avatar', data: form);
    _ensureOk(r);
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  Future<Post> uploadPost({
    required Uint8List imageBytes,
    required String imageMime,
    required Uint8List thumbBytes,
    required int width,
    required int height,
    String? caption,
  }) async {
    final imgExt = imageMime == 'image/png' ? 'png' : 'jpg';
    final form = FormData.fromMap({
      'image': MultipartFile.fromBytes(imageBytes, filename: 'image.$imgExt', contentType: _mediaType(imageMime)),
      'thumb': MultipartFile.fromBytes(thumbBytes, filename: 'thumb.jpg', contentType: _mediaType('image/jpeg')),
      'width': width.toString(),
      'height': height.toString(),
      if (caption != null && caption.isNotEmpty) 'caption': caption,
    });
    final r = await _dio.post('/posts', data: form);
    _ensureOk(r);
    // /posts returns a partial; refetch to get author/likes shape
    return getPost((r.data as Map<String, dynamic>)['id'] as String);
  }

  void _ensureOk(Response r) {
    if (r.statusCode != null && r.statusCode! >= 200 && r.statusCode! < 300) return;
    final data = r.data;
    String? code; String message = 'request failed';
    if (data is Map) {
      code = data['error']?.toString();
      message = data['message']?.toString() ?? code ?? message;
    }
    throw ApiException(r.statusCode ?? 0, message, code: code);
  }

  static DioMediaType _mediaType(String mime) {
    final parts = mime.split('/');
    return DioMediaType(parts[0], parts.length > 1 ? parts[1] : 'octet-stream');
  }
}
