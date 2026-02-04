import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _log(String message) {
  if (kDebugMode) {
    developer.log(message, name: 'AnchorCal.Store');
  }
}

/// Stores dismissed events keyed by content hash.
/// Hash includes eventId + event fields, uniquely identifying each occurrence.
class DismissedEventsStore {
  static final DismissedEventsStore _instance = DismissedEventsStore._();
  static DismissedEventsStore get instance => _instance;
  DismissedEventsStore._();

  static const String _storageKey = 'dismissed_events';

  SharedPreferences? _prefs;

  Future<SharedPreferences> get _preferences async {
    if (_prefs != null) return _prefs!;
    _prefs = await SharedPreferences.getInstance();
    return _prefs!;
  }

  /// Load events map from storage.
  Future<Map<String, _DismissedEntry>> _loadEntries() async {
    final prefs = await _preferences;
    await prefs.reload();
    final json = prefs.getString(_storageKey);
    if (json == null) return {};
    final map = jsonDecode(json) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(k, _DismissedEntry.fromJson(v)));
  }

  static const int _maxJsonBytes = 500000; // 500KB safety limit

  /// Save events map to storage.
  Future<void> _saveEntries(Map<String, _DismissedEntry> entries) async {
    final prefs = await _preferences;
    var json = jsonEncode(entries.map((k, v) => MapEntry(k, v.toJson())));
    if (json.length > _maxJsonBytes) {
      _pruneOldest(entries, json.length);
      json = jsonEncode(entries.map((k, v) => MapEntry(k, v.toJson())));
    }
    await prefs.setString(_storageKey, json);
  }

  /// Remove oldest entries until under size limit.
  void _pruneOldest(Map<String, _DismissedEntry> entries, int currentSize) {
    final sorted = entries.entries.toList()
      ..sort((a, b) => a.value.eventEnd.compareTo(b.value.eventEnd));
    while (currentSize > _maxJsonBytes && sorted.isNotEmpty) {
      final oldest = sorted.removeAt(0);
      entries.remove(oldest.key);
      currentSize -= 80; // Approximate bytes per entry
    }
  }

  /// Mark an event occurrence as dismissed.
  Future<void> dismiss(String eventHash, DateTime eventEnd) async {
    _log('STORE dismiss hash=${eventHash.substring(0, 8)}');
    final entries = await _loadEntries();
    entries[eventHash] = _DismissedEntry(
      eventEnd: eventEnd,
      snoozedUntil: null,
    );
    await _saveEntries(entries);
    _log('STORE dismiss complete, total=${entries.length}');
  }

  /// Snooze an event occurrence until a specific time.
  Future<void> snooze(
    String eventHash,
    DateTime eventEnd,
    DateTime until,
  ) async {
    _log('STORE snooze hash=${eventHash.substring(0, 8)} until=$until');
    final entries = await _loadEntries();
    entries[eventHash] = _DismissedEntry(
      eventEnd: eventEnd,
      snoozedUntil: until,
    );
    await _saveEntries(entries);
    _log('STORE snooze complete, total=${entries.length}');
  }

  /// Check if an event occurrence is dismissed (excludes snoozed entries).
  Future<bool> isDismissed(String eventHash) async {
    final entries = await _loadEntries();
    final entry = entries[eventHash];
    final result = entry != null && entry.snoozedUntil == null;
    _log('STORE isDismissed hash=${eventHash.substring(0, 8)} => $result');
    return result;
  }

  /// Check if an event occurrence is snoozed (returns snooze end time, or null).
  Future<DateTime?> getSnoozedUntil(String eventHash) async {
    final entries = await _loadEntries();
    return entries[eventHash]?.snoozedUntil;
  }

  /// Remove a dismissed event occurrence (re-enable notifications).
  Future<void> undismiss(String eventHash) async {
    final entries = await _loadEntries();
    entries.remove(eventHash);
    await _saveEntries(entries);
  }

  /// Clear all dismissed events.
  Future<void> clearAll() async {
    final prefs = await _preferences;
    await prefs.remove(_storageKey);
  }

  /// Clear expired snooze entries (snooze time has passed).
  Future<void> clearExpiredSnoozes() async {
    final entries = await _loadEntries();
    final now = DateTime.now();
    entries.removeWhere(
      (_, e) => e.snoozedUntil != null && e.snoozedUntil!.isBefore(now),
    );
    await _saveEntries(entries);
  }

  /// Remove dismissed events for events that ended more than [days] ago.
  Future<int> cleanupOldEntries({int days = 30}) async {
    final entries = await _loadEntries();
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final before = entries.length;
    entries.removeWhere((_, e) => e.eventEnd.isBefore(cutoff));
    await _saveEntries(entries);
    return before - entries.length;
  }
}

/// Internal model for a dismissed/snoozed event entry.
class _DismissedEntry {
  final DateTime eventEnd;
  final DateTime? snoozedUntil;

  _DismissedEntry({required this.eventEnd, this.snoozedUntil});

  factory _DismissedEntry.fromJson(Map<String, dynamic> json) {
    return _DismissedEntry(
      eventEnd: DateTime.fromMillisecondsSinceEpoch(json['end'] as int),
      snoozedUntil: json['snooze'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['snooze'] as int)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'end': eventEnd.millisecondsSinceEpoch,
    if (snoozedUntil != null) 'snooze': snoozedUntil!.millisecondsSinceEpoch,
  };
}
