import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/models/user_role.dart';

/// স্প্ল্যাশ স্ক্রিনের অভ্যন্তরীণ স্টেট (UpperCamelCase স্ট্যান্ডার্ড)
enum _SplashScreenStatus { loading, error }

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late final Animation<double> _fadeAnimation;
  late final Animation<double> _scaleAnimation;

  _SplashScreenStatus _status = _SplashScreenStatus.loading;
  String _statusMessage = 'Initializing SwiftServe...';
  String? _errorMessage;

  final SupabaseClient _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _startAnimation();
    // প্রথম ফ্রেম রেন্ডার হওয়ার পর সেশন ও রোল চেক শুরু করা নিরাপদ
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _verifySessionAndRoute();
    });
  }

  /// লোগোর Fade + Scale অ্যানিমেশন সেটআপ
  void _startAnimation() {
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    );

    _scaleAnimation = Tween<double>(begin: 0.82, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutBack,
      ),
    );

    _animationController.forward();
  }

  /// মূল বুটস্ট্র্যাপ গেট: সেশন, টোকেন রিফ্রেশ, ডাটাবেস রোল ও সক্রিয়তা যাচাই
  Future<void> _verifySessionAndRoute() async {
    if (!mounted) return;
    setState(() {
      _status = _SplashScreenStatus.loading;
      _statusMessage = 'Verifying your session...';
      _errorMessage = null;
    });

    final Future<void> minDelay = Future<void>.delayed(
      const Duration(milliseconds: 900),
    );

    try {
      Session? session = _supabase.auth.currentSession;

      // ১. কোনো সেশন না থাকলে সরাসরি লগইন পেজে পাঠাও
      if (session == null) {
        await minDelay;
        _navigateAndReplace('/login');
        return;
      }

      // ২. সেশন টোকেন মেয়াদোত্তীর্ণ হলে রিফ্রেশ করো
      if (session.isExpired) {
        _updateStatusText('Refreshing credentials...');
        final refreshResponse = await _supabase.auth
            .refreshSession()
            .timeout(const Duration(seconds: 10));
        session = refreshResponse.session;

        if (session == null) {
          await minDelay;
          _navigateAndReplace('/login');
          return;
        }
      }

      // ৩. ডাটাবেস থেকে অথরিটেটিভ রোল, সক্রিয়তা ও সাসপেনশন কারণ যাচাই
      _updateStatusText('Loading workspace...');
      final List<dynamic> results = await Future.wait<dynamic>([
        minDelay,
        _supabase
            .from('profiles')
            .select('role, is_active, suspended_reason')
            .eq('id', session.user.id)
            .single()
            .timeout(const Duration(seconds: 10)),
      ]);

      final Map<String, dynamic> profile = results[1] as Map<String, dynamic>;
      final bool isActive = profile['is_active'] == true;
      final UserRole? role = UserRole.tryParse(profile['role'] as String?);

      // ৪. সাসপেন্ডেড অ্যাকাউন্ট বা অবৈধ রোল হলে জোরপূর্বক সাইন-আউট
      if (!isActive || role == null) {
        await _supabase.auth.signOut();
        final String reason = (profile['suspended_reason'] as String?) ?? '';
        _navigateAndReplace(
          '/login',
          arguments: !isActive
              ? 'Your account has been suspended.${reason.isNotEmpty ? ' Reason: $reason' : ' Contact canteen desk.'}'
              : 'Invalid account role detected. Please sign in again.',
        );
        return;
      }

      // ৫. Shared UserRole মডেল থেকে সরাসরি রোল অনুযায়ী ড্যাশবোর্ডে রাউট করো
      _navigateAndReplace(role.homeRoute);
    } on TimeoutException {
      _showRetry('Server response timed out. Check your campus network.');
    } on AuthException {
      await _supabase.auth.signOut();
      _navigateAndReplace('/login');
    } on PostgrestException catch (e) {
      // সঠিক PostgREST কোড: PGRST116 (0 rows returned)
      if (e.code == 'PGRST116') {
        await _supabase.auth.signOut();
        _navigateAndReplace(
          '/login',
          arguments: 'Profile record not found. Contact canteen desk.',
        );
      } else {
        _showRetry('Database connection error. Please retry.');
      }
    } catch (_) {
      // নেটওয়ার্ক সমস্যা হলে লগআউট না করে Retry অপশন দাও
      _showRetry('Unable to connect. Please check your internet.');
    }
  }

  /// স্ট্যাক রিপ্লেস করে রাউট করা (যাতে Back চাপলে Splash-এ ফিরে না আসে)
  void _navigateAndReplace(String routeName, {Object? arguments}) {
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(
      routeName,
      arguments: arguments,
    );
  }

  void _updateStatusText(String text) {
    if (!mounted) return;
    setState(() => _statusMessage = text);
  }

  void _showRetry(String message) {
    if (!mounted) return;
    setState(() {
      _status = _SplashScreenStatus.error; // '=' (অ্যাসাইনমেন্ট), কখনোই '==' নয়!
      _errorMessage = message;
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: ক্র্যাশ-মুক্ত ও পরিষ্কার মডুলার লেআউট
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    const Color brandPrimary = Color(0xFFFF5722);
    const Color bgDark = Color(0xFF0F172A);
    const Color bgSecondary = Color(0xFF1E293B);

    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [bgDark, bgSecondary],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              children: [
                const Spacer(flex: 3),
                _buildAnimatedBrand(brandPrimary),
                const Spacer(flex: 2),
                _buildStatusSection(brandPrimary),
                const Spacer(),
                Text(
                  'V1.0.0 • Real-Time Atomic Architecture @63_E_CSE',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// অংশ ১: অ্যানিমেটেড লোগো ও ব্র্যান্ড টাইটেল (mainAxisSize.min ব্যবহার করায় নিরাপদ)
  Widget _buildAnimatedBrand(Color brandPrimary) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: brandPrimary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: brandPrimary.withValues(alpha: 0.5),
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.bolt_rounded,
                size: 48,
                color: brandPrimary,
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'SwiftServe',
              style: TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: 3.0,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Digital Canteen Management [LU]',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65),
                fontSize: 13.5,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// অংশ ২: ডায়নামিক লোডিং স্পিনার অথবা Retry কন্ট্রোল
  Widget _buildStatusSection(Color brandPrimary) {
    return SizedBox(
      height: 110,
      child: _status == _SplashScreenStatus.loading
          ? Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: brandPrimary,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _statusMessage,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.72),
              fontSize: 13,
            ),
          ),
        ],
      )
          : Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            _errorMessage ?? 'Connection failed.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFFCA5A5),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: _verifySessionAndRoute,
            style: ElevatedButton.styleFrom(
              backgroundColor: brandPrimary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 12,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text(
              'Retry Connection',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}