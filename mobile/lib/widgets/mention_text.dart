import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/auth.dart';

// Renders arbitrary text with `@username` references styled as tappable links
// in the theme's primary color. Username regex matches the same character set
// we accept on the server (a-z, 0-9, _).
//
// Tapping a mention does a lookup against /users/by-username and navigates to
// /user/<id>. We don't pre-resolve mentions to ids on the server, because the
// content is plain text — usernames are stable enough.
//
// Use either `inline: true` (returns a TextSpan, for embedding in larger
// captions) or default (returns a Text widget).
final _mentionRe = RegExp(r'@([a-z0-9_]{3,24})', caseSensitive: false);

class MentionText extends ConsumerStatefulWidget {
  final String text;
  final TextStyle? baseStyle;
  const MentionText(this.text, {super.key, this.baseStyle});

  @override
  ConsumerState<MentionText> createState() => _MentionTextState();
}

class _MentionTextState extends ConsumerState<MentionText> {
  final List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _onMentionTap(String username) async {
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

  @override
  Widget build(BuildContext context) {
    // Discard old recognizers before rebuilding — text may have changed.
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final mentionStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final spans = <InlineSpan>[];
    var idx = 0;
    for (final m in _mentionRe.allMatches(widget.text)) {
      if (m.start > idx) {
        spans.add(TextSpan(text: widget.text.substring(idx, m.start)));
      }
      final username = m.group(1)!;
      final recognizer = TapGestureRecognizer()..onTap = () => _onMentionTap(username);
      _recognizers.add(recognizer);
      spans.add(TextSpan(text: '@$username', style: mentionStyle, recognizer: recognizer));
      idx = m.end;
    }
    if (idx < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(idx)));
    }
    return Text.rich(TextSpan(style: widget.baseStyle, children: spans));
  }
}
