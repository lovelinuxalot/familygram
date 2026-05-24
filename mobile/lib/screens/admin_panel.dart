import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../state/auth.dart';
import '../widgets/user_avatar.dart';

class AdminPanelScreen extends ConsumerStatefulWidget {
  const AdminPanelScreen({super.key});
  @override
  ConsumerState<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends ConsumerState<AdminPanelScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() { _tabs.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family admin'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Allowlist'), Tab(text: 'Members')],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: TabBarView(controller: _tabs, children: const [_AllowlistTab(), _MembersTab()]),
        ),
      ),
    );
  }
}

// ─── Allowlist tab ─────────────────────────────────────────────────────────
class _AllowlistTab extends ConsumerStatefulWidget {
  const _AllowlistTab();
  @override
  ConsumerState<_AllowlistTab> createState() => _AllowlistTabState();
}

class _AllowlistTabState extends ConsumerState<_AllowlistTab> {
  List<AllowlistEntry> _entries = [];
  bool _loading = true;
  Object? _error;
  final _emailCtrl = TextEditingController();
  bool _adding = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final entries = await ref.read(apiClientProvider).adminListAllowlist();
      if (!mounted) return;
      setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _add() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty) return;
    setState(() => _adding = true);
    try {
      await ref.read(apiClientProvider).adminAddAllowlist(email);
      _emailCtrl.clear();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add: $e')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(String email) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from allowlist?'),
        content: Text('$email won\'t be able to sign in anymore. Their existing posts stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(apiClientProvider).adminRemoveAllowlist(email);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not remove: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _emailCtrl,
                decoration: const InputDecoration(labelText: 'Email to invite', hintText: 'family@example.com'),
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                onSubmitted: (_) => _add(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _adding ? null : _add,
              child: _adding
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Add'),
            ),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(_error.toString()))
                  : _entries.isEmpty
                      ? const Center(child: Text('No emails on the list yet.'))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            itemCount: _entries.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final e = _entries[i];
                              return ListTile(
                                leading: Icon(
                                  e.redeemed ? Icons.check_circle : Icons.hourglass_empty,
                                  color: e.redeemed ? Colors.green : Colors.grey,
                                ),
                                title: Text(e.email),
                                subtitle: Text(
                                  e.redeemed
                                      ? 'Joined as ${e.userDisplayName ?? e.userUsername ?? "?"}'
                                      : 'Pending — added ${DateFormat.yMMMd().format(DateTime.fromMillisecondsSinceEpoch(e.addedAt * 1000))}',
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _remove(e.email),
                                ),
                              );
                            },
                          ),
                        ),
        ),
      ],
    );
  }
}

// ─── Members tab ───────────────────────────────────────────────────────────
class _MembersTab extends ConsumerStatefulWidget {
  const _MembersTab();
  @override
  ConsumerState<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends ConsumerState<_MembersTab> {
  List<AdminUser> _users = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final users = await ref.read(apiClientProvider).adminListUsers();
      if (!mounted) return;
      setState(() { _users = users; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _toggle(AdminUser u, bool value) async {
    try {
      final updated = await ref.read(apiClientProvider).adminSetUserAdmin(u.id, value);
      setState(() {
        _users = [for (final x in _users) if (x.id == updated.id) updated else x];
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(authProvider).me?.id;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error.toString()));
    if (_users.isEmpty) return const Center(child: Text('No members yet.'));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: _users.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final u = _users[i];
          final isSelf = u.id == myId;
          return ListTile(
            leading: UserAvatar(displayName: u.displayName, avatarUrl: u.avatarUrl, cacheKey: u.id, radius: 20),
            title: Text('${u.displayName}${isSelf ? "  (you)" : ""}'),
            subtitle: Text('@${u.username} · ${u.email}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Admin', style: TextStyle(fontSize: 12, color: Colors.grey)),
                Switch(
                  value: u.isAdmin,
                  onChanged: isSelf ? null : (v) => _toggle(u, v),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
