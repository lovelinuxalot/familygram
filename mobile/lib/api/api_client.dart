import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../config.dart';
import '../models/models.dart';

class ServerConfig {
  final bool demoMode;
  final bool debug;
  // Hard cap on photos per post. Mobile reads this at startup so the picker
  // and the upload screen enforce the same number as the Worker.
  final int maxPostMedia;
  const ServerConfig({required this.demoMode, required this.debug, required this.maxPostMedia});
}

// One photo to attach to a multi-photo post. The upload screen produces this
// list after compressing each picked image to full + thumb WebP.
class UploadMedia {
  final Uint8List imageBytes;
  final String imageMime;     // 'image/webp' / 'image/jpeg' / 'image/png'
  final Uint8List thumbBytes;
  final int width;
  final int height;
  const UploadMedia({
    required this.imageBytes,
    required this.imageMime,
    required this.thumbBytes,
    required this.width,
    required this.height,
  });
}

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
  // Last successful fetchConfig() result. main.dart fetches at boot, so any
  // screen can read this without re-fetching. Null until the first /config
  // call succeeds; callers should fall back to a safe default.
  static ServerConfig? lastConfig;

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
    final cfg = await fetchConfig();
    return cfg.demoMode;
  }

  // Public, unauthenticated. Returns the full server config in one round-trip.
  // Called at app startup so the debug flag is available before push diagnostics
  // start firing.
  Future<ServerConfig> fetchConfig() async {
    final r = await _dio.get('/config');
    _ensureOk(r);
    final data = r.data as Map<String, dynamic>;
    final cfg = ServerConfig(
      demoMode: data['demo_mode'] == true,
      debug: data['debug'] == true,
      maxPostMedia: (data['max_post_media'] as int?) ?? 5,
    );
    ApiClient.lastConfig = cfg;
    return cfg;
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

  Future<List<UserProfile>> getLikes(String postId) async {
    final r = await _dio.get('/posts/$postId/likes');
    _ensureOk(r);
    return ((r.data as Map<String, dynamic>)['items'] as List)
        .map((j) => UserProfile.fromJson(j as Map<String, dynamic>))
        .toList();
  }
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

  Future<void> registerDeviceToken(String token, String platform) async {
    final r = await _dio.post('/me/device-tokens', data: {'token': token, 'platform': platform});
    _ensureOk(r);
  }

  // Best-effort: don't throw — diagnostics shouldn't break anything they touch.
  Future<void> pushDiagnostic(Map<String, Object?> info) async {
    try {
      await _dio.post('/me/push-diagnostic', data: info);
    } catch (_) {/* swallow */}
  }

  // Body-not-path so the FCM token (long, contains ':') doesn't need URL encoding.
  Future<void> unregisterDeviceToken(String token) async {
    final r = await _dio.delete('/me/device-tokens', data: {'token': token});
    _ensureOk(r);
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
    required List<UploadMedia> media,
    String? caption,
  }) async {
    if (media.isEmpty) {
      throw ArgumentError('uploadPost: at least one media required');
    }
    final fields = <String, dynamic>{
      if (caption != null && caption.isNotEmpty) 'caption': caption,
    };
    for (var i = 0; i < media.length; i++) {
      final m = media[i];
      final imgExt = m.imageMime == 'image/png'
          ? 'png'
          : m.imageMime == 'image/webp'
              ? 'webp'
              : 'jpg';
      fields['image_$i'] = MultipartFile.fromBytes(
        m.imageBytes,
        filename: 'image_$i.$imgExt',
        contentType: _mediaType(m.imageMime),
      );
      fields['thumb_$i'] = MultipartFile.fromBytes(
        m.thumbBytes,
        filename: 'thumb_$i.webp',
        contentType: _mediaType('image/webp'),
      );
      fields['width_$i'] = m.width.toString();
      fields['height_$i'] = m.height.toString();
    }
    final r = await _dio.post('/posts', data: FormData.fromMap(fields));
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
