import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/auth.dart';
import '../util/error_message.dart';

// Shared by post_tile and comments_sheet. Google Play's Child Safety Standards
// policy requires a way to raise a child-safety concern from inside the app, so
// that reason is listed first and worded plainly rather than hidden behind
// "Other".
const _reasons = <({String value, String label})>[
  (value: 'child_safety', label: 'Child safety concern'),
  (value: 'nudity', label: 'Nudity or sexual content'),
  (value: 'harassment', label: 'Harassment or bullying'),
  (value: 'other', label: 'Something else'),
];

Future<void> showReportSheet(
  BuildContext context,
  WidgetRef ref,
  String targetType, // 'post' | 'comment'
  String targetId,
) async {
  final noteCtrl = TextEditingController();
  String reason = _reasons.first.value;

  final submitted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
      ),
      child: StatefulBuilder(
        builder: (ctx, setSheetState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Report this $targetType',
                style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Reports go to the app administrator, who can remove the content '
              'and revoke access.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final r in _reasons)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  reason == r.value
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 20,
                ),
                title: Text(r.label),
                onTap: () => setSheetState(() => reason = r.value),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: noteCtrl,
              maxLines: 3,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Anything else we should know? (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Send report'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  if (submitted != true) {
    noteCtrl.dispose();
    return;
  }

  try {
    await ref
        .read(apiClientProvider)
        .report(targetType, targetId, reason, note: noteCtrl.text);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Report sent. Thank you — we review these quickly.'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send report. ${friendlyError(e)}')),
      );
    }
  } finally {
    noteCtrl.dispose();
  }
}
