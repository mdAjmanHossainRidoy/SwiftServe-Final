import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CounterQueueScreen extends StatefulWidget {
  const CounterQueueScreen({super.key});

  @override
  State<CounterQueueScreen> createState() => _CounterQueueScreenState();
}

class _CounterQueueScreenState extends State<CounterQueueScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchCtrl = TextEditingController();

  late final Stream<List<Map<String, dynamic>>> _readyOrdersStream;

  /// প্রতিটি ready অর্ডারের Student Profile + Items ঠিক একবারই ফেচ করার ক্যাশ
  final Map<String, Future<_ReadyOrderDetails>> _detailsFutureCache =
      <String, Future<_ReadyOrderDetails>>{};

  /// সিঙ্ক্রোনাস লোকাল সার্চের (নাম/আইডি/ইউজারনেম) জন্য রেজলভড ডেটা ম্যাপ
  final Map<String, _ReadyOrderDetails> _resolvedDetails =
      <String, _ReadyOrderDetails>{};

  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    final User? currentUser = _supabase.auth.currentUser;

    if (currentUser == null) {
      _readyOrdersStream = const Stream<List<Map<String, dynamic>>>.empty();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/login',
          (Route<dynamic> route) => false,
        );
      });
      return;
    }

    // কেবল 'ready' অবস্থার অর্ডারগুলোর ওপর ফিল্টার্ড WebSocket স্ট্রিম (O(k) লোড)
    _readyOrdersStream = _supabase
        .from('orders')
        .stream(primaryKey: <String>['id'])
        .eq('status', 'ready')
        .order('created_at', ascending: true);
  }

  /// PGRST201-নিরাপদ প্যারালাল ফেচ: Student Profile + Order Items একসাথে আনা
  Future<_ReadyOrderDetails> _getOrderDetails(String orderId, String userId) {
    return _detailsFutureCache.putIfAbsent(orderId, () async {
      final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
        _supabase
            .from('profiles')
            .select('first_name, last_name, username, student_id, phone')
            .eq('id', userId)
            .maybeSingle()
            .timeout(const Duration(seconds: 8)),
        _supabase
            .from('order_items')
            .select('item_name_snapshot, quantity')
            .eq('order_id', orderId)
            .timeout(const Duration(seconds: 8)),
      ]);

      final Map<String, dynamic>? profile = results[0] is Map
          ? Map<String, dynamic>.from(results[0] as Map)
          : null;

      final List<Map<String, dynamic>> items = (results[1] is List)
          ? (results[1] as List<dynamic>)
              .whereType<Map<String, dynamic>>()
              .map((Map<String, dynamic> e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];

      final _ReadyOrderDetails details = _ReadyOrderDetails(
        studentName: _formatFullName(profile),
        username: (profile?['username'] as String?)?.trim() ?? '',
        studentId: (profile?['student_id'] as String?)?.trim() ?? '',
        phone: (profile?['phone'] as String?)?.trim() ?? '',
        items: items,
      );

      _resolvedDetails[orderId] = details;
      return details;
    });
  }

  String _formatFullName(Map<String, dynamic>? profile) {
    if (profile == null) return 'Unknown Student';
    final String first = (profile['first_name'] as String?)?.trim() ?? '';
    final String last = (profile['last_name'] as String?)?.trim() ?? '';
    final String full = '$first $last'.trim();
    return full.isEmpty ? 'Student' : full;
  }

  /// ডেলিভারি হয়ে কিউ থেকে বেরিয়ে যাওয়া অর্ডারের ক্যাশ মুছে মেমোরি লিক রোধ করা
  void _pruneInactiveCache(List<Map<String, dynamic>> readyOrders) {
    if (_detailsFutureCache.isEmpty && _resolvedDetails.isEmpty) return;
    final Set<String> activeIds =
        readyOrders.map((Map<String, dynamic> o) => o['id'].toString()).toSet();
    _detailsFutureCache.removeWhere((String k, _) => !activeIds.contains(k));
    _resolvedDetails.removeWhere((String k, _) => !activeIds.contains(k));
  }

  /// ready_at ASC ক্রমে সাজানো (যে খাবার আগে তৈরি হয়েছে সেটি আগে ডেলিভারি হবে)
  List<Map<String, dynamic>> _sortAndFilterOrders(
    List<Map<String, dynamic>> rawOrders,
  ) {
    final List<Map<String, dynamic>> sorted =
        List<Map<String, dynamic>>.from(rawOrders);

    sorted.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final DateTime timeA = _resolveReadyTimestamp(a);
      final DateTime timeB = _resolveReadyTimestamp(b);
      return timeA.compareTo(timeB);
    });

    final String q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return sorted;

    return sorted.where((Map<String, dynamic> order) {
      final String id = order['id'].toString();
      final String token = ((order['token_number'] as String?) ?? '').toLowerCase();
      final String shortCode =
          (id.length >= 8 ? id.substring(0, 8) : id).toLowerCase();
      final _ReadyOrderDetails? details = _resolvedDetails[id];

      if (token.contains(q) || shortCode.contains(q)) return true;
      if (details == null) return false;

      return details.studentName.toLowerCase().contains(q) ||
          details.username.toLowerCase().contains(q) ||
          details.studentId.toLowerCase().contains(q);
    }).toList();
  }

  DateTime _resolveReadyTimestamp(Map<String, dynamic> order) {
    return DateTime.tryParse((order['ready_at'] as String?) ?? '') ??
        DateTime.tryParse((order['updated_at'] as String?) ?? '') ??
        DateTime.tryParse((order['created_at'] as String?) ?? '') ??
        DateTime.now();
  }

  /// [P13] Verification Screen-এ প্রিলোডেড অর্ডার ও স্টুডেন্ট তথ্যসহ পাঠানো
  void _openVerifyScreen({Map<String, dynamic>? order}) {
    if (order == null) {
      Navigator.of(context).pushNamed('/counter/verify');
      return;
    }

    final String orderId = order['id'].toString();
    final _ReadyOrderDetails? cached = _resolvedDetails[orderId];

    Navigator.of(context).pushNamed(
      '/counter/verify',
      arguments: <String, dynamic>{
        'order': order,
        if (cached != null) 'student_name': cached.studentName,
        if (cached != null) 'username': cached.username,
        if (cached != null) 'student_id': cached.studentId,
        if (cached != null) 'items': cached.items,
      },
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

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: রেস্পন্সিভ পিকআপ কিউ বোর্ড (ডিসপ্লে স্পষ্টতা ও দ্রুত সার্চসহ)
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: _buildAppBar(),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _readyOrdersStream,
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
                  'Counter Realtime queue disconnected.\nCheck your campus network.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.redAccent, fontSize: 15),
                ),
              ),
            );
          }

          final List<Map<String, dynamic>> rawOrders =
              snapshot.data ?? <Map<String, dynamic>>[];

          _pruneInactiveCache(rawOrders);

          final DateTime now = DateTime.now();
          int coldAlertCount = 0;
          for (final Map<String, dynamic> o in rawOrders) {
            if (now.difference(_resolveReadyTimestamp(o).toLocal()).inMinutes >=
                10) {
              coldAlertCount++;
            }
          }

          final List<Map<String, dynamic>> filtered =
              _sortAndFilterOrders(rawOrders);

          return Column(
            children: [
              _buildSummaryAndSearchBar(
                readyCount: rawOrders.length,
                coldCount: coldAlertCount,
              ),
              Expanded(child: _buildReadyQueueContent(filtered)),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFFF5722),
        foregroundColor: Colors.white,
        onPressed: () => _openVerifyScreen(),
        icon: const Icon(Icons.qr_code_scanner_rounded),
        label: const Text(
          'Scan / Verify Token',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0F172A),
      elevation: 0,
      title: Row(
        children: [
          const Icon(
            Icons.storefront_rounded,
            color: Colors.greenAccent,
            size: 24,
          ),
          const SizedBox(width: 10),
          const Flexible(
            child: Text(
              'Pickup Counter',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
          ),
          const SizedBox(width: 8),
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
                  'READY QUEUE',
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
        // কাউন্টার স্টাফের জন্য [P17] Wallet Top-Up/Refund শর্টকাট
        IconButton(
          tooltip: 'Wallet Top-Up & Refund Desk',
          icon: const Icon(
            Icons.account_balance_wallet_outlined,
            color: Color(0xFFFF5722),
          ),
          onPressed: () => Navigator.of(context).pushNamed('/admin/wallet'),
        ),
        // [P14] Shift Handover Log & Dispute শর্টকাট
        IconButton(
          tooltip: 'Shift Log & Disputes',
          icon: const Icon(Icons.assignment_outlined, color: Colors.white70),
          onPressed: () => Navigator.of(context).pushNamed('/counter/disputes'),
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

  /// অংশ ১: স্ট্যাটাস সামারি পিল + টোকেন/স্টুডেন্ট সার্চ বার
  Widget _buildSummaryAndSearchBar({
    required int readyCount,
    required int coldCount,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  label: 'READY FOR PICKUP',
                  value: '$readyCount',
                  accent: Colors.greenAccent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildStatCard(
                  label: 'WAITING 10+ MIN',
                  value: '$coldCount',
                  accent: coldCount > 0 ? Colors.redAccent : Colors.white54,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            onChanged: (String v) => setState(() => _searchQuery = v),
            decoration: InputDecoration(
              hintText: 'Search token (#SW-1005), verify code, student name or ID...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13.5),
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              filled: true,
              fillColor: const Color(0xFF1E293B),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required String label,
    required String value,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.6,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(
              color: accent,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  /// অংশ ২: রেস্পন্সিভ রেডি অর্ডার গ্রিড / লিস্ট
  Widget _buildReadyQueueContent(List<Map<String, dynamic>> orders) {
    if (orders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_outline_rounded,
                size: 58,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              const SizedBox(height: 14),
              Text(
                _searchQuery.isNotEmpty
                    ? 'No ready order matches "$_searchQuery".'
                    : 'Pickup queue is completely clear.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Orders marked READY by the kitchen will appear here automatically.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // ট্যাবলেট / ডেস্কটপ (>= 760px): পাশাপাশি একাধিক কার্ডের গ্রিড
        if (constraints.maxWidth >= 760) {
          final int crossAxisCount = constraints.maxWidth >= 1150 ? 3 : 2;
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisExtent: 264,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
            ),
            itemCount: orders.length,
            itemBuilder: (BuildContext context, int index) {
              return _buildReadyOrderCard(orders[index], isGridCard: true);
            },
          );
        }

        // মোবাইল (< 760px): আরামদায়ক সিঙ্গেল-কলাম লিস্ট
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
          itemCount: orders.length,
          itemBuilder: (BuildContext context, int index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _buildReadyOrderCard(orders[index], isGridCard: false),
            );
          },
        );
      },
    );
  }

  /// অংশ ৩: প্রতিটি রেডি অর্ডারের হাই-কন্ট্রাস্ট পিকআপ কার্ড
  Widget _buildReadyOrderCard(
    Map<String, dynamic> order, {
    required bool isGridCard,
  }) {
    final String orderId = order['id'].toString();
    final String userId = order['user_id'].toString();
    final String token = (order['token_number'] as String?) ?? '#SW';
    final String shortVerifyCode = orderId.length >= 8
        ? orderId.substring(0, 8).toUpperCase()
        : orderId.toUpperCase();
    final double total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final DateTime readyAt = _resolveReadyTimestamp(order);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.greenAccent.withValues(alpha: 0.45),
          width: 1.3,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // হেডার: বড় টোকেন + আইসোলেটেড Ready Wait Timer
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                  Text(
                    'Code: $shortVerifyCode  •  Paid ৳${total.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              _ReadyWaitBadge(readyAt: readyAt),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Colors.white12, height: 1),
          ),

          // স্টুডেন্ট পরিচয় + খাবারের তালিকা (Memoized FutureBuilder)
          if (isGridCard)
            Expanded(
              child: _buildDetailsBody(orderId: orderId, userId: userId),
            )
          else
            _buildDetailsBody(orderId: orderId, userId: userId),

          const SizedBox(height: 12),

          // মূল অ্যাকশন: [P13] Verification Screen-এ নিয়ে গিয়ে যাচাইপূর্বক Handover
          SizedBox(
            height: 44,
            child: ElevatedButton.icon(
              onPressed: () => _openVerifyScreen(order: order),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.verified_user_outlined, size: 18),
              label: const Text(
                'VERIFY & HANDOVER',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailsBody({
    required String orderId,
    required String userId,
  }) {
    return FutureBuilder<_ReadyOrderDetails>(
      future: _getOrderDetails(orderId, userId),
      builder: (
        BuildContext context,
        AsyncSnapshot<_ReadyOrderDetails> snap,
      ) {
        if (snap.connectionState == ConnectionState.waiting && !snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(
              color: Colors.greenAccent,
              backgroundColor: Colors.white12,
            ),
          );
        }

        if (snap.hasError || !snap.hasData) {
          return Row(
            children: [
              const Text(
                'Could not load student/item info.',
                style: TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
              TextButton(
                onPressed: () =>
                    setState(() => _detailsFutureCache.remove(orderId)),
                child: const Text('Retry'),
              ),
            ],
          );
        }

        final _ReadyOrderDetails details = snap.data!;
        final String idTag = details.studentId.isNotEmpty
            ? 'ID: ${details.studentId}'
            : (details.username.isNotEmpty ? '@${details.username}' : '');

        final String itemsLine = details.items
            .map(
              (Map<String, dynamic> i) =>
                  '${(i['quantity'] as num?)?.toInt() ?? 1}x ${i['item_name_snapshot'] ?? 'Item'}',
            )
            .join(', ');

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.person_outline_rounded,
                  size: 16,
                  color: Color(0xFFFF5722),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    idTag.isNotEmpty
                        ? '${details.studentName} ($idTag)'
                        : details.studentName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              itemsLine.isNotEmpty ? itemsLine : 'Order items verified',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                height: 1.35,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// স্টুডেন্ট প্রোফাইল ও আইটেম স্ন্যাপশট ধরে রাখার অপরিবর্তনীয় মডেল
class _ReadyOrderDetails {
  final String studentName;
  final String username;
  final String studentId;
  final String phone;
  final List<Map<String, dynamic>> items;

  const _ReadyOrderDetails({
    required this.studentName,
    required this.username,
    required this.studentId,
    required this.phone,
    required this.items,
  });
}

// =============================================================================
// হেল্পার উইজেট: আইসোলেটেড Ready Wait Timer (১০+ মিনিটে COLD ALERT লাল ব্যাজ)
// =============================================================================

class _ReadyWaitBadge extends StatefulWidget {
  final DateTime readyAt;
  const _ReadyWaitBadge({required this.readyAt});

  @override
  State<_ReadyWaitBadge> createState() => _ReadyWaitBadgeState();
}

class _ReadyWaitBadgeState extends State<_ReadyWaitBadge> {
  Timer? _ticker;
  late Duration _waiting;

  @override
  void initState() {
    super.initState();
    _sync();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _sync());
  }

  void _sync() {
    final Duration diff = DateTime.now().difference(widget.readyAt.toLocal());
    if (!mounted) return;
    setState(() => _waiting = diff.isNegative ? Duration.zero : diff);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isColdAlert = _waiting.inMinutes >= 10;
    final bool isWarning = _waiting.inMinutes >= 5 && !isColdAlert;
    final Color color = isColdAlert
        ? Colors.redAccent
        : (isWarning ? Colors.amber : Colors.greenAccent);

    final String mins = _waiting.inMinutes.toString().padLeft(2, '0');
    final String secs = (_waiting.inSeconds % 60).toString().padLeft(2, '0');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Text(
        isColdAlert ? 'COLD $mins:$secs' : 'READY $mins:$secs',
        style: TextStyle(
          color: color,
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}