import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Types of notification events that can be logged.
enum NotificationEventType {
  scheduled,
  shown,
  dismissed,
  snoozed,
  opened,
  cancelled,
  skippedActive,
}

/// A single notification event log entry.
class NotificationLogEntry {
  final DateTime timestamp;
  final NotificationEventType eventType;
  final String eventTitle;
  final String eventHash;
  final int? notificationId;
  final String? extra;

  NotificationLogEntry({
    required this.timestamp,
    required this.eventType,
    required this.eventTitle,
    required this.eventHash,
    this.notificationId,
    this.extra,
  });

  factory NotificationLogEntry.fromJson(Map<String, dynamic> json) {
    return NotificationLogEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['ts'] as int),
      eventType: NotificationEventType.values[json['type'] as int],
      eventTitle: json['title'] as String,
      eventHash: json['hash'] as String,
      notificationId: json['nid'] as int?,
      extra: json['extra'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'ts': timestamp.millisecondsSinceEpoch,
    'type': eventType.index,
    'title': eventTitle,
    'hash': eventHash,
    if (notificationId != null) 'nid': notificationId,
    if (extra != null) 'extra': extra,
  };

  String get eventTypeName {
    switch (eventType) {
      case NotificationEventType.scheduled:
        return 'SCHEDULED';
      case NotificationEventType.shown:
        return 'SHOWN';
      case NotificationEventType.dismissed:
        return 'DISMISSED';
      case NotificationEventType.snoozed:
        return 'SNOOZED';
      case NotificationEventType.opened:
        return 'OPENED';
      case NotificationEventType.cancelled:
        return 'CANCELLED';
      case NotificationEventType.skippedActive:
        return 'SKIP_ACTIVE';
    }
  }
}

/// Persistent store for notification event logs (debug only).
class NotificationLogStore {
  static final NotificationLogStore _instance = NotificationLogStore._();
  static NotificationLogStore get instance => _instance;
  NotificationLogStore._();

  static const String _storageKey = 'notification_log';
  static const int _maxEntries = 500;
  static const int _maxJsonBytes = 200000; // 200KB limit

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Log a notification event (only in debug builds).
  Future<void> log({
    required NotificationEventType eventType,
    required String eventTitle,
    required String eventHash,
    int? notificationId,
    String? extra,
  }) async {
    if (!kDebugMode) return;

    final entry = NotificationLogEntry(
      timestamp: DateTime.now(),
      eventType: eventType,
      eventTitle: eventTitle,
      eventHash: eventHash,
      notificationId: notificationId,
      extra: extra,
    );

    final entries = await _loadEntries();
    entries.insert(0, entry);

    // Prune to max entries
    while (entries.length > _maxEntries) {
      entries.removeLast();
    }

    await _saveEntries(entries);
  }

  /// Load all log entries.
  Future<List<NotificationLogEntry>> _loadEntries() async {
    final prefs = await _preferences;
    await prefs.reload();
    final json = prefs.getString(_storageKey);
    if (json == null) return [];

    final list = jsonDecode(json) as List<dynamic>;
    return list
        .map((e) => NotificationLogEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Get all log entries (public access for debug screen).
  Future<List<NotificationLogEntry>> getEntries() async {
    if (!kDebugMode) return [];
    return _loadEntries();
  }

  /// Save log entries.
  Future<void> _saveEntries(List<NotificationLogEntry> entries) async {
    final prefs = await _preferences;
    var json = jsonEncode(entries.map((e) => e.toJson()).toList());

    // Prune if over size limit
    while (json.length > _maxJsonBytes && entries.isNotEmpty) {
      entries.removeLast();
      json = jsonEncode(entries.map((e) => e.toJson()).toList());
    }

    await prefs.setString(_storageKey, json);
  }

  /// Clear all log entries.
  Future<void> clear() async {
    final prefs = await _preferences;
    await prefs.remove(_storageKey);
  }
}
