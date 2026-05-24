import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../state/auth.dart';
import '../widgets/feed_image.dart';
import '../widgets/user_avatar.dart';

// View any user's profile (their avatar, name, posts grid). For the
// signed-in user we already have ProfileScreen with editing controls; this
// is the read-only version, used when tapping another user's name/avatar or
// an @mention.
class UserProfileScreen extends ConsumerStatefulWidget {
  final String userId;
  const UserProfileScreen({super.key, required this.userId});
  @override
  ConsumerState<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  UserProfile? _user;
  List<PostThumb> _posts = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final user = await api.getUser(widget.userId);
      final res = await api.userPosts(widget.userId);
      if (!mounted) return;
      setState(() { _user = user; _posts = res.items; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    // If user is viewing themselves, bounce to the editable /me screen.
    final me = ref.read(authProvider).me;
    if (me?.id == widget.userId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/me');
      });
    }
    return Scaffold(
      appBar: AppBar(title: Text(_user?.displayName ?? 'Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error.toString())))
              : _user == null
                  ? const Center(child: Text('User not found.'))
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 600),
                        child: RefreshIndicator(
                          onRefresh: _load,
                          child: CustomScrollView(
                            slivers: [
                              SliverToBoxAdapter(child: _header(_user!)),
                              const SliverToBoxAdapter(child: Divider(height: 1)),
                              SliverToBoxAdapter(child: _countLabel()),
                              _gridSliver(),
                            ],
                          ),
                        ),
                      ),
                    ),
    );
  }

  Widget _header(UserProfile user) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        UserAvatar(displayName: user.displayName, avatarUrl: user.avatarUrl, cacheKey: user.id, radius: 32),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(user.displayName, style: Theme.of(context).textTheme.titleLarge),
              Text('@${user.username}', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _countLabel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        _posts.isEmpty ? 'No posts yet' : '${_posts.length} ${_posts.length == 1 ? "post" : "posts"}',
        style: TextStyle(color: Colors.grey.shade700, fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.3),
      ),
    );
  }

  Widget _gridSliver() {
    if (_posts.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox(height: 64));
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 32),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 2,
          crossAxisSpacing: 2,
          childAspectRatio: 1,
        ),
        delegate: SliverChildBuilderDelegate(
          (ctx, i) {
            final p = _posts[i];
            return GestureDetector(
              onTap: () => context.push('/post/${p.id}'),
              child: MediaImage(url: p.thumbUrl, cacheKey: 'thumb:${p.id}', fit: BoxFit.cover),
            );
          },
          childCount: _posts.length,
        ),
      ),
    );
  }
}
