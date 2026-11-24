import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CounterVerifyScreen extends StatefulWidget {
  const CounterVerifyScreen({super.key});

  @override
  State<CounterVerifyScreen> createState() => _CounterVerifyScreenState();
}

class _CounterVerifyScreenState extends State<CounterVerifyScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _lookupCtrl = TextEditingController();

  static final RegExp _uuidRegex = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );
  static final RegExp _hexNonceRegex = RegExp(r'^[0-9a-fA-F]{16,128}$');
  static final RegExp _digitsOnlyRegex = RegExp(r'^\d+$');

  bool _didInit = false;
  bool _isSearching = false;
  bool _isMetaLoading = false;
  bool _isCompleting = false;

  /// Physical bag checklist (QR cryptographic verification is enforced server-side)
  bool _verifiedItemsPacked = false;

  String? _lookupError;
  String? _actionError;
  String? _currentStaffId;

  Map<String, dynamic>? _currentOrder;
  String _studentName = '';
  String _username = '';
  String _studentId = '';
  String _studentPhone = '';
  List<Map<String, dynamic>> _orderItems = <Map<String, dynamic>>[];

  /// Single-row Realtime subscription to stay synced if another staff completes it
  StreamSubscription<List<Map<String, dynamic>>>? _orderSub;

  @override
  void initState() {
    super.initState();
    final User? user = _supabase.auth.currentUser;
    if (user == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
      });
      return;
    }
    _currentStaffId = user.id;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;

    // Preloaded order from [P12] CounterQueueScreen (for packing preview prior to QR scan)
    final Object? args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['order'] is Map) {
      final Map<String, dynamic> order = Map<String, dynamic>.from(
        args['order'] as Map<dynamic, dynamic>,
      );

      final String? preName = args['student_name'] as String?;
      final String? preUser = args['username'] as String?;
      final String? preSid = args['student_id'] as String?;
      final List<Map<String, dynamic>>? preItems = args['items'] is List
          ? (args['items'] as List<dynamic>)
                .whereType<Map>()
                .map((Map<dynamic, dynamic> e) => Map<String, dynamic>.from(e))
                .toList()
          : null;

      _lookupCtrl.text = (order['token_number'] as String?) ?? '';
      _bindOrderAndSync(
        order: order,
        preloadedName: preName,
        preloadedUsername: preUser,
        preloadedStudentId: preSid,
        preloadedItems: preItems,
      );
    }
  }

  /// Checks whether this operator verified the student's live 30s QR within the last 3 minutes
  bool _hasFreshQrVerification(Map<String, dynamic>? order) {
    if (order == null || _currentStaffId == null) return false;
    final String? verifiedBy = order['qr_verified_by']?.toString();
    final String? rawVerifiedAt = order['qr_verified_at'] as String?;
    if (verifiedBy != _currentStaffId || rawVerifiedAt == null) return false;

    final DateTime? verifiedAt = DateTime.tryParse(rawVerifiedAt)?.toUtc();
    if (verifiedAt == null) return false;

    final Duration age = DateTime.now().toUtc().difference(verifiedAt);
    return age.inSeconds <= 180; // Matches PostgreSQL 3-minute handover window
  }

  /// Opens the live Camera QR Scanner and immediately verifies the scanned 30s nonce
  Future<void> _openCameraScanner() async {
    if (_isSearching || _isCompleting) return;

    final String? scannedRaw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const _PickupQrScannerPage()),
    );

    if (!mounted || scannedRaw == null || scannedRaw.trim().isEmpty) return;
    await _verifyScannedQrPayload(scannedRaw.trim());
  }

  /// Parses "SWIFTSERVE:<order_uuid>:<hex_nonce>" and invokes RPC `verify_pickup_qr`
  Future<void> _verifyScannedQrPayload(String rawPayload) async {
    FocusScope.of(context).unfocus();

    final List<String> parts = rawPayload.split(':');
    if (parts.length != 3 ||
        parts[0] != 'SWIFTSERVE' ||
        !_uuidRegex.hasMatch(parts[1]) ||
        !_hexNonceRegex.hasMatch(parts[2])) {
      setState(() {
        _lookupError =
            'INVALID QR CODE: Not a valid SwiftServe live pickup pass.';
        _actionError = null;
      });
      return;
    }

    final String scannedOrderId = parts[1];
    final String scannedNonce = parts[2];

    // If staff pre-opened a specific order from [P12], warn if QR belongs to a different order
    final String? preselectedId = _currentOrder?['id']?.toString();
    if (preselectedId != null && preselectedId != scannedOrderId) {
      // Allow switching cleanly to the scanned order, while informing staff via SnackBar
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.amber,
          content: Text(
            'Scanned QR belongs to a different order — switched view to scanned order.',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }

    setState(() {
      _isSearching = true;
      _lookupError = null;
      _actionError = null;
    });

    try {
      final dynamic raw = await _supabase
          .rpc(
            'verify_pickup_qr',
            params: <String, dynamic>{
              'p_order_id': scannedOrderId,
              'p_qr_token': scannedNonce,
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      if (raw is! Map) {
        setState(
          () => _lookupError = 'Unexpected server response for QR scan.',
        );
        return;
      }

      final Map<String, dynamic> verifiedOrder = Map<String, dynamic>.from(raw);
      _lookupCtrl.text = (verifiedOrder['token_number'] as String?) ?? '';

      await _bindOrderAndSync(order: verifiedOrder);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text(
            'Live QR verified for ${verifiedOrder['token_number']}! Check bag items and confirm handover.',
          ),
        ),
      );
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _lookupError = 'QR verification timed out. Ask student to keep QR open and scan again.',
        );
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() => _lookupError = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _lookupError = 'Could not verify QR code. Check campus Wi-Fi.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  /// Manual token/QR lookup (for packing preview or pasting a live QR payload)
  Future<void> _handleLookup() async {
    final String rawInput = _lookupCtrl.text.trim();
    if (rawInput.isEmpty) {
      setState(
        () => _lookupError =
            'Tap Open Camera Scanner or enter a token number (e.g., 1005).',
      );
      return;
    }

    // If someone pasted a full SWIFTSERVE:<uuid>:<nonce> string, route straight to QR RPC
    if (rawInput.startsWith('SWIFTSERVE:')) {
      await _verifyScannedQrPayload(rawInput);
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isSearching = true;
      _lookupError = null;
      _actionError = null;
    });

    try {
      Map<String, dynamic>? foundOrder;

      if (_uuidRegex.hasMatch(rawInput)) {
        final dynamic row = await _supabase
            .from('orders')
            .select()
            .eq('id', rawInput)
            .maybeSingle()
            .timeout(const Duration(seconds: 8));
        if (row is Map) {
          foundOrder = Map<String, dynamic>.from(row);
        }
      } else {
        String normalized = rawInput.toUpperCase();
        if (_digitsOnlyRegex.hasMatch(normalized)) {
          normalized = '#SW-$normalized';
        } else if (normalized.startsWith('SW-')) {
          normalized = '#$normalized';
        }

        // Fixed cardinality: order by newest & limit(1) before maybeSingle()
        final dynamic row = await _supabase
            .from('orders')
            .select()
            .ilike('token_number', normalized)
            .order('created_at', ascending: false)
            .limit(1)
            .maybeSingle()
            .timeout(const Duration(seconds: 8));

        if (row is Map) {
          foundOrder = Map<String, dynamic>.from(row);
        }
      }

      if (!mounted) return;

      if (foundOrder == null) {
        await _clearCurrentOrder();
        setState(() {
          _lookupError =
              'No order found matching "$rawInput". Verify token and retry.';
        });
        return;
      }

      await _bindOrderAndSync(order: foundOrder);
    } on TimeoutException {
      if (mounted) {
        setState(() => _lookupError = 'Lookup timed out. Check campus Wi-Fi.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _lookupError = 'Order lookup failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  /// Binds order, cancels prior subscription, and attaches single-row Realtime sync
  Future<void> _bindOrderAndSync({
    required Map<String, dynamic> order,
    String? preloadedName,
    String? preloadedUsername,
    String? preloadedStudentId,
    List<Map<String, dynamic>>? preloadedItems,
  }) async {
    await _orderSub?.cancel();
    if (!mounted) return;

    final String orderId = order['id'].toString();
    final String userId = order['user_id'].toString();
    final bool hasPreloadedMeta =
        preloadedName != null && preloadedItems != null;

    setState(() {
      _currentOrder = order;
      _lookupError = null;
      _actionError = null;
      _verifiedItemsPacked = false;
      _studentName = preloadedName ?? '';
      _username = preloadedUsername ?? '';
      _studentId = preloadedStudentId ?? '';
      _studentPhone = '';
      _orderItems = preloadedItems ?? <Map<String, dynamic>>[];
      _isMetaLoading = !hasPreloadedMeta;
    });

    _orderSub = _supabase
        .from('orders')
        .stream(primaryKey: <String>['id'])
        .eq('id', orderId)
        .listen(
          (List<Map<String, dynamic>> rows) {
            if (!mounted || rows.isEmpty) return;
            setState(
              () => _currentOrder = Map<String, dynamic>.from(rows.first),
            );
          },
          onError: (_) {
            // Server-side RPC guards remain authoritative even if stream hiccups
          },
        );

    if (!hasPreloadedMeta) {
      await _fetchStudentAndItems(orderId, userId);
    }
  }

  Future<void> _fetchStudentAndItems(String orderId, String userId) async {
    try {
      final List<dynamic> results = await Future.wait<dynamic>(
        <Future<dynamic>>[
          _supabase
              .from('profiles')
              .select('first_name, last_name, username, student_id, phone')
              .eq('id', userId)
              .maybeSingle()
              .timeout(const Duration(seconds: 8)),
          _supabase
              .from('order_items')
              .select('item_name_snapshot, quantity, subtotal')
              .eq('order_id', orderId)
              .timeout(const Duration(seconds: 8)),
        ],
      );

      if (!mounted || _currentOrder?['id'].toString() != orderId) return;

      final Map<String, dynamic>? profile = results[0] is Map
          ? Map<String, dynamic>.from(results[0] as Map<dynamic, dynamic>)
          : null;

      final List<Map<String, dynamic>> items = results[1] is List
          ? (results[1] as List<dynamic>)
                .whereType<Map>()
                .map((Map<dynamic, dynamic> e) => Map<String, dynamic>.from(e))
                .toList()
          : <Map<String, dynamic>>[];

      final String first = (profile?['first_name'] as String?)?.trim() ?? '';
      final String last = (profile?['last_name'] as String?)?.trim() ?? '';
      final String full = '$first $last'.trim();

      setState(() {
        _studentName = full.isEmpty ? 'Unknown Student' : full;
        _username = (profile?['username'] as String?)?.trim() ?? '';
        _studentId = (profile?['student_id'] as String?)?.trim() ?? '';
        _studentPhone = (profile?['phone'] as String?)?.trim() ?? '';
        _orderItems = items;
        _isMetaLoading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isMetaLoading = false;
          _actionError =
              'Could not load complete student or item list. Retry lookup.';
        });
      }
    }
  }

  /// Final Atomic Handover RPC: ready -> completed (requires recent QR verification)
  Future<void> _handleConfirmHandover() async {
    if (_isCompleting || _currentOrder == null) return;
    final String orderId = _currentOrder!['id'].toString();
    final String token = (_currentOrder!['token_number'] as String?) ?? '#SW';
    final String status = (_currentOrder!['status'] as String?) ?? '';

    if (status != 'ready' ||
        !_hasFreshQrVerification(_currentOrder) ||
        !_verifiedItemsPacked) {
      return;
    }

    setState(() {
      _isCompleting = true;
      _actionError = null;
    });

    try {
      await _supabase
          .rpc(
            'complete_order_handover',
            params: <String, dynamic>{'p_order_id': orderId},
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      setState(() {
        _currentOrder = <String, dynamic>{
          ..._currentOrder!,
          'status': 'completed',
          'completed_at': DateTime.now().toUtc().toIso8601String(),
        };
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text('Order $token verified & handed over successfully!'),
        ),
      );
    } on TimeoutException {
      if (mounted) {
        setState(
          () => _actionError = 'Handover timed out. Check order status before handing over food.',
        );
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() => _actionError = e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _actionError = 'Handover failed. Check network connection.',
        );
      }
    } finally {
      if (mounted) setState(() => _isCompleting = false);
    }
  }

  Future<void> _clearCurrentOrder() async {
    await _orderSub?.cancel();
    _orderSub = null;
    if (!mounted) return;
    setState(() {
      _currentOrder = null;
      _orderItems = <Map<String, dynamic>>[];
      _verifiedItemsPacked = false;
      _actionError = null;
    });
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
    _orderSub?.cancel();
    _lookupCtrl.dispose();
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
          'Verify & Handover',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        actions: [
          if (_currentOrder != null)
            TextButton(
              onPressed: _isCompleting
                  ? null
                  : () {
                      _lookupCtrl.clear();
                      _clearCurrentOrder();
                    },
              child: const Text('Clear'),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildScannerAndLookupBox(),
                  if (_lookupError != null) ...[
                    const SizedBox(height: 14),
                    _buildAlertBox(
                      icon: Icons.gpp_bad_rounded,
                      color: Colors.redAccent,
                      title: 'QR Verification / Lookup Error',
                      message: _lookupError!,
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (_currentOrder == null)
                    _buildEmptyInstructionsCard()
                  else ...[
                    _buildStateBanner(_currentOrder!),
                    const SizedBox(height: 14),
                    _buildOrderVerificationCard(_currentOrder!),
                    if (_actionError != null) ...[
                      const SizedBox(height: 14),
                      _buildAlertBox(
                        icon: Icons.error_outline,
                        color: Colors.redAccent,
                        title: 'Action Blocked',
                        message: _actionError!,
                      ),
                    ],
                    const SizedBox(height: 16),
                    _buildBottomActionSection(_currentOrder!),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Primary Camera Scanner CTA + Secondary Token Packing Lookup
  Widget _buildScannerAndLookupBox() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _isSearching || _isCompleting
                  ? null
                  : _openCameraScanner,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF5722),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _isSearching
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.qr_code_scanner_rounded, size: 24),
              label: Text(
                _isSearching
                    ? 'VERIFYING LIVE PICKUP QR...'
                    : 'OPEN CAMERA SCANNER',
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'OR INSPECT ORDER BY TOKEN NUMBER (PACKING PREVIEW)',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10.5,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _lookupCtrl,
                  enabled: !_isSearching && !_isCompleting,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _handleLookup(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                  decoration: InputDecoration(
                    hintText: 'e.g., 1005 or #SW-1005',
                    hintStyle: const TextStyle(
                      color: Colors.white38,
                      fontSize: 13,
                    ),
                    prefixIcon: const Icon(
                      Icons.tag_rounded,
                      color: Colors.white54,
                      size: 19,
                    ),
                    filled: true,
                    fillColor: const Color(0xFF0F172A),
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 46,
                child: OutlinedButton(
                  onPressed: _isSearching || _isCompleting
                      ? null
                      : _handleLookup,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text(
                    'LOOKUP',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Dynamic Anti-Replay Status Banner
  Widget _buildStateBanner(Map<String, dynamic> order) {
    final String status = (order['status'] as String?) ?? '';
    final bool qrVerified = _hasFreshQrVerification(order);

    switch (status) {
      case 'ready':
        if (qrVerified) {
          return _buildAlertBox(
            icon: Icons.verified_rounded,
            color: Colors.greenAccent,
            title: 'LIVE QR VERIFIED • SINGLE-USE TOKEN BURNED',
            message: 'Student ownership confirmed via 30s rotating QR. Verify packed bag items below and tap Confirm Handover.',
          );
        }
        return _buildAlertBox(
          icon: Icons.qr_code_2_rounded,
          color: Colors.amber,
          title: 'QR SCAN REQUIRED BEFORE HANDOVER',
          message: 'Order is ready in the pickup queue. Tap "Open Camera Scanner" to scan the student\'s live 30-second QR code to unlock handover.',
        );
      case 'completed':
        return _buildAlertBox(
          icon: Icons.block_rounded,
          color: Colors.redAccent,
          title: 'ALREADY CLAIMED — DO NOT HAND OVER AGAIN',
          message:
              'Completed at ${_formatTimestamp(order['completed_at'] as String?)}. Duplicate handover is permanently blocked.',
        );
      case 'cancelled':
        return _buildAlertBox(
          icon: Icons.cancel_rounded,
          color: Colors.redAccent,
          title: 'ORDER CANCELLED & REFUNDED',
          message:
              'Do NOT serve this order. Reason: ${(order['cancel_reason'] as String?) ?? 'Cancelled'}.',
        );
      case 'preparing':
        return _buildAlertBox(
          icon: Icons.local_fire_department_rounded,
          color: const Color(0xFFFF5722),
          title: 'STILL PREPARING IN KITCHEN',
          message: 'Kitchen has not marked this order READY yet. Handover is locked.',
        );
      default:
        return _buildAlertBox(
          icon: Icons.hourglass_top_rounded,
          color: Colors.amber,
          title: 'PENDING IN KITCHEN QUEUE',
          message: 'Chef has not started preparing this order yet. Handover is locked.',
        );
    }
  }

  /// Order Token, QR Verification Badge, Student Info, and Item Checklist
  Widget _buildOrderVerificationCard(Map<String, dynamic> order) {
    final String token = (order['token_number'] as String?) ?? '#SW';
    final double total = (order['total_amount'] as num?)?.toDouble() ?? 0.0;
    final String notes = (order['customer_notes'] as String?)?.trim() ?? '';
    final String status = (order['status'] as String?) ?? '';
    final bool qrVerified = _hasFreshQrVerification(order);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: status == 'ready' && qrVerified
              ? Colors.greenAccent.withValues(alpha: 0.65)
              : Colors.white.withValues(alpha: 0.1),
          width: 1.4,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    token,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Paid via Wallet: ৳ ${total.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Color(0xFFFF5722),
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: (qrVerified ? Colors.greenAccent : Colors.amber)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: qrVerified ? Colors.greenAccent : Colors.amber,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      qrVerified
                          ? Icons.verified_user_rounded
                          : Icons.qr_code_scanner_rounded,
                      size: 15,
                      color: qrVerified ? Colors.greenAccent : Colors.amber,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      qrVerified ? 'QR VERIFIED' : 'AWAITING QR',
                      style: TextStyle(
                        color: qrVerified ? Colors.greenAccent : Colors.amber,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(color: Colors.white12, height: 1),
          ),
          if (_isMetaLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFFFF5722),
                ),
              ),
            )
          else ...[
            const Text(
              'STUDENT OWNER',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _studentName.isNotEmpty ? _studentName : 'Student',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              [
                if (_username.isNotEmpty) '@$_username',
                if (_studentId.isNotEmpty) 'ID: $_studentId',
                if (_studentPhone.isNotEmpty) _studentPhone,
              ].join('  •  '),
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12.5,
                fontFamily: 'monospace',
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Divider(color: Colors.white12, height: 1),
            ),
            const Text(
              'ITEMS TO HAND OVER',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.9,
              ),
            ),
            const SizedBox(height: 10),
            ..._orderItems.map((Map<String, dynamic> item) {
              final int qty = (item['quantity'] as num?)?.toInt() ?? 1;
              final String name =
                  (item['item_name_snapshot'] as String?) ?? 'Item';
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '${qty}x',
                        style: const TextStyle(
                          color: Colors.greenAccent,
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
            }),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'Customer Note: $notes',
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 12.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// Handover Controls: Scan QR (if not verified) -> Check Bag -> Confirm Handover
  Widget _buildBottomActionSection(Map<String, dynamic> order) {
    final String status = (order['status'] as String?) ?? '';
    final bool isReady = status == 'ready';
    final bool qrVerified = _hasFreshQrVerification(order);
    final bool canConfirm =
        isReady && qrVerified && _verifiedItemsPacked && !_isCompleting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isReady && !qrVerified) ...[
          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _isSearching ? null : _openCameraScanner,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade700,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.qr_code_scanner_rounded, size: 22),
              label: const Text(
                'SCAN STUDENT\'S LIVE QR TO UNLOCK',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ] else if (isReady && qrVerified) ...[
          // Uses Material canvas so CheckboxListTile triggers zero ListTile assertions
          Material(
            color: const Color(0xFF1E293B),
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: CheckboxListTile(
              value: _verifiedItemsPacked,
              activeColor: Colors.green.shade600,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Checked all food items & quantities in bag',
                style: TextStyle(color: Colors.white, fontSize: 13.5),
              ),
              onChanged: _isCompleting
                  ? null
                  : (bool? val) =>
                        setState(() => _verifiedItemsPacked = val == true),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: canConfirm ? _handleConfirmHandover : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade600,
                disabledBackgroundColor: Colors.white12,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _isCompleting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check_circle_rounded, size: 22),
              label: Text(
                _isCompleting
                    ? 'COMPLETING HANDOVER...'
                    : 'CONFIRM HANDOVER (MARK COMPLETED)',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _openCameraScanner,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 19),
                    label: const Text(
                      'SCAN NEXT ORDER',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
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
                    child: const Text('BACK TO QUEUE'),
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: _isCompleting
              ? null
              : () =>
                    Navigator.of(context)
                        .pushNamed('/counter/disputes', arguments: order),
          icon: const Icon(
            Icons.report_problem_outlined,
            color: Colors.amber,
            size: 18,
          ),
          label: const Text(
            'Item missing or mismatch? Log Shift Dispute',
            style: TextStyle(color: Colors.amber, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildAlertBox({
    required IconData icon,
    required Color color,
    required String title,
    required String message,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.65)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyInstructionsCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        children: [
          Icon(
            Icons.qr_code_scanner_rounded,
            size: 54,
            color: Colors.white.withValues(alpha: 0.22),
          ),
          const SizedBox(height: 14),
          const Text(
            'Ready to Scan Pickup QR',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Tap "Open Camera Scanner" to scan the student\'s 30-second auto-regenerating Pickup QR. Expired screenshots and already-claimed orders are automatically blocked.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.45),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Fullscreen Live Camera QR Scanner Page (Android, iOS & Web Compatible)
// =============================================================================

class _PickupQrScannerPage extends StatefulWidget {
  const _PickupQrScannerPage();

  @override
  State<_PickupQrScannerPage> createState() => _PickupQrScannerPageState();
}

class _PickupQrScannerPageState extends State<_PickupQrScannerPage> {
  final MobileScannerController _scannerController = MobileScannerController(
    formats: const <BarcodeFormat>[BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final Barcode barcode in capture.barcodes) {
      final String? value = barcode.rawValue?.trim();
      if (value != null && value.isNotEmpty) {
        _handled = true;
        _scannerController.stop();
        if (mounted) {
          Navigator.of(context).pop<String>(value);
        }
        return;
      }
    }
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        foregroundColor: Colors.white,
        title: const Text(
          'Scan Student Pickup QR',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Toggle Flash',
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _scannerController.toggleTorch(),
          ),
          IconButton(
            tooltip: 'Switch Camera',
            icon: const Icon(Icons.cameraswitch_rounded),
            onPressed: () => _scannerController.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _scannerController, onDetect: _onDetect),
          // Centered high-contrast target viewfinder
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFFF5722), width: 3),
                ),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 32,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              child: const Text(
                'Align the student\'s live 30-second Pickup QR inside the orange frame.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
