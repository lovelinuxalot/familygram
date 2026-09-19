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
  String? _activeTenantId;

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
      if (_activeTenantId != null) opts.headers['X-Tenant-Id'] = _activeTenantId;
      h.next(opts);
    }));
  }

  void setToken(String? t) => _token = t;

  // Scopes subsequent requests to one family. Null (e.g. before /me resolves
  // or after logout) lets the server fall back to the user's first membership.
  void setActiveTenant(String? tenantId) => _activeTenantId = tenantId;

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

  Future<void> adminAddAllowlist(String email, {required String tenantId}) async {
    final r = await _dio.post('/admin/allowlist', data: {'email': email, 'tenant_id': tenantId});
    _ensureOk(r);
  }

  Future<void> adminRemoveAllowlist(String email, {required String tenantId}) async {
    final r = await _dio.delete(
      '/admin/allowlist/${Uri.encodeComponent(email)}',
      queryParameters: {'tenant_id': tenantId},
    );
    _ensureOk(r);
  }

  Future<List<AdminTenant>> adminListTenants() async {
    final r = await _dio.get('/admin/tenants');
    _ensureOk(r);
    return ((r.data as Map<String, dynamic>)['items'] as List)
        .map((j) => AdminTenant.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<AdminTenant> adminCreateTenant(String name) async {
    final r = await _dio.post('/admin/tenants', data: {'name': name});
    _ensureOk(r);
    return AdminTenant.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> adminRenameTenant(String tenantId, String name) async {
    final r = await _dio.patch('/admin/tenants/$tenantId', data: {'name': name});
    _ensureOk(r);
  }

  Future<List<UserProfile>> adminListTenantMembers(String tenantId) async {
    final r = await _dio.get('/admin/tenants/$tenantId/members');
    _ensureOk(r);
    return ((r.data as Map<String, dynamic>)['items'] as List)
        .map((j) => UserProfile.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<void> adminAddTenantMember(String tenantId, String userId) async {
    final r = await _dio.post('/admin/tenants/$tenantId/members', data: {'user_id': userId});
    _ensureOk(r);
  }

  // Per-family save permission (migration 0010). Admins are always allowed
  // server-side, so toggling one off is a no-op for them.
  Future<void> adminSetTenantMemberDownload(String tenantId, String userId, bool canDownload) async {
    final r = await _dio.patch(
      '/admin/tenants/$tenantId/members/$userId',
      data: {'can_download': canDownload},
    );
    _ensureOk(r);
  }

  Future<void> adminRemoveTenantMember(String tenantId, String userId) async {
    final r = await _dio.delete('/admin/tenants/$tenantId/members/$userId');
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

  // reason: child_safety | nudity | harassment | other
  Future<void> report(String targetType, String targetId, String reason, {String? note}) async =>
      _ensureOk(await _dio.post('/reports', data: {
        'target_type': targetType,
        'target_id': targetId,
        'reason': reason,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }));

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
    final r = await _dio.post('/me/avatar', data: form, options: _uploadOptions());
    _ensureOk(r);
    return Me.fromJson(r.data as Map<String, dynamic>);
  }

  // Uploads are split per-photo (POST /media) instead of one big multipart POST
  // so a stalling uplink can't kill a whole multi-photo post. Each photo is
  // small, but a 2000px WebP can still take a while on a slow link, so keep a
  // generous send window. Avatar uploads reuse this too.
  static Options _uploadOptions() => Options(sendTimeout: const Duration(seconds: 90));

  // Retry only transient network failures — timeouts, dropped connections, 5xx.
  // A 4xx (too large, wrong type, auth) surfaces as ApiException and won't get
  // better on retry, so it's not handled here.
  static bool _isRetryable(DioException e) {
    switch (e.type) {
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        return (e.response?.statusCode ?? 0) >= 500;
      default:
        return false;
    }
  }

  // Upload one photo (full + thumb) to the staging area and return its media id.
  // Retries transient failures with backoff; rethrows a 4xx (ApiException) or a
  // non-retryable error immediately. FormData is rebuilt each attempt because
  // its byte streams are single-use.
  Future<String> uploadMedia(UploadMedia m) async {
    final imgExt = m.imageMime == 'image/png'
        ? 'png'
        : m.imageMime == 'image/webp'
            ? 'webp'
            : 'jpg';
    Object lastError = StateError('uploadMedia: no attempts made');
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 400 * (1 << (attempt - 1))));
      }
      try {
        final form = FormData.fromMap({
          'image': MultipartFile.fromBytes(m.imageBytes, filename: 'image.$imgExt', contentType: _mediaType(m.imageMime)),
          'thumb': MultipartFile.fromBytes(m.thumbBytes, filename: 'thumb.webp', contentType: _mediaType('image/webp')),
          'width': m.width.toString(),
          'height': m.height.toString(),
        });
        final r = await _dio.post('/media', data: form, options: _uploadOptions());
        _ensureOk(r);
        return (r.data as Map<String, dynamic>)['media_id'] as String;
      } on ApiException {
        rethrow; // 4xx — won't succeed on retry.
      } on DioException catch (e) {
        if (!_isRetryable(e)) rethrow;
        lastError = e;
      }
    }
    throw lastError;
  }

  // Assemble a post from photos already uploaded via [uploadMedia]. Small JSON
  // request, so it effectively never times out. /posts returns a partial;
  // refetch to get the full author/likes shape.
  Future<Post> createPost({required List<String> mediaIds, String? caption, List<String>? tenantIds}) async {
    if (mediaIds.isEmpty) {
      throw ArgumentError('createPost: at least one media id required');
    }
    final r = await _dio.post('/posts', data: {
      if (caption != null && caption.isNotEmpty) 'caption': caption,
      'media_ids': mediaIds,
      if (tenantIds != null && tenantIds.isNotEmpty) 'tenant_ids': tenantIds,
    });
    _ensureOk(r);
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
