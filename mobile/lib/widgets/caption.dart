import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/auth.dart';

// Caption: `username <body>` with @mentions in the body rendered as tappable
// links to /user/<id>. Body collapses past `collapsedChars` with a "more"/
// "less" toggle. Username prefix is also tappable → the author's profile.
final _mentionRe = RegExp(r'@([a-z0-9_]{3,24})', caseSensitive: false);

class CaptionText extends ConsumerStatefulWidget {
  final String username;
  final String caption;
  final int collapsedChars;
  const CaptionText({super.key, required this.username, required this.caption, this.collapsedChars = 140});

  @override
  ConsumerState<CaptionText> createState() => _CaptionTextState();
}

class _CaptionTextState extends ConsumerState<CaptionText> {
  bool _expanded = false;
  late final TapGestureRecognizer _toggle;
  final List<TapGestureRecognizer> _mentionRecognizers = [];
  late TapGestureRecognizer _usernameTap;

  @override
  void initState() {
    super.initState();
    _toggle = TapGestureRecognizer()..onTap = () => setState(() => _expanded = !_expanded);
    _usernameTap = TapGestureRecognizer()..onTap = () => _openUser(widget.username);
  }

  @override
  void dispose() {
    _toggle.dispose();
    _usernameTap.dispose();
    for (final r in _mentionRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _openUser(String username) async {
    try {
      final user = await ref.read(apiClientProvider).getUserByUsername(username.toLowerCase());
      if (!mounted) return;
      context.push('/user/${user.id}');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No family member named @$username')),
      );
    }
  }

  // Tokenize the body into TextSpans, swapping @mentions in for tappable spans.
  List<InlineSpan> _spans(String body) {
    for (final r in _mentionRecognizers) {
      r.dispose();
    }
    _mentionRecognizers.clear();
    final mentionStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final result = <InlineSpan>[];
    var idx = 0;
    for (final m in _mentionRe.allMatches(body)) {
      if (m.start > idx) {
        result.add(TextSpan(text: body.substring(idx, m.start)));
      }
      final name = m.group(1)!;
      final rec = TapGestureRecognizer()..onTap = () => _openUser(name);
      _mentionRecognizers.add(rec);
      result.add(TextSpan(text: '@$name', style: mentionStyle, recognizer: rec));
      idx = m.end;
    }
    if (idx < body.length) {
      result.add(TextSpan(text: body.substring(idx)));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final isLong = widget.caption.length > widget.collapsedChars;
    final shown = (_expanded || !isLong)
        ? widget.caption
        : '${widget.caption.substring(0, widget.collapsedChars).trimRight()}…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Text.rich(
        TextSpan(
          style: const TextStyle(fontSize: 14, height: 1.35),
          children: [
            TextSpan(
              text: '${widget.username} ',
              style: const TextStyle(fontWeight: FontWeight.w600),
              recognizer: _usernameTap,
            ),
            ..._spans(shown),
            if (isLong)
              TextSpan(
                text: _expanded ? '  less' : '  more',
                style: TextStyle(color: Colors.grey.shade600),
                recognizer: _toggle,
              ),
          ],
        ),
      ),
    );
  }
}
