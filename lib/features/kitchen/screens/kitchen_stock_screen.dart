import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class KitchenStockScreen extends StatefulWidget {
  const KitchenStockScreen({super.key});

  @override
  State<KitchenStockScreen> createState() => _KitchenStockScreenState();
}

class _KitchenStockScreenState extends State<KitchenStockScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchCtrl = TextEditingController();

  static const List<String> _categories = <String>[
    'All',
    'Snacks',
    'Meals',
    'Drinks',
    'Desserts',
  ];

  late final Stream<List<Map<String, dynamic>>> _menuStream;

  /// Per-Item লক: ১টি সুইচ আপডেট হওয়ার সময় বাকি আইটেমগুলোর সুইচ সচল থাকবে
  final Set<String> _busyItemIds = <String>{};

  String _selectedCategory = 'All';
  String _searchQuery = '';
  bool _showUnavailableOnly = false;

  @override
  void initState() {
    super.initState();
    final User? currentUser = _supabase.auth.currentUser;

    if (currentUser == null) {
      _menuStream = const Stream<List<Map<String, dynamic>>>.empty();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/login',
          (Route<dynamic> route) => false,
        );
      });
      return;
    }

    // একবারই Realtime স্ট্রিম বাইন্ড করো (WebSocket Thrashing প্রতিরোধ)
    _menuStream = _supabase
        .from('menu_items')
        .stream(primaryKey: <String>['id'])
        .order('name', ascending: true);
  }

  /// লোকাল সার্চ, ক্যাটাগরি এবং Paused ফিল্টার (Client-Side O(N) — শূন্য DB কল)
  List<Map<String, dynamic>> _filterItems(List<Map<String, dynamic>> items) {
    final String query = _searchQuery.trim().toLowerCase();

    return items.where((Map<String, dynamic> item) {
      final String category = (item['category'] as String?) ?? '';
      final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
      final bool isOrderable = item['is_available'] == true && stock > 0;

      if (_selectedCategory != 'All' && category != _selectedCategory) {
        return false;
      }
      if (_showUnavailableOnly && isOrderable) {
        return false;
      }
      if (query.isEmpty) return true;

      final String name = ((item['name'] as String?) ?? '').toLowerCase();
      return name.contains(query);
    }).toList();
  }

  /// Least-Privilege RPC: কেবল `is_available` ফ্ল্যাগ টগল করার ক্ষমতা
  Future<void> _toggleAvailability({
    required Map<String, dynamic> item,
    required bool nextValue,
  }) async {
    final String itemId = item['id'].toString();
    final String name = (item['name'] as String?) ?? 'Item';
    final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;

    if (_busyItemIds.contains(itemId)) return;

    // Zero-Stock Guard: স্টক ০ থাকা অবস্থায় ON করলে Zombie State তৈরি হবে
    if (nextValue && stock <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.amber.shade800,
          content: Text(
            '"$name" has 0 stock. Ask Admin to restock quantity in Menu Manager first.',
          ),
        ),
      );
      return;
    }

    setState(() => _busyItemIds.add(itemId));
    try {
      await _supabase
          .rpc(
            'toggle_menu_availability',
            params: <String, dynamic>{
              'p_menu_item_id': itemId,
              'p_is_available': nextValue,
            },
          )
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              nextValue ? Colors.green.shade700 : Colors.orange.shade800,
          duration: const Duration(seconds: 2),
          content: Text(
            nextValue
                ? '"$name" is now LIVE for students.'
                : '"$name" PAUSED — students immediately see SOLD OUT.',
          ),
        ),
      );
    } on TimeoutException {
      _showError('Network timed out. Switch status was NOT changed.');
    } on PostgrestException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('Failed to update availability. Check campus Wi-Fi.');
    } finally {
      if (mounted) {
        setState(() => _busyItemIds.remove(itemId));
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.redAccent,
        content: Text(message),
      ),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: হাই-কন্ট্রাস্ট ও বড় ট্যাপ-টার্গেট কিচেন কন্ট্রোল প্যানেল
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: _buildAppBar(),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _menuStream,
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
                  'Unable to sync live inventory.\nCheck your network connection.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.redAccent, fontSize: 15),
                ),
              ),
            );
          }

          final List<Map<String, dynamic>> allItems =
              snapshot.data ?? <Map<String, dynamic>>[];

          int activeCount = 0;
          for (final Map<String, dynamic> item in allItems) {
            final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
            if (item['is_available'] == true && stock > 0) {
              activeCount++;
            }
          }
          final int unavailableCount = allItems.length - activeCount;
          final List<Map<String, dynamic>> filtered = _filterItems(allItems);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Column(
                children: [
                  _buildSummaryStrip(
                    total: allItems.length,
                    active: activeCount,
                    unavailable: unavailableCount,
                  ),
                  _buildSearchBar(),
                  _buildFilterBar(unavailableCount),
                  Expanded(child: _buildItemList(filtered)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xFF0F172A),
      elevation: 0,
      title: const Row(
        children: [
          Icon(Icons.flash_on_rounded, color: Color(0xFFFF5722), size: 22),
          SizedBox(width: 8),
          Text(
            'Stock Kill-Switch',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 19,
            ),
          ),
        ],
      ),
      actions: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
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
                'INSTANT SYNC',
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
    );
  }

  /// অংশ ১: লাইভ ইনভেন্টরি স্ট্যাটাস কাউন্টার
  Widget _buildSummaryStrip({
    required int total,
    required int active,
    required int unavailable,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: _buildStatPill('TOTAL ITEMS', '$total', Colors.white70),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _buildStatPill('LIVE NOW', '$active', Colors.greenAccent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _buildStatPill('SOLD OUT', '$unavailable', Colors.redAccent),
          ),
        ],
      ),
    );
  }

  Widget _buildStatPill(String label, String count, Color accent) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        children: [
          Text(
            count,
            style: TextStyle(
              color: accent,
              fontSize: 20,
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
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }

  /// অংশ ২: দ্রুত সার্চ বার
  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        onChanged: (String v) => setState(() => _searchQuery = v),
        decoration: InputDecoration(
          hintText: 'Search menu item to pause or resume...',
          hintStyle: const TextStyle(color: Colors.white38),
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
    );
  }

  /// অংশ ৩: ক্যাটাগরি + "Unavailable Only" কুইক ফিল্টার
  Widget _buildFilterBar(int unavailableCount) {
    return SizedBox(
      height: 44,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        children: [
          FilterChip(
            label: Text('Sold Out ($unavailableCount)'),
            selected: _showUnavailableOnly,
            showCheckmark: false,
            selectedColor: Colors.redAccent,
            backgroundColor: const Color(0xFF1E293B),
            side: BorderSide(
              color: _showUnavailableOnly
                  ? Colors.redAccent
                  : Colors.redAccent.withValues(alpha: 0.4),
            ),
            labelStyle: TextStyle(
              color: _showUnavailableOnly ? Colors.white : Colors.redAccent,
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
            ),
            onSelected: (bool val) =>
                setState(() => _showUnavailableOnly = val),
          ),
          const SizedBox(width: 10),
          ..._categories.map((String cat) {
            final bool selected = _selectedCategory == cat;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(cat),
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
                onSelected: (_) => setState(() => _selectedCategory = cat),
              ),
            );
          }),
        ],
      ),
    );
  }

  /// অংশ ৪: টগলযোগ্য খাবারের তালিকা
  Widget _buildItemList(List<Map<String, dynamic>> items) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.inventory_2_outlined,
                size: 50,
                color: Colors.white.withValues(alpha: 0.22),
              ),
              const SizedBox(height: 12),
              const Text(
                'No matching menu items found.',
                style: TextStyle(color: Colors.white60, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        return _buildStockRowCard(items[index]);
      },
    );
  }

  /// প্রতিটি খাবারের হাই-ভিজিবিলিটি Kill-Switch কার্ড
  Widget _buildStockRowCard(Map<String, dynamic> item) {
    final String id = item['id'].toString();
    final String name = (item['name'] as String?) ?? 'Unnamed Item';
    final String category = (item['category'] as String?) ?? 'Menu';
    final double price = (item['price'] as num?)?.toDouble() ?? 0.0;
    final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
    final bool dbAvailable = item['is_available'] == true;
    final bool effectivelyLive = dbAvailable && stock > 0;
    final bool isBusy = _busyItemIds.contains(id);

    final Color stockColor = stock == 0
        ? Colors.redAccent
        : (stock <= 5 ? Colors.amber : Colors.greenAccent);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: effectivelyLive
              ? Colors.green.withValues(alpha: 0.35)
              : Colors.redAccent.withValues(alpha: 0.45),
          width: 1.2,
        ),
      ),
      child: Row(
        children: [
          // বাম পাশে খাবারের তথ্য ও স্টক ব্যাজ
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: effectivelyLive ? Colors.white : Colors.white60,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        category,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      '৳ ${price.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Color(0xFFFF5722),
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: stockColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        stock == 0 ? '0 IN STOCK' : 'Stock: $stock',
                        style: TextStyle(
                          color: stockColor,
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                if (stock == 0)
                  const Padding(
                    padding: EdgeInsets.only(top: 5),
                    child: Text(
                      'Admin must restock quantity before re-enabling.',
                      style: TextStyle(
                        color: Color(0xFFFCA5A5),
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // ডান পাশে বড় ট্যাপ-টার্গেট Kill-Switch (সার্ভার-অথরিটেটিভ)
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (isBusy)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Color(0xFFFF5722),
                    ),
                  ),
                )
              else
                Transform.scale(
                  scale: 1.15,
                  child: Switch.adaptive(
                    value: effectivelyLive,
                    activeTrackColor: Colors.green.shade600,
                    activeThumbColor: Colors.white,
                    inactiveTrackColor:
                        Colors.redAccent.withValues(alpha: 0.35),
                    inactiveThumbColor: Colors.white70,
                    onChanged: (bool nextVal) => _toggleAvailability(
                      item: item,
                      nextValue: nextVal,
                    ),
                  ),
                ),
              Text(
                effectivelyLive
                    ? 'AVAILABLE'
                    : (stock == 0 ? 'OUT OF STOCK' : 'PAUSED'),
                style: TextStyle(
                  color: effectivelyLive ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}