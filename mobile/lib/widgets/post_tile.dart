import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../state/auth.dart';
import '../state/feed.dart';
import '../util/share.dart';
import '../util/time.dart';
import 'caption.dart';
import 'comments_sheet.dart';
import 'feed_image.dart';
import 'user_avatar.dart';

class PostTile extends ConsumerWidget {
  final Post post;
  const PostTile({super.key, required this.post});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final me = ref.watch(authProvider).me;
    final isMine = me?.id == post.userId;
    final ar = (post.width != null && post.height != null && post.height! > 0)
        ? post.width! / post.height!
        : 1.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            InkWell(
              onTap: () => context.push('/user/${post.author.id}'),
              child: Row(children: [
                UserAvatar(displayName: post.author.displayName, avatarUrl: post.author.avatarUrl, cacheKey: post.author.id, radius: 16),
                const SizedBox(width: 10),
                Text(post.author.displayName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ]),
            ),
            const Spacer(),
            Text(formatPostTime(post.createdAt), style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            if (isMine)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 20),
                tooltip: 'More',
                onSelected: (value) async {
                  if (value == 'delete') await _confirmDelete(context, ref);
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'delete', child: Text('Delete post')),
                ],
              ),
          ]),
        ),
        GestureDetector(
          onTap: () => context.push('/view', extra: {'url': post.imageUrl, 'cacheKey': 'full:${post.id}'}),
          child: MediaImage(url: post.thumbUrl, cacheKey: 'thumb:${post.id}', aspectRatio: ar, fit: BoxFit.cover),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(children: [
            IconButton(
              icon: Icon(post.liked ? Icons.favorite : Icons.favorite_border, color: post.liked ? Colors.red : null),
              onPressed: () async {
                final next = post.copyWith(liked: !post.liked, likeCount: post.likeCount + (post.liked ? -1 : 1));
                ref.read(feedProvider.notifier).replacePost(next);
                try {
                  if (post.liked) {
                    await api.unlike(post.id);
                  } else {
                    await api.like(post.id);
                  }
                } catch (e) {
                  ref.read(feedProvider.notifier).replacePost(post);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not update like: $e')),
                    );
                  }
                }
              },
            ),
            Text('${post.likeCount}', style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 12),
            IconButton(
              icon: const Icon(Icons.mode_comment_outlined),
              onPressed: () => showCommentsSheet(context, post),
            ),
            Text('${post.commentCount}', style: const TextStyle(fontSize: 13)),
            const Spacer(),
            // Builder gives us the share IconButton's own render box for the
            // iPad share-popover anchor.
            Builder(builder: (innerContext) => IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.ios_share),
              onPressed: () => sharePost(innerContext, post),
            )),
          ]),
        ),
        if (post.caption != null && post.caption!.trim().isNotEmpty)
          CaptionText(username: post.author.username, caption: post.caption!),
        if ((post.caption == null || post.caption!.trim().isEmpty)) const SizedBox(height: 8),
        // View-comments hint at the bottom of each tile, Instagram-style.
        if (post.commentCount > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: InkWell(
              onTap: () => showCommentsSheet(context, post),
              child: Text(
                post.commentCount == 1
                    ? 'View 1 comment'
                    : 'View all ${post.commentCount} comments',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
              ),
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiClientProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete post?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.deletePost(post.id);
      ref.read(feedProvider.notifier).remove(post.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Post deleted.'), duration: Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete: $e')),
        );
      }
    }
  }
}
