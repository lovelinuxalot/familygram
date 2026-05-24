import 'package:flutter/material.dart';
import '../widgets/feed_image.dart';

// Full-screen image viewer with pinch-to-zoom + double-tap reset.
// The URL signed at navigation time is reused here; cacheKey ensures the
// download is shared with the post-detail view.
class ImageViewerScreen extends StatelessWidget {
  final String url;
  final String? cacheKey;
  const ImageViewerScreen({super.key, required this.url, this.cacheKey});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: InteractiveViewer(
          minScale: 1.0,
          maxScale: 4.0,
          child: Center(child: MediaImage(url: url, cacheKey: cacheKey, fit: BoxFit.contain)),
        ),
      ),
    );
  }
}
