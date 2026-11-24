import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/validators/app_validators.dart';

class KitchenKdsScreen extends StatefulWidget {
  const KitchenKdsScreen({super.key});

  @override
  State<KitchenKdsScreen> createState() => _KitchenKdsScreenState();
}

class _KitchenKdsScreenState extends State<KitchenKdsScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  late final Stream<List<Map<String, dynamic>>> _kdsStream;

  /// Memoized order_items ক্যাশ (স্ট্রিম আপডেটে ডুপ্লিকেট DB কুয়েরি রোধে)
  final Map<String, Future<List<Map<String, dynamic>>>> _itemsCache =
      <String, Future<List<Map<String, dynamic>>>>{};

  /// Per-Order লক: ১টি অর্ডার প্রসেস হলে বাকি কার্ডগুলোর বাটন ফ্রিজ হবে না
  final Set<String> _busyOrderIds = <String>{};

  @override
  void initState() {
    super.initState();
    final User? currentUser = _supabase.auth.currentUser;

    if (currentUser == null) {
      _kdsStream = const Stream<List<Map<String, dynamic>>>.empty();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/login',
          (Route<dynamic> route) => false,
        );
      });
      return;
    }

    // কেবল সক্রিয় কিচেন স্টেট ('pending', 'preparing') ও কঠোর FIFO (ASC) ক্রম
    _kdsStream = _supabase
        .from('orders')
        .stream(primaryKey: <String>['id'])
        .inFilter('status', <String>['pending', 'preparing'])
        .order('created_at', ascending: true);
  }

  /// Memoized আইটেম ফেচ (প্রতিটি সক্রিয় অর্ডারের জন্য মাত্র ১ বার DB কল)
  Future<List<Map<String, dynamic>>> _getOrderItems(String orderId) {
    return _itemsCache.putIfAbsent(orderId, () async {
      final List<dynamic> rows = await _supabase
          .from('order_items')
          .select('item_name_snapshot, quantity')
          .eq('order_id', orderId)
          .timeout(const Duration(seconds: 8));

      return rows
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> r) => Map<String, dynamic>.from(r))
          .toList();
    });
  }

  /// দীর্ঘ শিফটে মেমোরি লিক রোধে কিউ থেকে বেরিয়ে যাওয়া অর্ডারের ক্যাশ পরিষ্কার করা
  void _pruneInactiveCache(List<Map<String, dynamic>> activeOrders) {
    if (_itemsCache.isEmpty) return;
    final Set<String> activeIds = activeOrders
        .map((Map<String, dynamic> o) => o['id'].toString())
        .toSet();
    _itemsCache.removeWhere((String key, _) => !activeIds.contains(key));
  }

  /// Per-Order লকসহ কেন্দ্রীয় RPC এক্সিকিউটর
  Future<void> _runOrderAction({
    required String orderId,
    required Future<void> Function() action,
    required String successMessage,
  }) async {
    if (_busyOrderIds.contains(orderId)) return;

    setState(() => _busyOrderIds.add(orderId));
    try {
      await action().timeout(const Duration(seconds: 10));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 2),
          content: Text(successMessage),
        ),
      );
    } on TimeoutException {
      _showErrorSnack('Network timed out. Verify order state and retry.');
    } on PostgrestException catch (e) {
      // Race Condition (যেমন: স্টুডেন্ট ঠিক আগে ক্যানসেল করলে) সার্ভারের স্পষ্ট বার্তা দেখাবে
      _showErrorSnack(e.message);
    } catch (_) {
      _showErrorSnack('Action failed. Check campus Wi-Fi and try again.');
    } finally {
      if (mounted) {
        setState(() => _busyOrderIds.remove(orderId));
      }
    }
  }

  /// [Action 1] Pending -> Preparing (One-Tap Prep Time Picker সহ)
  Future<void> _handleStartPrep(Map<String, dynamic> order) async {
    final String orderId = order['id'].toString();
    final String token = (order['token_number'] as String?) ?? '#SW';
    if (_busyOrderIds.contains(orderId)) return;

    final int? estMinutes = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _PrepTimePickerSheet(tokenNumber: token),
    );

    if (estMinutes == null || !mounted) return;

    await _runOrderAction(
      orderId: orderId,
      action: () => _supabase.rpc(
        'start_order_prep',
        params: <String, dynamic>{
          'p_order_id': orderId,
          'p_est_minutes': estMinutes,
        },
      ),
      successMessage: '$token moved to Preparing (ETA: $estMinutes min).',
    );
  }

  /// [Action 2] Preparing অবস্থায় +5 মিনিট সময় বাড়ানো
  Future<void> _handleExtendEta(Map<String, dynamic> order) async {
    final String orderId = order['id'].toString();
    final String token = (order['token_number'] as String?) ?? '#SW';

    await _runOrderAction(
      orderId: orderId,
      action: () => _supabase.rpc(
        'extend_order_prep',
        params: <String, dynamic>{
          'p_order_id': orderId,
          'p_extra_minutes': 5,
        },
      ),
      successMessage: '$token ETA extended by +5 minutes.',
    );
  }

  /// [Action 3] Preparing -> Ready (কাউন্টার পিকআপ কিউতে পাঠানো)
  Future<void> _handleMarkReady(Map<String, dynamic> order) async {
    final String orderId = order['id'].toString();
    final String token = (order['token_number'] as String?) ?? '#SW';

    await _runOrderAction(
      orderId: orderId,
      action: () => _supabase.rpc(
        'mark_order_ready',
        params: <String, dynamic>{'p_order_id': orderId},
      ),
      successMessage: '$token marked READY and sent to Pickup Counter.',
    );
  }

  /// [Action 4] Reject / Cancel (অ্যাটমিক ওয়ালেট রিফান্ড + স্টক রিস্টোর)
  Future<void> _handleRejectOrder(Map<String, dynamic> order) async {
    final String orderId = order['id'].toString();
    final String token = (order['token_number'] as String?) ?? '#SW';
    if (_busyOrderIds.contains(orderId)) return;

    final String? reason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RejectOrderDialog(tokenNumber: token),
    );

    if (reason == null || reason.trim().isEmpty || !mounted) return;

    await _runOrderAction(
      orderId: orderId,
      action: () => _supabase.rpc(
        'cancel_order_atomic',
        params: <String, dynamic>{
          'p_order_id': orderId,
          'p_reason': reason.trim(),
        },
      ),
      successMessage: '$token cancelled. Student refunded atomically.',
    );
  }

  Future<void> _handleSignOut() async {
    await _supabase.auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/login',
      (Route<dynamic> route) => false,
    );
  }

  void _showErrorSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.redAccent,
        content: Text(message),
      ),
    );
  }

  // ===========================================================================
  // UI অংশ: রেস্পন্সিভ Kanban (ট্যাবলেট = ২ কলাম, মোবাইল = ২ ট্যাব)
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: _buildAppBar(),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _kdsStream,
        builder: (
          BuildContext context,
          AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
        ) {
          if (snapshot.connectionState == ConnectionState.waiting &&
              !snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF5722)),
            );
          }

          if (snapshot.hasError) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Kitchen Realtime stream disconnected.\nCheck network connectivity.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.redAccent, fontSize: 15),
                ),
              ),
            );
          }

          final List<Map<String, dynamic>> activeOrders =
              snapshot.data ?? <Map<String, dynamic>>[];

          _pruneInactiveCache(activeOrders);

          final List<Map<String, dynamic>> pendingOrders = activeOrders
              .where((Map<String, dynamic> o) => o['status'] == 'pending')
              .toList();
          final List<Map<String, dynamic>> preparingOrders = activeOrders
              .where((Map<String, dynamic> o) => o['status'] == 'preparing')
              .toList();

          return LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // ট্যাবলেট / ডেস্কটপ (>= 720px): পাশাপাশি ২-কলাম Kanban বোর্ড
              if (constraints.maxWidth >= 720) {
                return Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _buildKanbanColumn(
                          title: 'INCOMING QUEUE (PENDING)',
                          accent: Colors.amber,
                          orders: pendingOrders,
                          isPendingColumn: true,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _buildKanbanColumn(
                          title: 'ACTIVE PREP (PREPARING)',
                          accent: const Color(0xFFFF5722),
                          orders: preparingOrders,
                          isPendingColumn: false,
                        ),
                      ),
                    ],
                  ),
                );
              }

              // মোবাইল (< 720px): জিরো-ওভারফ্লো ২-ট্যাব ভিউ
              return DefaultTabController(
                length: 2,
                child: Column(
                  children: [
                    TabBar(
                      indicatorColor: const Color(0xFFFF5722),
                      indicatorWeight: 3,
                      labelColor: Colors.white,
                      unselectedLabelColor: Colors.white54,
                      tabs: [
                        Tab(text: 'Incoming (${pendingOrders.length})'),
                        Tab(text: 'Preparing (${preparingOrders.length})'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildOrderListView(
                            orders: pendingOrders,
                            isPendingColumn: true,
                          ),
                          _buildOrderListView(
                            orders: preparingOrders,
                            isPendingColumn: false,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0F172A),
      elevation: 0,
      title: Row(
        children: [
          const Icon(Icons.kitchen_rounded, color: Color(0xFFFF5722), size: 24),
          const SizedBox(width: 10),
          const Text(
            'Kitchen KDS',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 19,
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.greenAccent.withValues(alpha: 0.6),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 7, color: Colors.greenAccent),
                SizedBox(width: 5),
                Text(
                  'LIVE FIFO',
                  style: TextStyle(
                    color: Colors.greenAccent,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        // [P11] Quick Stock Kill-Switch শর্টকাট
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).pushNamed('/kitchen/stock'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF5722),
              side: BorderSide(
                color: const Color(0xFFFF5722).withValues(alpha: 0.65),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.flash_on_rounded, size: 17),
            label: const Text(
              'Stock Switch',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Sign Out',
          icon: const Icon(Icons.logout_rounded, color: Colors.white60),
          onPressed: _handleSignOut,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// ট্যাবলেট/ডেস্কটপের প্রতিটি Kanban কলামের কাঠামো
  Widget _buildKanbanColumn({
    required String title,
    required Color accent,
    required List<Map<String, dynamic>> orders,
    required bool isPendingColumn,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(15),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${orders.length}',
                    style: const TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.w900,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildOrderListView(
              orders: orders,
              isPendingColumn: isPendingColumn,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderListView({
    required List<Map<String, dynamic>> orders,
    required bool isPendingColumn,
  }) {
    if (orders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isPendingColumn
                    ? Icons.inbox_outlined
                    : Icons.local_fire_department_outlined,
                size: 46,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              const SizedBox(height: 10),
              Text(
                isPendingColumn
                    ? 'No incoming orders right now.'
                    : 'No orders currently cooking.',
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: orders.length,
      itemBuilder: (BuildContext context, int index) {
        return _buildOrderCard(
          order: orders[index],
          isPending: isPendingColumn,
        );
      },
    );
  }

  /// প্রতিটি অর্ডারের হাই-কন্ট্রাস্ট কিচেন টিকিট কার্ড
  Widget _buildOrderCard({
    required Map<String, dynamic> order,
    required bool isPending,
  }) {
    final String orderId = order['id'].toString();
    final String token = (order['token_number'] as String?) ?? '#SW';
    final String notes = (order['customer_notes'] as String?)?.trim() ?? '';
    final DateTime createdAt =
        DateTime.tryParse((order['created_at'] as String?) ?? '') ??
            DateTime.now();
    final DateTime? estReadyAt =
        DateTime.tryParse((order['estimated_ready_at'] as String?) ?? '');
    final bool isBusy = _busyOrderIds.contains(orderId);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPending
              ? Colors.amber.withValues(alpha: 0.45)
              : const Color(0xFFFF5722).withValues(alpha: 0.6),
          width: 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // হেডার: বড় টোকেন নম্বর + আইসোলেটেড লাইভ টাইমার
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                token,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.0,
                ),
              ),
              if (isPending)
                _ElapsedWaitBadge(createdAt: createdAt)
              else if (estReadyAt != null)
                _PrepCountdownBadge(estimatedReadyAt: estReadyAt),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Colors.white12, height: 1),
          ),

          // খাবারের তালিকা (Memoized FutureBuilder)
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _getOrderItems(orderId),
            builder: (
              BuildContext context,
              AsyncSnapshot<List<Map<String, dynamic>>> snap,
            ) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: LinearProgressIndicator(
                    color: Color(0xFFFF5722),
                    backgroundColor: Colors.white12,
                  ),
                );
              }
              if (snap.hasError) {
                return Row(
                  children: [
                    const Text(
                      'Failed to load items.',
                      style: TextStyle(color: Colors.redAccent, fontSize: 12.5),
                    ),
                    TextButton(
                      onPressed: () =>
                          setState(() => _itemsCache.remove(orderId)),
                      child: const Text('Retry'),
                    ),
                  ],
                );
              }

              final List<Map<String, dynamic>> items =
                  snap.data ?? <Map<String, dynamic>>[];

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: items.map((Map<String, dynamic> item) {
                  final int qty = (item['quantity'] as num?)?.toInt() ?? 1;
                  final String name =
                      (item['item_name_snapshot'] as String?) ?? 'Item';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${qty}x',
                            style: const TextStyle(
                              color: Color(0xFFFF5722),
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),

          // কাস্টমার নোট থাকলে হাইলাইট করে দেখানো
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.sticky_note_2_outlined,
                    size: 16,
                    color: Colors.amber,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Note: $notes',
                      style: const TextStyle(
                        color: Colors.amber,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),

          // বড় ট্যাপ-টার্গেট অ্যাকশন বাটন (ভেজা হাতেও সহজে চাপ দেওয়া যাবে)
          if (isPending)
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: isBusy ? null : () => _handleStartPrep(order),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF5722),
                        foregroundColor: Colors.white,
                      ),
                      icon: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.timer_outlined, size: 19),
                      label: const Text(
                        'START PREP',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton(
                      onPressed:
                          isBusy ? null : () => _handleRejectOrder(order),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'REJECT',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                SizedBox(
                  height: 48,
                  child: OutlinedButton(
                    onPressed: isBusy ? null : () => _handleExtendEta(order),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.amber,
                      side: const BorderSide(color: Colors.amber),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      '+5m',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: isBusy ? null : () => _handleMarkReady(order),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade600,
                        foregroundColor: Colors.white,
                      ),
                      icon: isBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline, size: 20),
                      label: const Text(
                        'MARK READY',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  height: 48,
                  width: 44,
                  child: IconButton(
                    tooltip: 'Emergency Cancel & Refund',
                    style: IconButton.styleFrom(
                      side: BorderSide(
                        color: Colors.redAccent.withValues(alpha: 0.6),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.redAccent,
                    ),
                    onPressed: isBusy ? null : () => _handleRejectOrder(order),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// হেল্পার ১: আইসোলেটেড Elapsed Wait Timer (Pending কার্ডের জন্য — ৫+ মিনিটে লাল)
// =============================================================================

class _ElapsedWaitBadge extends StatefulWidget {
  final DateTime createdAt;
  const _ElapsedWaitBadge({required this.createdAt});

  @override
  State<_ElapsedWaitBadge> createState() => _ElapsedWaitBadgeState();
}

class _ElapsedWaitBadgeState extends State<_ElapsedWaitBadge> {
  Timer? _ticker;
  late Duration _elapsed;

  @override
  void initState() {
    super.initState();
    _sync();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _sync());
  }

  void _sync() {
    final Duration diff = DateTime.now().difference(widget.createdAt.toLocal());
    if (!mounted) return;
    setState(() => _elapsed = diff.isNegative ? Duration.zero : diff);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isUrgent = _elapsed.inMinutes >= 5;
    final Color color = isUrgent ? Colors.redAccent : Colors.amber;
    final String mins = _elapsed.inMinutes.toString().padLeft(2, '0');
    final String secs = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Text(
        'WAIT $mins:$secs',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

// =============================================================================
// হেল্পার ২: আইসোলেটেড Prep Countdown Badge (Preparing কার্ড + +5m Extend সাপোর্ট)
// =============================================================================

class _PrepCountdownBadge extends StatefulWidget {
  final DateTime estimatedReadyAt;
  const _PrepCountdownBadge({required this.estimatedReadyAt});

  @override
  State<_PrepCountdownBadge> createState() => _PrepCountdownBadgeState();
}

class _PrepCountdownBadgeState extends State<_PrepCountdownBadge> {
  Timer? _ticker;
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _sync();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _sync());
  }

  @override
  void didUpdateWidget(covariant _PrepCountdownBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.estimatedReadyAt != widget.estimatedReadyAt) {
      _sync();
    }
  }

  void _sync() {
    final Duration diff =
        widget.estimatedReadyAt.toLocal().difference(DateTime.now());
    if (!mounted) return;
    setState(() => _remaining = diff);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isOverdue = _remaining.isNegative;
    final Duration absDur = _remaining.abs();
    final Color color = isOverdue
        ? Colors.redAccent
        : (_remaining.inMinutes < 2 ? Colors.amber : Colors.greenAccent);
    final String mins = absDur.inMinutes.toString().padLeft(2, '0');
    final String secs = (absDur.inSeconds % 60).toString().padLeft(2, '0');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Text(
        isOverdue ? 'OVERDUE +$mins:$secs' : 'LEFT $mins:$secs',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

// =============================================================================
// হেল্পার ৩: One-Tap Prep Time Picker Bottom Sheet (No Keyboard Needed)
// =============================================================================

class _PrepTimePickerSheet extends StatefulWidget {
  final String tokenNumber;
  const _PrepTimePickerSheet({required this.tokenNumber});

  @override
  State<_PrepTimePickerSheet> createState() => _PrepTimePickerSheetState();
}

class _PrepTimePickerSheetState extends State<_PrepTimePickerSheet> {
  static const List<int> _presets = <int>[3, 5, 10, 15, 20, 25, 30, 45];
  int _selectedMinutes = 10;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Set Prep Time • ${widget.tokenNumber}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Student will see a live countdown based on this estimate.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _presets.map((int min) {
                final bool selected = _selectedMinutes == min;
                return ChoiceChip(
                  label: Text('$min min'),
                  selected: selected,
                  showCheckmark: false,
                  selectedColor: const Color(0xFFFF5722),
                  backgroundColor: const Color(0xFF0F172A),
                  side: BorderSide(
                    color: selected
                        ? const Color(0xFFFF5722)
                        : Colors.white12,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  labelStyle: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
                  ),
                  onSelected: (_) => setState(() => _selectedMinutes = min),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pop<int>(_selectedMinutes),
                icon: const Icon(Icons.local_fire_department_rounded),
                label: Text(
                  'CONFIRM & START ($_selectedMinutes MIN)',
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// হেল্পার ৪: Quick-Chip Reject / Cancel Dialog (Mandatory Audit Reason)
// =============================================================================

class _RejectOrderDialog extends StatefulWidget {
  final String tokenNumber;
  const _RejectOrderDialog({required this.tokenNumber});

  @override
  State<_RejectOrderDialog> createState() => _RejectOrderDialogState();
}

class _RejectOrderDialogState extends State<_RejectOrderDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _reasonCtrl = TextEditingController();

  static const List<String> _quickReasons = <String>[
    'Item out of stock',
    'Missing ingredients',
    'Kitchen overloaded',
  ];

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(
        'Reject ${widget.tokenNumber}?',
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cancelling will automatically refund the student wallet and restore menu stock.',
                style: TextStyle(color: Colors.white70, fontSize: 12.5),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _quickReasons.map((String preset) {
                  return ActionChip(
                    label: Text(preset),
                    backgroundColor: const Color(0xFF0F172A),
                    labelStyle: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                    ),
                    onPressed: () {
                      _reasonCtrl.text = preset;
                      _formKey.currentState?.validate();
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _reasonCtrl,
                maxLength: 150,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                decoration: InputDecoration(
                  labelText: 'Rejection Reason *',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                validator: (String? v) => AppValidators.requiredReason(
                  v,
                  fieldName: 'Rejection reason',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop<String>(_reasonCtrl.text.trim());
            }
          },
          child: const Text('Reject & Refund'),
        ),
      ],
    );
  }
}