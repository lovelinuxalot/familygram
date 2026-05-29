import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../state/auth.dart';
import 'user_avatar.dart';

// Bottom sheet shown on long-press of the heart icon. Lists every user who
// liked the post, newest first; tap a row → user profile.
//
// Usage:
//   showLikesSheet(context, postId);
Future<void> showLikesSheet(BuildContext context, String postId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _LikesSheet(postId: postId),
  );
}

class _LikesSheet extends ConsumerStatefulWidget {
  final String postId;
  const _LikesSheet({required this.postId});
  @override
  ConsumerState<_LikesSheet> createState() => _LikesSheetState();
}

class _LikesSheetState extends ConsumerState<_LikesSheet> {
  List<UserProfile> _users = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(apiClientProvider).getLikes(widget.postId);
      if (!mounted) return;
      setState(() { _users = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text('Liked by', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error.toString())));
    }
    if (_users.isEmpty) {
      return const Center(child: Text('No likes yet.', style: TextStyle(color: Colors.grey)));
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _users.length,
      itemBuilder: (_, i) {
        final u = _users[i];
        return ListTile(
          leading: UserAvatar(displayName: u.displayName, avatarUrl: u.avatarUrl, cacheKey: u.id, radius: 20),
          title: Text(u.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('@${u.username}', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          onTap: () {
            Navigator.pop(context);
            context.push('/user/${u.id}');
          },
        );
      },
    );
  }
}
