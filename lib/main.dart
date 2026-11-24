import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Module A: Auth [P01 - P03]
import 'features/auth/screens/splash_screen.dart';
import 'features/auth/screens/login_screen.dart';
import 'features/auth/screens/register_screen.dart';

// Module B: Student [P04 - P09]
import 'features/student/screens/student_home_screen.dart';
import 'features/student/screens/item_detail_screen.dart';
import 'features/student/screens/cart_checkout_screen.dart';
import 'features/student/screens/live_order_tracker_screen.dart';
import 'features/student/screens/student_wallet_screen.dart';
import 'features/student/screens/order_history_profile_screen.dart';

// Module C: Kitchen [P10 - P11]
import 'features/kitchen/screens/kitchen_kds_screen.dart';
import 'features/kitchen/screens/kitchen_stock_screen.dart';

// Module D: Counter [P12 - P14]
import 'features/counter/screens/counter_queue_screen.dart';
import 'features/counter/screens/counter_verify_screen.dart';
import 'features/counter/screens/counter_dispute_screen.dart';

// Module E: Admin [P15 - P18]
import 'features/admin/screens/admin_dashboard_screen.dart';
import 'features/admin/screens/admin_menu_screen.dart';
import 'features/admin/screens/admin_wallet_desk_screen.dart';
import 'features/admin/screens/admin_users_screen.dart';

/// Supabase কনফিগারেশন (কখনোই SERVICE_ROLE Key এখানে বসবে না)
class AppConfig {
  AppConfig._();

  // এখানে defaultValue-তে নিজের আসল Supabase URL বসাও
  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://tddbanvhtkedbnzlbrax.supabase.co',
  );

  // এখানে defaultValue-তে নিজের আসল Supabase Anon / Publishable Key বসাও
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'sb_publishable_1ul8R_0HGuDV4gJKDYeN6Q_HVx13XKk',
  );
}

Future<void> main() async {
  // ১. অ্যাসিংক ইনিশিয়ালাইজেশনের আগে Flutter Engine বাইন্ডিং চালু করা বাধ্যতামূলক
  WidgetsFlutterBinding.ensureInitialized();

  // ২. ডিবাগ গার্ড: খালি বা প্লেসহোল্ডার ক্রেডেনশিয়াল থাকলে শুরুতেই ধরবে
  assert(
    AppConfig.supabaseUrl.trim().isNotEmpty &&
        AppConfig.supabaseAnonKey.trim().isNotEmpty &&
        !AppConfig.supabaseUrl.contains('YOUR_PROJECT_ID') &&
        AppConfig.supabaseAnonKey != 'YOUR_SUPABASE_ANON_KEY',
    'Set real SUPABASE_URL and SUPABASE_ANON_KEY in AppConfig defaultValue '
    'or pass via --dart-define.',
  );

  // ৩. Supabase ক্লায়েন্ট ইনিশিয়ালাইজেশন
  await Supabase.initialize(
    url: AppConfig.supabaseUrl.trim(),
    anonKey: AppConfig.supabaseAnonKey.trim(),
  );

  // ৪. রুট উইজেট মাউন্ট করো
  runApp(const SwiftServeApp());
}

class SwiftServeApp extends StatelessWidget {
  const SwiftServeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SwiftServe',
      debugShowCheckedModeBanner: false,
      theme: _buildAppTheme(),
      initialRoute: '/',
      onGenerateRoute: _AppRouter.generateRoute,

      // =====================================================================
      // ✅ FIX: Localization Delegates added to resolve "No MaterialLocalizations"
      // =====================================================================
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en', 'US'), // English
        Locale('bn', 'BD'), // Bengali (Optional, if you want native Bangla UI)
      ],
    );
  }

  /// পুরো ১৮টি পেজের কেন্দ্রীয় থিম সিস্টেম (Single Source of Truth)
  ThemeData _buildAppTheme() {
    const Color primaryOrange = Color(0xFFFF5722);
    const Color darkBackground = Color(0xFF0F172A);
    const Color darkSurface = Color(0xFF1E293B);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: primaryOrange,
        secondary: primaryOrange,
        surface: darkSurface,
        error: Colors.redAccent,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryOrange,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

/// কেন্দ্রীয় রাউট ডিসপ্যাচার (সব ১৮টি পেজের পূর্ণাঙ্গ নেভিগেশন ম্যাপ)
class _AppRouter {
  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      // ==================== MODULE A: AUTH ====================
      case '/':
        return _page(const SplashScreen(), settings);
      case '/login':
        return _page(const LoginScreen(), settings);
      case '/register':
        return _page(const RegisterScreen(), settings);

      // ==================== MODULE B: STUDENT ====================
      case '/student/home':
        return _page(const StudentHomeScreen(), settings);
      case '/student/item-detail':
        return _page(const ItemDetailScreen(), settings);
      case '/student/cart':
        return _page(const CartCheckoutScreen(), settings);
      case '/student/order-tracker':
        return _page(const LiveOrderTrackerScreen(), settings);
      case '/student/wallet':
        return _page(const StudentWalletScreen(), settings);
      case '/student/history':
        return _page(const OrderHistoryProfileScreen(), settings);

      // ==================== MODULE C: KITCHEN ====================
      case '/kitchen/kds':
        return _page(const KitchenKdsScreen(), settings);
      case '/kitchen/stock':
        return _page(const KitchenStockScreen(), settings);

      // ==================== MODULE D: COUNTER ====================
      case '/counter/queue':
        return _page(const CounterQueueScreen(), settings);
      case '/counter/verify':
        return _page(const CounterVerifyScreen(), settings);
      case '/counter/disputes':
        return _page(const CounterDisputeScreen(), settings);

      // ==================== MODULE E: ADMIN ====================
      case '/admin/dashboard':
        return _page(const AdminDashboardScreen(), settings);
      case '/admin/menu':
        return _page(const AdminMenuScreen(), settings);
      case '/admin/wallet':
        return _page(const AdminWalletDeskScreen(), settings);
      case '/admin/users':
        return _page(const AdminUsersScreen(), settings);

      // ==================== 404 FALLBACK ====================
      default:
        return _page(
          Scaffold(
            appBar: AppBar(title: const Text('Route Not Found')),
            body: Center(
              child: Text(
                'Unknown route: ${settings.name}',
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ),
          settings,
        );
    }
  }

  static MaterialPageRoute<dynamic> _page(
    Widget child,
    RouteSettings settings,
  ) {
    return MaterialPageRoute<dynamic>(
      builder: (_) => child,
      settings: settings,
    );
  }
}
