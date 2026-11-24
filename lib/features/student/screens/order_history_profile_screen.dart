import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/models/user_role.dart';
import '../../../core/validators/app_validators.dart';

class OrderHistoryProfileScreen extends StatefulWidget {
  const OrderHistoryProfileScreen({super.key});

  @override
  State<OrderHistoryProfileScreen> createState() =>
      _OrderHistoryProfileScreenState();
}

class _OrderHistoryProfileScreenState extends State<OrderHistoryProfileScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const int _pageSize = 15;
  static const List<Map<String, String>> _historyFilters = <Map<String, String>>[
    <String, String>{'key': 'all', 'label': 'All Past'},
    <String, String>{'key': 'completed', 'label': 'Completed'},
    <String, String>{'key': 'cancelled', 'label': 'Cancelled'},
  ];

  String? _userId;
  String _userEmail = '';
  Map<String, dynamic>? _profile;
  bool _isProfileLoading = true;

  final List<Map<String, dynamic>> _orders = <Map<String, dynamic>>[];
  String _selectedFilter = 'all';
  bool _isInitialOrdersLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String? _ordersError;

  @override
  void initState() {
    super.initState();
    final User? currentUser = _supabase.auth.currentUser;

    if (currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/login',
          (Route<dynamic> route) => false,
        );
      });
      return;
    }

    _userId = currentUser.id;
    _userEmail = currentUser.email ?? '';

    // প্রোফাইল ও প্রথম পেজের হিস্ট্রি প্যারালালি লোড করো
    _loadProfile();
    _fetchOrderHistory(reset: true);
  }

  /// প্রোফাইল টেবিল থেকে স্টুডেন্টের ভেরিফায়েড পরিচয় আনা (auth.users থেকে email ইতিমধ্যেই আছে)
  Future<void> _loadProfile() async {
    if (_userId == null) return;
    try {
      final Map<String, dynamic> data = await _supabase
          .from('profiles')
          .select(
            'first_name, last_name, username, student_id, phone, role, is_active, created_at',
          )
          .eq('id', _userId!)
          .single()
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      setState(() {
        _profile = data;
        _isProfileLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isProfileLoading = false);
      }
    }
  }

  /// N+1 Query সমাধান: মাত্র ১টি Embedded Join কুয়েরিতে অর্ডার + আইটেম স্ন্যাপশট আনা
  Future<void> _fetchOrderHistory({required bool reset}) async {
    if (_userId == null) return;
    if (!reset && (_isLoadingMore || !_hasMore)) return;

    if (mounted) {
      setState(() {
        _ordersError = null;
        if (reset) {
          _isInitialOrdersLoading = true;
          _hasMore = true;
        } else {
          _isLoadingMore = true;
        }
      });
    }

    try {
      final int from = reset ? 0 : _orders.length;
      final int to = from + _pageSize - 1;

      var query = _supabase
          .from('orders')
          .select(
            'id, token_number, status, total_amount, customer_notes, '
            'cancel_reason, created_at, completed_at, '
            'order_items(item_name_snapshot, unit_price_snapshot, quantity, subtotal)',
          )
          .eq('user_id', _userId!);

      if (_selectedFilter == 'completed') {
        query = query.eq('status', 'completed');
      } else if (_selectedFilter == 'cancelled') {
        query = query.eq('status', 'cancelled');
      } else {
        // কেবল অতীতের টার্মিনাল স্টেটগুলো (Completed ও Cancelled)
        query = query.or('status.eq.completed,status.eq.cancelled');
      }

      final List<dynamic> rawRows = await query
          .order('created_at', ascending: false)
          .range(from, to)
          .timeout(const Duration(seconds: 10));

      final List<Map<String, dynamic>> fetched = rawRows
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> r) => Map<String, dynamic>.from(r))
          .toList();

      if (!mounted) return;
      setState(() {
        if (reset) {
          _orders
            ..clear()
            ..addAll(fetched);
        } else {
          _orders.addAll(fetched);
        }
        _hasMore = fetched.length == _pageSize;
      });
    } on TimeoutException {
      if (mounted) {
        setState(() => _ordersError = 'Request timed out. Pull down to retry.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _ordersError = 'Could not load order history. Check internet.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isInitialOrdersLoading = false;
          _isLoadingMore = false;
        });
      }
    }
  }

  void _onFilterChanged(String key) {
    if (_selectedFilter == key) return;
    setState(() => _selectedFilter = key);
    _fetchOrderHistory(reset: true);
  }

  /// নিরাপদ পাসওয়ার্ড পরিবর্তন ডায়ালগ খোলা
  Future<void> _openChangePasswordDialog() async {
    if (_userEmail.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Account email unavailable for re-authentication.'),
        ),
      );
      return;
    }

    final bool? updated = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ChangePasswordDialog(userEmail: _userEmail),
    );

    if (updated == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: const Text('Password updated securely.'),
        ),
      );
    }
  }

  /// নিশ্চিতকরণ ডায়ালগসহ সম্পূর্ণ স্ট্যাক-ক্লিয়ারিং সাইন-আউট
  Future<void> _confirmAndSignOut() async {
    final bool? shouldLogout = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text(
            'Sign Out?',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: const Text(
            'You will need to sign in again with your email or username to access SwiftServe.',
            style: TextStyle(color: Colors.white70, fontSize: 13.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Sign Out'),
            ),
          ],
        );
      },
    );

    if (shouldLogout != true || !mounted) return;
    await _supabase.auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      '/login',
      (Route<dynamic> route) => false,
    );
  }

  /// ডিজিটাল রিসিট বটম শিট (ঐতিহাসিক স্ন্যাপশট দামসহ)
  void _showDigitalReceipt(Map<String, dynamic> order) {
    final String token = (order['token_number'] as String?) ?? '#SW';
    final String status = (order['status'] as String?) ?? '';
    final bool isCompleted = status == 'completed';
    final double total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final String notes = (order['customer_notes'] as String?)?.trim() ?? '';
    final String cancelReason = (order['cancel_reason'] as String?)?.trim() ?? '';
    final List<Map<String, dynamic>> items = _extractOrderItems(order);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 24),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'DIGITAL RECEIPT',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          token,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    _buildStatusBadge(status),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'Placed: ${_formatTimestamp(order['created_at'] as String?)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                if (isCompleted && order['completed_at'] != null)
                  Text(
                    'Handed Over: ${_formatTimestamp(order['completed_at'] as String?)}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Divider(color: Colors.white12, height: 1),
                ),

                // আইটেম স্ন্যাপশট তালিকা
                ...items.map((Map<String, dynamic> item) {
                  final String name =
                      (item['item_name_snapshot'] as String?) ?? 'Item';
                  final int qty = (item['quantity'] as num?)?.toInt() ?? 1;
                  final double unitPrice =
                      (item['unit_price_snapshot'] as num?)?.toDouble() ?? 0.0;
                  final double sub =
                      (item['subtotal'] as num?)?.toDouble() ?? (unitPrice * qty);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${qty}x $name (৳${unitPrice.toStringAsFixed(0)})',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        Text(
                          '৳ ${sub.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                }),

                if (notes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Kitchen Note: $notes',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],

                if (!isCompleted && cancelReason.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Cancel Reason: $cancelReason (Refunded to Wallet)',
                      style: const TextStyle(
                        color: Color(0xFFFCA5A5),
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],

                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Divider(color: Colors.white12, height: 1),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      isCompleted ? 'Total Paid (Wallet)' : 'Refunded Amount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '৳ ${total.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: isCompleted
                            ? const Color(0xFFFF5722)
                            : Colors.tealAccent,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('Close Receipt'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Map<String, dynamic>> _extractOrderItems(Map<String, dynamic> order) {
    final Object? raw = order['order_items'];
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((Map<String, dynamic> e) => Map<String, dynamic>.from(e))
        .toList();
  }

  String _formatTimestamp(String? rawIso) {
    if (rawIso == null) return '-';
    final DateTime? parsed = DateTime.tryParse(rawIso)?.toLocal();
    if (parsed == null) return '-';

    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final int hour12 = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
    final String minute = parsed.minute.toString().padLeft(2, '0');
    final String suffix = parsed.hour >= 12 ? 'PM' : 'AM';
    return '${parsed.day} ${months[parsed.month - 1]} ${parsed.year}, $hour12:$minute $suffix';
  }

  String _formatDateOnly(String? rawIso) {
    if (rawIso == null) return '-';
    final DateTime? parsed = DateTime.tryParse(rawIso)?.toLocal();
    if (parsed == null) return '-';

    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${parsed.day} ${months[parsed.month - 1]} ${parsed.year}';
  }

  // ===========================================================================
  // UI অংশ: দুই-ট্যাববিশিষ্ট পরিষ্কার ও মডুলার লেআউট
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F172A),
          elevation: 0,
          title: const Text(
            'History & Profile',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          bottom: const TabBar(
            indicatorColor: Color(0xFFFF5722),
            indicatorWeight: 3,
            labelColor: Color(0xFFFF5722),
            unselectedLabelColor: Colors.white60,
            labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5),
            tabs: [
              Tab(icon: Icon(Icons.receipt_long_rounded, size: 19), text: 'Order History'),
              Tab(icon: Icon(Icons.person_outline_rounded, size: 19), text: 'My Profile'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildOrderHistoryTab(),
            _buildProfileTab(),
          ],
        ),
      ),
    );
  }

  // ==================== TAB 1: ORDER HISTORY ====================

  Widget _buildOrderHistoryTab() {
    return RefreshIndicator(
      color: const Color(0xFFFF5722),
      backgroundColor: const Color(0xFF1E293B),
      onRefresh: () => _fetchOrderHistory(reset: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHistoryFilterRow(),
                      if (_ordersError != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.redAccent.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _ordersError!,
                            style: const TextStyle(
                              color: Color(0xFFFCA5A5),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          ..._buildOrderListSlivers(),
        ],
      ),
    );
  }

  Widget _buildHistoryFilterRow() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _historyFilters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final Map<String, String> filter = _historyFilters[index];
          final bool isSelected = _selectedFilter == filter['key'];

          return ChoiceChip(
            label: Text(filter['label']!),
            selected: isSelected,
            showCheckmark: false,
            selectedColor: const Color(0xFFFF5722),
            backgroundColor: const Color(0xFF1E293B),
            side: BorderSide.none,
            labelStyle: TextStyle(
              color: isSelected ? Colors.white : Colors.white70,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              fontSize: 12.5,
            ),
            onSelected: (_) => _onFilterChanged(filter['key']!),
          );
        },
      ),
    );
  }

  List<Widget> _buildOrderListSlivers() {
    if (_isInitialOrdersLoading) {
      return const <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFFFF5722)),
          ),
        ),
      ];
    }

    if (_orders.isEmpty) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history_toggle_off_rounded,
                    size: 56,
                    color: Colors.white.withValues(alpha: 0.22),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'No past orders found.',
                    style: TextStyle(color: Colors.white60, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Completed and cancelled orders will appear here with digital receipts.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
            (BuildContext context, int index) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _buildHistoryOrderCard(_orders[index]),
                ),
              );
            },
            childCount: _orders.length,
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
          child: Center(
            child: _hasMore
                ? OutlinedButton(
                    onPressed: _isLoadingMore
                        ? null
                        : () => _fetchOrderHistory(reset: false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                    ),
                    child: _isLoadingMore
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFFFF5722),
                            ),
                          )
                        : const Text('Load Older Orders'),
                  )
                : Text(
                    'End of order archive',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
          ),
        ),
      ),
    ];
  }

  Widget _buildHistoryOrderCard(Map<String, dynamic> order) {
    final String token = (order['token_number'] as String?) ?? '#SW';
    final String status = (order['status'] as String?) ?? '';
    final double total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final List<Map<String, dynamic>> items = _extractOrderItems(order);

    final String itemsSummary = items.isEmpty
        ? 'Canteen order items'
        : items
            .map(
              (Map<String, dynamic> i) =>
                  '${(i['quantity'] as num?)?.toInt() ?? 1}x ${i['item_name_snapshot'] ?? 'Item'}',
            )
            .join(', ');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _showDigitalReceipt(order),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    token,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  _buildStatusBadge(status),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _formatTimestamp(order['created_at'] as String?),
                style: const TextStyle(color: Colors.white38, fontSize: 11.5),
              ),
              const SizedBox(height: 8),
              Text(
                itemsSummary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 13.5),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(color: Colors.white12, height: 1),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '৳ ${total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Color(0xFFFF5722),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Row(
                    children: [
                      Text(
                        'Digital Receipt',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(width: 4),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white54,
                        size: 18,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge(String status) {
    final bool isCompleted = status == 'completed';
    final Color color = isCompleted ? Colors.greenAccent : Colors.redAccent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.65)),
      ),
      child: Text(
        status.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10.5,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  // ==================== TAB 2: MY PROFILE & SECURITY ====================

  Widget _buildProfileTab() {
    if (_isProfileLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF5722)),
      );
    }

    final String first = (_profile?['first_name'] as String?)?.trim() ?? '';
    final String last = (_profile?['last_name'] as String?)?.trim() ?? '';
    final String fullName = '$first $last'.trim().isEmpty
        ? 'SwiftServe Student'
        : '$first $last'.trim();
    final String initial = fullName.isNotEmpty ? fullName[0].toUpperCase() : 'S';
    final String username = (_profile?['username'] as String?)?.trim() ?? '-';
    final String studentId = (_profile?['student_id'] as String?)?.trim() ?? 'Not provided';
    final String phone = (_profile?['phone'] as String?)?.trim() ?? '-';
    final UserRole? role = UserRole.tryParse(_profile?['role'] as String?);
    final String joined = _formatDateOnly(_profile?['created_at'] as String?);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // প্রোফাইল হেডার কার্ড
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFFFF5722).withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: const Color(0xFFFF5722),
                      child: Text(
                        initial,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fullName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '@$username',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 13.5,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF5722).withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              (role?.displayName ?? 'Student').toUpperCase(),
                              style: const TextStyle(
                                color: Color(0xFFFF5722),
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ভেরিফায়েড পরিচয়ের তালিকা (Read-Only)
              const Text(
                'VERIFIED ACCOUNT DETAILS',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                ),
                child: Column(
                  children: [
                    _buildProfileInfoRow(Icons.email_outlined, 'Email', _userEmail),
                    const Divider(color: Colors.white12, height: 22),
                    _buildProfileInfoRow(Icons.credit_card_outlined, 'Student ID', studentId),
                    const Divider(color: Colors.white12, height: 22),
                    _buildProfileInfoRow(Icons.phone_outlined, 'Phone', phone),
                    const Divider(color: Colors.white12, height: 22),
                    _buildProfileInfoRow(Icons.calendar_today_outlined, 'Member Since', joined),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Identity fields are locked for audit integrity. Contact canteen admin for corrections.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.38),
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: 24),

              // সিকিউরিটি ও লগআউট অ্যাকশন
              const Text(
                'ACCOUNT SECURITY',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(height: 10),
              _buildActionTile(
                icon: Icons.lock_reset_rounded,
                title: 'Change Password',
                subtitle: 'Requires current password verification',
                accent: const Color(0xFFFF5722),
                onTap: _openChangePasswordDialog,
              ),
              const SizedBox(height: 10),
              _buildActionTile(
                icon: Icons.logout_rounded,
                title: 'Sign Out',
                subtitle: 'Clear session and return to login screen',
                accent: Colors.redAccent,
                onTap: _confirmAndSignOut,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProfileInfoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 19),
        const SizedBox(width: 12),
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 13.5),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.end,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: accent, size: 21),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 14.5,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
        onTap: onTap,
      ),
    );
  }
}

// =============================================================================
// হেল্পার উইজেট: Re-Authenticated Password Change Dialog (Controller Safe)
// =============================================================================

class _ChangePasswordDialog extends StatefulWidget {
  final String userEmail;
  const _ChangePasswordDialog({required this.userEmail});

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _currentCtrl = TextEditingController();
  final TextEditingController _newCtrl = TextEditingController();
  final TextEditingController _confirmCtrl = TextEditingController();

  bool _isSubmitting = false;
  bool _hideCurrent = true;
  bool _hideNew = true;
  bool _hideConfirm = true;
  String? _errorMsg;

  Future<void> _submitPasswordChange() async {
    if (!_formKey.currentState!.validate()) return;

    if (_newCtrl.text == _currentCtrl.text) {
      setState(() => _errorMsg = 'New password must be different from current password.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMsg = null;
    });

    final SupabaseClient supabase = Supabase.instance.client;
    try {
      // ধাপ ১: OWASP Re-Authentication — বর্তমান পাসওয়ার্ড সঠিক কি না যাচাই
      await supabase.auth
          .signInWithPassword(
            email: widget.userEmail,
            password: _currentCtrl.text,
          )
          .timeout(const Duration(seconds: 10));

      // ধাপ ২: নতুন স্ট্রং পাসওয়ার্ড সেট করা
      await supabase.auth
          .updateUser(UserAttributes(password: _newCtrl.text))
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      Navigator.of(context).pop<bool>(true);
    } on AuthException catch (e) {
      if (!mounted) return;
      final String msg = e.message.toLowerCase();
      setState(() {
        _errorMsg = msg.contains('invalid login')
            ? 'Current password is incorrect.'
            : e.message;
      });
    } on TimeoutException {
      if (mounted) {
        setState(() => _errorMsg = 'Request timed out. Check your internet.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMsg = 'Failed to update password. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text(
        'Change Password',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_errorMsg != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _errorMsg!,
                    style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 12.5),
                  ),
                ),
              _buildPassInput(
                controller: _currentCtrl,
                label: 'Current Password',
                hidden: _hideCurrent,
                onToggle: () => setState(() => _hideCurrent = !_hideCurrent),
                validator: AppValidators.loginPassword,
              ),
              const SizedBox(height: 12),
              _buildPassInput(
                controller: _newCtrl,
                label: 'New Password',
                hidden: _hideNew,
                onToggle: () => setState(() => _hideNew = !_hideNew),
                validator: AppValidators.password,
              ),
              const SizedBox(height: 12),
              _buildPassInput(
                controller: _confirmCtrl,
                label: 'Confirm New Password',
                hidden: _hideConfirm,
                onToggle: () => setState(() => _hideConfirm = !_hideConfirm),
                validator: (String? v) =>
                    AppValidators.confirmPassword(v, _newCtrl.text),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submitPasswordChange,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Update Password'),
        ),
      ],
    );
  }

  Widget _buildPassInput({
    required TextEditingController controller,
    required String label,
    required bool hidden,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_isSubmitting,
      obscureText: hidden,
      style: const TextStyle(color: Colors.white, fontSize: 13.5),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white60, fontSize: 13),
        filled: true,
        fillColor: const Color(0xFF0F172A),
        errorMaxLines: 2,
        suffixIcon: IconButton(
          icon: Icon(
            hidden ? Icons.visibility_off : Icons.visibility,
            color: Colors.white54,
            size: 19,
          ),
          onPressed: onToggle,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
      validator: validator,
    );
  }
}