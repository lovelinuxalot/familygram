import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import 'feed_image.dart';

// Renders a post's photo(s). When there's just one, it behaves identically
// to the previous single-image tile. When there's more than one, it shows a
// horizontal PageView with a dots indicator below; tapping any page opens
// the image viewer at that index with all photos swipeable.
//
// `useThumb` chooses between the thumb (feed) and full (post_detail) tier.
class PostCarousel extends StatefulWidget {
  final Post post;
  final bool useThumb;
  final bool heroForFirst;
  const PostCarousel({super.key, required this.post, this.useThumb = true, this.heroForFirst = false});

  @override
  State<PostCarousel> createState() => _PostCarouselState();
}

class _PostCarouselState extends State<PostCarousel> {
  final _ctrl = PageController();
  int _page = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final post = widget.post;
    final media = post.media;
    if (media.isEmpty) return const SizedBox.shrink();

    // First photo sets the aspect ratio of the pane; the rest are letter-boxed.
    final first = media.first;
    final ar = (first.height != null && first.width != null && first.height! > 0)
        ? first.width! / first.height!
        : 1.0;

    final fullUrls = media.map((m) => m.imageUrl).toList(growable: false);
    final fullKeys = media.map<String?>((m) => 'full:${post.id}:${m.idx}').toList(growable: false);

    Widget page(int i) {
      final m = media[i];
      final url = widget.useThumb ? m.thumbUrl : m.imageUrl;
      final cacheKey = widget.useThumb ? 'thumb:${post.id}:${m.idx}' : 'full:${post.id}:${m.idx}';
      final img = MediaImage(url: url, cacheKey: cacheKey, fit: BoxFit.cover);
      final wrapped = (widget.heroForFirst && i == 0)
          ? Hero(tag: 'image-${post.id}', child: img)
          : img;
      return GestureDetector(
        onTap: () => context.push('/view', extra: {
          'urls': fullUrls,
          'cacheKeys': fullKeys,
          'initialIndex': i,
          'post': post,
        }),
        child: wrapped,
      );
    }

    if (media.length == 1) {
      return AspectRatio(aspectRatio: ar, child: page(0));
    }

    return Column(
      children: [
        AspectRatio(
          aspectRatio: ar,
          child: Stack(children: [
            PageView.builder(
              controller: _ctrl,
              itemCount: media.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) => page(i),
            ),
            Positioned(
              top: 8, right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_page + 1}/${media.length}',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 6),
        _Dots(count: media.length, current: _page),
      ],
    );
  }
}

class _Dots extends StatelessWidget {
  final int count;
  final int current;
  const _Dots({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    final active = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isActive = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          margin: const EdgeInsets.symmetric(horizontal: 3),
          width: isActive ? 8 : 6,
          height: isActive ? 8 : 6,
          decoration: BoxDecoration(
            color: isActive ? active : Colors.grey.shade400,
            shape: BoxShape.circle,
          ),
        );
      }),
    );
  }
}
