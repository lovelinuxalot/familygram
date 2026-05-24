import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class MediaImage extends StatelessWidget {
  final String url;
  // Stable cache identifier (e.g. post id). The signed URL rotates every
  // hour, but cached_network_image stores by cacheKey, so we keep the disk
  // cache across URL refreshes.
  final String? cacheKey;
  final BoxFit fit;
  final double? aspectRatio;
  const MediaImage({super.key, required this.url, this.cacheKey, this.fit = BoxFit.cover, this.aspectRatio});

  @override
  Widget build(BuildContext context) {
    final image = CachedNetworkImage(
      imageUrl: url,
      cacheKey: cacheKey,
      fit: fit,
      placeholder: (_, __) => Container(color: Colors.grey.shade200),
      errorWidget: (_, __, ___) => Container(color: Colors.grey.shade300, child: const Icon(Icons.broken_image)),
    );
    if (aspectRatio != null) return AspectRatio(aspectRatio: aspectRatio!, child: image);
    return image;
  }
}
