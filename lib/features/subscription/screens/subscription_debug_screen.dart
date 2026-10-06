/// 开发者选项：订阅调试面板。
///
/// 解决「后台已删订阅但 App 仍显示已订阅」这类多层缓存问题，并提供
/// 不发起真实购买即可测试会员 UI / Paywall 门禁的调试手段。仅供开发调试，
/// 经设置页「开发者选项」进入。提供四类工具：
/// 1. 当前权益只读视图（读 [SubscriptionController.state]）；
/// 2. RevenueCat 原始 CustomerInfo 诊断（定位 entitlement 没对上等配置问题）；
/// 3. 清本地缓存 + 失效 RC 缓存 + 强刷对账；
/// 4. 手动覆盖权益（debug-only）、快捷恢复购买 / 登出。
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/auth_providers.dart';
import '../providers/subscription_controller.dart';
import '../providers/subscription_identity.dart';
import '../services/revenuecat_purchase_service.dart'
    show purchaseServiceProvider;
import '../state/entitlement_state.dart';

/// 订阅调试面板页面。
class SubscriptionDebugScreen extends ConsumerStatefulWidget {
  const SubscriptionDebugScreen({super.key});

  @override
  ConsumerState<SubscriptionDebugScreen> createState() =>
      _SubscriptionDebugScreenState();
}

class _SubscriptionDebugScreenState
    extends ConsumerState<SubscriptionDebugScreen> {
  /// RevenueCat 原始诊断快照（异步加载）。
  Future<Map<String, Object?>>? _snapshotFuture;

  /// 正在执行的耗时操作描述（非 null 时禁用按钮并显示进度）。
  String? _busy;

  @override
  void initState() {
    super.initState();
    _loadSnapshot();
  }

  void _loadSnapshot() {
    setState(() {
      _snapshotFuture = ref
          .read(purchaseServiceProvider)
          .debugCustomerInfoSnapshot();
    });
  }

  /// 包裹一个耗时操作：置忙、跑、完成后提示并刷新快照。
  Future<void> _run(String label, Future<void> Function() action) async {
    setState(() => _busy = label);
    try {
      await action();
      if (!mounted) return;
      _toast('$label completed');
    } catch (e) {
      if (!mounted) return;
      _toast('$label failed: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = null);
        _loadSnapshot();
      }
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(subscriptionControllerProvider);
    final controller = ref.read(subscriptionControllerProvider.notifier);
    final identity = ref.watch(subscriptionIdentityProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Subscription Debug')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _entitlementCard(state, identity),
          const SizedBox(height: 16),
          _snapshotCard(),
          const SizedBox(height: 16),
          _actionsCard(controller, identity),
          if (kDebugMode) ...[
            const SizedBox(height: 16),
            _overrideCard(state, controller),
          ],
        ],
      ),
    );
  }

  // ── 当前权益卡片 ────────────────────────────────────────────

  Widget _entitlementCard(
    EntitlementState state,
    SubscriptionIdentity identity,
  ) {
    final ent = state.entitlement;
    return _card('Current entitlement (app source of truth)', [
      _row('status', state.status.name),
      _row('isActive', '${state.isActive}'),
      _row('isStale (from stale cache)', '${state.isStale}'),
      if (state.error != null) _row('error', state.error!),
      _row('userId', identity.userId ?? 'Anonymous'),
      if (ent != null) ...[
        _row('isPremium', '${ent.isPremium}'),
        _row('productId', ent.productId ?? '—'),
        _row(
          'expiresAt',
          ent.expiresAt?.toIso8601String() ?? 'Permanent / none',
        ),
        _row('willRenew', '${ent.willRenew}'),
      ],
    ]);
  }

  // ── RevenueCat 原始数据卡片 ─────────────────────────────────

  Widget _snapshotCard() {
    return _card('Raw RevenueCat CustomerInfo', [
      FutureBuilder<Map<String, Object?>>(
        future: _snapshotFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snap.hasError) {
            return Text('Read failed: ${snap.error}');
          }
          final data = snap.data ?? const {};
          if (data.isEmpty) {
            return const Text(
              'No data (RevenueCat or a stub implementation is not configured).',
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in data.entries) _row(e.key, '${e.value}'),
              const SizedBox(height: 8),
              const Text(
                'activeEntitlements is empty despite a subscription → the product is not linked to an entitlement;\n'
                'key differs from lookForEntitlementId → the entitlement identifier does not match;\n'
                'activeSubscriptions still has values → this may be a local StoreKit Configuration transaction.\n'
                'Remove it in Xcode: Debug ▸ StoreKit ▸ Manage Transactions.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          );
        },
      ),
    ]);
  }

  // ── 操作卡片 ────────────────────────────────────────────────

  Widget _actionsCard(
    SubscriptionController controller,
    SubscriptionIdentity identity,
  ) {
    final busy = _busy != null;
    return _card('Actions', [
      ListTile(
        leading: const Text('🔄', style: TextStyle(fontSize: 20)),
        title: const Text('Clear local + RC caches and force refresh'),
        subtitle: const Text(
          'Fixes subscriptions that still appear active after removal',
        ),
        enabled: !busy,
        onTap: busy
            ? null
            : () => _run(
                'Clear cache and force refresh',
                controller.clearLocalCacheAndRefresh,
              ),
      ),
      ListTile(
        leading: const Text('♻️', style: TextStyle(fontSize: 20)),
        title: const Text('Restore purchases'),
        enabled: !busy,
        onTap: busy
            ? null
            : () => _run('Restore purchases', controller.restore),
      ),
      ListTile(
        leading: const Text('🚪', style: TextStyle(fontSize: 20)),
        title: const Text('Sign out (clears entitlements)'),
        subtitle: Text(
          identity.isSignedIn
              ? 'Currently signed in'
              : 'Not signed in; unavailable',
        ),
        enabled: !busy && identity.isSignedIn,
        onTap: (busy || !identity.isSignedIn)
            ? null
            : () => _run(
                'Sign out',
                () => ref.read(authControllerProvider).signOut(),
              ),
      ),
      if (busy)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text('$_busy…'),
            ],
          ),
        ),
    ]);
  }

  // ── 手动覆盖权益卡片（debug-only）──────────────────────────

  Widget _overrideCard(
    EntitlementState state,
    SubscriptionController controller,
  ) {
    return _card('Manual entitlement override (Debug only)', [
      const Text(
        'Test the Premium UI / paywall without a real purchase. Choose "Live" to remove the override and resume online reconciliation.',
        style: TextStyle(fontSize: 12, color: Colors.grey),
      ),
      const SizedBox(height: 12),
      SegmentedButton<EntitlementStatus?>(
        segments: const [
          ButtonSegment(value: null, label: Text('Live')),
          ButtonSegment(
            value: EntitlementStatus.premium,
            label: Text('Force Premium'),
          ),
          ButtonSegment(
            value: EntitlementStatus.free,
            label: Text('Force Free'),
          ),
        ],
        selected: {_overrideSelection(state)},
        onSelectionChanged: (sel) {
          controller.debugOverrideEntitlement(sel.first);
        },
      ),
    ]);
  }

  /// 当前分段控件应高亮的选项：仅当处于覆盖态时才高亮 Pro/Free，否则「真实」。
  ///
  /// 覆盖态的 productId 为 `debug_override`，据此区分人为覆盖与真实在线结果。
  EntitlementStatus? _overrideSelection(EntitlementState state) {
    final isOverride = state.entitlement?.productId == 'debug_override';
    if (!isOverride) return null;
    return state.status;
  }

  // ── 通用小部件 ──────────────────────────────────────────────

  Widget _card(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 160,
            child: Text(
              label,
              style: const TextStyle(fontSize: 13, color: Colors.grey),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
