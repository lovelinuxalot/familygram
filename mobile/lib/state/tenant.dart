import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'auth.dart';

const _kActiveTenantKey = 'active_tenant_id';

// The family the app is currently browsing. Null until /me resolves (or when
// logged out) — the API client then sends no X-Tenant-Id header and the
// server falls back to the user's first membership.
class ActiveTenantController extends StateNotifier<String?> {
  ActiveTenantController(this._ref) : super(null);
  final Ref _ref;

  // Restore the persisted choice if it's still one of the user's memberships,
  // otherwise fall back to the first membership.
  Future<void> initFromMe(Me me) async {
    String? stored;
    try {
      stored = await _ref.read(secureStorageProvider).read(key: _kActiveTenantKey);
    } catch (_) {}
    final ids = me.tenants.map((t) => t.id).toList();
    final active = (stored != null && ids.contains(stored)) ? stored : (ids.isEmpty ? null : ids.first);
    _ref.read(apiClientProvider).setActiveTenant(active);
    state = active;
  }

  Future<void> switchTo(String tenantId) async {
    if (tenantId == state) return;
    _ref.read(apiClientProvider).setActiveTenant(tenantId);
    state = tenantId;
    try {
      await _ref.read(secureStorageProvider).write(key: _kActiveTenantKey, value: tenantId);
    } catch (_) {}
  }

  Future<void> clear() async {
    _ref.read(apiClientProvider).setActiveTenant(null);
    state = null;
    try {
      await _ref.read(secureStorageProvider).delete(key: _kActiveTenantKey);
    } catch (_) {}
  }
}

final activeTenantProvider =
    StateNotifierProvider<ActiveTenantController, String?>((ref) => ActiveTenantController(ref));
