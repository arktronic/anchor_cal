import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _log(String message) {
  if (kDebugMode) {
    developer.log(message, name: 'AnchorCal.Store');
  }
}

/// Tracks active event hashes for displayed notifications.
/// Used to cancel displayed notifications when their calendar event is deleted,
/// since awesome_notifications only lists pending scheduled notifications.
class ActiveNotificationStore {
  static final ActiveNotificationStore _instance = ActiveNotificationStore._();
  static ActiveNotificationStore get instance => _instance;
  ActiveNotificationStore._();

  @visibleForTesting
  ActiveNotificationStore.forTest();

  static const String _storageKey = 'active_notification_hashes';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    if (_prefs != null) return _prefs!;
    _prefs = await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Record an event hash as active.
  Future<void> add(String eventHash) async {
    final hashes = await getAll();
    hashes.add(eventHash);
    await _save(hashes);
    _log(
      'ACTIVE add hash=${eventHash.substring(0, eventHash.length.clamp(0, 8))}, total=${hashes.length}',
    );
  }

  /// Remove an event hash from active tracking.
  Future<void> remove(String eventHash) async {
    final hashes = await getAll();
    hashes.remove(eventHash);
    await _save(hashes);
    _log(
      'ACTIVE remove hash=${eventHash.substring(0, eventHash.length.clamp(0, 8))}, total=${hashes.length}',
    );
  }

  /// Get all tracked event hashes.
  Future<Set<String>> getAll() async {
    final prefs = await _preferences;
    await prefs.reload();
    final json = prefs.getString(_storageKey);
    if (json == null) return {};
    final list = jsonDecode(json) as List<dynamic>;
    return list.cast<String>().toSet();
  }

  /// Replace all tracked hashes.
  Future<void> replaceAll(Set<String> hashes) async {
    await _save(hashes);
    _log('ACTIVE replaceAll total=${hashes.length}');
  }

  Future<void> _save(Set<String> hashes) async {
    final prefs = await _preferences;
    await prefs.setString(_storageKey, jsonEncode(hashes.toList()));
  }
}
