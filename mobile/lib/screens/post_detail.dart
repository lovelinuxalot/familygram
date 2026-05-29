import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../util/share.dart';

import '../models/models.dart';
import '../state/auth.dart';
import '../state/feed.dart';
import '../util/time.dart';
import '../widgets/caption.dart';
import '../widgets/likes_sheet.dart';
import '../widgets/mention_field.dart';
import '../widgets/mention_text.dart';
import '../widgets/post_carousel.dart';
import '../widgets/user_avatar.dart';

class PostDetailScreen extends ConsumerStatefulWidget {
  final String postId;
  const PostDetailScreen({super.key, required this.postId});
  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  Post? _post;
  List<Comment> _comments = [];
  bool _loading = true;
  Object? _error;
  final _commentCtrl = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final post = await api.getPost(widget.postId);
      final comments = await api.getComments(widget.postId);
      setState(() { _post = post; _comments = comments; _loading = false; });
    } catch (e) {
      setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _submitComment() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _posting = true);
    try {
      final api = ref.read(apiClientProvider);
      final c = await api.addComment(widget.postId, text);
      setState(() {
        _comments = [..._comments, c];
        _commentCtrl.clear();
        if (_post != null) _post = _post!.copyWith(commentCount: _post!.commentCount + 1);
      });
      if (_post != null) ref.read(feedProvider.notifier).replacePost(_post!);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not post comment: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _posting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error.toString()))
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 600),
                    child: _build(_post!),
                  ),
                ),
    );
  }

  Widget _build(Post post) {
    final api = ref.read(apiClientProvider);
    final me = ref.read(authProvider).me;
    return Column(
      children: [
        Expanded(
          child: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  InkWell(
                    onTap: () => context.push('/user/${post.author.id}'),
                    child: Row(children: [
                      UserAvatar(displayName: post.author.displayName, avatarUrl: post.author.avatarUrl, cacheKey: post.author.id, radius: 16),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(post.author.displayName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          Text(formatPostTime(post.createdAt), style: TextStyle(color: Colors.grey.shade600, fontSize: 11)),
                        ],
                      ),
                    ]),
                  ),
                  const Spacer(),
                  if (me?.id == post.userId)
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
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
                        if (ok == true) {
                          try {
                            await api.deletePost(post.id);
                            ref.read(feedProvider.notifier).remove(post.id);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Post deleted.'), duration: Duration(seconds: 2)),
                              );
                              Navigator.of(context).pop();
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Could not delete: $e')),
                              );
                            }
                          }
                        }
                      },
                    ),
                ]),
              ),
              PostCarousel(post: post, useThumb: false, heroForFirst: true),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(children: [
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () async {
                      final next = post.copyWith(liked: !post.liked, likeCount: post.likeCount + (post.liked ? -1 : 1));
                      setState(() => _post = next);
                      ref.read(feedProvider.notifier).replacePost(next);
                      try {
                        if (post.liked) {
                          await api.unlike(post.id);
                        } else {
                          await api.like(post.id);
                        }
                      } catch (e) {
                        setState(() => _post = post);
                        ref.read(feedProvider.notifier).replacePost(post);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Could not update like: $e')),
                          );
                        }
                      }
                    },
                    onLongPress: post.likeCount > 0 ? () => showLikesSheet(context, post.id) : null,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(post.liked ? Icons.favorite : Icons.favorite_border, color: post.liked ? Colors.red : null),
                    ),
                  ),
                  Text('${post.likeCount}', style: const TextStyle(fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Share',
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => sharePost(context, post),
                  ),
                ]),
              ),
              if (post.caption != null && post.caption!.trim().isNotEmpty)
                CaptionText(username: post.author.username, caption: post.caption!, collapsedChars: 1000),
              const Divider(),
              ..._comments.map((c) => ListTile(
                    dense: true,
                    leading: InkWell(
                      onTap: () => context.push('/user/${c.userId}'),
                      child: UserAvatar(displayName: c.displayName, avatarUrl: c.avatarUrl, cacheKey: c.userId, radius: 16),
                    ),
                    title: InkWell(
                      onTap: () => context.push('/user/${c.userId}'),
                      child: Text(c.displayName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    ),
                    subtitle: MentionText(c.body, baseStyle: const TextStyle(fontSize: 14)),
                    trailing: Text(
                      formatPostTime(c.createdAt),
                      style: const TextStyle(fontSize: 11),
                    ),
                  )),
              const SizedBox(height: 80),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
            child: Row(children: [
              Expanded(
                child: MentionTextField(
                  controller: _commentCtrl,
                  decoration: const InputDecoration(hintText: 'Add a comment…', border: OutlineInputBorder()),
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _submitComment(),
                ),
              ),
              IconButton(
                icon: _posting
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send),
                onPressed: _posting ? null : _submitComment,
              ),
            ]),
          ),
        ),
      ],
    );
  }
}
