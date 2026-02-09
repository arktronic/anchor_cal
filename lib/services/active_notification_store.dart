import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _log(String message) {
  if (kDebugMode) {
    developer.log(message, name: 'AnchorCal.Store');
  }
}

/// Tracks all notification IDs the app has created (both scheduled and shown).
/// Used to cancel displayed notifications when their calendar event is deleted,
/// since awesome_notifications only lists pending scheduled notifications.
class ActiveNotificationStore {
  static final ActiveNotificationStore _instance = ActiveNotificationStore._();
  static ActiveNotificationStore get instance => _instance;
  ActiveNotificationStore._();

  @visibleForTesting
  ActiveNotificationStore.forTest();

  static const String _storageKey = 'active_notification_ids';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    if (_prefs != null) return _prefs!;
    _prefs = await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Record a notification ID as active.
  Future<void> add(int notificationId) async {
    final ids = await getAll();
    ids.add(notificationId);
    await _save(ids);
    _log('ACTIVE add id=$notificationId, total=${ids.length}');
  }

  /// Remove a notification ID from active tracking.
  Future<void> remove(int notificationId) async {
    final ids = await getAll();
    ids.remove(notificationId);
    await _save(ids);
    _log('ACTIVE remove id=$notificationId, total=${ids.length}');
  }

  /// Get all tracked notification IDs.
  Future<Set<int>> getAll() async {
    final prefs = await _preferences;
    await prefs.reload();
    final json = prefs.getString(_storageKey);
    if (json == null) return {};
    final list = jsonDecode(json) as List<dynamic>;
    return list.cast<int>().toSet();
  }

  /// Replace all tracked IDs with the given set.
  Future<void> replaceAll(Set<int> ids) async {
    await _save(ids);
    _log('ACTIVE replaceAll total=${ids.length}');
  }

  Future<void> _save(Set<int> ids) async {
    final prefs = await _preferences;
    await prefs.setString(_storageKey, jsonEncode(ids.toList()));
  }
}
