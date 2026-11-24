import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/models/user_role.dart';
import '../../../core/validators/app_validators.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _identifierCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();

  bool _isLoading = false;
  bool _hidePassword = true;
  bool _didReadArgs = false;
  String? _errorMessage;

  final SupabaseClient _supabase = Supabase.instance.client;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // SplashScreen থেকে পাঠানো সাসপেনশন বা প্রোফাইল এরর মেসেজ ঠিক একবারই রিসিভ করবে
    if (!_didReadArgs) {
      _didReadArgs = true;
      final Object? args = ModalRoute.of(context)?.settings.arguments;
      if (args is String && args.trim().isNotEmpty) {
        _errorMessage = args.trim();
      }
    }
  }

  /// মূল লগইন ফ্লো: Regex যাচাই -> Email/Username রেজলভ -> Auth -> Profile Gate
  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // ১. ইনপুটটি ইমেইল নাকি ইউজারনেম তা শনাক্ত করে ইমেইল বের করা
      final String? resolvedEmail = await _resolveEmail(
        _identifierCtrl.text.trim(),
      );

      if (resolvedEmail == null) {
        _showError('Invalid email/username or password.');
        return;
      }

      // ২. Supabase Auth-এ সাইন-ইন (পাসওয়ার্ডে কখনোই .trim() করা যাবে না)
      final AuthResponse authRes = await _supabase.auth
          .signInWithPassword(
        email: resolvedEmail,
        password: _passwordCtrl.text,
      )
          .timeout(const Duration(seconds: 10));

      final User? user = authRes.user;
      if (user == null) {
        _showError('Authentication failed. Please try again.');
        return;
      }

      // ৩. ডাটাবেস থেকে অথরিটেটিভ রোল, সক্রিয়তা ও সাসপেনশনের কারণ যাচাই
      final Map<String, dynamic> profile = await _supabase
          .from('profiles')
          .select('role, is_active, suspended_reason')
          .eq('id', user.id)
          .single()
          .timeout(const Duration(seconds: 8));

      final bool isActive = profile['is_active'] == true;
      final UserRole? role = UserRole.tryParse(profile['role'] as String?);

      // ৪. সাসপেন্ডেড বা অবৈধ রোল হলে জোরপূর্বক সাইন-আউট
      if (!isActive || role == null) {
        await _supabase.auth.signOut();
        final String reason = (profile['suspended_reason'] as String?) ?? '';
        _showError(
          !isActive
              ? 'Account suspended.${reason.isNotEmpty ? ' Reason: $reason' : ' Contact canteen desk.'}'
              : 'Invalid user role assigned. Contact admin.',
        );
        return;
      }

      // ৫. রোল অনুযায়ী ড্যাশবোর্ডে প্রবেশ (স্ট্যাক থেকে Login পেজ মুছে যাবে)
      if (!mounted) return;
      Navigator.of(context).pushReplacementNamed(role.homeRoute);
    } on TimeoutException {
      _showError('Server response timed out. Check your campus network.');
    } on AuthException {
      // User Enumeration ঠেকাতে সবসময় Generic এরর মেসেজ
      _showError('Invalid email/username or password.');
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST116') {
        await _supabase.auth.signOut();
        _showError('Profile record not found. Contact canteen desk.');
      } else {
        _showError('Database connection error. Please try again.');
      }
    } catch (_) {
      _showError('Connection failed. Check your internet and retry.');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// ইমেইল হলে সরাসরি রিটার্ন করবে, ইউজারনেম হলে RLS-নিরাপদ RPC দিয়ে ইমেইল আনবে
  Future<String?> _resolveEmail(String identifier) async {
    if (AppValidators.isValidEmail(identifier)) {
      return identifier.toLowerCase();
    }

    final dynamic result = await _supabase
        .rpc(
      'get_email_by_username',
      params: {'p_username': identifier},
    )
        .timeout(const Duration(seconds: 8));

    if (result is String && result.trim().isNotEmpty) {
      return result.trim().toLowerCase();
    }
    return null;
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: পরিষ্কার ও মডুলার হেল্পার মেথড (সহজে পড়া ও এডিট করার জন্য)
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 32),
                    if (_errorMessage != null) _buildErrorBanner(),
                    _buildIdentifierField(),
                    const SizedBox(height: 16),
                    _buildPasswordField(),
                    const SizedBox(height: 24),
                    _buildLoginButton(),
                    const SizedBox(height: 24),
                    _buildFooter(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    const Color brandPrimary = Color(0xFFFF5722);
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: brandPrimary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: brandPrimary.withValues(alpha: 0.5),
              width: 1.5,
            ),
          ),
          child: const Icon(
            Icons.bolt_rounded,
            size: 40,
            color: brandPrimary,
          ),
        ),
        const SizedBox(height: 18),
        const Text(
          'Welcome Back',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Sign in to SwiftServe [LU] with email or username',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.65),
            fontSize: 13.5,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
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

  Widget _buildIdentifierField() {
    return TextFormField(
      controller: _identifierCtrl,
      enabled: !_isLoading,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Colors.white),
      decoration: _inputStyle('Email or Username', Icons.person_outline),
      validator: AppValidators.loginIdentifier,
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordCtrl,
      enabled: !_isLoading,
      obscureText: _hidePassword,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _handleLogin(),
      style: const TextStyle(color: Colors.white),
      decoration: _inputStyle('Password', Icons.lock_outline).copyWith(
        suffixIcon: IconButton(
          icon: Icon(
            _hidePassword ? Icons.visibility_off : Icons.visibility,
            color: Colors.white54,
          ),
          onPressed: () => setState(() => _hidePassword = !_hidePassword),
        ),
      ),
      validator: AppValidators.loginPassword,
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFFF5722),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: _isLoading
            ? const SizedBox(
          height: 22,
          width: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white,
          ),
        )
            : const Text(
          'SIGN IN',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'New Student? ',
              style: TextStyle(color: Colors.white60),
            ),
            GestureDetector(
              onTap: _isLoading
                  ? null
                  : () => Navigator.of(context).pushNamed('/register'),
              child: const Text(
                'Create Account',
                style: TextStyle(
                  color: Color(0xFFFF5722),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Staff accounts (Kitchen, Counter, Admin) are issued by Admin only.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.38),
            fontSize: 11.5,
          ),
        ),
      ],
    );
  }

  InputDecoration _inputStyle(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white60),
      prefixIcon: Icon(icon, color: Colors.white54),
      filled: true,
      fillColor: const Color(0xFF1E293B),
      errorMaxLines: 2,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFFF5722), width: 1.5),
      ),
    );
  }
}