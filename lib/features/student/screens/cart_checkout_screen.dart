import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class CartCheckoutScreen extends StatefulWidget {
  const CartCheckoutScreen({super.key});

  @override
  State<CartCheckoutScreen> createState() => _CartCheckoutScreenState();
}

class _CartCheckoutScreenState extends State<CartCheckoutScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _notesCtrl = TextEditingController();

  bool _didInit = false;
  bool _isSubmitting = false;
  String? _errorMessage;

  /// বর্তমান কার্ট আইটেমসমূহ (P04 থেকে আসা পেলোডের লোকাল কপি)
  List<Map<String, dynamic>> _cartItems = <Map<String, dynamic>>[];

  /// প্রতিটি স্বতন্ত্র কার্ট স্টেটের জন্য এককালীন Idempotency Key (Retry-Safe)
  late String _idempotencyKey;

  /// লাইভ ওয়ালেট ব্যালেন্স স্ট্রিম (WebSocket Thrashing রোধে একবারই তৈরি হবে)
  late final Stream<List<Map<String, dynamic>>> _walletStream;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = _generateUuidV4();

    final User? currentUser = _supabase.auth.currentUser;
    if (currentUser == null) {
      _walletStream = const Stream<List<Map<String, dynamic>>>.empty();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/login',
          (Route<dynamic> route) => false,
        );
      });
    } else {
      _walletStream = _supabase
          .from('wallets')
          .stream(primaryKey: <String>['user_id'])
          .eq('user_id', currentUser.id);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;

    final Object? args = ModalRoute.of(context)?.settings.arguments;
    if (args is List) {
      _cartItems = args
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> e) => Map<String, dynamic>.from(e))
          .toList();
    }
  }

  /// ক্রিপ্টোগ্রাফিকভাবে নিরাপদ RFC-4122 UUID v4 জেনারেটর (Zero External Package)
  String _generateUuidV4() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    // Version 4 (0100xxxx) এবং RFC-4122 Variant (10xxxxxx) বিট সেট করা
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

  /// কার্টের আনুমানিক মোট বিল (শুধু UI প্রিভিউ; আসল হিসাব সার্ভার RPC করবে)
  double get _estimatedTotal {
    double sum = 0.0;
    for (final Map<String, dynamic> item in _cartItems) {
      final double price = (item['price'] as num?)?.toDouble() ?? 0.0;
      final int qty = (item['quantity'] as num?)?.toInt() ?? 0;
      sum += price * qty;
    }
    return sum;
  }

  /// কার্ট পরিবর্তন হলে নতুন Idempotency Key তৈরি করতে হয় (নতুন অর্ডার ইন্টেন্ট)
  void _updateQuantity(int index, int delta) {
    if (_isSubmitting) return;
    final Map<String, dynamic> item = _cartItems[index];
    final int currentQty = (item['quantity'] as num?)?.toInt() ?? 1;
    final int maxStock = (item['stock_quantity'] as num?)?.toInt() ?? 99;
    final int nextQty = currentQty + delta;

    if (nextQty > maxStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Only $maxStock available in stock.')),
      );
      return;
    }

    setState(() {
      _errorMessage = null;
      _idempotencyKey = _generateUuidV4();
      if (nextQty <= 0) {
        _cartItems.removeAt(index);
      } else {
        item['quantity'] = nextQty;
      }
    });
  }

  /// P04-এ ফেরত পাঠানোর জন্য আপডেটেড কার্ট ম্যাপ তৈরি
  Map<String, int> _buildUpdatedCartMap() {
    final Map<String, int> result = <String, int>{};
    for (final Map<String, dynamic> item in _cartItems) {
      final String id = item['menu_item_id'].toString();
      final int qty = (item['quantity'] as num?)?.toInt() ?? 0;
      if (qty > 0) result[id] = qty;
    }
    return result;
  }

  void _popWithUpdatedCart() {
    if (_isSubmitting) return;
    Navigator.of(context).pop<Map<String, int>>(_buildUpdatedCartMap());
  }

  /// মূল Atomic Checkout ফাংশন (Supabase RPC: place_order_atomic)
  Future<void> _handleAtomicCheckout() async {
    if (_isSubmitting || _cartItems.isEmpty) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      // নিরাপত্তা: সার্ভারে কেবল menu_item_id ও quantity পাঠানো হবে (দাম কখনোই নয়!)
      final List<Map<String, dynamic>> rpcItems = _cartItems
          .map(
            (Map<String, dynamic> item) => <String, dynamic>{
              'menu_item_id': item['menu_item_id'].toString(),
              'quantity': (item['quantity'] as num).toInt(),
            },
          )
          .toList();

      final dynamic rawResponse = await _supabase.rpc(
        'place_order_atomic',
        params: <String, dynamic>{
          'p_items': rpcItems,
          'p_customer_notes': _notesCtrl.text.trim(),
          'p_idempotency_key': _idempotencyKey,
        },
      ).timeout(const Duration(seconds: 12));

      if (!mounted) return;

      final Map<String, dynamic> orderResult = rawResponse is Map
          ? Map<String, dynamic>.from(rawResponse)
          : <String, dynamic>{};

      // স্ট্যাক রিপ্লেস করে [P07] Tracker-এ যাও এবং একই সাথে [P04]-এর কার্ট ক্লিয়ার করো
      Navigator.of(context).pushReplacementNamed(
        '/student/order-tracker',
        result: 'order_placed',
        arguments: orderResult,
      );
    } on TimeoutException {
      // একই _idempotencyKey অক্ষত থাকায় ইউজার নিরাপদে আবার চাপতে পারবে
      _showError(
        'Network timed out. Tap Pay again safely — your order is protected against double charge.',
      );
    } on PostgrestException catch (e) {
      // সার্ভারের সুনির্দিষ্ট এরর (যেমন: Insufficient stock, Insufficient balance, Suspended)
      _showError(e.message);
    } catch (_) {
      _showError('Checkout failed. Check your connection and try again.');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: পরিষ্কার, মডুলার এবং ট্রানজ্যাকশন-নিরাপদ লেআউট
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || _isSubmitting) return;
        _popWithUpdatedCart();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0F172A),
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _isSubmitting ? null : _popWithUpdatedCart,
          ),
          title: const Text(
            'Cart & Checkout',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
        body: _cartItems.isEmpty
            ? _buildEmptyCartState()
            : StreamBuilder<List<Map<String, dynamic>>>(
                stream: _walletStream,
                builder: (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> walletSnap,
                ) {
                  final bool walletLoaded =
                      walletSnap.data != null && walletSnap.data!.isNotEmpty;
                  final double liveBalance = walletLoaded
                      ? ((walletSnap.data!.first['balance'] as num?)?.toDouble() ??
                          0.0)
                      : 0.0;
                  final double total = _estimatedTotal;
                  final bool hasSufficientFunds =
                      walletLoaded && liveBalance >= total;

                  return Column(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_errorMessage != null) _buildErrorBanner(),
                              _buildSectionTitle(
                                'ORDER ITEMS (${_cartItems.length})',
                              ),
                              const SizedBox(height: 10),
                              ...List<Widget>.generate(
                                _cartItems.length,
                                (int i) => _buildCartItemCard(i),
                              ),
                              const SizedBox(height: 18),
                              _buildSectionTitle('KITCHEN NOTE (OPTIONAL)'),
                              const SizedBox(height: 8),
                              _buildNotesField(),
                              const SizedBox(height: 20),
                              _buildSectionTitle('ATOMIC WALLET SUMMARY'),
                              const SizedBox(height: 10),
                              _buildWalletSummaryCard(
                                walletLoaded: walletLoaded,
                                liveBalance: liveBalance,
                                total: total,
                                hasSufficientFunds: hasSufficientFunds,
                              ),
                            ],
                          ),
                        ),
                      ),
                      _buildPayFooter(
                        walletLoaded: walletLoaded,
                        hasSufficientFunds: hasSufficientFunds,
                        total: total,
                        shortage: total - liveBalance,
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
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
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.55)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// প্রতিটি কার্ট আইটেম কার্ড (+ / - স্টেপারসহ)
  Widget _buildCartItemCard(int index) {
    final Map<String, dynamic> item = _cartItems[index];
    final String name = (item['name'] as String?) ?? 'Item';
    final double unitPrice = (item['price'] as num?)?.toDouble() ?? 0.0;
    final int qty = (item['quantity'] as num?)?.toInt() ?? 1;
    final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '৳ ${unitPrice.toStringAsFixed(0)} × $qty  =  ৳ ${(unitPrice * qty).toStringAsFixed(0)}',
                  style: const TextStyle(
                    color: Color(0xFFFF5722),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Available stock: $stock',
                  style: const TextStyle(color: Colors.white38, fontSize: 11.5),
                ),
              ],
            ),
          ),
          // কোয়ান্টিটি স্টেপার
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  padding: EdgeInsets.zero,
                  icon: Icon(
                    qty == 1 ? Icons.delete_outline : Icons.remove,
                    size: 18,
                    color: qty == 1 ? Colors.redAccent : Colors.white,
                  ),
                  onPressed:
                      _isSubmitting ? null : () => _updateQuantity(index, -1),
                ),
                SizedBox(
                  width: 24,
                  child: Text(
                    '$qty',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.add, size: 18, color: Colors.white),
                  onPressed:
                      _isSubmitting ? null : () => _updateQuantity(index, 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// কিচেনের জন্য ঐচ্ছিক নোট ফিল্ড
  Widget _buildNotesField() {
    return TextField(
      controller: _notesCtrl,
      enabled: !_isSubmitting,
      maxLength: 150,
      maxLines: 2,
      onChanged: (_) {
        // নোট বদলালে নতুন অর্ডার ইন্টেন্ট হিসেবে নতুন Idempotency Key তৈরি হবে
        _idempotencyKey = _generateUuidV4();
      },
      style: const TextStyle(color: Colors.white, fontSize: 13.5),
      decoration: InputDecoration(
        hintText: 'e.g., Less spicy, extra sauce, no onions...',
        hintStyle: const TextStyle(color: Colors.white38),
        counterStyle: const TextStyle(color: Colors.white38, fontSize: 11),
        filled: true,
        fillColor: const Color(0xFF1E293B),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFFF5722), width: 1.4),
        ),
      ),
    );
  }

  /// লাইভ ওয়ালেট ব্যালেন্স বনাম অর্ডার বিলের তুলনা কার্ড
  Widget _buildWalletSummaryCard({
    required bool walletLoaded,
    required double liveBalance,
    required double total,
    required bool hasSufficientFunds,
  }) {
    final double remaining = liveBalance - total;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: !walletLoaded
              ? Colors.white12
              : (hasSufficientFunds
                  ? Colors.green.withValues(alpha: 0.45)
                  : Colors.redAccent.withValues(alpha: 0.55)),
        ),
      ),
      child: Column(
        children: [
          _buildSummaryRow(
            'Order Total (Server Verified)',
            '৳ ${total.toStringAsFixed(2)}',
            valueColor: Colors.white,
          ),
          const SizedBox(height: 10),
          _buildSummaryRow(
            'Live Wallet Balance',
            walletLoaded ? '৳ ${liveBalance.toStringAsFixed(2)}' : 'Loading...',
            valueColor: hasSufficientFunds ? Colors.greenAccent : Colors.redAccent,
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Colors.white12, height: 1),
          ),
          _buildSummaryRow(
            hasSufficientFunds ? 'Balance After Payment' : 'Shortfall Amount',
            walletLoaded
                ? '৳ ${remaining.abs().toStringAsFixed(2)}'
                : '...',
            isBold: true,
            valueColor: hasSufficientFunds
                ? Colors.white
                : const Color(0xFFFCA5A5),
          ),
          if (walletLoaded && !hasSufficientFunds) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.amber,
                  size: 18,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Insufficient wallet balance. Top up at the canteen counter.',
                    style: TextStyle(color: Colors.amber, fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pushNamed('/student/wallet'),
                  child: const Text('Wallet'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryRow(
    String label,
    String value, {
    required Color valueColor,
    bool isBold = false,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: isBold ? Colors.white : Colors.white70,
            fontSize: isBold ? 14 : 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: isBold ? 16 : 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// স্টিকি পেমেন্ট বাটন (অপর্যাপ্ত ব্যালেন্স বা প্রসেসিং অবস্থায় সম্পূর্ণ লক)
  Widget _buildPayFooter({
    required bool walletLoaded,
    required bool hasSufficientFunds,
    required double total,
    required double shortage,
  }) {
    final bool canPay = walletLoaded && hasSufficientFunds && !_isSubmitting;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: canPay ? _handleAtomicCheckout : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF5722),
                  disabledBackgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _isSubmitting
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
                  _isSubmitting
                      ? 'PROCESSING ATOMIC PAYMENT...'
                      : !walletLoaded
                          ? 'SYNCING WALLET...'
                          : hasSufficientFunds
                              ? 'PAY ৳ ${total.toStringAsFixed(0)} WITH WALLET'
                              : 'INSUFFICIENT BALANCE (NEED ৳ ${shortage.toStringAsFixed(0)})',
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Protected by server-side atomic locking & idempotency verification.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.42),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// কার্ট থেকে সব আইটেম মুছে ফেললে নিরাপদ এম্পটি ভিউ
  Widget _buildEmptyCartState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.shopping_cart_outlined,
              size: 60,
              color: Colors.white.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 14),
            const Text(
              'Your cart is empty.',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Add food items from the canteen menu to place an order.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13.5),
            ),
            const SizedBox(height: 22),
            ElevatedButton(
              onPressed: _popWithUpdatedCart,
              child: const Text('Back to Menu'),
            ),
          ],
        ),
      ),
    );
  }
}