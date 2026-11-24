import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/validators/app_validators.dart';

const String _kMenuImagesBucket = 'menu-images';
const int _kMaxImageBytes = 5 * 1024 * 1024; // 5 MB (matches SQL bucket limit)

/// Extracts the relative object path if the URL belongs to our `menu-images` bucket.
String? _extractStoragePath(String? imageUrl) {
  if (imageUrl == null || imageUrl.trim().isEmpty) return null;
  const String marker = '/object/public/$_kMenuImagesBucket/';
  final int idx = imageUrl.indexOf(marker);
  if (idx == -1) return null;
  final String tail = imageUrl.substring(idx + marker.length);
  final int queryIdx = tail.indexOf('?');
  final String clean = queryIdx == -1 ? tail : tail.substring(0, queryIdx);
  return clean.trim().isEmpty ? null : Uri.decodeComponent(clean);
}

class AdminMenuScreen extends StatefulWidget {
  const AdminMenuScreen({super.key});

  @override
  State<AdminMenuScreen> createState() => _AdminMenuScreenState();
}

class _AdminMenuScreenState extends State<AdminMenuScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchCtrl = TextEditingController();

  /// Matches SQL `menu_items.category` CHECK constraint
  static const List<String> _categories = <String>[
    'All',
    'Snacks',
    'Meals',
    'Drinks',
    'Desserts',
  ];

  late final Stream<List<Map<String, dynamic>>> _menuStream;

  /// Per-Item lock so updating/deleting one item never freezes the rest
  final Set<String> _busyItemIds = <String>{};

  String _selectedCategory = 'All';
  String _searchQuery = '';
  bool _onlyLowOrOut = false;

  @override
  void initState() {
    super.initState();
    if (_supabase.auth.currentUser == null) {
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

    _menuStream = _supabase
        .from('menu_items')
        .stream(primaryKey: <String>['id'])
        .order('name', ascending: true);
  }

  /// Local client-side search, category, and low/out-of-stock filter (O(N))
  List<Map<String, dynamic>> _filterItems(List<Map<String, dynamic>> items) {
    final String q = _searchQuery.trim().toLowerCase();

    return items.where((Map<String, dynamic> item) {
      final String cat = (item['category'] as String?) ?? '';
      final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
      final bool isAvail = item['is_available'] == true;

      if (_selectedCategory != 'All' && cat != _selectedCategory) return false;
      if (_onlyLowOrOut && (stock > 5 && isAvail)) return false;
      if (q.isEmpty) return true;

      final String name = ((item['name'] as String?) ?? '').toLowerCase();
      final String desc = ((item['description'] as String?) ?? '').toLowerCase();
      return name.contains(q) || desc.contains(q);
    }).toList();
  }

  /// Opens Create / Edit dialog with direct Supabase Storage photo upload
  Future<void> _openItemForm({Map<String, dynamic>? existingItem}) async {
    final bool? saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _MenuItemFormDialog(existingItem: existingItem),
    );

    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text(
            existingItem == null
                ? 'New menu item added successfully.'
                : 'Menu item updated successfully.',
          ),
        ),
      );
    }
  }

  /// Opens One-Tap Quick Restock dialog
  Future<void> _openQuickRestock(Map<String, dynamic> item) async {
    final String itemId = item['id'].toString();
    if (_busyItemIds.contains(itemId)) return;

    final bool? restocked = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _QuickRestockDialog(item: item),
    );

    if (restocked == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text('Stock updated for "${item['name']}".'),
        ),
      );
    }
  }

  /// Toggles availability with Zero-Stock Guard
  Future<void> _toggleAvailability(Map<String, dynamic> item) async {
    final String id = item['id'].toString();
    final String name = (item['name'] as String?) ?? 'Item';
    final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
    final bool currentAvail = item['is_available'] == true;
    final bool nextAvail = !currentAvail;

    if (_busyItemIds.contains(id)) return;

    if (nextAvail && stock <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.amber.shade800,
          content: Text('Restock "$name" above 0 before enabling it.'),
        ),
      );
      return;
    }

    setState(() => _busyItemIds.add(id));
    try {
      await _supabase
          .from('menu_items')
          .update(<String, dynamic>{'is_available': nextAvail})
          .eq('id', id)
          .timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _showError('Request timed out. Status unchanged.');
    } on PostgrestException catch (e) {
      _showError(e.message);
    } catch (_) {
      _showError('Failed to update availability.');
    } finally {
      if (mounted) setState(() => _busyItemIds.remove(id));
    }
  }

  /// Foreign-Key (23503) aware delete + best-effort Storage image cleanup
  Future<void> _confirmAndDelete(Map<String, dynamic> item) async {
    final String id = item['id'].toString();
    final String name = (item['name'] as String?) ?? 'Item';
    final String? oldStoragePath =
        _extractStoragePath(item['image_url'] as String?);
    if (_busyItemIds.contains(id)) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Delete "$name"?',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'Items that have already been ordered cannot be deleted to preserve financial audit history. You can pause them instead.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busyItemIds.add(id));
    try {
      await _supabase
          .from('menu_items')
          .delete()
          .eq('id', id)
          .timeout(const Duration(seconds: 8));

      // Best-effort cleanup of uploaded Storage photo after DB deletion succeeds
      if (oldStoragePath != null) {
        unawaited(
          _supabase.storage
              .from(_kMenuImagesBucket)
              .remove(<String>[oldStoragePath])
              .catchError((_) => <FileObject>[]),
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: Text('"$name" removed from menu.'),
        ),
      );
    } on PostgrestException catch (e) {
      if (e.code == '23503') {
        _showError(
          'Cannot delete "$name" because past orders reference it. Use PAUSE to hide it from students.',
        );
      } else {
        _showError(e.message);
      }
    } on TimeoutException {
      _showError('Delete request timed out. Please retry.');
    } catch (_) {
      _showError('Failed to delete menu item.');
    } finally {
      if (mounted) setState(() => _busyItemIds.remove(id));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 4),
        content: Text(message),
      ),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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
          'Menu & Stock Manager',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
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
                  'LIVE CRUD',
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
              child: Text(
                'Failed to connect to live menu inventory.',
                style: TextStyle(color: Colors.redAccent),
              ),
            );
          }

          final List<Map<String, dynamic>> allItems =
              snapshot.data ?? <Map<String, dynamic>>[];

          int liveCount = 0;
          int lowOrOutCount = 0;
          for (final Map<String, dynamic> item in allItems) {
            final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
            final bool avail = item['is_available'] == true;
            if (avail && stock > 0) liveCount++;
            if (!avail || stock <= 5) lowOrOutCount++;
          }

          final List<Map<String, dynamic>> filtered = _filterItems(allItems);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: Column(
                children: [
                  _buildSummaryStrip(
                    total: allItems.length,
                    live: liveCount,
                    lowOrOut: lowOrOutCount,
                  ),
                  _buildSearchBar(),
                  _buildFilterChips(lowOrOutCount),
                  Expanded(child: _buildMenuList(filtered)),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFFF5722),
        foregroundColor: Colors.white,
        onPressed: () => _openItemForm(),
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          'Add Menu Item',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildSummaryStrip({
    required int total,
    required int live,
    required int lowOrOut,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Expanded(child: _buildStatCard('TOTAL', '$total', Colors.white70)),
          const SizedBox(width: 8),
          Expanded(child: _buildStatCard('LIVE', '$live', Colors.greenAccent)),
          const SizedBox(width: 8),
          Expanded(
            child: _buildStatCard(
              'LOW / OUT',
              '$lowOrOut',
              lowOrOut > 0 ? Colors.redAccent : Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(String label, String val, Color accent) {
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
            val,
            style: TextStyle(
              color: accent,
              fontSize: 19,
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
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        onChanged: (String v) => setState(() => _searchQuery = v),
        decoration: InputDecoration(
          hintText: 'Search menu item by name or description...',
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

  Widget _buildFilterChips(int lowOrOutCount) {
    return SizedBox(
      height: 44,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        children: [
          FilterChip(
            label: Text('Low / Out ($lowOrOutCount)'),
            selected: _onlyLowOrOut,
            showCheckmark: false,
            selectedColor: Colors.redAccent,
            backgroundColor: const Color(0xFF1E293B),
            side: BorderSide(
              color: _onlyLowOrOut
                  ? Colors.redAccent
                  : Colors.redAccent.withValues(alpha: 0.4),
            ),
            labelStyle: TextStyle(
              color: _onlyLowOrOut ? Colors.white : Colors.redAccent,
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
            ),
            onSelected: (bool val) => setState(() => _onlyLowOrOut = val),
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

  Widget _buildMenuList(List<Map<String, dynamic>> items) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.restaurant_menu_rounded,
                size: 52,
                color: Colors.white.withValues(alpha: 0.2),
              ),
              const SizedBox(height: 12),
              const Text(
                'No menu items yet. Tap "Add Menu Item" to upload your first dish.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        return _buildAdminMenuCard(items[index]);
      },
    );
  }

  Widget _buildAdminMenuCard(Map<String, dynamic> item) {
    final String id = item['id'].toString();
    final String name = (item['name'] as String?) ?? 'Unnamed Item';
    final String category = (item['category'] as String?) ?? 'Menu';
    final String? imageUrl = (item['image_url'] as String?)?.trim();
    final double price = (item['price'] as num?)?.toDouble() ?? 0.0;
    final int stock = (item['stock_quantity'] as num?)?.toInt() ?? 0;
    final int prepMin = (item['default_prep_minutes'] as num?)?.toInt() ?? 10;
    final bool dbAvail = item['is_available'] == true;
    final bool isLive = dbAvail && stock > 0;
    final bool isBusy = _busyItemIds.contains(id);

    final Color stockColor = stock == 0
        ? Colors.redAccent
        : (stock <= 5 ? Colors.amber : Colors.greenAccent);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isLive
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.redAccent.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Item Thumbnail
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  width: 62,
                  height: 62,
                  color: const Color(0xFF0F172A),
                  child: (imageUrl != null && imageUrl.isNotEmpty)
                      ? Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.fastfood_rounded,
                            color: Colors.white24,
                            size: 28,
                          ),
                        )
                      : const Icon(
                          Icons.fastfood_rounded,
                          color: Colors.white24,
                          size: 28,
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _buildTag(category, Colors.white60),
                        _buildTag('~${prepMin}m prep', Colors.white54),
                        _buildTag(
                          stock == 0 ? '0 STOCK' : 'Stock: $stock',
                          stockColor,
                        ),
                        _buildTag(
                          isLive ? 'LIVE' : 'PAUSED / OUT',
                          isLive ? Colors.greenAccent : Colors.redAccent,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '৳ ${price.toStringAsFixed(0)}',
                style: const TextStyle(
                  color: Color(0xFFFF5722),
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(color: Colors.white12, height: 1),
          ),
          if (isBusy)
            const LinearProgressIndicator(
              color: Color(0xFFFF5722),
              backgroundColor: Colors.white12,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _openQuickRestock(item),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.greenAccent,
                    side: BorderSide(
                      color: Colors.greenAccent.withValues(alpha: 0.6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.add_box_outlined, size: 17),
                  label: const Text('Restock'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _openItemForm(existingItem: item),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: const Text('Edit'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _toggleAvailability(item),
                  style: OutlinedButton.styleFrom(
                    foregroundColor:
                        isLive ? Colors.amber : Colors.lightBlueAccent,
                    side: BorderSide(
                      color: (isLive ? Colors.amber : Colors.lightBlueAccent)
                          .withValues(alpha: 0.6),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  icon: Icon(
                    isLive
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline,
                    size: 17,
                  ),
                  label: Text(isLive ? 'Pause' : 'Enable'),
                ),
                IconButton(
                  tooltip: 'Delete Item (Only if never ordered)',
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.redAccent,
                  ),
                  onPressed: () => _confirmAndDelete(item),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// =============================================================================
// Helper 1: Create / Edit Menu Item Dialog with Direct Storage Photo Upload
// =============================================================================

class _MenuItemFormDialog extends StatefulWidget {
  final Map<String, dynamic>? existingItem;
  const _MenuItemFormDialog({this.existingItem});

  @override
  State<_MenuItemFormDialog> createState() => _MenuItemFormDialogState();
}

class _MenuItemFormDialogState extends State<_MenuItemFormDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final SupabaseClient _supabase = Supabase.instance.client;
  final ImagePicker _picker = ImagePicker();

  static const List<String> _validCategories = <String>[
    'Snacks',
    'Meals',
    'Drinks',
    'Desserts',
  ];

  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;
  late final TextEditingController _priceCtrl;
  late final TextEditingController _stockCtrl;
  late final TextEditingController _prepCtrl;

  late String _category;
  late bool _isAvailable;

  String? _existingImageUrl;
  Uint8List? _pickedBytes;
  String? _pickedExt;
  String? _pickedMime;
  bool _removeExistingImage = false;

  bool _isSaving = false;
  String? _errorMsg;

  bool get _isEditing => widget.existingItem != null;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? item = widget.existingItem;
    _nameCtrl = TextEditingController(text: (item?['name'] as String?) ?? '');
    _descCtrl =
        TextEditingController(text: (item?['description'] as String?) ?? '');
    _priceCtrl = TextEditingController(
      text: item != null
          ? ((item['price'] as num?)?.toDouble().toStringAsFixed(2) ?? '')
          : '',
    );
    _stockCtrl = TextEditingController(
      text: item != null
          ? '${(item['stock_quantity'] as num?)?.toInt() ?? 0}'
          : '20',
    );
    _prepCtrl = TextEditingController(
      text: item != null
          ? '${(item['default_prep_minutes'] as num?)?.toInt() ?? 10}'
          : '10',
    );

    final String? rawImg = (item?['image_url'] as String?)?.trim();
    _existingImageUrl = (rawImg != null && rawImg.isNotEmpty) ? rawImg : null;

    final String rawCat = (item?['category'] as String?) ?? 'Snacks';
    _category = _validCategories.contains(rawCat) ? rawCat : 'Snacks';
    _isAvailable = item != null ? (item['is_available'] == true) : true;
  }

  /// Resolves validated MIME type & file extension matching Supabase bucket rules
  ({String ext, String mime})? _resolveImageFormat(XFile file) {
    final String mime = (file.mimeType ?? '').toLowerCase().trim();
    if (mime == 'image/png') return (ext: 'png', mime: 'image/png');
    if (mime == 'image/webp') return (ext: 'webp', mime: 'image/webp');
    if (mime == 'image/jpeg' || mime == 'image/jpg') {
      return (ext: 'jpg', mime: 'image/jpeg');
    }

    final String nameLower = file.name.toLowerCase();
    if (nameLower.endsWith('.png')) return (ext: 'png', mime: 'image/png');
    if (nameLower.endsWith('.webp')) return (ext: 'webp', mime: 'image/webp');
    if (nameLower.endsWith('.jpg') || nameLower.endsWith('.jpeg')) {
      return (ext: 'jpg', mime: 'image/jpeg');
    }

    // If platform stripped extension/MIME after JPEG re-encoding, check magic bytes
    return null;
  }

  ({String ext, String mime})? _detectMagicFormat(Uint8List bytes) {
    if (bytes.length < 12) return null;
    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return (ext: 'jpg', mime: 'image/jpeg');
    }
    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return (ext: 'png', mime: 'image/png');
    }
    // WEBP: RIFF....WEBP
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return (ext: 'webp', mime: 'image/webp');
    }
    return null;
  }

  Future<void> _pickImage() async {
    if (_isSaving) return;
    try {
      final XFile? file = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 82,
      );
      if (file == null) return;

      final Uint8List bytes = await file.readAsBytes();
      if (!mounted) return;

      if (bytes.isEmpty) {
        setState(() => _errorMsg = 'Selected image file is empty.');
        return;
      }

      if (bytes.lengthInBytes > _kMaxImageBytes) {
        setState(
          () => _errorMsg =
              'Image exceeds 5 MB limit. Please choose a smaller photo.',
        );
        return;
      }

      final ({String ext, String mime})? fmt =
          _detectMagicFormat(bytes) ?? _resolveImageFormat(file);
      if (fmt == null) {
        setState(
          () => _errorMsg =
              'Unsupported image format. Please select a JPG, PNG, or WEBP photo.',
        );
        return;
      }

      setState(() {
        _pickedBytes = bytes;
        _pickedExt = fmt.ext;
        _pickedMime = fmt.mime;
        _removeExistingImage = false;
        _errorMsg = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _errorMsg = 'Could not open image picker. Try again.');
      }
    }
  }

  void _clearImageSelection() {
    if (_isSaving) return;
    setState(() {
      _pickedBytes = null;
      _pickedExt = null;
      _pickedMime = null;
      _removeExistingImage = true;
      _errorMsg = null;
    });
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
      _errorMsg = null;
    });

    String? newlyUploadedPath;
    final String? oldStoragePath = _extractStoragePath(_existingImageUrl);

    try {
      String? finalImageUrl = _removeExistingImage ? null : _existingImageUrl;

      // Step 1: Upload new image binary to Supabase Storage if selected
      if (_pickedBytes != null && _pickedExt != null && _pickedMime != null) {
        final int rand = Random.secure().nextInt(999999);
        newlyUploadedPath =
            'items/${DateTime.now().millisecondsSinceEpoch}_$rand.$_pickedExt';

        await _supabase.storage
            .from(_kMenuImagesBucket)
            .uploadBinary(
              newlyUploadedPath,
              _pickedBytes!,
              fileOptions: FileOptions(
                contentType: _pickedMime,
                cacheControl: '3600',
                upsert: false,
              ),
            )
            .timeout(const Duration(seconds: 15));

        finalImageUrl = _supabase.storage
            .from(_kMenuImagesBucket)
            .getPublicUrl(newlyUploadedPath);
      }

      // Step 2: Persist menu item record in PostgreSQL
      final double price = double.parse(_priceCtrl.text.trim());
      final int stock = int.parse(_stockCtrl.text.trim());
      final int prepMin = int.parse(_prepCtrl.text.trim());

      final Map<String, dynamic> payload = <String, dynamic>{
        'name': _nameCtrl.text.trim(),
        'description': _descCtrl.text.trim(),
        'category': _category,
        'price': price,
        'stock_quantity': stock,
        'default_prep_minutes': prepMin,
        'image_url': finalImageUrl,
        'is_available': stock == 0 ? false : _isAvailable,
      };

      if (_isEditing) {
        await _supabase
            .from('menu_items')
            .update(payload)
            .eq('id', widget.existingItem!['id'].toString())
            .timeout(const Duration(seconds: 10));
      } else {
        await _supabase
            .from('menu_items')
            .insert(payload)
            .timeout(const Duration(seconds: 10));
      }

      // Step 3: Best-effort cleanup of replaced or removed old Storage photo
      final bool replacedOrRemovedOld =
          oldStoragePath != null &&
          (newlyUploadedPath != null || _removeExistingImage);
      if (replacedOrRemovedOld) {
        unawaited(
          _supabase.storage
              .from(_kMenuImagesBucket)
              .remove(<String>[oldStoragePath])
              .catchError((_) => <FileObject>[]),
        );
      }

      if (!mounted) return;
      Navigator.of(context).pop<bool>(true);
    } on TimeoutException {
      await _rollbackUploadedImage(newlyUploadedPath);
      if (mounted) {
        setState(() => _errorMsg = 'Upload or save timed out. Check network.');
      }
    } on StorageException catch (e) {
      if (mounted) {
        setState(
          () => _errorMsg =
              'Image upload failed: ${e.message}. Ensure Admin Storage policy is applied.',
        );
      }
    } on PostgrestException catch (e) {
      await _rollbackUploadedImage(newlyUploadedPath);
      if (mounted) setState(() => _errorMsg = e.message);
    } catch (_) {
      await _rollbackUploadedImage(newlyUploadedPath);
      if (mounted) setState(() => _errorMsg = 'Could not save menu item.');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _rollbackUploadedImage(String? path) async {
    if (path == null) return;
    try {
      await _supabase.storage.from(_kMenuImagesBucket).remove(<String>[path]);
    } catch (_) {
      // Best-effort rollback; never mask the original database error
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _stockCtrl.dispose();
    _prepCtrl.dispose();
    super.dispose();
  }

  Widget _buildImageUploadBox() {
    final bool hasNew = _pickedBytes != null;
    final bool hasExisting = !_removeExistingImage && _existingImageUrl != null;
    final bool hasAnyPhoto = hasNew || hasExisting;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 140,
              color: const Color(0xFF1E293B),
              child: hasNew
                  ? Image.memory(_pickedBytes!, fit: BoxFit.cover)
                  : hasExisting
                      ? Image.network(
                          _existingImageUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white38,
                              size: 40,
                            ),
                          ),
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.add_photo_alternate_outlined,
                              size: 40,
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'No food photo selected (JPG / PNG / WEBP, max 5 MB)',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11.5,
                              ),
                            ),
                          ],
                        ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isSaving ? null : _pickImage,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF5722),
                    side: BorderSide(
                      color: const Color(0xFFFF5722).withValues(alpha: 0.65),
                    ),
                  ),
                  icon: const Icon(Icons.upload_rounded, size: 18),
                  label: Text(
                    hasAnyPhoto ? 'Change Photo' : 'Upload Photo',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              if (hasAnyPhoto) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Remove Photo',
                  onPressed: _isSaving ? null : _clearImageSelection,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.redAccent,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(
        _isEditing ? 'Edit Menu Item' : 'Add New Menu Item',
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
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
                      style: const TextStyle(
                        color: Color(0xFFFCA5A5),
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                _buildImageUploadBox(),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _nameCtrl,
                  enabled: !_isSaving,
                  style: const TextStyle(color: Colors.white),
                  decoration: _fieldStyle('Item Name *', 'e.g., Chicken Burger'),
                  validator: (String? v) => (v == null || v.trim().length < 2)
                      ? 'Name must be at least 2 characters'
                      : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  dropdownColor: const Color(0xFF0F172A),
                  style: const TextStyle(color: Colors.white),
                  decoration: _fieldStyle('Category *', null),
                  items: _validCategories
                      .map(
                        (String c) => DropdownMenuItem<String>(
                          value: c,
                          child: Text(c),
                        ),
                      )
                      .toList(),
                  onChanged: _isSaving
                      ? null
                      : (String? val) {
                          if (val != null) setState(() => _category = val);
                        },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _priceCtrl,
                        enabled: !_isSaving,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        style: const TextStyle(color: Colors.white),
                        decoration: _fieldStyle('Price (BDT) *', '120'),
                        validator: (String? v) =>
                            AppValidators.amount(v, min: 1, max: 10000),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _stockCtrl,
                        enabled: !_isSaving,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white),
                        decoration: _fieldStyle('Stock Qty *', '20'),
                        validator: (String? v) {
                          final int? n = int.tryParse(v?.trim() ?? '');
                          if (n == null || n < 0 || n > 10000) {
                            return '0 to 10000';
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _prepCtrl,
                  enabled: !_isSaving,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: _fieldStyle(
                    'Default Prep Time (Minutes) *',
                    '1 to 120',
                  ),
                  validator: (String? v) {
                    final int? n = int.tryParse(v?.trim() ?? '');
                    if (n == null || n < 1 || n > 120) {
                      return 'Must be between 1 and 120 minutes';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descCtrl,
                  enabled: !_isSaving,
                  maxLines: 2,
                  maxLength: 200,
                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                  decoration: _fieldStyle(
                    'Description (Optional)',
                    'Short ingredients or portion note',
                  ),
                ),
                const SizedBox(height: 4),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  activeTrackColor: Colors.green.shade600,
                  title: const Text(
                    'Available for Students',
                    style: TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  value: _isAvailable,
                  onChanged: _isSaving
                      ? null
                      : (bool val) => setState(() => _isAvailable = val),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Text(_isEditing ? 'Save Changes' : 'Add Item'),
        ),
      ],
    );
  }

  InputDecoration _fieldStyle(String label, String? hint) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Colors.white60, fontSize: 13),
      hintStyle: const TextStyle(color: Colors.white38, fontSize: 12.5),
      filled: true,
      fillColor: const Color(0xFF0F172A),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }
}

// =============================================================================
// Helper 2: Quick Restock Dialog (+10 / +25 / +50 & Auto-Enable Option)
// =============================================================================

class _QuickRestockDialog extends StatefulWidget {
  final Map<String, dynamic> item;
  const _QuickRestockDialog({required this.item});

  @override
  State<_QuickRestockDialog> createState() => _QuickRestockDialogState();
}

class _QuickRestockDialogState extends State<_QuickRestockDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _qtyCtrl = TextEditingController();
  final SupabaseClient _supabase = Supabase.instance.client;

  late int _currentStock;
  bool _autoEnable = true;
  bool _isSaving = false;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    _currentStock = (widget.item['stock_quantity'] as num?)?.toInt() ?? 0;
    _qtyCtrl.text = '$_currentStock';
  }

  void _addDelta(int delta) {
    final int base = int.tryParse(_qtyCtrl.text.trim()) ?? _currentStock;
    final int next = (base + delta).clamp(0, 10000).toInt();
    _qtyCtrl.text = '$next';
  }

  Future<void> _saveRestock() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isSaving = true;
      _errorMsg = null;
    });

    try {
      final int newStock = int.parse(_qtyCtrl.text.trim());
      final Map<String, dynamic> updates = <String, dynamic>{
        'stock_quantity': newStock,
      };
      if (newStock == 0) {
        updates['is_available'] = false;
      } else if (_autoEnable) {
        updates['is_available'] = true;
      }

      await _supabase
          .from('menu_items')
          .update(updates)
          .eq('id', widget.item['id'].toString())
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      Navigator.of(context).pop<bool>(true);
    } catch (_) {
      if (mounted) {
        setState(() => _errorMsg = 'Failed to update stock. Check network.');
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String name = (widget.item['name'] as String?) ?? 'Item';

    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(
        'Restock: $name',
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current Stock: $_currentStock',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <int>[10, 25, 50].map((int delta) {
                return ActionChip(
                  label: Text('+$delta'),
                  backgroundColor: const Color(0xFF0F172A),
                  labelStyle: const TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                  ),
                  onPressed: _isSaving ? null : () => _addDelta(delta),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _qtyCtrl,
              enabled: !_isSaving,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                labelText: 'New Total Stock Quantity *',
                labelStyle: const TextStyle(color: Colors.white60),
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              validator: (String? v) {
                final int? n = int.tryParse(v?.trim() ?? '');
                if (n == null || n < 0 || n > 10000) {
                  return 'Enter a valid number (0 - 10000)';
                }
                return null;
              },
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _autoEnable,
              activeColor: Colors.green.shade600,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Auto-enable item for students',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              onChanged: _isSaving
                  ? null
                  : (bool? v) => setState(() => _autoEnable = v == true),
            ),
            if (_errorMsg != null)
              Text(
                _errorMsg!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12.5),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving ? null : _saveRestock,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Update Stock'),
        ),
      ],
    );
  }
}