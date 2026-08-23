import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/models.dart';
import '../state/auth.dart';
import '../state/feed.dart';
import '../state/tenant.dart';
import '../util/error_message.dart';
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
    // No initial refresh here — feedProvider refreshes on creation (and on
    // every family switch, which recreates it).
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
        title: _title(context),
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

  // Single-family users see a plain title; multi-family users get the
  // Instagram-style switcher: active family name + chevron, bottom sheet on
  // tap.
  Widget _title(BuildContext context) {
    final tenants = ref.watch(authProvider).me?.tenants ?? const <TenantMembership>[];
    final activeId = ref.watch(activeTenantProvider);
    if (tenants.length < 2) {
      return Text(tenants.isEmpty ? 'Familygram' : tenants.first.name);
    }
    final active = tenants.firstWhere((t) => t.id == activeId, orElse: () => tenants.first);
    return InkWell(
      onTap: () => _showTenantPicker(context, tenants, active.id),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(active.name),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 20),
          ],
        ),
      ),
    );
  }

  void _showTenantPicker(BuildContext context, List<TenantMembership> tenants, String activeId) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Switch family', style: Theme.of(sheetCtx).textTheme.titleMedium),
            ),
            for (final t in tenants)
              ListTile(
                leading: Icon(t.id == activeId ? Icons.home : Icons.home_outlined),
                title: Text(t.name),
                trailing: t.id == activeId ? const Icon(Icons.check) : null,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  ref.read(activeTenantProvider.notifier).switchTo(t.id);
                },
              ),
            const SizedBox(height: 8),
          ],
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
            child: Center(child: Text(friendlyError(feed.error), style: const TextStyle(color: Colors.red))),
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
