import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  final String displayName;
  final String? avatarUrl;
  // Stable cache identifier (typically the user id). Signed URLs rotate.
  final String? cacheKey;
  final double radius;
  const UserAvatar({
    super.key,
    required this.displayName,
    required this.avatarUrl,
    this.cacheKey,
    this.radius = 16,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.trim().isNotEmpty ? displayName.trim()[0].toUpperCase() : '?';
    if (avatarUrl == null || avatarUrl!.isEmpty) {
      return CircleAvatar(
        radius: radius,
        child: Text(initial, style: TextStyle(fontSize: radius * 0.9)),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.grey.shade200,
      backgroundImage: CachedNetworkImageProvider(avatarUrl!, cacheKey: cacheKey),
      onBackgroundImageError: (_, __) {},
      child: null,
    );
  }
}
