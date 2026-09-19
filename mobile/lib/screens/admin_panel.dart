import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';
import '../state/auth.dart';
import '../util/error_message.dart';
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
    _tabs = TabController(length: 3, vsync: this);
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
          tabs: const [Tab(text: 'Allowlist'), Tab(text: 'Members'), Tab(text: 'Families')],
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: TabBarView(controller: _tabs, children: const [_AllowlistTab(), _MembersTab(), _FamiliesTab()]),
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
  List<AdminTenant> _tenants = [];
  String _selectedTenantId = 'default';
  bool _loading = true;
  Object? _error;
  final _emailCtrl = TextEditingController();
  bool _adding = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final entries = await api.adminListAllowlist();
      final tenants = await api.adminListTenants();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _tenants = tenants;
        if (!tenants.any((t) => t.id == _selectedTenantId) && tenants.isNotEmpty) {
          _selectedTenantId = tenants.first.id;
        }
        _loading = false;
      });
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
      await ref.read(apiClientProvider).adminAddAllowlist(email, tenantId: _selectedTenantId);
      _emailCtrl.clear();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add to allowlist. ${friendlyError(e)}')));
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _remove(AllowlistEntry entry) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from allowlist?'),
        content: Text('${entry.email} won\'t be able to sign in anymore. Their existing posts stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(apiClientProvider).adminRemoveAllowlist(entry.email, tenantId: entry.tenantId);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not remove from allowlist. ${friendlyError(e)}')));
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
        if (_tenants.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              const Text('Invite to: '),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _selectedTenantId,
                items: [for (final t in _tenants) DropdownMenuItem(value: t.id, child: Text(t.name))],
                onChanged: (v) { if (v != null) setState(() => _selectedTenantId = v); },
              ),
            ]),
          ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(friendlyError(_error)))
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
                                  '${e.tenantName != null ? "${e.tenantName} — " : ""}${e.redeemed
                                      ? 'Joined as ${e.userDisplayName ?? e.userUsername ?? "?"}'
                                      : 'Pending — added ${DateFormat.yMMMd().format(DateTime.fromMillisecondsSinceEpoch(e.addedAt * 1000))}'}',
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _remove(e),
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update admin status. ${friendlyError(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = ref.watch(authProvider).me?.id;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(friendlyError(_error)));
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
            subtitle: Text('@${u.username} · ${u.email}${u.tenantNames != null ? "\n${u.tenantNames}" : ""}'),
            isThreeLine: u.tenantNames != null,
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

// ---- Families tab: create/rename tenants, manage their members. ----------

class _FamiliesTab extends ConsumerStatefulWidget {
  const _FamiliesTab();
  @override
  ConsumerState<_FamiliesTab> createState() => _FamiliesTabState();
}

class _FamiliesTabState extends ConsumerState<_FamiliesTab> {
  List<AdminTenant> _tenants = [];
  bool _loading = true;
  Object? _error;
  final _nameCtrl = TextEditingController();
  bool _creating = false;

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _nameCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final tenants = await ref.read(apiClientProvider).adminListTenants();
      if (!mounted) return;
      setState(() { _tenants = tenants; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() => _creating = true);
    try {
      await ref.read(apiClientProvider).adminCreateTenant(name);
      _nameCtrl.clear();
      await _load();
      // The creator auto-joins the new family — refresh /me so the feed
      // switcher appears without an app restart.
      await ref.read(authProvider.notifier).refreshMe();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create family: ${friendlyError(e)}')));
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _rename(AdminTenant t) async {
    final ctrl = TextEditingController(text: t.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename family'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == t.name) return;
    try {
      await ref.read(apiClientProvider).adminRenameTenant(t.id, name);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not rename: ${friendlyError(e)}')));
    }
  }

  void _openMembers(AdminTenant t) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scroll) => _FamilyMembersSheet(tenant: t, scrollController: scroll),
      ),
    ).then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(friendlyError(_error)));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'New family name', border: OutlineInputBorder(), isDense: true),
              onSubmitted: (_) => _create(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Create'),
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView.separated(
            itemCount: _tenants.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = _tenants[i];
              return ListTile(
                leading: const Icon(Icons.home_outlined),
                title: Text(t.name),
                subtitle: Text('${t.memberCount} member${t.memberCount == 1 ? "" : "s"}'),
                trailing: IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _rename(t)),
                onTap: () => _openMembers(t),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

class _FamilyMembersSheet extends ConsumerStatefulWidget {
  final AdminTenant tenant;
  final ScrollController scrollController;
  const _FamilyMembersSheet({required this.tenant, required this.scrollController});
  @override
  ConsumerState<_FamilyMembersSheet> createState() => _FamilyMembersSheetState();
}

class _FamilyMembersSheetState extends ConsumerState<_FamilyMembersSheet> {
  List<UserProfile> _members = [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final members = await ref.read(apiClientProvider).adminListTenantMembers(widget.tenant.id);
      if (!mounted) return;
      setState(() { _members = members; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _addMember() async {
    // Pick from all real users not already in this family. Existing users
    // join directly; people without an account are invited via the
    // Allowlist tab instead.
    List<AdminUser> candidates;
    try {
      final all = await ref.read(apiClientProvider).adminListUsers();
      final memberIds = _members.map((m) => m.id).toSet();
      candidates = all.where((u) => !memberIds.contains(u.id)).toList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load users: ${friendlyError(e)}')));
      return;
    }
    if (!mounted) return;
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Everyone is already in this family. Invite new people via the Allowlist tab.')));
      return;
    }
    final picked = await showDialog<AdminUser>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Add to ${widget.tenant.name}'),
        children: [
          for (final u in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, u),
              child: Row(children: [
                UserAvatar(displayName: u.displayName, avatarUrl: u.avatarUrl, cacheKey: u.id, radius: 16),
                const SizedBox(width: 12),
                Expanded(child: Text('${u.displayName} (@${u.username})', overflow: TextOverflow.ellipsis)),
              ]),
            ),
        ],
      ),
    );
    if (picked == null) return;
    try {
      await ref.read(apiClientProvider).adminAddTenantMember(widget.tenant.id, picked.id);
      await _load();
      await ref.read(authProvider.notifier).refreshMe();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add member: ${friendlyError(e)}')));
    }
  }

  Future<void> _removeMember(UserProfile m) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from family?'),
        content: Text('${m.displayName} will no longer see ${widget.tenant.name}\'s feed. Their posts in it stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(apiClientProvider).adminRemoveTenantMember(widget.tenant.id, m.id);
      await _load();
      await ref.read(authProvider.notifier).refreshMe();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not remove: ${friendlyError(e)}')));
    }
  }

  Future<void> _setDownload(UserProfile m, bool value) async {
    try {
      await ref.read(apiClientProvider).adminSetTenantMemberDownload(widget.tenant.id, m.id, value);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update: ${friendlyError(e)}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(children: [
            Expanded(child: Text(widget.tenant.name, style: Theme.of(context).textTheme.titleMedium)),
            TextButton.icon(icon: const Icon(Icons.person_add_alt, size: 18), label: const Text('Add'), onPressed: _addMember),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text(friendlyError(_error)))
                  : ListView.separated(
                      controller: widget.scrollController,
                      itemCount: _members.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final m = _members[i];
                        return ListTile(
                          leading: UserAvatar(displayName: m.displayName, avatarUrl: m.avatarUrl, cacheKey: m.id, radius: 20),
                          title: Text(m.displayName),
                          subtitle: Text(m.canDownload ? '@${m.username} · can save photos' : '@${m.username}'),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            Switch(
                              value: m.canDownload,
                              onChanged: (v) => _setDownload(m, v),
                            ),
                            IconButton(icon: const Icon(Icons.person_remove_outlined), onPressed: () => _removeMember(m)),
                          ]),
                        );
                      },
                    ),
        ),
      ]),
    );
  }
}
