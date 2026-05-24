import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../state/auth.dart';
import '../state/feed.dart';
import '../util/time.dart';
import 'mention_field.dart';
import 'mention_text.dart';
import 'user_avatar.dart';

// Bottom sheet shown when the user taps the comment icon on a feed tile.
// Holds the comment list + composer. Replaces the previous "open
// /post/:id" navigation.
//
// Usage:
//   showCommentsSheet(context, post);
Future<void> showCommentsSheet(BuildContext context, Post post) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,        // grows to ~90% screen
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _CommentsSheet(post: post),
  );
}

class _CommentsSheet extends ConsumerStatefulWidget {
  final Post post;
  const _CommentsSheet({required this.post});
  @override
  ConsumerState<_CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends ConsumerState<_CommentsSheet> {
  List<Comment> _comments = [];
  bool _loading = true;
  Object? _error;
  final _commentCtrl = TextEditingController();
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await ref.read(apiClientProvider).getComments(widget.post.id);
      if (!mounted) return;
      setState(() { _comments = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _submit() async {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _posting = true);
    try {
      final c = await ref.read(apiClientProvider).addComment(widget.post.id, text);
      if (!mounted) return;
      setState(() {
        _comments = [..._comments, c];
        _commentCtrl.clear();
      });
      // Update feed count so the tile's comment number rolls forward.
      final updated = widget.post.copyWith(commentCount: widget.post.commentCount + 1);
      ref.read(feedProvider.notifier).replacePost(updated);
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
    // Take ~85% of screen height, with extra padding for the keyboard.
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text('Comments', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            Expanded(child: _body()),
            const Divider(height: 1),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(children: [
                  Expanded(
                    child: MentionTextField(
                      controller: _commentCtrl,
                      decoration: const InputDecoration(hintText: 'Add a comment…', border: OutlineInputBorder()),
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  IconButton(
                    icon: _posting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    onPressed: _posting ? null : _submit,
                  ),
                ]),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Padding(padding: const EdgeInsets.all(16), child: Text(_error.toString())));
    if (_comments.isEmpty) {
      return const Center(child: Text('No comments yet. Be the first.', style: TextStyle(color: Colors.grey)));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _comments.length,
      separatorBuilder: (_, __) => const SizedBox(height: 0),
      itemBuilder: (_, i) {
        final c = _comments[i];
        return ListTile(
          dense: true,
          leading: InkWell(
            onTap: () { Navigator.pop(context); context.push('/user/${c.userId}'); },
            child: UserAvatar(displayName: c.displayName, avatarUrl: c.avatarUrl, cacheKey: c.userId, radius: 16),
          ),
          title: InkWell(
            onTap: () { Navigator.pop(context); context.push('/user/${c.userId}'); },
            child: Text(c.displayName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          subtitle: MentionText(c.body, baseStyle: const TextStyle(fontSize: 14)),
          trailing: Text(formatPostTime(c.createdAt), style: const TextStyle(fontSize: 11)),
        );
      },
    );
  }
}
