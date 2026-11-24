/// SwiftServe-এর সমস্ত ফর্মের জন্য কেন্দ্রীয় Regex ভ্যালিডেশন ইঞ্জিন।
/// এখানে Auth ([P02], [P03]) এবং Admin/Wallet ([P16], [P17], [P18])-এর
/// সমস্ত লিনিয়ার-টাইম O(n) ভ্যালিডেটর একত্রে রাখা হয়েছে।
class AppValidators {
  AppValidators._(); // ইনস্ট্যান্স তৈরি প্রতিরোধ করা হলো

  // ==================== Pre-Compiled Linear-Time Regex ====================

  // শুধু ইংরেজি অক্ষর; মাঝে স্পেস, হাইফেন বা অ্যাপোস্ট্রফি অনুমোদিত (যেমন: Al-Amin)
  static final RegExp _nameRegex =
  RegExp(r"^[a-zA-Z]{2,30}(?:[ '-][a-zA-Z]{1,30})*$");

  // অক্ষর দিয়ে শুরু, ৩-২০ ক্যারেক্টার, শুধু অক্ষর/সংখ্যা/আন্ডারস্কোর (@ নিষিদ্ধ)
  static final RegExp _usernameRegex =
  RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,19}$');

  // স্ট্যান্ডার্ড RFC-কমপ্লায়েন্ট ইমেইল প্যাটার্ন (ডোমেইনে ডাবল ডট ছাড়া)
  static final RegExp _emailRegex =
  RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.[a-zA-Z]{2,}$');

  // Optional Student ID: ৪-২০ ক্যারেক্টার, শুরু ও শেষে অবশ্যই অক্ষর বা সংখ্যা
  static final RegExp _studentIdRegex =
  RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{2,18}[A-Za-z0-9]$');

  // বাংলাদেশি বৈধ মোবাইল অপারেটর ফরম্যাট (013-019, +880 সহ বা ছাড়া)
  static final RegExp _bdPhoneRegex =
  RegExp(r'^(?:\+880|880|0)1[3-9]\d{8}$');

  // সর্বোচ্চ ২ দশমিক স্থান পর্যন্ত পজিটিভ টাকা (PostgreSQL NUMERIC(10, 2) ম্যাচিং)
  static final RegExp _currencyRegex =
  RegExp(r'^\d+(?:\.\d{1,2})?$');

  // পাসওয়ার্ডের ৪টি স্বতন্ত্র শর্ত (আলাদা চেক থাকায় ইউজার নিখুঁত এরর মেসেজ পায়)
  static final RegExp _hasUppercase = RegExp(r'[A-Z]');
  static final RegExp _hasLowercase = RegExp(r'[a-z]');
  static final RegExp _hasDigit = RegExp(r'\d');
  static final RegExp _hasSpecial = RegExp(r'[@$!%*?&#^()_\-+=]');

  // ==================== Boolean Identification Helpers ====================

  /// ইনপুটটি বৈধ ইমেইল কি না যাচাই (Login স্ক্রিনে Email বনাম Username চেনার জন্য)
  static bool isValidEmail(String input) {
    final text = input.trim();
    if (text.length > 254 || text.contains('..')) return false;
    return _emailRegex.hasMatch(text);
  }

  /// ইনপুটটি বৈধ ইউজারনেম কি না যাচাই
  static bool isValidUsername(String input) {
    return _usernameRegex.hasMatch(input.trim());
  }

  // ==================== [P02] Login Screen Validators ====================

  /// Email অথবা Username — যেকোনো একটি বৈধ ফরম্যাটে থাকতে হবে
  static String? loginIdentifier(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Email or username is required';

    if (text.contains('@')) {
      return isValidEmail(text) ? null : 'Enter a valid email address';
    }
    return isValidUsername(text)
        ? null
        : 'Username: 3-20 chars, start with letter (A-Z, 0-9, _)';
  }

  /// লগইনে পুরোনো অ্যাকাউন্টের Backward Compatibility রক্ষায় শুধু নন-এম্পটি চেক
  static String? loginPassword(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    return null;
  }

  // ==================== [P03] Registration Validators ====================

  /// First Name ও Last Name ভ্যালিডেশন
  static String? name(String? value, {required String fieldName}) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$fieldName is required';
    if (text.length < 2 || text.length > 30) {
      return '$fieldName must be 2 to 30 characters';
    }
    if (!_nameRegex.hasMatch(text)) {
      return '$fieldName can only contain letters, spaces, or hyphens';
    }
    return null;
  }

  /// ইউনিক Username ভ্যালিডেশন
  static String? username(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Username is required';
    if (!_usernameRegex.hasMatch(text)) {
      return '3-20 chars, start with a letter (letters, numbers, _ only)';
    }
    return null;
  }

  /// ইউনিভার্সিটি বা ব্যক্তিগত Email ভ্যালিডেশন
  static String? email(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Email is required';
    if (!isValidEmail(text)) return 'Enter a valid email address';
    return null;
  }

  /// Optional Student ID — খালি রাখলে পাস করবে, লিখলে সঠিক ফরম্যাট বাধ্যতামূলক
  static String? optionalStudentId(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    if (!_studentIdRegex.hasMatch(text)) {
      return 'Invalid ID (4-20 alphanumeric chars, hyphen allowed inside)';
    }
    return null;
  }

  /// বাংলাদেশি ফোন নম্বর ভ্যালিডেশন
  static String? phone(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Phone number is required';
    if (!_bdPhoneRegex.hasMatch(text)) {
      return 'Enter a valid BD phone number (e.g., 017XXXXXXXX)';
    }
    return null;
  }

  /// Strong Password ভ্যালিডেশন (পাসওয়ার্ডে কখনোই .trim() করা যাবে না)
  static String? password(String? value) {
    final text = value ?? '';
    if (text.isEmpty) return 'Password is required';
    if (text.length < 8) return 'Password must be at least 8 characters';
    if (text.length > 64) return 'Password cannot exceed 64 characters';
    if (!_hasUppercase.hasMatch(text)) return 'Add at least 1 uppercase letter (A-Z)';
    if (!_hasLowercase.hasMatch(text)) return 'Add at least 1 lowercase letter (a-z)';
    if (!_hasDigit.hasMatch(text)) return 'Add at least 1 number (0-9)';
    if (!_hasSpecial.hasMatch(text)) {
      return 'Add at least 1 special character (@\$!%*?&#)';
    }
    return null;
  }

  /// Confirm Password ম্যাচিং চেক
  static String? confirmPassword(String? value, String originalPassword) {
    if (value == null || value.isEmpty) return 'Please confirm your password';
    if (value != originalPassword) return 'Passwords do not match';
    return null;
  }

  // ==================== [P16/P17/P18] Finance & Admin Validators ====================

  /// Wallet Top-Up, Refund ও Menu Price-এর জন্য টাকা ভ্যালিডেশন
  static String? amount(
      String? value, {
        double min = 1.0,
        double max = 50000.0,
      }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Amount is required';
    if (!_currencyRegex.hasMatch(text)) {
      return 'Enter a valid amount (max 2 decimal places)';
    }
    final double? parsed = double.tryParse(text);
    if (parsed == null || parsed < min || parsed > max) {
      return 'Amount must be between ${min.toStringAsFixed(0)} and ${max.toStringAsFixed(0)} BDT';
    }
    return null;
  }

  /// Audit Reason (Wallet Note, Order Cancel, Account Suspension) ভ্যালিডেশন
  static String? requiredReason(
      String? value, {
        String fieldName = 'Reason',
        int minLength = 3,
        int maxLength = 200,
      }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '$fieldName is required for audit';
    if (text.length < minLength) {
      return '$fieldName must be at least $minLength characters';
    }
    if (text.length > maxLength) {
      return '$fieldName cannot exceed $maxLength characters';
    }
    return null;
  }
}