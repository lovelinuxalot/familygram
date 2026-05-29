import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../models/models.dart';
import '../state/auth.dart';
import '../widgets/feed_image.dart';
import '../widgets/main_scaffold.dart';
import '../widgets/user_avatar.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  bool _uploadingAvatar = false;
  List<PostThumb> _posts = [];
  bool _postsLoading = true;
  Object? _postsError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPosts());
  }

  Future<void> _loadPosts() async {
    final me = ref.read(authProvider).me;
    if (me == null) return;
    setState(() { _postsLoading = true; _postsError = null; });
    try {
      final res = await ref.read(apiClientProvider).userPosts(me.id);
      if (!mounted) return;
      setState(() { _posts = res.items; _postsLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _postsError = e; _postsLoading = false; });
    }
  }

  Future<void> _pickAvatar() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 95);
    if (x == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final raw = await x.readAsBytes();
      final processed = _processAvatar(raw);
      final me = await ref.read(apiClientProvider).uploadAvatar(processed);
      ref.read(authProvider.notifier).setMe(me);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Avatar updated.'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update avatar: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(authProvider).me;
    return MainScaffold(
      selected: MainTab.profile,
      appBar: AppBar(title: const Text('You'), automaticallyImplyLeading: false),
      body: me == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: RefreshIndicator(
                  onRefresh: _loadPosts,
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(child: _header(context, me)),
                      const SliverToBoxAdapter(child: Divider(height: 1)),
                      SliverToBoxAdapter(child: _gridHeader()),
                      _gridSliver(),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _header(BuildContext context, Me me) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              UserAvatar(displayName: me.displayName, avatarUrl: me.avatarUrl, cacheKey: me.id, radius: 32),
              Positioned(
                right: -4,
                bottom: -4,
                child: Material(
                  color: Theme.of(context).colorScheme.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _uploadingAvatar ? null : _pickAvatar,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: _uploadingAvatar
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.edit, size: 14, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ]),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(me.displayName, style: Theme.of(context).textTheme.titleLarge),
                  Text('@${me.username}', style: Theme.of(context).textTheme.bodyMedium),
                  Text(me.email, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 20),
          if (me.isAdmin)
            FilledButton.icon(
              icon: const Icon(Icons.admin_panel_settings),
              label: const Text('Family admin'),
              onPressed: () => context.push('/admin'),
            ),
          if (me.isAdmin) const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.privacy_tip_outlined),
            label: const Text('Privacy policy'),
            onPressed: () async {
              final uri = Uri.parse('${AppConfig.apiBase}/privacy');
              await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
            },
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
            onPressed: () => ref.read(authProvider.notifier).logout(),
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            icon: const Icon(Icons.delete_forever, color: Colors.red),
            label: const Text('Delete my account', style: TextStyle(color: Colors.red)),
            onPressed: () => _confirmDeleteAccount(context, ref),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteAccount(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'This deletes your profile, every photo you\'ve posted, all your '
          'comments, likes, and your avatar. This cannot be undone.\n\n'
          'You will be signed out immediately afterward.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton.tonal(
            style: FilledButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiClientProvider).deleteAccount();
      await ref.read(authProvider.notifier).logout();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not delete: $e')));
      }
    }
  }

  Widget _gridHeader() {
    final label = _postsLoading
        ? 'Loading…'
        : _postsError != null
            ? 'Could not load posts'
            : _posts.isEmpty
                ? 'No posts yet'
                : '${_posts.length} ${_posts.length == 1 ? "post" : "posts"}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(label, style: TextStyle(color: Colors.grey.shade700, fontSize: 13, fontWeight: FontWeight.w500, letterSpacing: 0.3)),
    );
  }

  Widget _gridSliver() {
    if (_postsLoading) {
      return const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())));
    }
    if (_postsError != null) {
      return SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(16), child: Text(_postsError.toString(), style: const TextStyle(color: Colors.red))));
    }
    if (_posts.isEmpty) {
      return const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 32), child: Text('Tap the camera icon below to share your first photo.', style: TextStyle(color: Colors.grey))));
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(2, 2, 2, 80),
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
              child: Stack(children: [
                Positioned.fill(child: MediaImage(url: p.thumbUrl, cacheKey: 'thumb:${p.id}:0', fit: BoxFit.cover)),
                if (p.mediaCount > 1)
                  const Positioned(
                    top: 4, right: 4,
                    child: Icon(Icons.collections, size: 16, color: Colors.white, shadows: [Shadow(blurRadius: 2)]),
                  ),
              ]),
            );
          },
          childCount: _posts.length,
        ),
      ),
    );
  }

  static Uint8List _processAvatar(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('Could not decode image');
    final fixed = img.bakeOrientation(decoded);
    final side = fixed.width < fixed.height ? fixed.width : fixed.height;
    final x = (fixed.width - side) ~/ 2;
    final y = (fixed.height - side) ~/ 2;
    final cropped = img.copyCrop(fixed, x: x, y: y, width: side, height: side);
    final resized = img.copyResize(cropped, width: 256, height: 256, interpolation: img.Interpolation.linear);
    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }
}
