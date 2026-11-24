import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/models/user_role.dart';
import '../../../core/validators/app_validators.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  final TextEditingController _firstNameCtrl = TextEditingController();
  final TextEditingController _lastNameCtrl = TextEditingController();
  final TextEditingController _usernameCtrl = TextEditingController();
  final TextEditingController _emailCtrl = TextEditingController();
  final TextEditingController _studentIdCtrl = TextEditingController();
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _passwordCtrl = TextEditingController();
  final TextEditingController _confirmPassCtrl = TextEditingController();

  bool _isLoading = false;
  bool _hidePassword = true;
  bool _hideConfirmPass = true;
  String? _errorMessage;

  final SupabaseClient _supabase = Supabase.instance.client;

  /// স্টুডেন্ট রেজিস্ট্রেশন (ব্যাকএন্ড SQL Trigger স্বয়ংক্রিয়ভাবে Profile ও Wallet তৈরি করবে)
  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final String rawStudentId = _studentIdCtrl.text.trim();
      final String normalizedPhone = _normalizeBdPhone(_phoneCtrl.text.trim());

      final AuthResponse response = await _supabase.auth
          .signUp(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text, // পাসওয়ার্ডে কখনোই .trim() নয়
        data: <String, dynamic>{
          'first_name': _firstNameCtrl.text.trim(),
          'last_name': _lastNameCtrl.text.trim(),
          'username': _usernameCtrl.text.trim().toLowerCase(),
          // Optional ফিল্ড খালি থাকলে NULL পাঠানো বাধ্যতামূলক ("" দিলে Unique ক্র্যাশ হবে)
          'student_id': rawStudentId.isEmpty ? null : rawStudentId,
          'phone': normalizedPhone,
        },
      )
          .timeout(const Duration(seconds: 12));

      if (!mounted) return;

      // ইমেইল কনফার্মেশন অফ থাকলে সরাসরি সেশন তৈরি হয় -> পুরো Auth স্ট্যাক মুছে Home-এ যাও
      if (response.session != null) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          UserRole.student.homeRoute,
              (Route<dynamic> route) => false,
        );
      } else {
        // ইমেইল কনফার্মেশন অন থাকলে পরিষ্কার বার্তা দেখিয়ে Login স্ক্রিনে ফেরত পাঠাও
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Account created! Check your email to verify, then sign in.',
            ),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop();
      }
    } on TimeoutException {
      _showError('Server response timed out. Check your campus network.');
    } on AuthException catch (e) {
      final String msg = e.message.toLowerCase();
      // ডুপ্লিকেট ইমেইল অথবা SQL Trigger-এ ডুপ্লিকেট Username/Student ID ধরা পড়লে
      if (msg.contains('already registered') ||
          msg.contains('database error saving new user') ||
          msg.contains('unique')) {
        _showError('Email, username, or Student ID is already registered.');
      } else {
        _showError(e.message);
      }
    } catch (_) {
      _showError('Registration failed. Check your internet and try again.');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// +88017... বা 88017... ইনপুটকে স্ট্যান্ডার্ড ১১-অঙ্কের 017... ফরম্যাটে নরমালাইজ করে
  String _normalizeBdPhone(String raw) {
    if (raw.startsWith('+880')) return '0${raw.substring(4)}';
    if (raw.startsWith('880')) return '0${raw.substring(3)}';
    return raw;
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _errorMessage = message);
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _usernameCtrl.dispose();
    _emailCtrl.dispose();
    _studentIdCtrl.dispose();
    _phoneCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  // ===========================================================================
  // UI অংশ: পরিষ্কার ও মডুলার হেল্পার মেথড
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Create Student Account',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildSubtitle(),
                    const SizedBox(height: 20),
                    if (_errorMessage != null) _buildErrorBanner(),
                    _buildNameRow(),
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _usernameCtrl,
                      label: 'Username *',
                      hint: 'e.g., ridoy_cse',
                      icon: Icons.alternate_email,
                      validator: AppValidators.username,
                    ),
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _emailCtrl,
                      label: 'University Email *',
                      hint: 'e.g., student@lus.ac.bd',
                      icon: Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                      validator: AppValidators.email,
                    ),
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _studentIdCtrl,
                      label: 'Student ID (Optional)',
                      hint: 'e.g., 221-115-042',
                      icon: Icons.credit_card_outlined,
                      validator: AppValidators.optionalStudentId,
                    ),
                    const SizedBox(height: 14),
                    _buildTextField(
                      controller: _phoneCtrl,
                      label: 'Phone Number *',
                      hint: 'e.g., 017XXXXXXXX',
                      icon: Icons.phone_outlined,
                      keyboardType: TextInputType.phone,
                      validator: AppValidators.phone,
                    ),
                    const SizedBox(height: 14),
                    _buildPasswordField(
                      controller: _passwordCtrl,
                      label: 'Password *',
                      isHidden: _hidePassword,
                      onToggle: () =>
                          setState(() => _hidePassword = !_hidePassword),
                      validator: AppValidators.password,
                    ),
                    const SizedBox(height: 14),
                    _buildPasswordField(
                      controller: _confirmPassCtrl,
                      label: 'Confirm Password *',
                      isHidden: _hideConfirmPass,
                      isLastField: true,
                      onToggle: () =>
                          setState(() => _hideConfirmPass = !_hideConfirmPass),
                      validator: (v) =>
                          AppValidators.confirmPassword(v, _passwordCtrl.text),
                    ),
                    const SizedBox(height: 26),
                    _buildRegisterButton(),
                    const SizedBox(height: 20),
                    _buildSignInFooter(),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitle() {
    return Text(
      'Register to access SwiftServe [LU] canteen ordering and digital wallet.',
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.65),
        fontSize: 13.5,
      ),
    );
  }

  Widget _buildNameRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _buildTextField(
            controller: _firstNameCtrl,
            label: 'First Name *',
            icon: Icons.badge_outlined,
            validator: (v) => AppValidators.name(v, fieldName: 'First name'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildTextField(
            controller: _lastNameCtrl,
            label: 'Last Name *',
            icon: Icons.badge_outlined,
            validator: (v) => AppValidators.name(v, fieldName: 'Last name'),
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String? Function(String?) validator,
    String? hint,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_isLoading,
      keyboardType: keyboardType,
      textInputAction: TextInputAction.next,
      style: const TextStyle(color: Colors.white),
      decoration: _inputStyle(label, icon, hint: hint),
      validator: validator,
    );
  }

  Widget _buildPasswordField({
    required TextEditingController controller,
    required String label,
    required bool isHidden,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
    bool isLastField = false,
  }) {
    return TextFormField(
      controller: controller,
      enabled: !_isLoading,
      obscureText: isHidden,
      textInputAction:
      isLastField ? TextInputAction.done : TextInputAction.next,
      onFieldSubmitted: isLastField ? (_) => _handleRegister() : null,
      style: const TextStyle(color: Colors.white),
      decoration: _inputStyle(label, Icons.lock_outline).copyWith(
        suffixIcon: IconButton(
          icon: Icon(
            isHidden ? Icons.visibility_off : Icons.visibility,
            color: Colors.white54,
          ),
          onPressed: onToggle,
        ),
      ),
      validator: validator,
    );
  }

  Widget _buildRegisterButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleRegister,
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
          'REGISTER ACCOUNT',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _buildSignInFooter() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          'Already have an account? ',
          style: TextStyle(color: Colors.white60),
        ),
        GestureDetector(
          onTap: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text(
            'Sign In',
            style: TextStyle(
              color: Color(0xFFFF5722),
              fontWeight: FontWeight.bold,
            ),
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

  InputDecoration _inputStyle(String label, IconData icon, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: const TextStyle(color: Colors.white60, fontSize: 13.5),
      hintStyle: TextStyle(
        color: Colors.white.withValues(alpha: 0.28),
        fontSize: 13,
      ),
      prefixIcon: Icon(icon, color: Colors.white54, size: 20),
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