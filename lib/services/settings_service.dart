import 'package:shared_preferences/shared_preferences.dart';

/// Service for managing app settings persistence.
class SettingsService {
  static final SettingsService _instance = SettingsService._();
  static SettingsService get instance => _instance;
  SettingsService._();

  static const String _keySnoozeDuration = 'snooze_duration_minutes';
  static const String _keyPersistOverReboot = 'persist_over_reboot';
  static const String _keyFirstRunTimestamp = 'first_run_timestamp';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    await _prefs!.reload(); // Force reload from disk for background isolates
    await _ensureFirstRunTimestamp();
  }

  /// Record first run timestamp if not already set.
  Future<void> _ensureFirstRunTimestamp() async {
    if (_prefs?.getInt(_keyFirstRunTimestamp) == null) {
      await _prefs?.setInt(_keyFirstRunTimestamp, DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// Get the timestamp of when the app was first run.
  /// Returns null if not yet initialized.
  DateTime? get firstRunTimestamp {
    final ms = _prefs?.getInt(_keyFirstRunTimestamp);
    return ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null;
  }

  /// Get snooze duration in minutes (default: 15).
  int get snoozeDurationMinutes => _prefs?.getInt(_keySnoozeDuration) ?? 15;

  /// Set snooze duration in minutes.
  Future<void> setSnoozeDurationMinutes(int minutes) async {
    await _prefs?.setInt(_keySnoozeDuration, minutes);
  }

  /// Whether to persist notifications over device reboots (default: true).
  bool get persistOverReboot => _prefs?.getBool(_keyPersistOverReboot) ?? true;

  /// Set persist over reboot preference.
  Future<void> setPersistOverReboot(bool value) async {
    await _prefs?.setBool(_keyPersistOverReboot, value);
  }
}
