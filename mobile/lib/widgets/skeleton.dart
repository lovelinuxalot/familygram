import 'package:flutter/material.dart';

// Simple shimmering skeleton block. Animates opacity for a subtle "loading"
// effect without pulling in shimmer/skeletonizer packages.
class Skeleton extends StatefulWidget {
  final double? width;
  final double? height;
  final double radius;
  const Skeleton({super.key, this.width, this.height, this.radius = 8});
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _a;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
    _a = Tween<double>(begin: 0.55, end: 1).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _a,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.grey.shade300.withValues(alpha: _a.value * 0.6 + 0.4),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

class PostTileSkeleton extends StatelessWidget {
  const PostTileSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Skeleton(width: 32, height: 32, radius: 16),
            SizedBox(width: 10),
            Skeleton(width: 120, height: 14),
            Spacer(),
            Skeleton(width: 32, height: 12),
          ]),
        ),
        AspectRatio(aspectRatio: 1, child: Skeleton(radius: 0)),
        Padding(
          padding: EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Skeleton(width: 200, height: 12),
        ),
        Divider(height: 1),
      ],
    );
  }
}
