/// SwiftServe-এর ৪-স্তরের RBAC রোল মডেল (Single Source of Truth)।
/// প্রতিটি রোলের সাথে তার DB ভ্যালু, UI লেবেল এবং ড্যাশবোর্ড রাউট যুক্ত আছে।
enum UserRole {
  student(
    dbValue: 'student',
    displayName: 'Student',
    homeRoute: '/student/home',
  ),
  kitchen(
    dbValue: 'kitchen',
    displayName: 'Kitchen Staff',
    homeRoute: '/kitchen/kds',
  ),
  counter(
    dbValue: 'counter',
    displayName: 'Counter Staff',
    homeRoute: '/counter/queue',
  ),
  admin(
    dbValue: 'admin',
    displayName: 'Admin',
    homeRoute: '/admin/dashboard',
  );

  /// Supabase `profiles.role` কলামে যে মানটি সংরক্ষিত থাকে
  final String dbValue;

  /// UI ব্যাজ, প্রোফাইল ও অ্যাডমিন টেবিলে দেখানোর নাম
  final String displayName;

  /// অথেনটিকেশনের পর ইউজার যে মূল স্ক্রিনে প্রবেশ করবে
  final String homeRoute;

  const UserRole({
    required this.dbValue,
    required this.displayName,
    required this.homeRoute,
  });

  /// ডাটাবেস থেকে পাওয়া কাঁচা স্ট্রিংকে নিরাপদে UserRole-এ রূপান্তর করে।
  /// অবৈধ বা null মান এলে ক্র্যাশ না করে `null` রিটার্ন করে।
  static UserRole? tryParse(String? rawRole) {
    if (rawRole == null) return null;

    final String normalized = rawRole.trim().toLowerCase();
    for (final UserRole role in UserRole.values) {
      if (role.dbValue == normalized) {
        return role;
      }
    }
    return null;
  }

  // ==================== UI Convenience Helpers ====================
  // সতর্কতা: এগুলো কেবল UI নিয়ন্ত্রণের জন্য; প্রকৃত নিরাপত্তা Supabase RLS/RPC দেয়।

  bool get isStaff => this != UserRole.student;

  bool get canAccessKds => this == UserRole.kitchen || this == UserRole.admin;

  bool get canAccessWalletDesk =>
      this == UserRole.counter || this == UserRole.admin;
}