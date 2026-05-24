import 'package:dio/dio.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../config.dart';

// Auth is Google-only. The native OIDC "session_token_exchange_code" flow
// runs directly against Ory (native apps don't hit browser CORS), producing
// an Ory session_token that the Worker accepts as a Bearer credential.
class OryClient {
  final Dio _direct;

  OryClient()
      : _direct = Dio(BaseOptions(
          baseUrl: AppConfig.oryBase,
          headers: {'Accept': 'application/json'},
          validateStatus: (s) => s != null && s < 500,
        ));

  // Native OIDC entry points. Both use the same session_token_exchange_code
  // flow against Ory — only the provider's display name differs (which the
  // flow's UI nodes list).
  Future<String> signInWithGoogle() => _signInWithProvider('Google');
  Future<String> signInWithApple() => _signInWithProvider('Apple');

  // Implements Ory's session_token_exchange_code flow for native apps:
  //   1. start an API flow with return_session_token_exchange_code=true and
  //      return_to=familygram://callback
  //   2. discover the provider id from the flow's UI nodes by display name
  //   3. submit method=oidc, provider=<id> → Ory returns redirect_browser_to
  //   4. open that URL in a system browser session
  //   5. user completes OAuth with the IdP → Ory redirects to
  //      familygram://callback?code=<>
  //   6. GET /sessions/token-exchange with init_code + return_to_code →
  //      session_token
  Future<String> _signInWithProvider(String providerDisplayName) async {
    final init = await _direct.get('/self-service/login/api', queryParameters: {
      'return_session_token_exchange_code': 'true',
      // Captured at flow init time, not submit. Ory persists return_to with
      // the flow and redirects to it after OIDC completes (if allowlisted).
      'return_to': 'familygram://callback',
    });
    if (init.statusCode != 200 || init.data is! Map) {
      throw OryError._('Could not start Google login (${init.statusCode})');
    }
    final flowId = init.data['id'] as String;
    final exchangeCode = init.data['session_token_exchange_code'] as String?;
    if (exchangeCode == null) {
      throw OryError._('Ory did not return a session_token_exchange_code — verify the OIDC method is enabled on the project.');
    }

    // Ory's provider id is not always literally "google" / "apple" — each
    // gets a unique suffix per provider config (e.g. "google--I75TIYk"). Look
    // it up from the flow's UI nodes so the code keeps working regardless of
    // how Ory names it.
    final providerId = _discoverProvider(init.data, providerDisplayName);
    if (providerId == null) {
      throw OryError._('No $providerDisplayName provider found in the Ory login flow. Add it under Ory Console → Authentication → Social Sign-In.');
    }

    final submit = await _direct.post(
      '/self-service/login',
      queryParameters: {'flow': flowId},
      data: {'method': 'oidc', 'provider': providerId},
    );
    // Ory may put the redirect URL either at the top level (older Kratos
    // shape) or inside a continue_with action array (newer shape).
    final redirectTo = _extractRedirect(submit.data);
    if (redirectTo == null) {
      // Surface what Ory actually returned so we can diagnose mis-config.
      // ignore: avoid_print
      print('Ory login submit response (${submit.statusCode}): ${submit.data}');
      throw OryError._('Ory did not return a Google redirect URL. Status=${submit.statusCode}. Response keys: ${submit.data is Map ? (submit.data as Map).keys.toList() : submit.data.runtimeType}');
    }

    final callbackUrl = await FlutterWebAuth2.authenticate(
      url: redirectTo,
      callbackUrlScheme: 'familygram',
      options: const FlutterWebAuth2Options(preferEphemeral: false),
    );
    // ignore: avoid_print
    print('Ory callback URL: $callbackUrl');

    final parsed = Uri.parse(callbackUrl);
    // Ory calls this the "return_to_code" — the second half of the exchange
    // pair, delivered back to the app via the callback URL. The flow-init
    // half is `exchangeCode` (above).
    final returnToCode = parsed.queryParameters['code']
        ?? Uri.splitQueryString(parsed.fragment)['code'];
    if (returnToCode == null) {
      // Ory bounced back with a flow id instead of a code — fetch the flow
      // and surface whatever the UI messages say. Most common cause: an
      // existing identity with the same email blocks the OIDC sign-in.
      final flowParam = parsed.queryParameters['flow'];
      if (flowParam != null) {
        final detail = await _describeFlowError(flowParam);
        // Translate the most common cause (existing identity) into a clearer
        // message; otherwise pass Ory's raw message through.
        final lower = detail.toLowerCase();
        if (lower.contains('exists') || lower.contains('already')) {
          throw OryError._(
            'An account with this email already exists. '
            'Sign in with email and password instead, or ask your admin to delete the existing account.',
          );
        }
        throw OryError._('Sign-in could not complete: $detail');
      }
      throw OryError._('No code in Ory callback URL: $callbackUrl');
    }

    // GET (not POST — POST trips CSRF) at /sessions/token-exchange (hyphen).
    // Parameter mapping per Kratos source:
    //   init_code      = session_token_exchange_code returned by flow init
    //   return_to_code = the `code` query param on the callback URL
    final exchange = await _direct.get('/sessions/token-exchange', queryParameters: {
      'init_code': exchangeCode,
      'return_to_code': returnToCode,
    });
    if (exchange.statusCode == 200 && exchange.data is Map && exchange.data['session_token'] is String) {
      return exchange.data['session_token'] as String;
    }
    throw OryError._(_extractMsg(exchange.data) ?? 'Token exchange failed (${exchange.statusCode})');
  }

  // Fetch a login flow and pull every UI message text out so the caller can
  // show the user a useful "what went wrong" instead of a generic error.
  Future<String> _describeFlowError(String flowId) async {
    try {
      final r = await _direct.get('/self-service/login/flows', queryParameters: {'id': flowId});
      // ignore: avoid_print
      print('Ory flow $flowId state: ${r.data}');
      final ui = (r.data is Map) ? (r.data as Map)['ui'] : null;
      final messages = <String>[];
      if (ui is Map) {
        for (final m in (ui['messages'] as List? ?? <dynamic>[])) {
          if (m is Map && m['text'] is String) messages.add(m['text'] as String);
        }
        for (final node in (ui['nodes'] as List? ?? <dynamic>[])) {
          if (node is Map) {
            for (final m in (node['messages'] as List? ?? <dynamic>[])) {
              if (m is Map && m['text'] is String) messages.add(m['text'] as String);
            }
          }
        }
      }
      if (messages.isEmpty) return 'no messages on flow $flowId';
      return messages.join('; ');
    } catch (e) {
      return 'failed to fetch flow $flowId: $e';
    }
  }

  // Look through a flow's UI nodes to find an OIDC provider by its display
  // name (e.g. "Google"). Returns the actual provider id Ory expects in the
  // submit payload (e.g. "google--I75TIYk").
  static String? _discoverProvider(Map data, String displayName) {
    final ui = data['ui'];
    if (ui is! Map) return null;
    final nodes = ui['nodes'];
    if (nodes is! List) return null;
    for (final n in nodes) {
      if (n is! Map) continue;
      if (n['group'] != 'oidc') continue;
      final attrs = n['attributes'];
      if (attrs is! Map || attrs['name'] != 'provider') continue;
      final meta = n['meta'];
      final ctx = (meta is Map ? meta['label'] : null);
      final label = (ctx is Map ? ctx['context'] : null);
      final provider = label is Map ? label['provider'] : null;
      if (provider == displayName) {
        final value = attrs['value'];
        if (value is String) return value;
      }
    }
    return null;
  }

  // Pull a redirect URL out of either shape of Ory login response:
  //   1. top-level `redirect_browser_to`
  //   2. `continue_with` array containing { action: 'redirect_browser_to', redirect_browser_to: ... }
  //   3. nested under `error` (some error responses still include the URL)
  static String? _extractRedirect(dynamic data) {
    if (data is! Map) return null;
    final top = data['redirect_browser_to'];
    if (top is String) return top;
    final cw = data['continue_with'];
    if (cw is List) {
      for (final entry in cw) {
        if (entry is Map && entry['action'] == 'redirect_browser_to') {
          final url = entry['redirect_browser_to'];
          if (url is String) return url;
        }
      }
    }
    final err = data['error'];
    if (err is Map && err['redirect_browser_to'] is String) return err['redirect_browser_to'] as String;
    return null;
  }

  static String? _extractMsg(dynamic data) {
    if (data is Map && data['message'] is String) return data['message'] as String;
    if (data is Map && data['error'] is Map && data['error']['message'] is String) {
      return data['error']['message'] as String;
    }
    return null;
  }
}

class OryError implements Exception {
  final String message;
  OryError._(this.message);
  @override
  String toString() => message;
}
