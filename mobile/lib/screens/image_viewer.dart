import 'package:flutter/material.dart';

import '../models/models.dart';
import '../util/share.dart';
import '../widgets/feed_image.dart';

// Full-screen image viewer with pinch-to-zoom and swipe-between when the
// post has multiple photos. Each page uses the same signed URL the caller
// already had (so cache hits) — see MediaImage.cacheKey.
//
// Pass `post` (the originating post) to enable a share IconButton in the
// app bar that downloads whichever image is currently visible. Without it
// (e.g. external/single-image callers), the share button is hidden.
class ImageViewerScreen extends StatefulWidget {
  final List<String> urls;
  final List<String?> cacheKeys;
  final int initialIndex;
  final Post? post;
  const ImageViewerScreen({
    super.key,
    required this.urls,
    required this.cacheKeys,
    this.initialIndex = 0,
    this.post,
  }) : assert(urls.length == cacheKeys.length, 'urls and cacheKeys must align');

  factory ImageViewerScreen.single({Key? key, required String url, String? cacheKey}) =>
      ImageViewerScreen(key: key, urls: [url], cacheKeys: [cacheKey]);

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _ctrl = PageController(initialPage: widget.initialIndex);
  late int _current = widget.initialIndex;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final multi = widget.urls.length > 1;
    final post = widget.post;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: multi ? Text('${_current + 1} of ${widget.urls.length}') : null,
        actions: post != null
            ? [
                Builder(builder: (innerContext) => IconButton(
                  tooltip: 'Share',
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => sharePost(innerContext, post, idx: _current),
                )),
              ]
            : null,
      ),
      body: SafeArea(
        child: PageView.builder(
          controller: _ctrl,
          itemCount: widget.urls.length,
          onPageChanged: (i) => setState(() => _current = i),
          itemBuilder: (_, i) {
            return InteractiveViewer(
              minScale: 1.0,
              maxScale: 4.0,
              child: Center(
                child: MediaImage(
                  url: widget.urls[i],
                  cacheKey: widget.cacheKeys[i],
                  fit: BoxFit.contain,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
