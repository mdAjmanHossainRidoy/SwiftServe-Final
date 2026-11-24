import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef JsonMap = Map<String, dynamic>;

enum _AnalyticsRange {
  today('Today'),
  week('Last 7 Days'),
  allTime('All Time');

  final String label;
  const _AnalyticsRange(this.label);
}

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  _AnalyticsRange _selectedRange = _AnalyticsRange.today;
  bool _isLoading = true;
  String? _errorMessage;
  DateTime? _lastSyncedAt;

  JsonMap _orders = <String, dynamic>{};
  JsonMap _finance = <String, dynamic>{};
  JsonMap _alerts = <String, dynamic>{};
  JsonMap _users = <String, dynamic>{};
  List<JsonMap> _topItems = <JsonMap>[];

  @override
  void initState() {
    super.initState();
    if (_supabase.auth.currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
      });
      return;
    }
    _fetchDashboard();
  }

  /// Computes exact UTC boundary from local midnight (e.g., +06:00) for server RPC
  String? _computeSinceUtc(_AnalyticsRange range) {
    final DateTime now = DateTime.now();
    final DateTime localMidnight = DateTime(now.year, now.month, now.day);

    switch (range) {
      case _AnalyticsRange.today:
        return localMidnight.toUtc().toIso8601String();
      case _AnalyticsRange.week:
        return localMidnight
            .subtract(const Duration(days: 6))
            .toUtc()
            .toIso8601String();
      case _AnalyticsRange.allTime:
        return null;
    }
  }

  /// Single server-side RPC call for complete executive telemetry (O(1) RTT)
  Future<void> _fetchDashboard() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final dynamic raw = await _supabase
          .rpc(
            'admin_get_dashboard_summary',
            params: <String, dynamic>{
              'p_since': _computeSinceUtc(_selectedRange),
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (raw is! Map) {
        setState(() => _errorMessage = 'Unexpected dashboard response format.');
        return;
      }

      final JsonMap data = JsonMap.from(raw);
      setState(() {
        _orders = _asMap(data['orders']);
        _finance = _asMap(data['finance']);
        _alerts = _asMap(data['alerts']);
        _users = _asMap(data['users']);
        _topItems = _asMapList(data['top_items']);
        _lastSyncedAt = DateTime.now();
      });
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _errorMessage =
              'Analytics request timed out. Pull down to retry.',
        );
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() => _errorMessage = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _errorMessage = 'Failed to load admin analytics. Check network.',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Automatically refreshes telemetry whenever Admin returns from any sub-screen
  Future<void> _navigateAndRefresh(String routeName) async {
    await Navigator.of(context).pushNamed(routeName);
    if (mounted) {
      _fetchDashboard();
    }
  }

  Future<void> _handleSignOut() async {
    await _supabase.auth.signOut();
    if (!mounted) return;
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
  }

  JsonMap _asMap(Object? val) {
    if (val is Map) return JsonMap.from(val);
    return <String, dynamic>{};
  }

  List<JsonMap> _asMapList(Object? val) {
    if (val is! List) return <JsonMap>[];
    return <JsonMap>[
      for (final dynamic e in val)
        if (e is Map) JsonMap.from(e),
    ];
  }

  double _numD(JsonMap m, String k) => (m[k] as num?)?.toDouble() ?? 0.0;

  int _numI(JsonMap m, String k) => (m[k] as num?)?.toInt() ?? 0;

  String _formatClock(DateTime dt) {
    final int h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final String m = dt.minute.toString().padLeft(2, '0');
    final String s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s ${dt.hour >= 12 ? 'PM' : 'AM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: _buildAppBar(),
      body: RefreshIndicator(
        color: const Color(0xFFFF5722),
        backgroundColor: const Color(0xFF1E293B),
        onRefresh: _fetchDashboard,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1020),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildRangeSelectorRow(),
                  const SizedBox(height: 14),
                  if (_errorMessage != null) _buildErrorBanner(),
                  if (_isLoading && _lastSyncedAt == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 80),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Color(0xFFFF5722),
                        ),
                      ),
                    )
                  else ...[
                    _buildActionableAlerts(),
                    const SizedBox(height: 18),
                    _buildSectionTitle(
                      'FINANCIAL TELEMETRY (${_selectedRange.label.toUpperCase()})',
                    ),
                    const SizedBox(height: 10),
                    _buildFinancialGrid(),
                    const SizedBox(height: 20),
                    _buildSectionTitle(
                      'ORDER LIFECYCLE PIPELINE (5-STATE FSM)',
                    ),
                    const SizedBox(height: 10),
                    _buildFsmStrip(),
                    const SizedBox(height: 20),
                    _buildResponsiveLowerDeck(),
                    const SizedBox(height: 28),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0F172A),
      elevation: 0,
      title: const Row(
        children: [
          Icon(
            Icons.admin_panel_settings_rounded,
            color: Color(0xFFFF5722),
            size: 25,
          ),
          SizedBox(width: 10),
          Flexible(
            child: Text(
              'Admin Command Center',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 19,
              ),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'Refresh Telemetry',
          icon: _isLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFFF5722),
                  ),
                )
              : const Icon(Icons.refresh_rounded, color: Colors.white70),
          onPressed: _isLoading ? null : _fetchDashboard,
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

  /// Section 1: Timeframe filter chips + last sync clock
  Widget _buildRangeSelectorRow() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Wrap(
          spacing: 8,
          children: _AnalyticsRange.values.map((_AnalyticsRange range) {
            final bool selected = _selectedRange == range;
            return ChoiceChip(
              label: Text(range.label),
              selected: selected,
              showCheckmark: false,
              selectedColor: const Color(0xFFFF5722),
              backgroundColor: const Color(0xFF1E293B),
              side: BorderSide.none,
              labelStyle: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                fontSize: 12.5,
              ),
              onSelected: (_) {
                if (_selectedRange == range) return;
                setState(() => _selectedRange = range);
                _fetchDashboard();
              },
            );
          }).toList(),
        ),
        if (_lastSyncedAt != null)
          Text(
            'Synced: ${_formatClock(_lastSyncedAt!)}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.42),
              fontSize: 11.5,
              fontFamily: 'monospace',
            ),
          ),
      ],
    );
  }

  /// Section 2: Actionable operational alerts (Open Disputes & Low/Out-of-Stock)
  Widget _buildActionableAlerts() {
    final int openDisputes = _numI(_alerts, 'open_disputes');
    final int outOfStock = _numI(_alerts, 'out_of_stock_items');
    final int lowStock = _numI(_alerts, 'low_stock_items');

    if (openDisputes == 0 && outOfStock == 0 && lowStock == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.45)),
        ),
        child: const Row(
          children: [
            Icon(Icons.verified_rounded, color: Colors.greenAccent, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'All systems nominal — zero open disputes and healthy kitchen inventory.',
                style: TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        if (openDisputes > 0)
          _buildAlertChip(
            icon: Icons.report_problem_rounded,
            color: Colors.amber,
            label:
                '$openDisputes Open Dispute${openDisputes > 1 ? 's' : ''} — Review Now',
            onTap: () => _navigateAndRefresh('/counter/disputes'),
          ),
        if (outOfStock > 0 || lowStock > 0)
          _buildAlertChip(
            icon: Icons.inventory_2_rounded,
            color: Colors.redAccent,
            label: '$outOfStock Sold Out • $lowStock Low Stock — Restock',
            onTap: () => _navigateAndRefresh('/admin/menu'),
          ),
      ],
    );
  }

  /// Fixed: Uses Material canvas so InkWell ripple renders cleanly on top
  Widget _buildAlertChip({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withValues(alpha: 0.14),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.65)),
      ),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.arrow_forward_ios_rounded, color: color, size: 13),
            ],
          ),
        ),
      ),
    );
  }

  /// Section 3: 4-card financial telemetry separating Earned Revenue from Wallet Liability
  Widget _buildFinancialGrid() {
    final double earnedRevenue = _numD(_orders, 'earned_revenue');
    final double cashTopups = _numD(_finance, 'cash_topups');
    final double walletLiability = _numD(_finance, 'wallet_liability');
    final double totalRefunds =
        _numD(_finance, 'order_refunds') + _numD(_finance, 'cash_refunds');

    final List<Widget> cards = <Widget>[
      _buildFinanceCard(
        title: 'EARNED REVENUE',
        amount: earnedRevenue,
        subtitle: 'Completed orders only',
        icon: Icons.trending_up_rounded,
        accent: Colors.greenAccent,
      ),
      _buildFinanceCard(
        title: 'CASH TOP-UPS IN',
        amount: cashTopups,
        subtitle: 'Counter desk collections',
        icon: Icons.payments_outlined,
        accent: const Color(0xFFFF5722),
      ),
      _buildFinanceCard(
        title: 'WALLET LIABILITY',
        amount: walletLiability,
        subtitle: 'Live unspent student funds',
        icon: Icons.account_balance_outlined,
        accent: Colors.lightBlueAccent,
      ),
      _buildFinanceCard(
        title: 'TOTAL REFUNDS',
        amount: totalRefunds,
        subtitle: 'Order cancel + cash-out',
        icon: Icons.replay_rounded,
        accent: Colors.amber,
      ),
    ];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int cols = constraints.maxWidth >= 820 ? 4 : 2;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: cols == 4 ? 1.55 : 1.45,
          children: cards,
        );
      },
    );
  }

  Widget _buildFinanceCard({
    required String title,
    required double amount,
    required String subtitle,
    required IconData icon,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Icon(icon, color: accent, size: 18),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              '৳ ${amount.toStringAsFixed(0)}',
              style: TextStyle(
                color: accent,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }

  /// Section 4: 5-State FSM order pipeline breakdown strip
  Widget _buildFsmStrip() {
    final List<JsonMap> states = <JsonMap>[
      <String, dynamic>{
        'label': 'Pending',
        'count': _numI(_orders, 'pending_count'),
        'color': Colors.amber,
      },
      <String, dynamic>{
        'label': 'Preparing',
        'count': _numI(_orders, 'preparing_count'),
        'color': const Color(0xFFFF5722),
      },
      <String, dynamic>{
        'label': 'Ready',
        'count': _numI(_orders, 'ready_count'),
        'color': Colors.greenAccent,
      },
      <String, dynamic>{
        'label': 'Completed',
        'count': _numI(_orders, 'completed_count'),
        'color': Colors.lightBlueAccent,
      },
      <String, dynamic>{
        'label': 'Cancelled',
        'count': _numI(_orders, 'cancelled_count'),
        'color': Colors.redAccent,
      },
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        children: states.map((JsonMap s) {
          final Color color = s['color'] as Color;
          return Container(
            width: 110,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Column(
              children: [
                Text(
                  '${s['count']}',
                  style: TextStyle(
                    color: color,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  (s['label'] as String).toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  /// Section 5: Responsive lower deck (Top Sellers + Users vs. Operations Hub)
  Widget _buildResponsiveLowerDeck() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth >= 780) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTopItemsCard(),
                    const SizedBox(height: 16),
                    _buildUserSnapshotCard(),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(flex: 2, child: _buildOperationsHubCard()),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildOperationsHubCard(),
            const SizedBox(height: 16),
            _buildTopItemsCard(),
            const SizedBox(height: 16),
            _buildUserSnapshotCard(),
          ],
        );
      },
    );
  }

  /// Zero-dependency horizontal bar chart for Top 5 Selling Items
  Widget _buildTopItemsCard() {
    final int maxQty = _topItems.isEmpty
        ? 1
        : _topItems
              .map((JsonMap e) => (e['qty_sold'] as num?)?.toInt() ?? 0)
              .reduce((int a, int b) => a > b ? a : b)
              .clamp(1, 999999);

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
            'TOP 5 SELLING ITEMS (COMPLETED)',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 14),
          if (_topItems.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(
                  'No completed sales recorded in this timeframe.',
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            )
          else
            ..._topItems.map((JsonMap item) {
              final String name = (item['name'] as String?) ?? 'Item';
              final int qty = (item['qty_sold'] as num?)?.toInt() ?? 0;
              final double rev = (item['revenue'] as num?)?.toDouble() ?? 0.0;
              final double ratio = (qty / maxQty).clamp(0.05, 1.0);

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '$qty sold • ৳${rev.toStringAsFixed(0)}',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 8,
                        backgroundColor: const Color(0xFF0F172A),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFFF5722),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  /// Fixed: Uses Material canvas so InkWell ripple renders cleanly on tap
  Widget _buildUserSnapshotCard() {
    final int totalUsers = _numI(_users, 'total_users');
    final int students = _numI(_users, 'students');
    final int staff = _numI(_users, 'staff');
    final int suspended = _numI(_users, 'suspended_users');

    return Material(
      color: const Color(0xFF1E293B),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: InkWell(
        onTap: () => _navigateAndRefresh('/admin/users'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'USER GOVERNANCE SNAPSHOT',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.9,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white54,
                    size: 18,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _buildMiniStat('TOTAL', '$totalUsers', Colors.white),
                  ),
                  Expanded(
                    child: _buildMiniStat(
                      'STUDENTS',
                      '$students',
                      Colors.greenAccent,
                    ),
                  ),
                  Expanded(
                    child: _buildMiniStat(
                      'STAFF',
                      '$staff',
                      Colors.lightBlueAccent,
                    ),
                  ),
                  Expanded(
                    child: _buildMiniStat(
                      'SUSPENDED',
                      '$suspended',
                      suspended > 0 ? Colors.redAccent : Colors.white54,
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

  Widget _buildMiniStat(String label, String val, Color color) {
    return Column(
      children: [
        Text(
          val,
          style: TextStyle(
            color: color,
            fontSize: 19,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// Admin & Floor Oversight Quick Navigation Hub
  Widget _buildOperationsHubCard() {
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
            'MANAGEMENT CONSOLES',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 12),
          _buildNavActionTile(
            icon: Icons.restaurant_menu_rounded,
            color: const Color(0xFFFF5722),
            title: 'Menu & Stock CRUD [P16]',
            subtitle: '${_numI(_alerts, 'total_menu_items')} items configured',
            route: '/admin/menu',
          ),
          _buildNavActionTile(
            icon: Icons.account_balance_wallet_rounded,
            color: Colors.greenAccent,
            title: 'Wallet Top-Up & Refund [P17]',
            subtitle: 'Cash recharge & audit refunds',
            route: '/admin/wallet',
          ),
          _buildNavActionTile(
            icon: Icons.manage_accounts_rounded,
            color: Colors.lightBlueAccent,
            title: 'User Directory & Staff [P18]',
            subtitle: 'Search, create staff, suspend',
            route: '/admin/users',
          ),
          const Divider(color: Colors.white12, height: 22),
          const Text(
            'LIVE FLOOR OVERSIGHT',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          _buildNavActionTile(
            icon: Icons.kitchen_rounded,
            color: Colors.amber,
            title: 'Kitchen KDS [P10]',
            subtitle: 'Monitor live cooking queue',
            route: '/kitchen/kds',
          ),
          _buildNavActionTile(
            icon: Icons.storefront_rounded,
            color: Colors.tealAccent,
            title: 'Counter Queue [P12]',
            subtitle: 'Monitor pickup handovers',
            route: '/counter/queue',
          ),
          _buildNavActionTile(
            icon: Icons.gavel_rounded,
            color: Colors.redAccent,
            title: 'Disputes & Shift Audit [P14]',
            subtitle: '${_numI(_alerts, 'open_disputes')} open issues pending',
            route: '/counter/disputes',
          ),
        ],
      ),
    );
  }

  /// Fixed: Uses Material canvas so ListTile throws zero ink-clip assertion errors
  Widget _buildNavActionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String route,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: const Color(0xFF0F172A),
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          dense: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: color, size: 19),
          ),
          title: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13.5,
            ),
          ),
          subtitle: Text(
            subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 11.5),
          ),
          trailing: const Icon(
            Icons.chevron_right_rounded,
            color: Colors.white38,
          ),
          onTap: () => _navigateAndRefresh(route),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 12,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.0,
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.55)),
      ),
      child: Text(
        _errorMessage!,
        style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
      ),
    );
  }
}
