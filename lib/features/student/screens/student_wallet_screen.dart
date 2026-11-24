import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StudentWalletScreen extends StatefulWidget {
  const StudentWalletScreen({super.key});

  @override
  State<StudentWalletScreen> createState() => _StudentWalletScreenState();
}

class _StudentWalletScreenState extends State<StudentWalletScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  static const int _pageSize = 20;
  static const List<Map<String, String>> _filters = <Map<String, String>>[
    <String, String>{'key': 'all', 'label': 'All'},
    <String, String>{'key': 'topup', 'label': 'Top-Up'},
    <String, String>{'key': 'order_debit', 'label': 'Orders'},
    <String, String>{'key': 'refunds', 'label': 'Refunds'},
  ];

  String? _userId;
  String _fullName = 'Student';
  String _username = '';
  String _studentId = '';

  double _liveBalance = 0.0;
  bool _walletLoaded = false;
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  String _selectedFilter = 'all';
  String? _errorMessage;

  final List<Map<String, dynamic>> _transactions = <Map<String, dynamic>>[];
  StreamSubscription<List<Map<String, dynamic>>>? _walletSub;

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
    _loadProfileInfo(currentUser.id);
    _subscribeLiveWallet(currentUser.id);
    _fetchLedger(reset: true);
  }

  /// ওয়ালেট কার্ডে দেখানোর জন্য স্টুডেন্টের নাম, ইউজারনেম ও আইডি একবার ফেচ করা
  Future<void> _loadProfileInfo(String userId) async {
    try {
      final Map<String, dynamic> profile = await _supabase
          .from('profiles')
          .select('first_name, last_name, username, student_id')
          .eq('id', userId)
          .single()
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      final String first = (profile['first_name'] as String?)?.trim() ?? '';
      final String last = (profile['last_name'] as String?)?.trim() ?? '';
      final String combined = '$first $last'.trim();

      setState(() {
        if (combined.isNotEmpty) _fullName = combined;
        _username = (profile['username'] as String?)?.trim() ?? '';
        _studentId = (profile['student_id'] as String?)?.trim() ?? '';
      });
    } catch (_) {
      // প্রোফাইল মেটাডেটা লোড না হলেও ওয়ালেট ও লেজার স্বাভাবিকভাবে চলবে
    }
  }

  /// একক-রো Realtime Balance Stream: ব্যালেন্স বদলালেই লেজার স্বয়ংক্রিয়ভাবে রিফ্রেশ হবে
  void _subscribeLiveWallet(String userId) {
    _walletSub = _supabase
        .from('wallets')
        .stream(primaryKey: <String>['user_id'])
        .eq('user_id', userId)
        .listen(
      (List<Map<String, dynamic>> rows) {
        if (!mounted || rows.isEmpty) return;
        final double incomingBalance =
            (rows.first['balance'] as num?)?.toDouble() ?? 0.0;

        // প্রথমবারের পর যদি লাইভ ব্যালেন্স বদলায় (যেমন [P17]-এ টপ-আপ হলো), লেজার রিফ্রেশ করো
        final bool shouldRefreshLedger =
            _walletLoaded && incomingBalance != _liveBalance;

        setState(() {
          _liveBalance = incomingBalance;
          _walletLoaded = true;
        });

        if (shouldRefreshLedger) {
          _fetchLedger(reset: true);
        }
      },
      onError: (_) {
        if (!mounted) return;
        setState(() {
          _errorMessage ??= 'Live balance sync interrupted. Pull down to refresh.';
        });
      },
    );
  }

  /// Paginated Immutable Ledger Fetch (প্রতি পেজে সর্বোচ্চ ২০টি লেনদেন)
  Future<void> _fetchLedger({required bool reset}) async {
    if (_userId == null) return;
    if (!reset && (_isLoadingMore || !_hasMore)) return;

    if (mounted) {
      setState(() {
        _errorMessage = null;
        if (reset) {
          _isInitialLoading = true;
          _hasMore = true;
        } else {
          _isLoadingMore = true;
        }
      });
    }

    try {
      final int from = reset ? 0 : _transactions.length;
      final int to = from + _pageSize - 1;

      var query = _supabase
          .from('wallet_transactions')
          .select(
            'id, order_id, type, amount, balance_after, reason, created_at',
          )
          .eq('user_id', _userId!);

      if (_selectedFilter == 'topup') {
        query = query.eq('type', 'topup');
      } else if (_selectedFilter == 'order_debit') {
        query = query.eq('type', 'order_debit');
      } else if (_selectedFilter == 'refunds') {
        query = query.or('type.eq.order_refund,type.eq.cash_refund');
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
          _transactions
            ..clear()
            ..addAll(fetched);
        } else {
          _transactions.addAll(fetched);
        }
        _hasMore = fetched.length == _pageSize;
      });
    } on TimeoutException {
      if (mounted) {
        setState(() => _errorMessage = 'Ledger request timed out. Pull to retry.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _errorMessage = 'Unable to load wallet history. Check internet.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isInitialLoading = false;
          _isLoadingMore = false;
        });
      }
    }
  }

  /// ক্যান্টিন ডেস্কে [P17] টপ-আপ করার জন্য আইডি/ইউজারনেম কপি করা
  void _copyWalletIdentifier() {
    final String valueToCopy = _studentId.isNotEmpty
        ? _studentId
        : (_username.isNotEmpty ? _username : (_userId ?? ''));
    if (valueToCopy.isEmpty) return;

    Clipboard.setData(ClipboardData(text: valueToCopy));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied "$valueToCopy" for canteen top-up desk.'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _onFilterSelected(String filterKey) {
    if (_selectedFilter == filterKey) return;
    setState(() => _selectedFilter = filterKey);
    _fetchLedger(reset: true);
  }

  /// এক্সটার্নাল intl প্যাকেজ ছাড়াই পরিষ্কার লোকাল ডেট-টাইম ফরম্যাটিং
  String _formatTimestamp(String? rawIso) {
    if (rawIso == null) return '';
    final DateTime? parsed = DateTime.tryParse(rawIso)?.toLocal();
    if (parsed == null) return '';

    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final int hour12 = parsed.hour % 12 == 0 ? 12 : parsed.hour % 12;
    final String minute = parsed.minute.toString().padLeft(2, '0');
    final String suffix = parsed.hour >= 12 ? 'PM' : 'AM';
    return '${parsed.day} ${months[parsed.month - 1]} ${parsed.year}, $hour12:$minute $suffix';
  }

  @override
  void dispose() {
    // মেমোরি লিক রোধে StreamSubscription ক্যানসেল করা বাধ্যতামূলক
    _walletSub?.cancel();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: পরিষ্কার, মডুলার এবং ফিনটেক-মানের লেআউট
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text(
          'Digital Wallet',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh Ledger',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white70),
            onPressed: () => _fetchLedger(reset: true),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xFFFF5722),
        backgroundColor: const Color(0xFF1E293B),
        onRefresh: () => _fetchLedger(reset: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildWalletHeroCard(),
                        const SizedBox(height: 14),
                        _buildTopUpInstructionBanner(),
                        const SizedBox(height: 20),
                        const Text(
                          'IMMUTABLE TRANSACTION LEDGER',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _buildFilterChips(),
                        const SizedBox(height: 12),
                        if (_errorMessage != null) _buildErrorBanner(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            ..._buildLedgerSlivers(),
          ],
        ),
      ),
    );
  }

  /// অংশ ১: এটিএম-কার্ড স্টাইলের লাইভ ব্যালেন্স কার্ড
  Widget _buildWalletHeroCard() {
    final String identityLine = _studentId.isNotEmpty
        ? '@$_username  •  ID: $_studentId'
        : (_username.isNotEmpty ? '@$_username' : 'SwiftServe Student Wallet');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF1E293B), Color(0xFF0F172A)],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFFF5722).withValues(alpha: 0.55),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF5722).withValues(alpha: 0.14),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.bolt_rounded, color: Color(0xFFFF5722), size: 20),
                  SizedBox(width: 6),
                  Text(
                    'SWIFTSERVE WALLET',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: Colors.greenAccent.withValues(alpha: 0.6)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.greenAccent, size: 7),
                    SizedBox(width: 5),
                    Text(
                      'LIVE SYNC',
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
          const SizedBox(height: 22),
          const Text(
            'Available Balance',
            style: TextStyle(color: Colors.white54, fontSize: 12.5),
          ),
          const SizedBox(height: 4),
          Text(
            _walletLoaded ? '৳ ${_liveBalance.toStringAsFixed(2)}' : '৳ ---.--',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 34,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fullName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      identityLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _copyWalletIdentifier,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFF5722),
                  side: BorderSide(
                    color: const Color(0xFFFF5722).withValues(alpha: 0.6),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text(
                  'Copy ID',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// অংশ ২: টপ-আপ নির্দেশিকা (নিরাপত্তা নীতি: স্টুডেন্ট নিজে ব্যালেন্স বাড়াতে পারবে না)
  Widget _buildTopUpInstructionBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: Color(0xFFFF5722),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'To add money or request cash-out refund, provide your Username or Student ID at the Canteen Counter Desk.',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// অংশ ৩: সার্ভার-সাইড ফিল্টার চিপস
  Widget _buildFilterChips() {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final Map<String, String> item = _filters[index];
          final bool isSelected = _selectedFilter == item['key'];

          return ChoiceChip(
            label: Text(item['label']!),
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
            onSelected: (_) => _onFilterSelected(item['key']!),
          );
        },
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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

  /// অংশ ৪: প্যাজিনেটেড ট্রানজেকশন তালিকা
  List<Widget> _buildLedgerSlivers() {
    if (_isInitialLoading) {
      return const <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFFFF5722)),
          ),
        ),
      ];
    }

    if (_transactions.isEmpty) {
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
                    Icons.receipt_outlined,
                    size: 54,
                    color: Colors.white.withValues(alpha: 0.22),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'No wallet transactions found.',
                    style: TextStyle(color: Colors.white60, fontSize: 15),
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
                  child: _buildTransactionTile(_transactions[index]),
                ),
              );
            },
            childCount: _transactions.length,
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
                        : () => _fetchLedger(reset: false),
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
                        : const Text('Load Older Transactions'),
                  )
                : Text(
                    'End of transaction ledger',
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

  /// প্রতিটি লেজার এন্ট্রির কার্ড (Credit বনাম Debit নির্ভুল রঙ ও Running Balance সহ)
  Widget _buildTransactionTile(Map<String, dynamic> tx) {
    final String type = (tx['type'] as String?) ?? '';
    final double amount = (tx['amount'] as num?)?.toDouble() ?? 0.0;
    final double balanceAfter =
        (tx['balance_after'] as num?)?.toDouble() ?? 0.0;
    final String reason = (tx['reason'] as String?) ?? '';
    final String timeStr = _formatTimestamp(tx['created_at'] as String?);
    final String? orderId = tx['order_id']?.toString();

    final _TxVisualMeta meta = _txMeta(type);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        // অর্ডার-সম্পর্কিত লেনদেনে ট্যাপ করলে সরাসরি [P07] অর্ডার ট্র্যাকার খুলবে
        onTap: orderId != null && orderId.isNotEmpty
            ? () => Navigator.of(context).pushNamed(
                  '/student/order-tracker',
                  arguments: orderId,
                )
            : null,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: meta.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(meta.icon, color: meta.color, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Text(
                          timeStr,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                        if (orderId != null && orderId.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          const Text(
                            '• Tap for order',
                            style: TextStyle(
                              color: Color(0xFFFF5722),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${meta.isCredit ? '+' : '-'} ৳ ${amount.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: meta.color,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Bal: ৳ ${balanceAfter.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11.5,
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

  _TxVisualMeta _txMeta(String type) {
    switch (type) {
      case 'topup':
        return const _TxVisualMeta(
          title: 'Cash Top-Up',
          icon: Icons.south_west_rounded,
          color: Colors.greenAccent,
          isCredit: true,
        );
      case 'order_refund':
        return const _TxVisualMeta(
          title: 'Order Refund',
          icon: Icons.replay_rounded,
          color: Colors.tealAccent,
          isCredit: true,
        );
      case 'order_debit':
        return const _TxVisualMeta(
          title: 'Order Payment',
          icon: Icons.north_east_rounded,
          color: Colors.redAccent,
          isCredit: false,
        );
      case 'cash_refund':
        return const _TxVisualMeta(
          title: 'Cash-Out Refund',
          icon: Icons.account_balance_rounded,
          color: Colors.amber,
          isCredit: false, // নগদ টাকা হাতে ফেরত নেওয়ায় ডিজিটাল ওয়ালেট থেকে কাটে!
        );
      default:
        return const _TxVisualMeta(
          title: 'Wallet Activity',
          icon: Icons.swap_horiz_rounded,
          color: Colors.white70,
          isCredit: false,
        );
    }
  }
}

class _TxVisualMeta {
  final String title;
  final IconData icon;
  final Color color;
  final bool isCredit;

  const _TxVisualMeta({
    required this.title,
    required this.icon,
    required this.color,
    required this.isCredit,
  });
}