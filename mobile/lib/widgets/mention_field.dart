import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../state/auth.dart';
import 'user_avatar.dart';

// TextField wrapper that shows an inline @mention autocomplete just above the
// field. When the caret sits inside an `@<chars>` token, we debounce a 200ms
// search against /users/search and render up to 6 matches. Tapping a match
// replaces the partial token with the full `@username ` and dismisses the
// suggestions.
//
// Suggestions render above (not below) the field so this works equally well
// inside a ListView caption form and inside the bottom-anchored comment bar
// on the post detail screen.
class MentionTextField extends ConsumerStatefulWidget {
  final TextEditingController controller;
  final InputDecoration? decoration;
  final int? maxLines;
  final int? minLines;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  const MentionTextField({
    super.key,
    required this.controller,
    this.decoration,
    this.maxLines,
    this.minLines,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  ConsumerState<MentionTextField> createState() => _MentionTextFieldState();
}

class _MentionTextFieldState extends ConsumerState<MentionTextField> {
  static final _partialRe = RegExp(r'@([a-z0-9_]*)$', caseSensitive: false);
  List<UserProfile> _suggestions = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleChange);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleChange);
    _debounce?.cancel();
    super.dispose();
  }

  void _handleChange() {
    final partial = _activePartial();
    if (partial == null) {
      if (_suggestions.isNotEmpty) setState(() => _suggestions = []);
      _debounce?.cancel();
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      if (!mounted) return;
      try {
        final users = await ref.read(apiClientProvider).searchUsers(partial);
        if (!mounted) return;
        // Discard if user already moved past the @ token by the time results come back.
        if (_activePartial() == null) return;
        setState(() => _suggestions = users);
      } catch (e, st) {
        // ignore: avoid_print
        print('mention search failed for "$partial": $e\n$st');
        if (!mounted) return;
        setState(() => _suggestions = []);
      }
    });
  }

  // The substring matching @<chars> immediately before the caret, or null if
  // the caret isn't in an @ token.
  String? _activePartial() {
    final c = widget.controller.selection;
    if (!c.isValid || !c.isCollapsed) return null;
    final caret = c.baseOffset;
    if (caret < 0 || caret > widget.controller.text.length) return null;
    final before = widget.controller.text.substring(0, caret);
    final m = _partialRe.firstMatch(before);
    return m?.group(1);
  }

  void _pick(UserProfile user) {
    final caret = widget.controller.selection.baseOffset;
    final text = widget.controller.text;
    final before = text.substring(0, caret);
    final m = _partialRe.firstMatch(before);
    if (m == null) return;
    final replaced = before.replaceRange(m.start, m.end, '@${user.username} ');
    final after = text.substring(caret);
    final newText = '$replaced$after';
    widget.controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: replaced.length),
    );
    setState(() => _suggestions = []);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_suggestions.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _suggestions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final u = _suggestions[i];
                return ListTile(
                  dense: true,
                  leading: UserAvatar(displayName: u.displayName, avatarUrl: u.avatarUrl, cacheKey: u.id, radius: 14),
                  title: Text(u.displayName, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  subtitle: Text('@${u.username}', style: const TextStyle(fontSize: 12)),
                  onTap: () => _pick(u),
                );
              },
            ),
          ),
        TextField(
          controller: widget.controller,
          decoration: widget.decoration,
          maxLines: widget.maxLines,
          minLines: widget.minLines,
          textInputAction: widget.textInputAction,
          onSubmitted: widget.onSubmitted,
        ),
      ],
    );
  }
}
