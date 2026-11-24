import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchCtrl = TextEditingController();

  /// SQL `menu_items.category` CHECK কন্সট্রেইন্টের সাথে হুবহু সামঞ্জস্যপূর্ণ
  static const List<String> _categories = <String>[
    'All',
    'Snacks',
    'Meals',
    'Drinks',
    'Desserts',
  ];

  String _studentName = 'Student';
  String _selectedCategory = 'All';
  String _searchQuery = '';

  /// কার্ট ম্যাপ: menu_item_id -> quantity (সর্বদা সার্ভারের লাইভ স্টকের সাথে মিলিয়ে যাচাই হয়)
  final Map<String, int> _cartQuantities = <String, int>{};

  // WebSocket Thrashing রোধে স্ট্রিমগুলো initState()-এ একবারই তৈরি হবে
  late final Stream<List<Map<String, dynamic>>> _menuStream;
  late final Stream<List<Map<String, dynamic>>> _walletStream;

  @override
  void initState() {
    super.initState();
    final User? currentUser = _supabase.auth.currentUser;

    // ১. সেশন না থাকলে নিরাপদে লগইনে ফেরত পাঠাও
    if (currentUser == null) {
      _menuStream = const Stream<List<Map<String, dynamic>>>.empty();
      _walletStream = const Stream<List<Map<String, dynamic>>>.empty();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
      });
      return;
    }

    // ২. দুটি স্বাধীন Realtime Stream একবারই চালু করো
    _menuStream = _supabase
        .from('menu_items')
        .stream(primaryKey: <String>['id'])
        .order('name', ascending: true);

    _walletStream = _supabase
        .from('wallets')
        .stream(primaryKey: <String>['user_id'])
        .eq('user_id', currentUser.id);

    // ৩. হেডারে দেখানোর জন্য স্টুডেন্টের নাম একবার ফেচ করো
    _loadStudentProfile(currentUser.id);
  }

  Future<void> _loadStudentProfile(String userId) async {
    try {
      final Map<String, dynamic> profile = await _supabase
          .from('profiles')
          .select('first_name')
          .eq('id', userId)
          .single();

      final String firstName = (profile['first_name'] as String?)?.trim() ?? '';
      if (mounted && firstName.isNotEmpty) {
        setState(() => _studentName = firstName);
      }
    } catch (_) {
      // নাম লোড না হলেও ডিফল্ট 'Student' দেখাবে; অ্যাপ আটকাবে না
    }
  }

  /// সার্চ ও ক্যাটাগরি অনুযায়ী মেনু ফিল্টার (Client-Side O(N) — শূন্য DB লোড)
  List<Map<String, dynamic>> _filterMenu(List<Map<String, dynamic>> items) {
    final String query = _searchQuery.trim().toLowerCase();
    return items.where((Map<String, dynamic> item) {
      final String category = (item['category'] as String?) ?? '';
      final bool matchesCategory =
          _selectedCategory == 'All' || category == _selectedCategory;

      if (!matchesCategory) return false;
      if (query.isEmpty) return true;

      final String name = ((item['name'] as String?) ?? '').toLowerCase();
      final String desc = ((item['description'] as String?) ?? '')
          .toLowerCase();
      return name.contains(query) || desc.contains(query);
    }).toList();
  }

  /// কার্টে আইটেম বাড়ানো (লাইভ স্টক সীমার ভেতরে)
  void _incrementItem(String itemId, int maxStock) {
    final int currentQty = _cartQuantities[itemId] ?? 0;
    if (currentQty >= maxStock) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Only $maxStock available in stock right now.'),
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() => _cartQuantities[itemId] = currentQty + 1);
  }

  /// কার্ট থেকে আইটেম কমানো
  void _decrementItem(String itemId) {
    final int currentQty = _cartQuantities[itemId] ?? 0;
    if (currentQty <= 1) {
      setState(() => _cartQuantities.remove(itemId));
    } else {
      setState(() => _cartQuantities[itemId] = currentQty - 1);
    }
  }

  /// লাইভ মেনু ডেটার সাথে মিলিয়ে কেবল বৈধ ও স্টকে থাকা কার্ট আইটেমগুলোর সারসংক্ষেপ তৈরি
  List<Map<String, dynamic>> _buildValidCartPayload(
    List<Map<String, dynamic>> liveMenu,
  ) {
    final List<Map<String, dynamic>> payload = <Map<String, dynamic>>[];

    for (final Map<String, dynamic> item in liveMenu) {
      final String id = item['id'].toString();
      final int requestedQty = _cartQuantities[id] ?? 0;
      if (requestedQty <= 0) continue;

      final bool isAvailable = item['is_available'] == true;
      final int liveStock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
      if (!isAvailable || liveStock <= 0) continue;

      // কিচেনে স্টক কমে গেলে কার্টের পরিমাণ স্বয়ংক্রিয়ভাবে লাইভ স্টকে সীমাবদ্ধ হবে
      final int safeQty = requestedQty > liveStock ? liveStock : requestedQty;
      payload.add(<String, dynamic>{
        'menu_item_id': id,
        'name': item['name'] ?? 'Item',
        'price': (item['price'] as num?)?.toDouble() ?? 0.0,
        'quantity': safeQty,
        'stock_quantity': liveStock,
        'image_url': item['image_url'],
      });
    }
    return payload;
  }

  /// Checkout [P06] স্ক্রিনে যাওয়া এবং ফিরে এলে কার্ট আপডেট সিঙ্ক করা
  Future<void> _openCart(List<Map<String, dynamic>> liveMenu) async {
    final List<Map<String, dynamic>> validItems = _buildValidCartPayload(
      liveMenu,
    );
    if (validItems.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selected items are currently out of stock.'),
        ),
      );
      return;
    }

    final Object? result = await Navigator.of(context)
        .pushNamed('/student/cart', arguments: validItems);

    // চেকআউট সফল হলে [P06] থেকে 'order_placed' বা আপডেটেড কার্ট ফেরত আসতে পারে
    if (!mounted) return;
    if (result == 'order_placed') {
      setState(() => _cartQuantities.clear());
    } else if (result is Map<String, int>) {
      setState(() {
        _cartQuantities
          ..clear()
          ..addAll(result);
      });
    }
  }

  /// Item Detail [P05] স্ক্রিনে যাওয়া
  Future<void> _openItemDetail(Map<String, dynamic> item) async {
    final String itemId = item['id'].toString();
    final Object? result = await Navigator.of(context).pushNamed(
      '/student/item-detail',
      arguments: <String, dynamic>{
        'item': item,
        'currentQty': _cartQuantities[itemId] ?? 0,
      },
    );

    if (!mounted || result is! int) return;
    setState(() {
      if (result <= 0) {
        _cartQuantities.remove(itemId);
      } else {
        _cartQuantities[itemId] = result;
      }
    });
  }

  Future<void> _handleSignOut() async {
    await _supabase.auth.signOut();
    if (!mounted) return;
    Navigator.of(context)
        .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: পরিষ্কার, মডুলার এবং Overflow-মুক্ত লেআউট
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: _buildAppBar(),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _menuStream,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
            ) {
              final List<Map<String, dynamic>> liveMenu =
                  snapshot.data ?? <Map<String, dynamic>>[];

              return Column(
                children: [
                  _buildSearchBar(),
                  _buildCategoryChips(),
                  Expanded(child: _buildMenuContent(snapshot, liveMenu)),
                  _buildFloatingCartBar(liveMenu),
                ],
              );
            },
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  /// অংশ ১: স্টুডেন্ট গ্রিটিং + লাইভ ওয়ালেট ব্যালেন্স পিল
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0F172A),
      elevation: 0,
      titleSpacing: 16,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Hi, $_studentName',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            'SwiftServe Campus Canteen',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 12,
            ),
          ),
        ],
      ),
      actions: [
        // রিয়েল-টাইম ওয়ালেট ব্যালেন্স পিল (ট্যাপ করলে [P08] Wallet খুলবে)
        StreamBuilder<List<Map<String, dynamic>>>(
          stream: _walletStream,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<Map<String, dynamic>>> snap,
              ) {
                final double balance =
                    (snap.data != null && snap.data!.isNotEmpty)
                    ? ((snap.data!.first['balance'] as num?)?.toDouble() ?? 0.0)
                    : 0.0;

                return GestureDetector(
                  onTap: () =>
                      Navigator.of(context).pushNamed('/student/wallet'),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 10),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF5722).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFFF5722).withValues(alpha: 0.6),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 16,
                          color: Color(0xFFFF5722),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '৳ ${balance.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
        ),
        IconButton(
          tooltip: 'Sign Out',
          icon: const Icon(
            Icons.logout_rounded,
            color: Colors.white60,
            size: 20,
          ),
          onPressed: _handleSignOut,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// অংশ ২: লোকাল সার্চ বার
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        onChanged: (String value) => setState(() => _searchQuery = value),
        decoration: InputDecoration(
          hintText: 'Search burgers, tea, rice...',
          hintStyle: const TextStyle(color: Colors.white38),
          prefixIcon: const Icon(Icons.search_rounded, color: Colors.white54),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white54,
                    size: 18,
                  ),
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
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// অংশ ৩: ক্যাটাগরি ফিল্টার চিপস
  Widget _buildCategoryChips() {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int index) {
          final String category = _categories[index];
          final bool isSelected = _selectedCategory == category;

          return ChoiceChip(
            label: Text(category),
            selected: isSelected,
            showCheckmark: false,
            selectedColor: const Color(0xFFFF5722),
            backgroundColor: const Color(0xFF1E293B),
            side: BorderSide.none,
            labelStyle: TextStyle(
              color: isSelected ? Colors.white : Colors.white70,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              fontSize: 13,
            ),
            onSelected: (_) => setState(() => _selectedCategory = category),
          );
        },
      ),
    );
  }

  /// অংশ ৪: লাইভ মেনু গ্রিড (লোডিং, এরর ও এম্পটি স্টেটসহ)
  Widget _buildMenuContent(
    AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
    List<Map<String, dynamic>> liveMenu,
  ) {
    if (snapshot.connectionState == ConnectionState.waiting &&
        liveMenu.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF5722)),
      );
    }

    if (snapshot.hasError) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Unable to load live canteen menu.\nCheck your internet connection.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      );
    }

    final List<Map<String, dynamic>> filtered = _filterMenu(liveMenu);

    if (filtered.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.restaurant_menu_rounded,
              size: 48,
              color: Colors.white.withValues(alpha: 0.25),
            ),
            const SizedBox(height: 12),
            const Text(
              'No food items found.',
              style: TextStyle(color: Colors.white60, fontSize: 15),
            ),
          ],
        ),
      );
    }

    // রেস্পন্সিভ গ্রিড: মোবাইলে ২ কলাম, ট্যাবলেট/ডেস্কটপে ৩-৪ কলাম (Zero Overflow)
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 230,
        mainAxisExtent: 258,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: filtered.length,
      itemBuilder: (BuildContext context, int index) {
        return _buildMenuCard(filtered[index]);
      },
    );
  }

  /// অংশ ৫: প্রতিটি মেনু আইটেমের কার্ড
  Widget _buildMenuCard(Map<String, dynamic> item) {
    final String id = item['id'].toString();
    final String name = (item['name'] as String?) ?? 'Unnamed Item';
    final double price = (item['price'] as num?)?.toDouble() ?? 0.0;
    final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
    final int prepMin = (item['default_prep_minutes'] as num?)?.toInt() ?? 10;
    final bool isAvailable = item['is_available'] == true && stock > 0;
    final String? imageUrl = item['image_url'] as String?;
    final int qtyInCart = _cartQuantities[id] ?? 0;

    return GestureDetector(
      onTap: () => _openItemDetail(item),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: qtyInCart > 0 && isAvailable
                ? const Color(0xFFFF5722)
                : Colors.white.withValues(alpha: 0.06),
            width: 1.2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ছবির অংশ + লাইভ স্টক ব্যাজ
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(15),
                    ),
                    child: _buildItemImage(imageUrl, isAvailable),
                  ),
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: isAvailable
                            ? Colors.green.shade700.withValues(alpha: 0.9)
                            : Colors.red.shade700.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        isAvailable ? 'Stock: $stock' : 'SOLD OUT',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.65),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '~${prepMin}m',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // আইটেমের নাম, দাম এবং Add/Stepper বাটন
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '৳ ${price.toStringAsFixed(0)}',
                    style: const TextStyle(
                      color: Color(0xFFFF5722),
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _buildCardActionButton(
                    itemId: id,
                    isAvailable: isAvailable,
                    stock: stock,
                    qtyInCart: qtyInCart,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemImage(String? imageUrl, bool isAvailable) {
    final Widget fallback = Container(
      color: const Color(0xFF0F172A),
      child: Icon(
        Icons.fastfood_rounded,
        size: 40,
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

    if (isAvailable) return imageWidget;
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.grey, BlendMode.saturation),
      child: Opacity(opacity: 0.6, child: imageWidget),
    );
  }

  Widget _buildCardActionButton({
    required String itemId,
    required bool isAvailable,
    required int stock,
    required int qtyInCart,
  }) {
    if (!isAvailable) {
      return Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'UNAVAILABLE',
          style: TextStyle(
            color: Colors.white38,
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    if (qtyInCart == 0) {
      return SizedBox(
        height: 34,
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => _incrementItem(itemId, stock),
          style: ElevatedButton.styleFrom(
            padding: EdgeInsets.zero,
            backgroundColor: const Color(0xFFFF5722),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          child: const Text(
            '+ ADD',
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }

    // কার্টে থাকলে - qty + স্টেপার দেখাবে
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: const Color(0xFFFF5722).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFF5722)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32),
            icon: const Icon(Icons.remove, size: 16, color: Colors.white),
            onPressed: () => _decrementItem(itemId),
          ),
          Text(
            '$qtyInCart',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 13.5,
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32),
            icon: const Icon(Icons.add, size: 16, color: Colors.white),
            onPressed: () => _incrementItem(itemId, stock),
          ),
        ],
      ),
    );
  }

  /// অংশ ৬: ফ্লোটিং কার্ট বার (শুধু কার্টে বৈধ আইটেম থাকলেই দেখাবে)
  Widget _buildFloatingCartBar(List<Map<String, dynamic>> liveMenu) {
    final List<Map<String, dynamic>> validItems = _buildValidCartPayload(
      liveMenu,
    );
    if (validItems.isEmpty) return const SizedBox.shrink();

    int totalCount = 0;
    double totalPrice = 0.0;
    for (final Map<String, dynamic> item in validItems) {
      final int qty = item['quantity'] as int;
      final double price = item['price'] as double;
      totalCount += qty;
      totalPrice += qty * price;
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFF5722),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF5722).withValues(alpha: 0.35),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: InkWell(
        onTap: () => _openCart(liveMenu),
        child: Row(
          children: [
            const Icon(Icons.shopping_bag_outlined, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$totalCount ${totalCount == 1 ? 'Item' : 'Items'}  •  ৳ ${totalPrice.toStringAsFixed(0)}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14.5,
                ),
              ),
            ),
            const Text(
              'VIEW CART',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 13,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.arrow_forward_ios_rounded,
              color: Colors.white,
              size: 14,
            ),
          ],
        ),
      ),
    );
  }

  /// অংশ ৭: স্টুডেন্ট মডিউলের বটম নেভিগেশন বার
  Widget _buildBottomNav() {
    return NavigationBar(
      backgroundColor: const Color(0xFF1E293B),
      indicatorColor: const Color(0xFFFF5722).withValues(alpha: 0.22),
      selectedIndex: 0,
      onDestinationSelected: (int index) {
        if (index == 0) return;
        const List<String> routes = <String>[
          '/student/home',
          '/student/order-tracker',
          '/student/wallet',
          '/student/history',
        ];
        Navigator.of(context).pushNamed(routes[index]);
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined, color: Colors.white60),
          selectedIcon: Icon(Icons.home_rounded, color: Color(0xFFFF5722)),
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.receipt_long_outlined, color: Colors.white60),
          selectedIcon: Icon(Icons.receipt_long, color: Color(0xFFFF5722)),
          label: 'Orders',
        ),
        NavigationDestination(
          icon: Icon(
            Icons.account_balance_wallet_outlined,
            color: Colors.white60,
          ),
          selectedIcon: Icon(
            Icons.account_balance_wallet,
            color: Color(0xFFFF5722),
          ),
          label: 'Wallet',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline, color: Colors.white60),
          selectedIcon: Icon(Icons.person, color: Color(0xFFFF5722)),
          label: 'Profile',
        ),
      ],
    );
  }
}
