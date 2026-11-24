import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/validators/app_validators.dart';

class LiveOrderTrackerScreen extends StatefulWidget {
  const LiveOrderTrackerScreen({super.key});

  @override
  State<LiveOrderTrackerScreen> createState() => _LiveOrderTrackerScreenState();
}

class _LiveOrderTrackerScreenState extends State<LiveOrderTrackerScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  late final Stream<List<Map<String, dynamic>>> _ordersStream;

  /// Memoization cache so each order_id fetches its line items only once
  final Map<String, Future<List<Map<String, dynamic>>>> _itemsCache =
      <String, Future<List<Map<String, dynamic>>>>{};

  bool _didReadArgs = false;
  bool _isCancelling = false;
  String? _pinnedOrderId;
  String? _selectedOrderId;

  static const Set<String> _activeStatuses = <String>{
    'pending',
    'preparing',
    'ready',
  };

  @override
  void initState() {
    super.initState();
    final User? currentUser = _supabase.auth.currentUser;

    if (currentUser == null) {
      _ordersStream = const Stream<List<Map<String, dynamic>>>.empty();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
      });
      return;
    }

    _ordersStream = _supabase
        .from('orders')
        .stream(primaryKey: <String>['id'])
        .eq('user_id', currentUser.id)
        .order('created_at', ascending: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didReadArgs) return;
    _didReadArgs = true;

    final Object? args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['order_id'] != null) {
      _pinnedOrderId = args['order_id'].toString();
      _selectedOrderId = _pinnedOrderId;
    } else if (args is String && args.trim().isNotEmpty) {
      _pinnedOrderId = args.trim();
      _selectedOrderId = _pinnedOrderId;
    }
  }

  /// Cross-platform safe Memoized Item Fetch
  Future<List<Map<String, dynamic>>> _getOrderItems(String orderId) {
    return _itemsCache.putIfAbsent(orderId, () async {
      final List<dynamic> rows = await _supabase
          .from('order_items')
          .select('item_name_snapshot, unit_price_snapshot, quantity, subtotal')
          .eq('order_id', orderId)
          .timeout(const Duration(seconds: 8));

      return rows
          .whereType<Map>()
          .map((Map<dynamic, dynamic> r) => Map<String, dynamic>.from(r))
          .toList();
    });
  }

  List<Map<String, dynamic>> _extractTrackableOrders(
    List<Map<String, dynamic>> allOrders,
  ) {
    final List<Map<String, dynamic>> result = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> order in allOrders) {
      final String id = order['id'].toString();
      final String status = (order['status'] as String?) ?? '';
      if (_activeStatuses.contains(status) || id == _pinnedOrderId) {
        result.add(order);
      }
    }
    return result;
  }

  /// Opens the 30-second auto-regenerating Pickup QR modal (only for READY orders)
  Future<void> _openPickupQrModal(Map<String, dynamic> order) async {
    final String orderId = order['id'].toString();
    final String token = (order['token_number'] as String?) ?? '#SW';

    // Pin the order so if it transitions to completed, the user sees the completed state cleanly
    setState(() {
      _pinnedOrderId = orderId;
      _selectedOrderId = orderId;
    });

    final String? outcome = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) =>
          _RotatingPickupQrDialog(orderId: orderId, tokenNumber: token),
    );

    if (!mounted) return;
    if (outcome == 'completed') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text('Order $token collected! Enjoy your meal.'),
        ),
      );
    }
  }

  /// Atomic Order Cancellation + automatic wallet refund
  Future<void> _promptAndCancelOrder(Map<String, dynamic> order) async {
    if (_isCancelling) return;
    final String orderId = order['id'].toString();
    final String token = (order['token_number'] as String?) ?? '';

    final String? reason = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CancelOrderDialog(tokenNumber: token),
    );

    if (reason == null || reason.trim().isEmpty || !mounted) return;

    setState(() => _isCancelling = true);
    try {
      final dynamic res = await _supabase
          .rpc(
            'cancel_order_atomic',
            params: <String, dynamic>{
              'p_order_id': orderId,
              'p_reason': reason.trim(),
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      final double refunded = res is Map
          ? ((res['refunded_amount'] as num?)?.toDouble() ?? 0.0)
          : 0.0;

      setState(() {
        _pinnedOrderId = orderId;
        _selectedOrderId = orderId;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text(
            'Order $token cancelled. ৳ ${refunded.toStringAsFixed(0)} refunded to your wallet.',
          ),
        ),
      );
    } on TimeoutException {
      _showSnack('Network timed out. Check order status before retrying.');
    } on PostgrestException catch (e) {
      _showSnack(e.message);
    } catch (_) {
      _showSnack('Failed to cancel order. Please check your connection.');
    } finally {
      if (mounted) setState(() => _isCancelling = false);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(backgroundColor: Colors.redAccent, content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text(
          'Live Order Tracker',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Order History',
            icon: const Icon(Icons.history_rounded, color: Colors.white70),
            onPressed: () =>
                Navigator.of(context).pushNamed('/student/history'),
          ),
        ],
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _ordersStream,
        builder:
            (
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
                      'Unable to connect to live order updates.\nCheck your campus network.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ),
                );
              }

              final List<Map<String, dynamic>> trackable =
                  _extractTrackableOrders(
                    snapshot.data ?? <Map<String, dynamic>>[],
                  );

              if (trackable.isEmpty) {
                return _buildNoActiveOrdersState();
              }

              final Map<String, dynamic> currentOrder = trackable.firstWhere(
                (Map<String, dynamic> o) =>
                    o['id'].toString() == _selectedOrderId,
                orElse: () => trackable.first,
              );

              return Column(
                children: [
                  if (trackable.length > 1)
                    _buildOrderSelectorStrip(
                      trackable,
                      currentOrder['id'].toString(),
                    ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 540),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildTokenHeroCard(currentOrder),
                              const SizedBox(height: 18),
                              _buildFsmSection(currentOrder),
                              const SizedBox(height: 18),
                              _buildOrderItemsCard(currentOrder),
                              const SizedBox(height: 18),
                              _buildCancelActionArea(currentOrder),
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
      ),
    );
  }

  Widget _buildOrderSelectorStrip(
    List<Map<String, dynamic>> orders,
    String activeId,
  ) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        scrollDirection: Axis.horizontal,
        itemCount: orders.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final Map<String, dynamic> order = orders[index];
          final String id = order['id'].toString();
          final String token = (order['token_number'] as String?) ?? '#SW';
          final String status = (order['status'] as String?) ?? '';
          final bool isSelected = id == activeId;

          return ChoiceChip(
            label: Text('$token • ${status.toUpperCase()}'),
            selected: isSelected,
            showCheckmark: false,
            selectedColor: const Color(0xFFFF5722),
            backgroundColor: const Color(0xFF1E293B),
            side: BorderSide.none,
            labelStyle: TextStyle(
              color: isSelected ? Colors.white : Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
            onSelected: (_) => setState(() => _selectedOrderId = id),
          );
        },
      ),
    );
  }

  /// Hero Pickup Token Card + State-Gated 30s Rotating QR Trigger Button
  Widget _buildTokenHeroCard(Map<String, dynamic> order) {
    final String token = (order['token_number'] as String?) ?? '#SW-0000';
    final String status = (order['status'] as String?) ?? 'pending';
    final double total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final String? rawEta = order['estimated_ready_at'] as String?;
    final DateTime? parsedEta = rawEta != null
        ? DateTime.tryParse(rawEta)
        : null;

    final Color statusColor = _statusColor(status);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.65),
          width: 1.4,
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'DIGITAL PICKUP PASS',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: statusColor),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            token,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 38,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.0,
            ),
          ),
          const SizedBox(height: 16),

          if (status == 'preparing' && parsedEta != null)
            _LiveEtaCountdown(estimatedReadyAt: parsedEta)
          else if (status == 'ready') ...[
            _buildStatusCallout(
              icon: Icons.notifications_active_rounded,
              color: Colors.greenAccent,
              text: 'Your food is READY! Tap below at the counter to show your live 30s Pickup QR.',
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton.icon(
                onPressed: () => _openPickupQrModal(order),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green.shade600,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.qr_code_2_rounded, size: 24),
                label: const Text(
                  'COLLECT FOOD • SHOW PICKUP QR',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ] else if (status == 'pending')
            _buildStatusCallout(
              icon: Icons.hourglass_top_rounded,
              color: Colors.amber,
              text: 'Sent to kitchen queue. Waiting for chef to confirm prep time.',
            )
          else if (status == 'completed')
            _buildStatusCallout(
              icon: Icons.verified_rounded,
              color: Colors.lightBlueAccent,
              text: 'Order verified via QR & handed over. Enjoy your meal!',
            )
          else if (status == 'cancelled')
            _buildStatusCallout(
              icon: Icons.cancel_outlined,
              color: Colors.redAccent,
              text:
                  'Cancelled & Refunded (৳ ${total.toStringAsFixed(0)}). Reason: ${(order['cancel_reason'] as String?) ?? 'Not specified'}',
            ),
        ],
      ),
    );
  }

  Widget _buildStatusCallout({
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFsmSection(Map<String, dynamic> order) {
    final String status = (order['status'] as String?) ?? 'pending';
    final bool isCancelled = status == 'cancelled';

    const List<Map<String, String>> steps = <Map<String, String>>[
      <String, String>{
        'key': 'pending',
        'title': 'Order Placed (Pending)',
        'subtitle': 'Paid atomically via wallet • Waiting for kitchen',
      },
      <String, String>{
        'key': 'preparing',
        'title': 'Preparing in Kitchen',
        'subtitle': 'Chef accepted order and set live prep timer',
      },
      <String, String>{
        'key': 'ready',
        'title': 'Ready for Pickup',
        'subtitle': 'Open live 30s QR at pickup counter to collect food',
      },
      <String, String>{
        'key': 'completed',
        'title': 'Completed',
        'subtitle': 'QR scanned and handed over at counter',
      },
    ];

    int activeStepIndex = steps.indexWhere((s) => s['key'] == status);
    if (isCancelled) activeStepIndex = -1;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORDER LIFECYCLE (FSM)',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 14),
          if (isCancelled)
            const Row(
              children: [
                Icon(
                  Icons.replay_circle_filled,
                  color: Colors.redAccent,
                  size: 28,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Order terminated in CANCELLED state. Full amount automatically returned to your digital wallet.',
                    style: TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
                  ),
                ),
              ],
            )
          else
            Column(
              children: List<Widget>.generate(steps.length, (int idx) {
                final bool isDone = idx < activeStepIndex;
                final bool isCurrent = idx == activeStepIndex;
                final bool isLast = idx == steps.length - 1;
                final Color dotColor = isDone
                    ? Colors.greenAccent
                    : (isCurrent ? const Color(0xFFFF5722) : Colors.white24);

                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDone || isCurrent
                                ? dotColor.withValues(alpha: 0.2)
                                : Colors.transparent,
                            border: Border.all(color: dotColor, width: 2),
                          ),
                          child: Icon(
                            isDone
                                ? Icons.check
                                : (isCurrent
                                      ? Icons.circle
                                      : Icons.circle_outlined),
                            size: isDone ? 13 : 9,
                            color: dotColor,
                          ),
                        ),
                        if (!isLast)
                          Container(
                            width: 2,
                            height: 30,
                            color: isDone
                                ? Colors.greenAccent.withValues(alpha: 0.6)
                                : Colors.white12,
                          ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              steps[idx]['title']!,
                              style: TextStyle(
                                color: isDone || isCurrent
                                    ? Colors.white
                                    : Colors.white38,
                                fontSize: 14,
                                fontWeight: isCurrent
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              steps[idx]['subtitle']!,
                              style: TextStyle(
                                color: isCurrent
                                    ? Colors.white70
                                    : Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildOrderItemsCard(Map<String, dynamic> order) {
    final String orderId = order['id'].toString();
    final double total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final String notes = (order['customer_notes'] as String?)?.trim() ?? '';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ORDER ITEMS',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<Map<String, dynamic>>>(
            future: _getOrderItems(orderId),
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> snap,
                ) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFFF5722),
                          ),
                        ),
                      ),
                    );
                  }

                  if (snap.hasError) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Could not load item details.',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() => _itemsCache.remove(orderId));
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    );
                  }

                  final List<Map<String, dynamic>> items =
                      snap.data ?? <Map<String, dynamic>>[];

                  return Column(
                    children: items.map((Map<String, dynamic> item) {
                      final String name =
                          (item['item_name_snapshot'] as String?) ?? 'Item';
                      final int qty = (item['quantity'] as num?)?.toInt() ?? 1;
                      final double sub =
                          (item['subtotal'] as num?)?.toDouble() ?? 0.0;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
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
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            Text(
                              '৳ ${sub.toStringAsFixed(0)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  );
                },
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Note: $notes',
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Colors.white12, height: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Paid (Wallet)',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14.5,
                ),
              ),
              Text(
                '৳ ${total.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Color(0xFFFF5722),
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCancelActionArea(Map<String, dynamic> order) {
    final String status = (order['status'] as String?) ?? '';

    if (status == 'completed' || status == 'cancelled') {
      return SizedBox(
        height: 48,
        child: OutlinedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            side: const BorderSide(color: Colors.white24),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('BACK TO MENU'),
        ),
      );
    }

    final bool canCancel = status == 'pending' && !_isCancelling;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 50,
          child: OutlinedButton.icon(
            onPressed: canCancel ? () => _promptAndCancelOrder(order) : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              disabledForegroundColor: Colors.white30,
              side: BorderSide(
                color: canCancel ? Colors.redAccent : Colors.white12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: _isCancelling
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.redAccent,
                    ),
                  )
                : Icon(
                    canCancel ? Icons.cancel_outlined : Icons.lock_outline,
                    size: 19,
                  ),
            label: Text(
              _isCancelling
                  ? 'CANCELLING & REFUNDING...'
                  : canCancel
                  ? 'CANCEL ORDER (INSTANT REFUND)'
                  : 'CANCEL LOCKED — ORDER IS ${status.toUpperCase()}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
        ),
        if (!canCancel && !_isCancelling)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Once kitchen preparation starts, orders cannot be self-cancelled.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 11.5),
            ),
          ),
      ],
    );
  }

  Widget _buildNoActiveOrdersState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_rounded,
              size: 62,
              color: Colors.white.withValues(alpha: 0.22),
            ),
            const SizedBox(height: 16),
            const Text(
              'No Active Orders',
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'When you place a canteen order, your live kitchen status and pickup QR will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13.5),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Browse Menu'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamed('/student/history'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  child: const Text('Order History'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'pending':
        return Colors.amber;
      case 'preparing':
        return const Color(0xFFFF5722);
      case 'ready':
        return Colors.greenAccent;
      case 'completed':
        return Colors.lightBlueAccent;
      case 'cancelled':
        return Colors.redAccent;
      default:
        return Colors.white54;
    }
  }
}

// =============================================================================
// Helper Widget 1: 30-Second Auto-Regenerating Anti-Replay Pickup QR Modal
// =============================================================================

class _RotatingPickupQrDialog extends StatefulWidget {
  final String orderId;
  final String tokenNumber;

  const _RotatingPickupQrDialog({
    required this.orderId,
    required this.tokenNumber,
  });

  @override
  State<_RotatingPickupQrDialog> createState() =>
      _RotatingPickupQrDialogState();
}

class _RotatingPickupQrDialogState extends State<_RotatingPickupQrDialog> {
  final SupabaseClient _supabase = Supabase.instance.client;

  Timer? _countdownTimer;
  StreamSubscription<List<Map<String, dynamic>>>? _orderStatusSub;

  String? _qrPayload;
  String? _errorMsg;
  bool _isLoading = true;
  bool _isFetching = false;
  bool _didAutoClose = false;

  int _ttlSeconds = 30;
  int _secondsLeft = 30;

  @override
  void initState() {
    super.initState();
    _subscribeOrderCompletion();
    _fetchFreshQr();
  }

  /// Watches this single order row so the modal closes immediately when collected
  void _subscribeOrderCompletion() {
    _orderStatusSub = _supabase
        .from('orders')
        .stream(primaryKey: <String>['id'])
        .eq('id', widget.orderId)
        .listen((List<Map<String, dynamic>> rows) {
          if (!mounted || rows.isEmpty || _didAutoClose) return;
          final String status = (rows.first['status'] as String?) ?? '';
          if (status != 'ready') {
            _didAutoClose = true;
            _countdownTimer?.cancel();
            Navigator.of(context).pop<String>(status);
          }
        });
  }

  /// Calls server RPC to generate a fresh 128-bit nonce and restarts the 30s timer
  Future<void> _fetchFreshQr() async {
    if (_isFetching || _didAutoClose) return;
    _isFetching = true;
    _countdownTimer?.cancel();

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMsg = null;
      });
    }

    try {
      final dynamic raw = await _supabase
          .rpc(
            'generate_order_pickup_qr',
            params: <String, dynamic>{'p_order_id': widget.orderId},
          )
          .timeout(const Duration(seconds: 8));

      if (!mounted || _didAutoClose) return;

      if (raw is! Map || raw['qr_payload'] == null) {
        setState(() {
          _errorMsg = 'Unexpected QR response from server.';
          _isLoading = false;
        });
        return;
      }

      final Map<String, dynamic> data = Map<String, dynamic>.from(raw);
      final int ttl = (data['ttl_seconds'] as num?)?.toInt() ?? 30;

      setState(() {
        _qrPayload = data['qr_payload'].toString();
        _ttlSeconds = ttl > 0 ? ttl : 30;
        _secondsLeft = _ttlSeconds;
        _isLoading = false;
        _errorMsg = null;
      });

      _startCountdown();
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _errorMsg = 'Network timed out generating QR. Tap Retry.';
          _isLoading = false;
        });
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() {
          _errorMsg = e.message;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorMsg = 'Could not generate live QR. Check connection.';
          _isLoading = false;
        });
      }
    } finally {
      _isFetching = false;
    }
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted || _didAutoClose) {
        t.cancel();
        return;
      }

      if (_secondsLeft <= 1) {
        t.cancel();
        _fetchFreshQr();
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _orderStatusSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double progress = (_secondsLeft / _ttlSeconds)
        .clamp(0.0, 1.0)
        .toDouble();
    final Color timerColor = _secondsLeft <= 5
        ? Colors.redAccent
        : (_secondsLeft <= 10 ? Colors.amber : Colors.greenAccent);

    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'LIVE PICKUP QR',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      Text(
                        widget.tokenNumber,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white60,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Pure white quiet-zone box for reliable optical scanning
              Container(
                width: 244,
                height: 244,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _isLoading && _qrPayload == null
                    ? const CircularProgressIndicator(color: Color(0xFFFF5722))
                    : _errorMsg != null
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.wifi_off_rounded,
                              color: Colors.redAccent,
                              size: 38,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _errorMsg!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 10),
                            ElevatedButton(
                              onPressed: _fetchFreshQr,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : Stack(
                        alignment: Alignment.center,
                        children: [
                          QrImageView(
                            data: _qrPayload!,
                            version: QrVersions.auto,
                            size: 224,
                            padding: const EdgeInsets.all(10),
                            backgroundColor: Colors.white,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                          ),
                          if (_isLoading)
                            Container(
                              width: 224,
                              height: 224,
                              color: Colors.white.withValues(alpha: 0.78),
                              alignment: Alignment.center,
                              child: const CircularProgressIndicator(
                                color: Color(0xFFFF5722),
                              ),
                            ),
                        ],
                      ),
              ),

              const SizedBox(height: 16),

              if (_errorMsg == null && _qrPayload != null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.autorenew_rounded,
                          size: 16,
                          color: timerColor,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Auto-regenerates in ${_secondsLeft}s',
                          style: TextStyle(
                            color: timerColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                    TextButton(
                      onPressed: _isLoading ? null : _fetchFreshQr,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text(
                        'Refresh Now',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 7,
                    backgroundColor: const Color(0xFF0F172A),
                    valueColor: AlwaysStoppedAnimation<Color>(timerColor),
                  ),
                ),
              ],

              const SizedBox(height: 14),
              Text(
                'Show this live screen at the pickup counter. Screenshots expire automatically and cannot be reused.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Helper Widget 2: Zero-Polling Local ETA Countdown
// =============================================================================

class _LiveEtaCountdown extends StatefulWidget {
  final DateTime estimatedReadyAt;
  const _LiveEtaCountdown({required this.estimatedReadyAt});

  @override
  State<_LiveEtaCountdown> createState() => _LiveEtaCountdownState();
}

class _LiveEtaCountdownState extends State<_LiveEtaCountdown> {
  Timer? _ticker;
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _syncRemaining();
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _syncRemaining(),
    );
  }

  @override
  void didUpdateWidget(covariant _LiveEtaCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.estimatedReadyAt != widget.estimatedReadyAt) {
      _syncRemaining();
    }
  }

  void _syncRemaining() {
    final Duration diff = widget.estimatedReadyAt.toLocal().difference(
      DateTime.now(),
    );
    if (!mounted) return;
    setState(() {
      _remaining = diff.isNegative ? Duration.zero : diff;
    });
  }

  String _formatClockTime(DateTime utcTime) {
    final DateTime local = utcTime.toLocal();
    final int hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final String minute = local.minute.toString().padLeft(2, '0');
    final String suffix = local.hour >= 12 ? 'PM' : 'AM';
    return '$hour12:$minute $suffix';
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isOverdue = _remaining == Duration.zero;
    final String mins = _remaining.inMinutes.toString().padLeft(2, '0');
    final String secs = (_remaining.inSeconds % 60).toString().padLeft(2, '0');
    final Color accent = isOverdue ? Colors.amber : const Color(0xFFFF5722);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isOverdue ? Icons.hourglass_bottom : Icons.timer_outlined,
            color: accent,
            size: 22,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              isOverdue
                  ? 'Almost ready • Kitchen finishing up'
                  : 'Ready in $mins:$secs  (Est. ${_formatClockTime(widget.estimatedReadyAt)})',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Helper Widget 3: Crash-Safe Cancel Reason Dialog
// =============================================================================

class _CancelOrderDialog extends StatefulWidget {
  final String tokenNumber;
  const _CancelOrderDialog({required this.tokenNumber});

  @override
  State<_CancelOrderDialog> createState() => _CancelOrderDialogState();
}

class _CancelOrderDialogState extends State<_CancelOrderDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _reasonCtrl = TextEditingController();

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        'Cancel ${widget.tokenNumber}?',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Full order amount will be refunded atomically to your wallet.',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _reasonCtrl,
              maxLength: 150,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
              decoration: InputDecoration(
                labelText: 'Cancellation Reason *',
                labelStyle: const TextStyle(color: Colors.white60),
                hintText: 'e.g., Ordered wrong item',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              validator: (String? v) =>
                  AppValidators.requiredReason(v, fieldName: 'Cancel reason'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep Order'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop<String>(_reasonCtrl.text.trim());
            }
          },
          child: const Text('Confirm Cancel'),
        ),
      ],
    );
  }
}
