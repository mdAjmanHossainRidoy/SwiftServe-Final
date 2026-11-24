import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/validators/app_validators.dart';

typedef JsonMap = Map<String, dynamic>;

enum _WalletAction {
  topup(
    rpcValue: 'topup',
    label: 'Add Money',
    fullTitle: 'Cash Top-Up',
    defaultReason: 'Cash received at canteen desk',
    isCredit: true,
    color: Colors.greenAccent,
    icon: Icons.add_circle_outline_rounded,
  ),
  orderRefund(
    rpcValue: 'order_refund',
    label: 'Order Refund',
    fullTitle: 'Manual Order Refund',
    defaultReason: 'Order issue refund approved',
    isCredit: true,
    color: Colors.tealAccent,
    icon: Icons.replay_rounded,
  ),
  cashRefund(
    rpcValue: 'cash_refund',
    label: 'Cash-Out',
    fullTitle: 'Cash-Out Refund',
    defaultReason: 'Cash handed over to student',
    isCredit: false,
    color: Colors.amber,
    icon: Icons.payments_outlined,
  );

  final String rpcValue;
  final String label;
  final String fullTitle;
  final String defaultReason;
  final bool isCredit;
  final Color color;
  final IconData icon;

  const _WalletAction({
    required this.rpcValue,
    required this.label,
    required this.fullTitle,
    required this.defaultReason,
    required this.isCredit,
    required this.color,
    required this.icon,
  });
}

class AdminWalletDeskScreen extends StatefulWidget {
  const AdminWalletDeskScreen({super.key});

  @override
  State<AdminWalletDeskScreen> createState() => _AdminWalletDeskScreenState();
}

class _AdminWalletDeskScreenState extends State<AdminWalletDeskScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _reasonCtrl = TextEditingController();

  static const List<int> _quickAmounts = <int>[50, 100, 200, 500, 1000];

  bool _isSearching = false;
  bool _isProcessing = false;
  bool _isLoadingLedger = false;

  String? _searchError;
  String? _actionError;

  List<JsonMap> _searchResults = <JsonMap>[];
  JsonMap? _selectedStudent;
  List<JsonMap> _recentTransactions = <JsonMap>[];

  _WalletAction _selectedAction = _WalletAction.topup;

  /// Immutable RFC-4122 UUID v4 per distinct transaction intent (retry-safe)
  late String _idempotencyKey;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = _generateUuidV4();

    if (_supabase.auth.currentUser == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
      });
      return;
    }

    _searchStudents(initialLoad: true);
  }

  /// Cryptographically secure UUID v4 generator (zero external package)
  String _generateUuidV4() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final String hex = bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// Server-side student search (RPC: search_users_detailed, role = 'student')
  Future<void> _searchStudents({bool initialLoad = false}) async {
    if (!initialLoad) FocusScope.of(context).unfocus();

    setState(() {
      _isSearching = true;
      _searchError = null;
    });

    try {
      final dynamic raw = await _supabase
          .rpc(
            'search_users_detailed',
            params: <String, dynamic>{
              'p_query': _searchCtrl.text.trim(),
              'p_role_filter': 'student',
              'p_limit': 20,
              'p_offset': 0,
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      final List<JsonMap> users = <JsonMap>[
        if (raw is List)
          for (final dynamic e in raw)
            if (e is Map) JsonMap.from(e),
      ];

      setState(() => _searchResults = users);
    } on TimeoutException {
      if (mounted) {
        setState(() => _searchError = 'Search timed out. Check campus Wi-Fi.');
      }
    } on PostgrestException catch (e) {
      if (mounted) setState(() => _searchError = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _searchError = 'Failed to search students. Please retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  /// Selects a student, enforces suspended-account action rules, and loads last 5 ledger rows
  void _selectStudent(JsonMap student) {
    final bool isActive = student['is_active'] == true;
    setState(() {
      _selectedStudent = JsonMap.from(student);
      if (!isActive && _selectedAction.isCredit) {
        _selectedAction = _WalletAction.cashRefund;
      }
      _actionError = null;
      _idempotencyKey = _generateUuidV4();
    });
    _fetchRecentLedger(student['id'].toString());
  }

  /// Cross-platform safe ledger preview (fixes Flutter Web Map<dynamic, dynamic> drop)
  Future<void> _fetchRecentLedger(String studentId) async {
    setState(() => _isLoadingLedger = true);
    try {
      final List<dynamic> rows = await _supabase
          .from('wallet_transactions')
          .select('id, type, amount, balance_after, reason, created_at')
          .eq('user_id', studentId)
          .order('created_at', ascending: false)
          .limit(5)
          .timeout(const Duration(seconds: 8));

      if (!mounted || _selectedStudent?['id'].toString() != studentId) return;
      setState(() {
        _recentTransactions = <JsonMap>[
          for (final dynamic e in rows)
            if (e is Map) JsonMap.from(e),
        ];
      });
    } catch (_) {
      // Keeps adjustment desk operational even if secondary ledger preview fails
    } finally {
      if (mounted) setState(() => _isLoadingLedger = false);
    }
  }

  /// Pre-commit math confirmation dialog + Atomic Wallet Adjustment RPC
  Future<void> _handleProcessAdjustment() async {
    if (_isProcessing || _selectedStudent == null) return;
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();

    final String studentId = _selectedStudent!['id'].toString();
    final String studentName = _fullName(_selectedStudent!);
    final bool isActive = _selectedStudent!['is_active'] == true;
    final double currentBalance =
        (_selectedStudent!['wallet_balance'] as num?)?.toDouble() ?? 0.0;
    final double amount = double.parse(_amountCtrl.text.trim());
    final String reason = _reasonCtrl.text.trim();

    if (!isActive && _selectedAction.isCredit) {
      setState(
        () => _actionError =
            'Suspended accounts can only process Cash-Out Refunds.',
      );
      return;
    }

    // Client-side overdraft pre-check (database re-verifies under FOR UPDATE lock)
    if (!_selectedAction.isCredit && amount > currentBalance) {
      setState(
        () => _actionError =
            'Insufficient balance for cash-out. Available: ৳ ${currentBalance.toStringAsFixed(2)}',
      );
      return;
    }

    final double projectedBalance = _selectedAction.isCredit
        ? currentBalance + amount
        : currentBalance - amount;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            'Confirm ${_selectedAction.fullTitle}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _confirmRow('Student', studentName),
              _confirmRow(
                'Action',
                _selectedAction.fullTitle,
                valColor: _selectedAction.color,
              ),
              _confirmRow(
                'Amount',
                '${_selectedAction.isCredit ? '+' : '-'} ৳ ${amount.toStringAsFixed(2)}',
                valColor: _selectedAction.color,
              ),
              const Divider(color: Colors.white12, height: 18),
              _confirmRow(
                'Current Balance',
                '৳ ${currentBalance.toStringAsFixed(2)}',
              ),
              _confirmRow(
                'New Balance',
                '৳ ${projectedBalance.toStringAsFixed(2)}',
                valColor: Colors.white,
                isBold: true,
              ),
              const SizedBox(height: 10),
              Text(
                'Reason: $reason',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _selectedAction.isCredit
                    ? Colors.green.shade600
                    : Colors.amber.shade800,
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Confirm & Commit'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      _isProcessing = true;
      _actionError = null;
    });

    try {
      final dynamic raw = await _supabase
          .rpc(
            'process_wallet_adjustment',
            params: <String, dynamic>{
              'p_student_id': studentId,
              'p_action': _selectedAction.rpcValue,
              'p_amount': amount,
              'p_reason': reason,
              'p_idempotency_key': _idempotencyKey,
            },
          )
          .timeout(const Duration(seconds: 12));

      if (!mounted) return;

      final JsonMap res = raw is Map ? JsonMap.from(raw) : <String, dynamic>{};
      final String status = (res['status'] as String?) ?? '';
      final double newBalance =
          (res['new_balance'] as num?)?.toDouble() ?? projectedBalance;

      // Commit succeeded -> sync UI balance, clear inputs, rotate fresh UUID v4
      setState(() {
        _selectedStudent!['wallet_balance'] = newBalance;
        for (final JsonMap row in _searchResults) {
          if (row['id'].toString() == studentId) {
            row['wallet_balance'] = newBalance;
          }
        }
        _amountCtrl.clear();
        _reasonCtrl.clear();
        _idempotencyKey = _generateUuidV4();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text(
            status == 'duplicate_ignored'
                ? 'Already processed! Duplicate transaction safely prevented.'
                : '${_selectedAction.fullTitle} committed. New Balance: ৳ ${newBalance.toStringAsFixed(2)}',
          ),
        ),
      );

      _fetchRecentLedger(studentId);
    } on TimeoutException {
      // Preserve _idempotencyKey intentionally so retrying cannot double-credit/debit
      if (mounted) {
        setState(
          () => _actionError = 'Network timed out. Tap Process again safely — protected against double credit/debit.',
        );
      }
    } on PostgrestException catch (e) {
      if (mounted) setState(() => _actionError = e.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _actionError = 'Transaction failed. Check internet and retry.',
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Widget _confirmRow(
    String label,
    String value, {
    Color valColor = Colors.white70,
    bool isBold = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: valColor,
                fontSize: isBold ? 15 : 13.5,
                fontWeight: isBold ? FontWeight.w900 : FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fullName(JsonMap user) {
    final String f = (user['first_name'] as String?)?.trim() ?? '';
    final String l = (user['last_name'] as String?)?.trim() ?? '';
    final String full = '$f $l'.trim();
    return full.isEmpty ? 'Student' : full;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text(
          'Wallet Top-Up & Refund Desk',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSearchBox(),
                  if (_searchError != null) ...[
                    const SizedBox(height: 12),
                    _buildErrorBanner(_searchError!),
                  ],
                  const SizedBox(height: 14),
                  _buildSearchResultsPanel(),
                  if (_selectedStudent != null) ...[
                    const SizedBox(height: 20),
                    _buildSelectedStudentCard(_selectedStudent!),
                    const SizedBox(height: 16),
                    _buildAdjustmentFormCard(_selectedStudent!),
                    const SizedBox(height: 18),
                    _buildRecentLedgerCard(),
                  ],
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Section 1: Reactive Student Search Bar
  Widget _buildSearchBox() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            enabled: !_isProcessing,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _searchStudents(),
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Search Student Name, Username, ID, Email or Phone...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13.5),
              prefixIcon: const Icon(
                Icons.search_rounded,
                color: Colors.white54,
              ),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white54,
                        size: 18,
                      ),
                      onPressed: () {
                        _searchCtrl.clear();
                        _searchStudents();
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
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: _isSearching || _isProcessing ? null : _searchStudents,
            child: _isSearching
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    'SEARCH',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
          ),
        ),
      ],
    );
  }

  /// Section 2: Fixed Material-backed Search Results List (Zero ListTile Assertions)
  Widget _buildSearchResultsPanel() {
    if (_isSearching && _searchResults.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFFFF5722)),
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'No students found matching your search.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white60, fontSize: 13.5),
        ),
      );
    }

    return Material(
      color: const Color(0xFF1E293B),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: _searchResults.length,
          separatorBuilder: (BuildContext _, int __) =>
              const Divider(color: Colors.white12, height: 1),
          itemBuilder: (BuildContext context, int index) {
            final JsonMap student = _searchResults[index];
            final String id = student['id'].toString();
            final bool isSelected = _selectedStudent?['id'].toString() == id;
            final double bal =
                (student['wallet_balance'] as num?)?.toDouble() ?? 0.0;
            final bool isActive = student['is_active'] == true;
            final String sid = (student['student_id'] as String?)?.trim() ?? '';
            final String uname = (student['username'] as String?)?.trim() ?? '';

            return ListTile(
              dense: true,
              selected: isSelected,
              selectedTileColor: const Color(0xFFFF5722)
                  .withValues(alpha: 0.14),
              leading: CircleAvatar(
                radius: 17,
                backgroundColor: isSelected
                    ? const Color(0xFFFF5722)
                    : const Color(0xFF0F172A),
                child: Text(
                  _fullName(student)[0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              title: Text(
                _fullName(student),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              subtitle: Text(
                '@$uname${sid.isNotEmpty ? ' • ID: $sid' : ''}${!isActive ? ' • SUSPENDED' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? Colors.white60 : Colors.redAccent,
                  fontSize: 12,
                ),
              ),
              trailing: Text(
                '৳ ${bal.toStringAsFixed(0)}',
                style: const TextStyle(
                  color: Colors.greenAccent,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              onTap: _isProcessing ? null : () => _selectStudent(student),
            );
          },
        ),
      ),
    );
  }

  /// Section 3: Selected Student Identity & Live Balance Card
  Widget _buildSelectedStudentCard(JsonMap student) {
    final double balance =
        (student['wallet_balance'] as num?)?.toDouble() ?? 0.0;
    final bool isActive = student['is_active'] == true;
    final String sid = (student['student_id'] as String?)?.trim() ?? 'Not set';
    final String phone = (student['phone'] as String?)?.trim() ?? '-';
    final String email = (student['email'] as String?)?.trim() ?? '-';
    final int orders = (student['total_orders'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isActive
              ? const Color(0xFFFF5722).withValues(alpha: 0.6)
              : Colors.redAccent,
          width: 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fullName(student),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '@${student['username']}  •  ID: $sid',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$email  •  $phone  •  Orders: $orders',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'WALLET BALANCE',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '৳ ${balance.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (!isActive) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'ACCOUNT SUSPENDED — Only Cash-Out Refund is permitted to settle remaining student funds.',
                style: TextStyle(
                  color: Color(0xFFFCA5A5),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Section 4: 3-Mode Wallet Adjustment Form (Suspension-Aware)
  Widget _buildAdjustmentFormCard(JsonMap student) {
    final bool isActive = student['is_active'] == true;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'TRANSACTION TYPE',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _WalletAction.values.map((_WalletAction action) {
                final bool selected = _selectedAction == action;
                final bool blockedBySuspension = !isActive && action.isCredit;
                return ChoiceChip(
                  avatar: Icon(
                    action.icon,
                    size: 17,
                    color: blockedBySuspension
                        ? Colors.white24
                        : (selected ? Colors.black : action.color),
                  ),
                  label: Text(action.label),
                  selected: selected,
                  showCheckmark: false,
                  selectedColor: action.color,
                  disabledColor: const Color(0xFF0F172A),
                  backgroundColor: const Color(0xFF0F172A),
                  side: BorderSide(
                    color: blockedBySuspension
                        ? Colors.white12
                        : (selected
                              ? action.color
                              : action.color.withValues(alpha: 0.35)),
                  ),
                  labelStyle: TextStyle(
                    color: blockedBySuspension
                        ? Colors.white30
                        : (selected ? Colors.black : Colors.white),
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                  onSelected: (_isProcessing || blockedBySuspension)
                      ? null
                      : (_) {
                          setState(() {
                            _selectedAction = action;
                            _actionError = null;
                            _idempotencyKey = _generateUuidV4();
                          });
                        },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: _quickAmounts.map((int amt) {
                return ActionChip(
                  label: Text('৳ $amt'),
                  backgroundColor: const Color(0xFF0F172A),
                  labelStyle: const TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  onPressed: _isProcessing
                      ? null
                      : () {
                          _amountCtrl.text = '$amt';
                          _idempotencyKey = _generateUuidV4();
                          setState(() => _actionError = null);
                        },
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amountCtrl,
              enabled: !_isProcessing,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => _idempotencyKey = _generateUuidV4(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
              decoration: _inputStyle(
                'Amount (BDT) *',
                'e.g., 500',
                Icons.currency_exchange_rounded,
              ),
              validator: (String? v) =>
                  AppValidators.amount(v, min: 1, max: 50000),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _reasonCtrl,
              enabled: !_isProcessing,
              maxLength: 180,
              onChanged: (_) => _idempotencyKey = _generateUuidV4(),
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration:
                  _inputStyle(
                    'Audit Reason / Receipt Note *',
                    _selectedAction.defaultReason,
                    Icons.description_outlined,
                  ).copyWith(
                    suffixIcon: TextButton(
                      onPressed: _isProcessing
                          ? null
                          : () {
                              _reasonCtrl.text = _selectedAction.defaultReason;
                              _idempotencyKey = _generateUuidV4();
                            },
                      child: const Text(
                        'Preset',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
              validator: (String? v) =>
                  AppValidators.requiredReason(v, fieldName: 'Audit reason'),
            ),
            if (_actionError != null) ...[
              const SizedBox(height: 8),
              _buildErrorBanner(_actionError!),
            ],
            const SizedBox(height: 14),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: _isProcessing ? null : _handleProcessAdjustment,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _selectedAction.isCredit
                      ? Colors.green.shade600
                      : Colors.amber.shade800,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _isProcessing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.lock_outline_rounded, size: 19),
                label: Text(
                  _isProcessing
                      ? 'COMMITTING ATOMIC LEDGER...'
                      : 'PROCESS ${_selectedAction.fullTitle.toUpperCase()}',
                  style: const TextStyle(
                    fontSize: 14,
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

  /// Section 5: Selected Student's Last 5 Immutable Ledger Entries
  Widget _buildRecentLedgerCard() {
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
            'RECENT LEDGER (LAST 5 TRANSACTIONS)',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.9,
            ),
          ),
          const SizedBox(height: 12),
          if (_isLoadingLedger)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFFFF5722),
                ),
              ),
            )
          else if (_recentTransactions.isEmpty)
            const Text(
              'No wallet transactions recorded for this student yet.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            )
          else
            ..._recentTransactions.map((JsonMap tx) {
              final String type = (tx['type'] as String?) ?? '';
              final bool isCredit = type == 'topup' || type == 'order_refund';
              final double amt = (tx['amount'] as num?)?.toDouble() ?? 0.0;
              final double balAfter =
                  (tx['balance_after'] as num?)?.toDouble() ?? 0.0;
              final String reason = (tx['reason'] as String?) ?? '';
              final Color color = isCredit
                  ? Colors.greenAccent
                  : Colors.redAccent;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            type.replaceAll('_', ' ').toUpperCase(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            reason,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${isCredit ? '+' : '-'} ৳ ${amt.toStringAsFixed(0)}',
                          style: TextStyle(
                            color: color,
                            fontWeight: FontWeight.w800,
                            fontSize: 13.5,
                          ),
                        ),
                        Text(
                          'Bal: ৳ ${balAfter.toStringAsFixed(0)}',
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String msg) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.55)),
      ),
      child: Text(
        msg,
        style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
      ),
    );
  }

  InputDecoration _inputStyle(String label, String hint, IconData icon) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Colors.white60, fontSize: 13),
      hintStyle: const TextStyle(color: Colors.white38, fontSize: 12.5),
      prefixIcon: Icon(icon, color: Colors.white54, size: 20),
      filled: true,
      fillColor: const Color(0xFF0F172A),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFFF5722), width: 1.4),
      ),
    );
  }
}
