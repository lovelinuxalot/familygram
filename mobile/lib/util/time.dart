import 'package:intl/intl.dart';

// Human-friendly relative time for a unix-seconds timestamp.
//
//   < 1 min       → "just now"
//   < 1 hour      → "5m ago"
//   today         → "3:42 PM"
//   yesterday     → "Yesterday at 3:42 PM"
//   < 7 days      → "Mon at 3:42 PM"
//   this year     → "Mar 5 at 3:42 PM"
//   older         → "Mar 5, 2024"
String formatPostTime(int unixSeconds) {
  final dt = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
  final now = DateTime.now();
  final diff = now.difference(dt);

  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';

  final t = DateFormat.jm().format(dt); // "3:42 PM"
  final today = _sameDay(dt, now);
  final yesterday = _sameDay(dt, now.subtract(const Duration(days: 1)));

  if (today) return t;
  if (yesterday) return 'Yesterday at $t';
  if (diff.inDays < 7) return '${DateFormat.E().format(dt)} at $t'; // "Mon at 3:42 PM"
  if (dt.year == now.year) return '${DateFormat.MMMd().format(dt)} at $t';
  return DateFormat.yMMMd().format(dt);
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
