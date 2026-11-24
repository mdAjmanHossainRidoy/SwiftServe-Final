import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/models/user_role.dart';
import '../../../core/validators/app_validators.dart';

typedef JsonMap = Map<String, dynamic>;
typedef StringMap = Map<String, String>;

class CounterDisputeScreen extends StatefulWidget {
  const CounterDisputeScreen({super.key});

  @override
  State<CounterDisputeScreen> createState() => _CounterDisputeScreenState();
}

class _CounterDisputeScreenState extends State<CounterDisputeScreen>
    with SingleTickerProviderStateMixin {
  final SupabaseClient _supabase = Supabase.instance.client;

  late final TabController _tabController;

  bool _didReadArgs = false;
  String? _userId;
  UserRole? _currentRole;

  // Tab 1: Today's Shift Handover Log State
  bool _isLoadingShift = true;
  bool _onlyMyHandovers = false;
  String? _shiftError;
  List<JsonMap> _todayCompletedOrders = <JsonMap>[];

  // Tab 2: Disputes Console State
  bool _isLoadingDisputes = true;
  String _disputeFilter = 'open'; // 'open', 'resolved', 'all'
  String? _disputeError;
  List<JsonMap> _disputes = <JsonMap>[];

  /// Per-Dispute lock so resolving one dispute never freezes other cards
  final Set<String> _busyDisputeIds = <String>{};

  /// Batched IN-Query cache: staff_uuid -> "Full Name" (Zero PGRST201 & Zero N+1)
  final StringMap _staffNameCache = <String, String>{};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    final User? currentUser = _supabase.auth.currentUser;
    if (currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
      });
      return;
    }

    _userId = currentUser.id;
    _loadCurrentRole();
    _fetchShiftLog();
    _fetchDisputes();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didReadArgs) return;
    _didReadArgs = true;

    final Object? args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['id'] != null) {
      final JsonMap prefilledOrder = JsonMap.from(args);
      _tabController.index = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _openLogDisputeDialog(prefilledOrder: prefilledOrder);
      });
    }
  }

  /// Loads current staff role (Admin unlocks the Resolve button)
  Future<void> _loadCurrentRole() async {
    if (_userId == null) return;
    try {
      final JsonMap row = await _supabase
          .from('profiles')
          .select('role, first_name, last_name, username')
          .eq('id', _userId!)
          .single()
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      _staffNameCache[_userId!] = _formatStaffDisplay(row);
      setState(() {
        _currentRole = UserRole.tryParse(row['role'] as String?);
      });
    } catch (_) {
      // Falls back safely to Read-Only (Non-Admin) mode if role lookup fails
    }
  }

  /// Tab 1: Fetches all Completed handovers since local midnight (converted to UTC)
  Future<void> _fetchShiftLog() async {
    if (mounted) {
      setState(() {
        _isLoadingShift = true;
        _shiftError = null;
      });
    }

    try {
      final DateTime now = DateTime.now();
      final String startOfTodayUtc = DateTime(
        now.year,
        now.month,
        now.day,
      ).toUtc().toIso8601String();

      final List<dynamic> raw = await _supabase
          .from('orders')
          .select('id, token_number, total_amount, completed_at, completed_by')
          .eq('status', 'completed')
          .gte('completed_at', startOfTodayUtc)
          .order('completed_at', ascending: false)
          .limit(150)
          .timeout(const Duration(seconds: 10));

      final List<JsonMap> orders = <JsonMap>[
        for (final dynamic r in raw)
          if (r is Map) JsonMap.from(r),
      ];
      final Set<String> staffIds = <String>{};
      for (final JsonMap o in orders) {
        final String? cb = o['completed_by']?.toString();
        if (cb != null && cb.isNotEmpty) staffIds.add(cb);
      }
      await _hydrateStaffNames(staffIds);

      if (!mounted) return;
      setState(() => _todayCompletedOrders = orders);
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _shiftError = 'Shift log timed out. Pull down to retry.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _shiftError = 'Failed to load today\'s shift handovers.',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoadingShift = false);
    }
  }

  /// Tab 2: Fetches disputes (Single-FK `orders` embed + Batched Staff Lookup)
  Future<void> _fetchDisputes() async {
    if (mounted) {
      setState(() {
        _isLoadingDisputes = true;
        _disputeError = null;
      });
    }

    try {
      final List<dynamic> raw = await _supabase
          .from('order_disputes')
          .select(
            'id, order_id, reported_by, resolved_by, issue_note, status, created_at, '
            'orders(token_number, status, total_amount)',
          )
          .order('created_at', ascending: false)
          .limit(100)
          .timeout(const Duration(seconds: 10));

      final List<JsonMap> rows = <JsonMap>[
        for (final dynamic r in raw)
          if (r is Map) JsonMap.from(r),
      ];

      final Set<String> staffIds = <String>{};
      for (final JsonMap d in rows) {
        final String? rep = d['reported_by']?.toString();
        final String? res = d['resolved_by']?.toString();
        if (rep != null && rep.isNotEmpty) staffIds.add(rep);
        if (res != null && res.isNotEmpty) staffIds.add(res);
      }
      await _hydrateStaffNames(staffIds);

      if (!mounted) return;
      setState(() => _disputes = rows);
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _disputeError = 'Disputes request timed out. Pull to retry.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _disputeError = 'Could not load shift disputes.');
      }
    } finally {
      if (mounted) setState(() => _isLoadingDisputes = false);
    }
  }

  /// Resolves unknown staff UUIDs in a single batched IN-query (Zero N+1 / Zero PGRST201)
  Future<void> _hydrateStaffNames(Set<String> ids) async {
    final List<String> missing = ids
        .where((String id) => !_staffNameCache.containsKey(id))
        .toList();
    if (missing.isEmpty) return;

    try {
      final List<dynamic> rows = await _supabase
          .from('profiles')
          .select('id, first_name, last_name, username')
          .inFilter('id', missing)
          .timeout(const Duration(seconds: 8));

      for (final dynamic item in rows) {
        if (item is Map) {
          final JsonMap p = JsonMap.from(item);
          final String id = p['id'].toString();
          _staffNameCache[id] = _formatStaffDisplay(p);
        }
      }
    } catch (_) {
      // Keeps audit logs usable even if secondary staff profile lookup fails
    }
  }

  String _formatStaffDisplay(JsonMap profile) {
    final String first = (profile['first_name'] as String?)?.trim() ?? '';
    final String last = (profile['last_name'] as String?)?.trim() ?? '';
    final String user = (profile['username'] as String?)?.trim() ?? '';
    final String full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    if (user.isNotEmpty) return '@$user';
    return 'Staff';
  }

  String _staffName(String? id) {
    if (id == null || id.isEmpty) return 'Unknown Staff';
    if (id == _userId) return '${_staffNameCache[id] ?? 'Me'} (You)';
    final String shortId = id.length >= 6 ? id.substring(0, 6) : id;
    return _staffNameCache[id] ?? 'Staff #$shortId';
  }

  Future<void> _openLogDisputeDialog({JsonMap? prefilledOrder}) async {
    if (_userId == null) return;

    final bool? created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _LogDisputeDialog(
        reporterId: _userId!,
        prefilledOrder: prefilledOrder,
      ),
    );

    if (created == true && mounted) {
      _tabController.animateTo(1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: const Text('Shift dispute logged for audit review.'),
        ),
      );
      await _fetchDisputes();
    }
  }

  /// Separation of Duties: Only Admin can transition an open dispute to resolved
  Future<void> _handleResolveDispute(JsonMap dispute) async {
    if (_currentRole != UserRole.admin || _userId == null) return;
    final String disputeId = dispute['id'].toString();
    if (_busyDisputeIds.contains(disputeId)) return;

    setState(() => _busyDisputeIds.add(disputeId));
    try {
      final List<dynamic> updated = await _supabase
          .from('order_disputes')
          .update(<String, dynamic>{
            'status': 'resolved',
            'resolved_by': _userId,
          })
          .eq('id', disputeId)
          .eq('status', 'open')
          .select('id')
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;

      if (updated.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Could not resolve dispute. Verify Admin UPDATE RLS policy or refresh.',
            ),
          ),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: const Text('Dispute marked as RESOLVED.'),
        ),
      );
      await _fetchDisputes();
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Request timed out. Please retry.'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Failed to resolve dispute. Check network.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busyDisputeIds.remove(disputeId));
    }
  }

  String _formatTimestamp(String? rawIso) {
    if (rawIso == null) return '-';
    final DateTime? parsed = DateTime.tryParse(rawIso)?.toLocal();
    if (parsed == null) return '-';

    const List<String> months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final int hour12 = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
    final String minute = parsed.minute.toString().padLeft(2, '0');
    final String suffix = parsed.hour >= 12 ? 'PM' : 'AM';
    return '${parsed.day} ${months[parsed.month - 1]}, $hour12:$minute $suffix';
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int openCount = _disputes
        .where((JsonMap d) => d['status'] == 'open')
        .length;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text(
          'Shift Log & Disputes',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh All',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            onPressed: () {
              _fetchShiftLog();
              _fetchDisputes();
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFFFF5722),
          indicatorWeight: 3,
          labelColor: const Color(0xFFFF5722),
          unselectedLabelColor: Colors.white60,
          labelStyle: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13.5,
          ),
          tabs: [
            Tab(
              icon: const Icon(Icons.fact_check_outlined, size: 19),
              text: 'Shift Log (${_todayCompletedOrders.length})',
            ),
            Tab(
              icon: const Icon(Icons.report_problem_outlined, size: 19),
              text: 'Disputes ($openCount Open)',
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildShiftLogTab(), _buildDisputesTab()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFFF5722),
        foregroundColor: Colors.white,
        onPressed: () => _openLogDisputeDialog(),
        icon: const Icon(Icons.add_alert_rounded),
        label: const Text(
          'Log Dispute',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  // ==================== TAB 1: TODAY'S SHIFT HANDOVER LOG ====================

  Widget _buildShiftLogTab() {
    final List<JsonMap> myOrders = _todayCompletedOrders
        .where((JsonMap o) => o['completed_by']?.toString() == _userId)
        .toList();

    final List<JsonMap> visibleOrders = _onlyMyHandovers
        ? myOrders
        : _todayCompletedOrders;

    double totalValue = 0.0;
    for (final JsonMap o in visibleOrders) {
      totalValue += (o['total_amount'] as num?)?.toDouble() ?? 0.0;
    }

    return RefreshIndicator(
      color: const Color(0xFFFF5722),
      backgroundColor: const Color(0xFF1E293B),
      onRefresh: _fetchShiftLog,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _buildKpiBox(
                              'ALL TODAY',
                              '${_todayCompletedOrders.length}',
                              Colors.greenAccent,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildKpiBox(
                              'MY SHIFT',
                              '${myOrders.length}',
                              const Color(0xFFFF5722),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildKpiBox(
                              'VALUE',
                              '৳${totalValue.toStringAsFixed(0)}',
                              Colors.lightBlueAccent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          ChoiceChip(
                            label: const Text('All Counter Staff'),
                            selected: !_onlyMyHandovers,
                            showCheckmark: false,
                            selectedColor: const Color(0xFFFF5722),
                            backgroundColor: const Color(0xFF1E293B),
                            side: BorderSide.none,
                            labelStyle: TextStyle(
                              color: !_onlyMyHandovers
                                  ? Colors.white
                                  : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                            onSelected: (_) =>
                                setState(() => _onlyMyHandovers = false),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('My Handovers'),
                            selected: _onlyMyHandovers,
                            showCheckmark: false,
                            selectedColor: const Color(0xFFFF5722),
                            backgroundColor: const Color(0xFF1E293B),
                            side: BorderSide.none,
                            labelStyle: TextStyle(
                              color: _onlyMyHandovers
                                  ? Colors.white
                                  : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                            onSelected: (_) =>
                                setState(() => _onlyMyHandovers = true),
                          ),
                        ],
                      ),
                      if (_shiftError != null) ...[
                        const SizedBox(height: 12),
                        _buildInlineError(_shiftError!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_isLoadingShift)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFFFF5722)),
              ),
            )
          else if (visibleOrders.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.assignment_turned_in_outlined,
                        size: 52,
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'No completed handovers logged today.',
                        style: TextStyle(color: Colors.white60, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((
                  BuildContext context,
                  int index,
                ) {
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: _buildShiftOrderTile(visibleOrders[index]),
                    ),
                  );
                }, childCount: visibleOrders.length),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildShiftOrderTile(JsonMap order) {
    final String token = (order['token_number'] as String?) ?? '#SW';
    final double total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final String completedAt = _formatTimestamp(
      order['completed_at'] as String?,
    );
    final String staff = _staffName(order['completed_by']?.toString());

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: const Color(0xFF1E293B),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.verified_rounded,
                  color: Colors.greenAccent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      token,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'By: $staff',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                      ),
                    ),
                    Text(
                      completedAt,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '৳ ${total.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: Color(0xFFFF5722),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _openLogDisputeDialog(prefilledOrder: order),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(
                        'Flag Issue',
                        style: TextStyle(
                          color: Colors.amber,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== TAB 2: ORDER DISPUTES CONSOLE ====================

  Widget _buildDisputesTab() {
    final List<JsonMap> filtered = _disputes.where((JsonMap d) {
      if (_disputeFilter == 'all') return true;
      return d['status'] == _disputeFilter;
    }).toList();

    final List<StringMap> filterOptions = <StringMap>[
      <String, String>{'k': 'open', 'l': 'Open'},
      <String, String>{'k': 'resolved', 'l': 'Resolved'},
      <String, String>{'k': 'all', 'l': 'All Disputes'},
    ];

    return RefreshIndicator(
      color: const Color(0xFFFF5722),
      backgroundColor: const Color(0xFF1E293B),
      onRefresh: _fetchDisputes,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        children: filterOptions.map((StringMap f) {
                          final bool selected = _disputeFilter == f['k'];
                          return ChoiceChip(
                            label: Text(f['l']!),
                            selected: selected,
                            showCheckmark: false,
                            selectedColor: const Color(0xFFFF5722),
                            backgroundColor: const Color(0xFF1E293B),
                            side: BorderSide.none,
                            labelStyle: TextStyle(
                              color: selected ? Colors.white : Colors.white70,
                              fontWeight: FontWeight.bold,
                              fontSize: 12.5,
                            ),
                            onSelected: (_) =>
                                setState(() => _disputeFilter = f['k']!),
                          );
                        }).toList(),
                      ),
                      if (_currentRole != UserRole.admin) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Separation of Duties: Counter staff can log issues; only Admin can close disputes as resolved.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                      if (_disputeError != null) ...[
                        const SizedBox(height: 12),
                        _buildInlineError(_disputeError!),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_isLoadingDisputes)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFFFF5722)),
              ),
            )
          else if (filtered.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 52,
                        color: Colors.white.withValues(alpha: 0.22),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _disputeFilter == 'open'
                            ? 'Zero open disputes! Smooth operations.'
                            : 'No disputes in this category.',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((
                  BuildContext context,
                  int index,
                ) {
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: _buildDisputeCard(filtered[index]),
                    ),
                  );
                }, childCount: filtered.length),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDisputeCard(JsonMap dispute) {
    final String disputeId = dispute['id'].toString();
    final String status = (dispute['status'] as String?) ?? 'open';
    final bool isOpen = status == 'open';
    final String issueNote = (dispute['issue_note'] as String?) ?? '';
    final String createdAt = _formatTimestamp(dispute['created_at'] as String?);
    final String reporter = _staffName(dispute['reported_by']?.toString());
    final String? resolverId = dispute['resolved_by']?.toString();
    final bool isBusy = _busyDisputeIds.contains(disputeId);

    final JsonMap? orderMeta = dispute['orders'] is Map
        ? JsonMap.from(dispute['orders'] as Map)
        : null;
    final String token = (orderMeta?['token_number'] as String?) ?? 'Order';
    final double total =
        (orderMeta?['total_amount'] as num?)?.toDouble() ?? 0.0;

    final Color badgeColor = isOpen ? Colors.amber : Colors.greenAccent;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isOpen
              ? Colors.amber.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    token,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16.5,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '৳ ${total.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: badgeColor),
                ),
                child: Text(
                  status.toUpperCase(),
                  style: TextStyle(
                    color: badgeColor,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            issueNote,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Colors.white12, height: 1),
          ),
          Text(
            'Reported by: $reporter  •  $createdAt',
            style: const TextStyle(color: Colors.white54, fontSize: 11.5),
          ),
          if (!isOpen && resolverId != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'Resolved by: ${_staffName(resolverId)}',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (isOpen && _currentRole == UserRole.admin) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: OutlinedButton.icon(
                onPressed: isBusy ? null : () => _handleResolveDispute(dispute),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.greenAccent,
                  side: const BorderSide(color: Colors.greenAccent),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: isBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.greenAccent,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline, size: 18),
                label: const Text(
                  'MARK AS RESOLVED (ADMIN)',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildKpiBox(String label, String value, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              color: accent,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineError(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
      ),
    );
  }
}

// =============================================================================
// Helper Widget: Crash-Safe Log Dispute Dialog (Cardinality-Safe Token Lookup)
// =============================================================================

class _LogDisputeDialog extends StatefulWidget {
  final String reporterId;
  final JsonMap? prefilledOrder;

  const _LogDisputeDialog({required this.reporterId, this.prefilledOrder});

  @override
  State<_LogDisputeDialog> createState() => _LogDisputeDialogState();
}

class _LogDisputeDialogState extends State<_LogDisputeDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _tokenCtrl = TextEditingController();
  final TextEditingController _noteCtrl = TextEditingController();
  final SupabaseClient _supabase = Supabase.instance.client;

  static final RegExp _digitsOnly = RegExp(r'^\d+$');
  static const List<String> _presets = <String>[
    'Missing item in bag',
    'Wrong food packed',
    'Duplicate screenshot claim attempt',
    'Food cold / quality issue',
  ];

  JsonMap? _resolvedOrder;
  bool _isSubmitting = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    if (widget.prefilledOrder != null) {
      _resolvedOrder = widget.prefilledOrder;
      _tokenCtrl.text =
          (widget.prefilledOrder!['token_number'] as String?) ?? '';
    }
  }

  /// Cardinality-safe lookup: always sorts newest-first & caps to 1 row before maybeSingle()
  Future<JsonMap?> _findOrderByToken(String rawInput) async {
    String normalized = rawInput.trim().toUpperCase();
    if (_digitsOnly.hasMatch(normalized)) {
      normalized = '#SW-$normalized';
    } else if (normalized.startsWith('SW-')) {
      normalized = '#$normalized';
    }

    final dynamic row = await _supabase
        .from('orders')
        .select('id, token_number, status, total_amount')
        .ilike('token_number', normalized)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle()
        .timeout(const Duration(seconds: 8));

    return row is Map ? JsonMap.from(row) : null;
  }

  Future<void> _submitDispute() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMsg = null;
    });

    try {
      JsonMap? targetOrder = _resolvedOrder;
      final String typedToken = _tokenCtrl.text.trim();

      if (targetOrder == null ||
          (targetOrder['token_number'] as String?)?.toUpperCase() !=
              typedToken.toUpperCase()) {
        targetOrder = await _findOrderByToken(typedToken);
      }

      if (targetOrder == null) {
        if (mounted) {
          setState(
            () => _errorMsg =
                'Order "$typedToken" not found. Check token number.',
          );
        }
        return;
      }

      await _supabase
          .from('order_disputes')
          .insert(<String, dynamic>{
            'order_id': targetOrder['id'].toString(),
            'reported_by': widget.reporterId,
            'issue_note': _noteCtrl.text.trim(),
            'status': 'open',
          })
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      Navigator.of(context).pop<bool>(true);
    } on TimeoutException {
      if (mounted) {
        setState(() => _errorMsg = 'Request timed out. Check campus Wi-Fi.');
      }
    } on PostgrestException catch (e) {
      if (mounted) setState(() => _errorMsg = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _errorMsg = 'Could not save dispute. Please retry.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  void dispose() {
    _tokenCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isTokenLocked = widget.prefilledOrder != null;

    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text(
        'Log Order Dispute',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
                    style: const TextStyle(
                      color: Color(0xFFFCA5A5),
                      fontSize: 12.5,
                    ),
                  ),
                ),
              TextFormField(
                controller: _tokenCtrl,
                enabled: !isTokenLocked && !_isSubmitting,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
                decoration: InputDecoration(
                  labelText: 'Order Token *',
                  hintText: 'e.g., 1005 or #SW-1005',
                  labelStyle: const TextStyle(color: Colors.white60),
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                validator: (String? v) => (v == null || v.trim().isEmpty)
                    ? 'Order token is required'
                    : null,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _presets.map((String preset) {
                  return ActionChip(
                    label: Text(preset),
                    backgroundColor: const Color(0xFF0F172A),
                    labelStyle: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                    ),
                    onPressed: _isSubmitting
                        ? null
                        : () {
                            _noteCtrl.text = preset;
                            _formKey.currentState?.validate();
                          },
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _noteCtrl,
                enabled: !_isSubmitting,
                maxLines: 3,
                maxLength: 200,
                style: const TextStyle(color: Colors.white, fontSize: 13.5),
                decoration: InputDecoration(
                  labelText: 'Issue Description *',
                  labelStyle: const TextStyle(color: Colors.white60),
                  hintText: 'Explain what went wrong for audit trail...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  filled: true,
                  fillColor: const Color(0xFF0F172A),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                validator: (String? v) =>
                    AppValidators.requiredReason(v, fieldName: 'Issue note'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submitDispute,
          child: _isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Submit Dispute'),
        ),
      ],
    );
  }
}
