import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'state/auth.dart';
import 'state/biometric.dart';
import 'theme.dart';
import 'screens/admin_panel.dart';
import 'screens/biometric_lock.dart';
import 'screens/feed.dart';
import 'screens/image_viewer.dart';
import 'screens/login.dart';
import 'screens/not_allowed.dart';
import 'screens/post_detail.dart';
import 'screens/profile.dart';
import 'screens/upload.dart';
import 'screens/user_profile.dart';

void main() {
  runApp(const ProviderScope(child: FamilygramApp()));
}

class FamilygramApp extends ConsumerStatefulWidget {
  const FamilygramApp({super.key});
  @override
  ConsumerState<FamilygramApp> createState() => _FamilygramAppState();
}

class _FamilygramAppState extends ConsumerState<FamilygramApp> with WidgetsBindingObserver {
  late final _AuthListenable _authListenable;
  late final GoRouter _router;
  bool _booted = false;
  DateTime? _backgroundedAt;
  // Re-lock the app if it was backgrounded for at least this long.
  static const _relockAfter = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authListenable = _AuthListenable();
    ref.listenManual(authProvider, (_, __) => _authListenable.ping());
    _router = GoRouter(
      refreshListenable: _authListenable,
      redirect: (ctx, state) {
        final auth = ref.read(authProvider);
        final loc = state.matchedLocation;
        final atLogin = loc == '/login';
        final atNotAllowed = loc == '/not-allowed';
        if (!auth.isAuthed) return atLogin ? null : '/login';
        if (auth.notAllowed) return atNotAllowed ? null : '/not-allowed';
        if (auth.isOnboarded && (atLogin || atNotAllowed)) return '/';
        return null;
      },
      routes: [
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(path: '/not-allowed', builder: (_, __) => const NotAllowedScreen()),
        GoRoute(path: '/', builder: (_, __) => const FeedScreen()),
        GoRoute(path: '/upload', builder: (_, __) => const UploadScreen()),
        GoRoute(path: '/me', builder: (_, __) => const ProfileScreen()),
        GoRoute(path: '/user/:id', builder: (_, s) => UserProfileScreen(userId: s.pathParameters['id']!)),
        GoRoute(path: '/admin', builder: (_, __) => const AdminPanelScreen()),
        GoRoute(path: '/post/:id', builder: (_, s) => PostDetailScreen(postId: s.pathParameters['id']!)),
        GoRoute(
          path: '/view',
          builder: (_, s) {
            final extra = (s.extra as Map<String, String>?) ?? const {};
            return ImageViewerScreen(
              url: extra['url'] ?? '',
              cacheKey: extra['cacheKey'],
            );
          },
        ),
      ],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(authProvider.notifier).bootstrap();
      if (mounted) setState(() => _booted = true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      if (since != null && DateTime.now().difference(since) >= _relockAfter) {
        ref.read(biometricProvider.notifier).lock();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_booted) {
      return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    return MaterialApp.router(
      title: 'Familygram',
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.system,
      routerConfig: _router,
      // Overlay the biometric lock screen over whatever route is current so
      // the user can resume right where they were after unlocking.
      builder: (context, child) {
        final auth = ref.watch(authProvider);
        final bio = ref.watch(biometricProvider);
        final showLock = auth.isAuthed && auth.isOnboarded && bio.shouldLock;
        return Stack(children: [
          child ?? const SizedBox.shrink(),
          if (showLock) const BiometricLockScreen(),
        ]);
      },
    );
  }
}

class _AuthListenable extends ChangeNotifier {
  void ping() => notifyListeners();
}
