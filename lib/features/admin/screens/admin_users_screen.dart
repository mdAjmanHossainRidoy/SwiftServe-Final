import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/models/user_role.dart';
import '../../../core/validators/app_validators.dart';

typedef JsonMap = Map<String, dynamic>;
typedef StringMap = Map<String, String>;

class AdminUsersScreen extends StatefulWidget {
  const AdminUsersScreen({super.key});

  @override
  State<AdminUsersScreen> createState() => _AdminUsersScreenState();
}

class _AdminUsersScreenState extends State<AdminUsersScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final TextEditingController _searchCtrl = TextEditingController();

  static const List<StringMap> _roleFilters = <StringMap>[
    <String, String>{'key': 'all', 'label': 'All'},
    <String, String>{'key': 'student', 'label': 'Student'},
    <String, String>{'key': 'kitchen', 'label': 'Kitchen'},
    <String, String>{'key': 'counter', 'label': 'Counter'},
    <String, String>{'key': 'admin', 'label': 'Admin'},
  ];

  String? _currentAdminId;
  String _selectedRoleFilter = 'all';
  bool _onlySuspended = false;

  bool _isLoadingStats = true;
  bool _isLoadingUsers = true;
  bool _isTogglingStatus = false;

  String? _errorMessage;
  JsonMap _stats = <String, dynamic>{};
  List<JsonMap> _users = <JsonMap>[];
  JsonMap? _selectedUser;

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

    _currentAdminId = currentUser.id;
    _refreshAll();
  }

  Future<void> _refreshAll() async {
    await Future.wait<void>(<Future<void>>[
      _fetchStats(),
      _fetchUsers(),
    ]);
  }

  /// Live user & role telemetry strip (RPC: admin_get_user_stats)
  Future<void> _fetchStats() async {
    if (mounted) setState(() => _isLoadingStats = true);
    try {
      final dynamic raw = await _supabase
          .rpc('admin_get_user_stats')
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      if (raw is Map) {
        setState(() => _stats = JsonMap.from(raw));
      }
    } catch (_) {
      // Directory remains usable even if stats strip experiences a transient failure
    } finally {
      if (mounted) setState(() => _isLoadingStats = false);
    }
  }

  /// Server-side directory search & role filter (RPC: search_users_detailed)
  Future<void> _fetchUsers() async {
    if (mounted) {
      setState(() {
        _isLoadingUsers = true;
        _errorMessage = null;
      });
    }

    try {
      final String? roleParam =
          _selectedRoleFilter == 'all' ? null : _selectedRoleFilter;

      final dynamic raw = await _supabase
          .rpc(
            'search_users_detailed',
            params: <String, dynamic>{
              'p_query': _searchCtrl.text.trim(),
              'p_role_filter': roleParam,
              'p_limit': 50,
              'p_offset': 0,
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      List<JsonMap> list = <JsonMap>[
        if (raw is List)
          for (final dynamic e in raw)
            if (e is Map) JsonMap.from(e),
      ];

      if (_onlySuspended) {
        list = list.where((JsonMap u) => u['is_active'] == false).toList();
      }

      // Keep wide-screen inspector synced with fresh snapshot after updates
      JsonMap? updatedSelected;
      if (_selectedUser != null) {
        final String selId = _selectedUser!['id'].toString();
        for (final JsonMap u in list) {
          if (u['id'].toString() == selId) {
            updatedSelected = u;
            break;
          }
        }
      }

      setState(() {
        _users = list;
        _selectedUser = updatedSelected;
      });
    } on TimeoutException {
      if (mounted) {
        setState(() => _errorMessage = 'User search timed out. Retry.');
      }
    } on PostgrestException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _errorMessage = 'Failed to load user directory.');
      }
    } finally {
      if (mounted) setState(() => _isLoadingUsers = false);
    }
  }

  /// Delete-Free Suspend / Reactivate Handler (Fixed: never pops screen on desktop)
  Future<void> _handleToggleUserStatus(
    JsonMap user, {
    BuildContext? sheetContext,
  }) async {
    if (_isTogglingStatus) return;
    final String targetId = user['id'].toString();
    final bool currentlyActive = user['is_active'] == true;
    final bool nextActive = !currentlyActive;
    final String name = _fullName(user);

    if (targetId == _currentAdminId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text(
            'Self-lockout guard: You cannot suspend your own account.',
          ),
        ),
      );
      return;
    }

    String? reason;
    if (!nextActive) {
      reason = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SuspendReasonDialog(userName: name),
      );
      if (reason == null || reason.trim().isEmpty || !mounted) return;
    } else {
      final bool? ok = await showDialog<bool>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Text(
            'Reactivate $name?',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'This will restore the user\'s login and platform access immediately.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green.shade600,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Reactivate'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }

    setState(() => _isTogglingStatus = true);
    try {
      await _supabase
          .rpc(
            'admin_toggle_user_status',
            params: <String, dynamic>{
              'p_target_user_id': targetId,
              'p_is_active': nextActive,
              'p_reason': nextActive ? null : reason!.trim(),
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              nextActive ? Colors.green.shade700 : Colors.orange.shade800,
          content: Text(
            nextActive
                ? '$name reactivated successfully.'
                : '$name has been suspended.',
          ),
        ),
      );

      // Fixed: Only close the mobile bottom sheet when explicitly opened from one
      if (sheetContext != null && sheetContext.mounted) {
        Navigator.of(sheetContext).pop();
      }
      await _refreshAll();
    } on TimeoutException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Status update timed out. Retry.'),
          ),
        );
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(e.message),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Could not update account status.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isTogglingStatus = false);
    }
  }

  /// Opens session-safe Kitchen / Counter staff provisioning dialog
  Future<void> _openCreateStaffDialog() async {
    final bool? created = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _CreateStaffDialog(),
    );

    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.green.shade700,
          content: const Text('New staff account provisioned successfully.'),
        ),
      );
      await _refreshAll();
    }
  }

  void _onUserTapped(JsonMap user, bool isWideScreen) {
    setState(() => _selectedUser = user);
    if (!isWideScreen) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF1E293B),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        builder: (BuildContext sheetCtx) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: _buildUserInspectorContent(
                user,
                sheetContext: sheetCtx,
              ),
            ),
          );
        },
      );
    }
  }

  int _statInt(String key) => (_stats[key] as num?)?.toInt() ?? 0;

  String _fullName(JsonMap u) {
    final String f = (u['first_name'] as String?)?.trim() ?? '';
    final String l = (u['last_name'] as String?)?.trim() ?? '';
    final String full = '$f $l'.trim();
    return full.isEmpty ? 'Unnamed User' : full;
  }

  String _formatDate(String? rawIso) {
    if (rawIso == null) return '-';
    final DateTime? dt = DateTime.tryParse(rawIso)?.toLocal();
    if (dt == null) return '-';
    const List<String> m = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${dt.day} ${m[dt.month - 1]} ${dt.year}';
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
          'User Directory & Access',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            child: ElevatedButton.icon(
              onPressed: _openCreateStaffDialog,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 17),
              label: const Text(
                'Add Staff',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool isWide = constraints.maxWidth >= 840;

            return Column(
              children: [
                _buildStatsStrip(),
                _buildSearchAndFilters(),
                if (_errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _buildErrorBanner(_errorMessage!),
                  ),
                Expanded(
                  child: isWide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              flex: 3,
                              child: _buildUserList(isWide: true),
                            ),
                            Container(
                              width: 1,
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                            Expanded(
                              flex: 2,
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: _selectedUser == null
                                    ? _buildEmptyInspectorHint()
                                    : Container(
                                        padding: const EdgeInsets.all(18),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1E293B),
                                          borderRadius:
                                              BorderRadius.circular(16),
                                          border: Border.all(
                                            color: Colors.white
                                                .withValues(alpha: 0.08),
                                          ),
                                        ),
                                        child: _buildUserInspectorContent(
                                          _selectedUser!,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        )
                      : _buildUserList(isWide: false),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Section 1: Live Role & Status Counters
  Widget _buildStatsStrip() {
    if (_isLoadingStats && _stats.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: LinearProgressIndicator(
          color: Color(0xFFFF5722),
          backgroundColor: Colors.white12,
        ),
      );
    }

    final List<JsonMap> cards = <JsonMap>[
      <String, dynamic>{
        'label': 'TOTAL',
        'val': _statInt('total_users'),
        'color': Colors.white,
      },
      <String, dynamic>{
        'label': 'STUDENTS',
        'val': _statInt('students'),
        'color': Colors.greenAccent,
      },
      <String, dynamic>{
        'label': 'KITCHEN',
        'val': _statInt('kitchen_staff'),
        'color': const Color(0xFFFF5722),
      },
      <String, dynamic>{
        'label': 'COUNTER',
        'val': _statInt('counter_staff'),
        'color': Colors.lightBlueAccent,
      },
      <String, dynamic>{
        'label': 'SUSPENDED',
        'val': _statInt('suspended_users'),
        'color': Colors.redAccent,
      },
    ];

    return SizedBox(
      height: 76,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (BuildContext _, int __) => const SizedBox(width: 8),
        itemBuilder: (BuildContext context, int i) {
          final JsonMap c = cards[i];
          final Color color = c['color'] as Color;
          return Container(
            width: 106,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.32)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${c['val']}',
                  style: TextStyle(
                    color: color,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  c['label'] as String,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Section 2: Reactive Search Bar + Role & Suspended Filter Chips
  Widget _buildSearchAndFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  textInputAction: TextInputAction.search,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _fetchUsers(),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText:
                        'Search name, username, student ID, email or phone...',
                    hintStyle: const TextStyle(
                      color: Colors.white38,
                      fontSize: 13,
                    ),
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
                              _fetchUsers();
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    contentPadding: const EdgeInsets.symmetric(vertical: 11),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 46,
                child: ElevatedButton(
                  onPressed: _isLoadingUsers ? null : _fetchUsers,
                  child: const Text(
                    'SEARCH',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                FilterChip(
                  label: const Text('Suspended'),
                  selected: _onlySuspended,
                  showCheckmark: false,
                  selectedColor: Colors.redAccent,
                  backgroundColor: const Color(0xFF1E293B),
                  side: BorderSide(
                    color: _onlySuspended
                        ? Colors.redAccent
                        : Colors.redAccent.withValues(alpha: 0.4),
                  ),
                  labelStyle: TextStyle(
                    color: _onlySuspended ? Colors.white : Colors.redAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                  onSelected: (bool val) {
                    setState(() => _onlySuspended = val);
                    _fetchUsers();
                  },
                ),
                const SizedBox(width: 8),
                ..._roleFilters.map((StringMap f) {
                  final bool selected = _selectedRoleFilter == f['key'];
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f['label']!),
                      selected: selected,
                      showCheckmark: false,
                      selectedColor: const Color(0xFFFF5722),
                      backgroundColor: const Color(0xFF1E293B),
                      side: BorderSide.none,
                      labelStyle: TextStyle(
                        color: selected ? Colors.white : Colors.white70,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.w500,
                        fontSize: 12,
                      ),
                      onSelected: (_) {
                        setState(() => _selectedRoleFilter = f['key']!);
                        _fetchUsers();
                      },
                    ),
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Section 3: Material-Backed User Directory List (Zero ListTile Assertions)
  Widget _buildUserList({required bool isWide}) {
    if (_isLoadingUsers) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFF5722)),
      );
    }

    if (_users.isEmpty) {
      return const Center(
        child: Text(
          'No users found matching your filter.',
          style: TextStyle(color: Colors.white60, fontSize: 14.5),
        ),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFFFF5722),
      backgroundColor: const Color(0xFF1E293B),
      onRefresh: _refreshAll,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _users.length,
        itemBuilder: (BuildContext context, int index) {
          final JsonMap u = _users[index];
          final String id = u['id'].toString();
          final bool isSelected =
              isWide && _selectedUser?['id'].toString() == id;
          final bool isActive = u['is_active'] == true;
          final UserRole? role = UserRole.tryParse(u['role'] as String?);
          final double bal = (u['wallet_balance'] as num?)?.toDouble() ?? 0.0;
          final String sid = (u['student_id'] as String?)?.trim() ?? '';

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: isSelected
                  ? const Color(0xFFFF5722).withValues(alpha: 0.14)
                  : const Color(0xFF1E293B),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
                side: BorderSide(
                  color: isSelected
                      ? const Color(0xFFFF5722)
                      : (!isActive
                          ? Colors.redAccent.withValues(alpha: 0.5)
                          : Colors.white.withValues(alpha: 0.06)),
                ),
              ),
              child: ListTile(
                onTap: () => _onUserTapped(u, isWide),
                leading: CircleAvatar(
                  backgroundColor: isActive
                      ? const Color(0xFF0F172A)
                      : Colors.redAccent.withValues(alpha: 0.2),
                  child: Text(
                    _fullName(u)[0].toUpperCase(),
                    style: TextStyle(
                      color: isActive ? Colors.white : Colors.redAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        _fullName(u),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildRolePill(
                      role?.displayName ?? (u['role']?.toString() ?? 'User'),
                    ),
                  ],
                ),
                subtitle: Text(
                  '@${u['username']}${sid.isNotEmpty ? ' • $sid' : ''} • ${isActive ? 'Active' : 'SUSPENDED'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isActive ? Colors.white60 : Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '৳ ${bal.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontWeight: FontWeight.w800,
                        fontSize: 13.5,
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: Colors.white38,
                      size: 16,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Section 4: Selected User Inspector + Delete-Free Suspend / Reactivate
  Widget _buildUserInspectorContent(
    JsonMap user, {
    BuildContext? sheetContext,
  }) {
    final String id = user['id'].toString();
    final bool isActive = user['is_active'] == true;
    final bool isSelf = id == _currentAdminId;
    final UserRole? role = UserRole.tryParse(user['role'] as String?);
    final double bal = (user['wallet_balance'] as num?)?.toDouble() ?? 0.0;
    final int ordersCount = (user['total_orders'] as num?)?.toInt() ?? 0;
    final String sid = (user['student_id'] as String?)?.trim() ?? 'Not provided';
    final String phone = (user['phone'] as String?)?.trim() ?? '-';
    final String email = (user['email'] as String?)?.trim() ?? '-';
    final String? suspReason = (user['suspended_reason'] as String?)?.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _buildRolePill(role?.displayName ?? 'User'),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: (isActive ? Colors.greenAccent : Colors.redAccent)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isActive ? Colors.greenAccent : Colors.redAccent,
                ),
              ),
              child: Text(
                isActive ? 'ACTIVE' : 'SUSPENDED',
                style: TextStyle(
                  color: isActive ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _fullName(user),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          '@${user['username']}',
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 13.5,
            fontFamily: 'monospace',
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Divider(color: Colors.white12, height: 1),
        ),
        _detailLine('Email', email),
        _detailLine('Student ID', sid),
        _detailLine('Phone', phone),
        _detailLine('Wallet Balance', '৳ ${bal.toStringAsFixed(2)}'),
        _detailLine('Total Orders', '$ordersCount'),
        _detailLine('Joined On', _formatDate(user['created_at'] as String?)),
        if (!isActive && suspReason != null && suspReason.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
            ),
            child: Text(
              'Suspension Reason: $suspReason',
              style: const TextStyle(
                color: Color(0xFFFCA5A5),
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: (isSelf || _isTogglingStatus)
                ? null
                : () => _handleToggleUserStatus(
                      user,
                      sheetContext: sheetContext,
                    ),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  isActive ? Colors.redAccent : Colors.green.shade600,
              disabledBackgroundColor: Colors.white12,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: _isTogglingStatus
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    isActive
                        ? Icons.block_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 19,
                  ),
            label: Text(
              isSelf
                  ? 'CURRENT ADMIN SESSION (PROTECTED)'
                  : (isActive ? 'SUSPEND ACCOUNT' : 'REACTIVATE ACCOUNT'),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'User deletion is intentionally disabled to preserve order & wallet audit records.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.38),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _detailLine(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              v,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRolePill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFF5722).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: Color(0xFFFF5722),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildEmptyInspectorHint() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 60, horizontal: 20),
      child: Column(
        children: [
          Icon(Icons.manage_accounts_outlined, size: 48, color: Colors.white24),
          SizedBox(height: 12),
          Text(
            'Select any user to inspect details or manage account suspension.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, fontSize: 13.5),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        msg,
        style: const TextStyle(color: Color(0xFFFCA5A5), fontSize: 13),
      ),
    );
  }
}

// =============================================================================
// Helper 1: Mandatory Audit Reason Dialog for Suspending a User
// =============================================================================

class _SuspendReasonDialog extends StatefulWidget {
  final String userName;
  const _SuspendReasonDialog({required this.userName});

  @override
  State<_SuspendReasonDialog> createState() => _SuspendReasonDialogState();
}

class _SuspendReasonDialogState extends State<_SuspendReasonDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _reasonCtrl = TextEditingController();

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: Text(
        'Suspend ${widget.userName}?',
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'User will be blocked from signing in and placing orders immediately.',
              style: TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _reasonCtrl,
              maxLength: 180,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
              decoration: InputDecoration(
                labelText: 'Suspension Reason *',
                hintText: 'e.g., Policy violation / graduated student',
                labelStyle: const TextStyle(color: Colors.white60),
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              validator: (String? v) => AppValidators.requiredReason(
                v,
                fieldName: 'Suspension reason',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop<String>(_reasonCtrl.text.trim());
            }
          },
          child: const Text('Confirm Suspend'),
        ),
      ],
    );
  }
}

// =============================================================================
// Helper 2: Session-Safe Staff Provisioning Dialog (Calls Edge Function)
// =============================================================================

class _CreateStaffDialog extends StatefulWidget {
  const _CreateStaffDialog();

  @override
  State<_CreateStaffDialog> createState() => _CreateStaffDialogState();
}

class _CreateStaffDialogState extends State<_CreateStaffDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final SupabaseClient _supabase = Supabase.instance.client;

  final TextEditingController _firstCtrl = TextEditingController();
  final TextEditingController _lastCtrl = TextEditingController();
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  String _staffRole = 'kitchen';
  bool _isCreating = false;
  String? _errorMsg;

  Future<void> _createStaff() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isCreating = true;
      _errorMsg = null;
    });

    try {
      final FunctionResponse res = await _supabase.functions
          .invoke(
            'admin-create-staff',
            body: <String, dynamic>{
              'first_name': _firstCtrl.text.trim(),
              'last_name': _lastCtrl.text.trim(),
              'username': _usernameCtrl.text.trim().toLowerCase(),
              'email': _emailCtrl.text.trim().toLowerCase(),
              'phone': _phoneCtrl.text.trim(),
              'password': _passwordCtrl.text,
              'role': _staffRole,
            },
          )
          .timeout(const Duration(seconds: 12));

      if (!mounted) return;
      if (res.status >= 200 && res.status < 300) {
        Navigator.of(context).pop<bool>(true);
      } else {
        final String errText =
            res.data is Map && (res.data as Map)['error'] != null
                ? (res.data as Map)['error'].toString()
                : 'Failed to create staff account.';
        setState(() => _errorMsg = errText);
      }
    } on FunctionException catch (e) {
      if (mounted) {
        final String details = e.details is Map && (e.details as Map)['error'] != null
            ? (e.details as Map)['error'].toString()
            : (e.details?.toString() ??
                'Staff creation service error. Ensure `admin-create-staff` Edge Function is deployed.');
        setState(() => _errorMsg = details);
      }
    } on TimeoutException {
      if (mounted) {
        setState(() => _errorMsg = 'Request timed out. Check connection.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errorMsg = 'Could not create staff user.');
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text(
        'Provision Staff Account',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
                DropdownButtonFormField<String>(
                  initialValue: _staffRole,
                  dropdownColor: const Color(0xFF0F172A),
                  style: const TextStyle(color: Colors.white),
                  decoration: _style('Staff Role *'),
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem<String>(
                      value: 'kitchen',
                      child: Text('Kitchen Staff (KDS + Stock Switch)'),
                    ),
                    DropdownMenuItem<String>(
                      value: 'counter',
                      child: Text(
                        'Counter Staff (Queue + Verify + Wallet Desk)',
                      ),
                    ),
                  ],
                  onChanged: _isCreating
                      ? null
                      : (String? v) {
                          if (v != null) setState(() => _staffRole = v);
                        },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _firstCtrl,
                        enabled: !_isCreating,
                        style: const TextStyle(color: Colors.white),
                        decoration: _style('First Name *'),
                        validator: (String? v) =>
                            AppValidators.name(v, fieldName: 'First name'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _lastCtrl,
                        enabled: !_isCreating,
                        style: const TextStyle(color: Colors.white),
                        decoration: _style('Last Name *'),
                        validator: (String? v) =>
                            AppValidators.name(v, fieldName: 'Last name'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _usernameCtrl,
                  enabled: !_isCreating,
                  style: const TextStyle(color: Colors.white),
                  decoration: _style('Username *'),
                  validator: AppValidators.username,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _emailCtrl,
                  enabled: !_isCreating,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Colors.white),
                  decoration: _style('Email *'),
                  validator: AppValidators.email,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phoneCtrl,
                  enabled: !_isCreating,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: Colors.white),
                  decoration: _style('Phone (017XXXXXXXX) *'),
                  validator: AppValidators.phone,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordCtrl,
                  enabled: !_isCreating,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: _style('Initial Password *'),
                  validator: AppValidators.password,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _isCreating ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isCreating ? null : _createStaff,
          child: _isCreating
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Create Staff'),
        ),
      ],
    );
  }

  InputDecoration _style(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white60, fontSize: 13),
      filled: true,
      fillColor: const Color(0xFF0F172A),
      errorMaxLines: 2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }
}