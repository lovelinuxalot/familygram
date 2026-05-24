import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/feed.dart';
import '../widgets/main_scaffold.dart';
import '../widgets/post_tile.dart';
import '../widgets/skeleton.dart';

class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({super.key});
  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(feedProvider.notifier).refresh());
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 800) {
        ref.read(feedProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(feedProvider);
    return MainScaffold(
      selected: MainTab.home,
      appBar: AppBar(
        title: const Text('Familygram'),
        centerTitle: true,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: RefreshIndicator(
            onRefresh: () => ref.read(feedProvider.notifier).refresh(),
            child: _body(context, feed),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, FeedState feed) {
    if (feed.items.isEmpty && feed.loading) {
      return ListView.builder(
        itemCount: 3,
        itemBuilder: (_, __) => const PostTileSkeleton(),
      );
    }
    if (feed.items.isEmpty) {
      return ListView(children: [
        const SizedBox(height: 120),
        const Center(child: Text('No posts yet.', style: TextStyle(fontSize: 16))),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.icon(
            icon: const Icon(Icons.add_a_photo),
            label: const Text('Share the first one'),
            onPressed: () => context.push('/upload'),
          ),
        ),
        if (feed.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(child: Text(feed.error.toString(), style: const TextStyle(color: Colors.red))),
          ),
      ]);
    }
    return ListView.builder(
      controller: _scroll,
      itemCount: feed.items.length + 1,
      itemBuilder: (_, i) {
        if (i == feed.items.length) {
          if (feed.exhausted) return const SizedBox(height: 80);
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return PostTile(post: feed.items[i]);
      },
    );
  }
}
