import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SessionStore {
  SessionStore._();

  static const _sessionKey = 'ansar_employee_session_v1';
  static const _employeeIdKey = 'ansar_employee_id';

  static Future<void> save(Map<String, dynamic> employee) async {
    final id = employee['id']?.toString().trim() ?? '';
    if (id.isEmpty) throw ArgumentError('Employee session requires an id');
    final safeEmployee = Map<String, dynamic>.from(employee)
      ..remove('password')
      ..remove('password_hash')
      ..remove('password_digest')
      ..remove('pin')
      ..remove('secret');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_employeeIdKey, id);
    await preferences.setString(_sessionKey, jsonEncode(safeEmployee));
  }

  static Future<Map<String, dynamic>?> load() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getString(_sessionKey);
    if (value == null || value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final data = Map<String, dynamic>.from(decoded);
      if ((data['id']?.toString().trim() ?? '').isEmpty) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_sessionKey);
    await preferences.remove(_employeeIdKey);
  }
}
