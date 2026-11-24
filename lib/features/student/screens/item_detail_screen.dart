import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ItemDetailScreen extends StatefulWidget {
  const ItemDetailScreen({super.key});

  @override
  State<ItemDetailScreen> createState() => _ItemDetailScreenState();
}

class _ItemDetailScreenState extends State<ItemDetailScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _didInit = false;
  Map<String, dynamic>? _initialItem;
  int _initialCartQty = 0;
  int _selectedQty = 1;

  Stream<List<Map<String, dynamic>>>? _itemStream;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ModalRoute আর্গুমেন্ট কেবল didChangeDependencies()-এ নিরাপদে পড়া যায় (একবারই চলবে)
    if (_didInit) return;
    _didInit = true;

    final Object? args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map<String, dynamic> && args['item'] is Map<String, dynamic>) {
      final Map<String, dynamic> item = Map<String, dynamic>.from(
        args['item'] as Map<String, dynamic>,
      );
      final int currentQty = (args['currentQty'] as num?)?.toInt() ?? 0;
      final String itemId = item['id']?.toString() ?? '';

      _initialItem = item;
      _initialCartQty = currentQty < 0 ? 0 : currentQty;
      // আগে কার্টে না থাকলে ১-ট্যাপ অ্যাডের জন্য ডিফল্ট 1, আর কার্টে থাকলে currentQty দেখাবে
      _selectedQty = _initialCartQty > 0 ? _initialCartQty : 1;

      if (itemId.isNotEmpty) {
        // নির্দিষ্ট ১টি রো-এর ওপর প্রাইমারি-কী ফিল্টার্ড Realtime Stream (O(1) Payload)
        _itemStream = _supabase
            .from('menu_items')
            .stream(primaryKey: <String>['id'])
            .eq('id', itemId);
      }
    }
  }

  /// কোয়ান্টিটি বাড়ানো (সর্বদা লাইভ স্টকের সীমার মধ্যে)
  void _incrementQty(int maxStock) {
    if (_selectedQty >= maxStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Maximum available stock is $maxStock.'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() => _selectedQty += 1);
  }

  /// কোয়ান্টিটি কমানো (আগে কার্টে থাকলে 0 করে রিমুভ করার সুযোগ থাকবে, নাহলে সর্বনিম্ন 1)
  void _decrementQty() {
    final int minQty = _initialCartQty > 0 ? 0 : 1;
    if (_selectedQty <= minQty) return;
    setState(() => _selectedQty -= 1);
  }

  /// [P04] StudentHomeScreen-এ চূড়ান্ত কোয়ান্টিটি ফেরত পাঠানো
  void _confirmAndReturn(int finalQty) {
    Navigator.of(context).pop<int>(finalQty);
  }

  // ===========================================================================
  // UI অংশ: পরিষ্কার, মডুলার এবং Overflow-মুক্ত লেআউট
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    // আর্গুমেন্ট ছাড়া বা ভুল আর্গুমেন্ট নিয়ে ঢুকলে ক্র্যাশ না করে নিরাপদ ফলব্যাক দেখাও
    if (_initialItem == null || _itemStream == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(title: const Text('Item Details')),
        body: const Center(
          child: Text(
            'Food item details could not be loaded.',
            style: TextStyle(color: Colors.white60, fontSize: 15),
          ),
        ),
      );
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _itemStream,
      initialData: <Map<String, dynamic>>[_initialItem!],
      builder: (
        BuildContext context,
        AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
      ) {
        final List<Map<String, dynamic>> rows =
            snapshot.data ?? <Map<String, dynamic>>[];
        if (rows.isEmpty) {
          return _buildRemovedState();
        }

        final Map<String, dynamic> item = rows.first;
        final String name = (item['name'] as String?) ?? 'Unnamed Item';
        final String description = (item['description'] as String?)?.trim() ?? '';
        final String category = (item['category'] as String?) ?? 'Menu';
        final double price = (item['price'] as num?)?.toDouble() ?? 0.0;
        final int liveStock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
        final int prepMin = (item['default_prep_minutes'] as num?)?.toInt() ?? 10;
        final bool isAvailable = item['is_available'] == true && liveStock > 0;
        final String? imageUrl = item['image_url'] as String?;

        // লাইভ স্টক হঠাৎ কমে গেলে নির্বাচিত সংখ্যা নিরাপদে সীমাবদ্ধ (Clamp) করা
        final int effectiveQty = !isAvailable
            ? 0
            : (_selectedQty > liveStock ? liveStock : _selectedQty);

        return Scaffold(
          backgroundColor: const Color(0xFF0F172A),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildHeroImage(
                          imageUrl: imageUrl,
                          category: category,
                          isAvailable: isAvailable,
                          liveStock: liveStock,
                          prepMin: prepMin,
                        ),
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTitleAndPrice(name: name, price: price),
                              const SizedBox(height: 16),
                              if (!isAvailable || liveStock <= 5)
                                _buildStockAlertBanner(
                                  isAvailable: isAvailable,
                                  liveStock: liveStock,
                                ),
                              _buildDescriptionSection(description),
                              const SizedBox(height: 20),
                              _buildInfoGrid(
                                category: category,
                                prepMin: prepMin,
                                liveStock: liveStock,
                                isAvailable: isAvailable,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _buildBottomActionBar(
                  isAvailable: isAvailable,
                  liveStock: liveStock,
                  effectiveQty: effectiveQty,
                  unitPrice: price,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// অংশ ১: হিরো ইমেজ + ব্যাক বাটন + ক্যাটাগরি ও স্টক ব্যাজ
  Widget _buildHeroImage({
    required String? imageUrl,
    required String category,
    required bool isAvailable,
    required int liveStock,
    required int prepMin,
  }) {
    final Widget fallback = Container(
      color: const Color(0xFF1E293B),
      child: Icon(
        Icons.fastfood_rounded,
        size: 72,
        color: Colors.white.withValues(alpha: 0.2),
      ),
    );

    Widget imageWidget;
    if (imageUrl != null && imageUrl.trim().isNotEmpty) {
      imageWidget = Image.network(
        imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback,
      );
    } else {
      imageWidget = fallback;
    }

    if (!isAvailable) {
      imageWidget = ColorFiltered(
        colorFilter: const ColorFilter.mode(Colors.grey, BlendMode.saturation),
        child: Opacity(opacity: 0.55, child: imageWidget),
      );
    }

    return SizedBox(
      height: 260,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          imageWidget,
          // নিচে হালকা গ্রেডিয়েন্ট যাতে ব্যাজগুলো স্পষ্ট দেখা যায়
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.45),
                  Colors.transparent,
                  const Color(0xFF0F172A).withValues(alpha: 0.92),
                ],
              ),
            ),
          ),
          // ব্যাক বাটন (কোনো পরিবর্তন না করেই ফিরে যাওয়া)
          Positioned(
            top: 12,
            left: 12,
            child: CircleAvatar(
              backgroundColor: Colors.black.withValues(alpha: 0.55),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          // আনুমানিক প্রস্তুতি সময়
          Positioned(
            top: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.65),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.timer_outlined,
                    size: 14,
                    color: Color(0xFFFF5722),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '~$prepMin min',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // নিচে ক্যাটাগরি ও লাইভ স্টক ব্যাজ
          Positioned(
            bottom: 14,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Text(
                    category.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: isAvailable
                        ? Colors.green.shade700
                        : Colors.red.shade700,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isAvailable ? 'In Stock: $liveStock' : 'SOLD OUT',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// অংশ ২: খাবারের নাম ও দাম
  Widget _buildTitleAndPrice({required String name, required double price}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '৳ ${price.toStringAsFixed(0)}',
          style: const TextStyle(
            color: Color(0xFFFF5722),
            fontSize: 24,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  /// অংশ ৩: রিয়েল-টাইম স্টক ওয়ার্নিং (হঠাৎ Sold Out বা ৫টির কম স্টক হলে)
  Widget _buildStockAlertBanner({
    required bool isAvailable,
    required int liveStock,
  }) {
    final Color accent = isAvailable ? Colors.amber : Colors.redAccent;
    final String msg = isAvailable
        ? 'Hurry! Only $liveStock portions left in the kitchen right now.'
        : 'This item was just marked unavailable by the kitchen.';

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Icon(
            isAvailable ? Icons.bolt_rounded : Icons.block_rounded,
            color: accent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                color: accent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// অংশ ৪: খাবারের বিবরণ
  Widget _buildDescriptionSection(String description) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'DESCRIPTION',
          style: TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description.isNotEmpty
              ? description
              : 'Freshly prepared at the university canteen upon order confirmation.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.82),
            fontSize: 14.5,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  /// অংশ ৫: মেটাডেটা কার্ড (Prep Time + Live Stock)
  Widget _buildInfoGrid({
    required String category,
    required int prepMin,
    required int liveStock,
    required bool isAvailable,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildMetaCell(
              icon: Icons.schedule_rounded,
              label: 'Avg. Prep Time',
              value: '~$prepMin mins',
            ),
          ),
          Container(
            width: 1,
            height: 36,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          Expanded(
            child: _buildMetaCell(
              icon: Icons.inventory_2_outlined,
              label: 'Kitchen Stock',
              value: isAvailable ? '$liveStock left' : 'Out of Stock',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaCell({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Column(
      children: [
        Icon(icon, color: const Color(0xFFFF5722), size: 20),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 11.5),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  /// অংশ ৬: স্টিকি বটম অ্যাকশন বার (কোয়ান্টিটি স্টেপার + Add/Update/Remove বাটন)
  Widget _buildBottomActionBar({
    required bool isAvailable,
    required int liveStock,
    required int effectiveQty,
    required double unitPrice,
  }) {
    final double lineTotal = unitPrice * effectiveQty;
    final bool isRemoving = _initialCartQty > 0 && effectiveQty == 0;

    String buttonLabel;
    Color buttonColor = const Color(0xFFFF5722);

    if (!isAvailable) {
      buttonLabel = 'CURRENTLY SOLD OUT';
      buttonColor = Colors.white12;
    } else if (isRemoving) {
      buttonLabel = 'REMOVE FROM CART';
      buttonColor = Colors.redAccent;
    } else if (_initialCartQty > 0) {
      buttonLabel = 'UPDATE CART  •  ৳ ${lineTotal.toStringAsFixed(0)}';
    } else {
      buttonLabel = 'ADD TO CART  •  ৳ ${lineTotal.toStringAsFixed(0)}';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          // কোয়ান্টিটি স্টেপার (- qty +)
          Container(
            height: 50,
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.remove, color: Colors.white, size: 18),
                  onPressed: isAvailable ? _decrementQty : null,
                ),
                SizedBox(
                  width: 28,
                  child: Text(
                    '$effectiveQty',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, color: Colors.white, size: 18),
                  onPressed: isAvailable ? () => _incrementQty(liveStock) : null,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // মূল কনফার্ম বাটন
          Expanded(
            child: SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: isAvailable
                    ? () => _confirmAndReturn(effectiveQty)
                    : (_initialCartQty > 0 ? () => _confirmAndReturn(0) : null),
                style: ElevatedButton.styleFrom(
                  backgroundColor: buttonColor,
                  disabledBackgroundColor: Colors.white12,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  buttonLabel,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// অ্যাডমিন যদি এই মুহূর্তে মেনু থেকে আইটেমটি ডিলিট করে দেয়
  Widget _buildRemovedState() {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(title: const Text('Item Unavailable')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.remove_shopping_cart, size: 54, color: Colors.white38),
              const SizedBox(height: 14),
              const Text(
                'This menu item is no longer available.',
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => _confirmAndReturn(0),
                child: const Text('Back to Menu'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}