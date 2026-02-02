import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Helper for requesting special permissions.
class PermissionsHelper {
  static const _channel = MethodChannel('anchor_cal/permissions');

  /// Check if auto-revoke (unused app hibernation) is disabled for this app.
  /// Returns true if disabled (good), false if enabled, null if unsupported.
  static Future<bool?> isAutoRevokeDisabled() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'isAutoRevokeWhitelisted',
      );
      return result;
    } on PlatformException {
      return null; // Not supported on this Android version
    } on MissingPluginException {
      return null;
    }
  }

  /// Open settings to disable auto-revoke for this app.
  static Future<void> openAutoRevokeSettings() async {
    try {
      // Try the direct auto-revoke intent first (Android 11+)
      const intent = AndroidIntent(
        action: 'android.intent.action.AUTO_REVOKE_PERMISSIONS',
        data: 'package:com.arktronic.anchor_cal',
      );
      await intent.launch();
    } catch (_) {
      // Fall back to app settings
      await openAppSettings();
    }
  }

  /// Request battery optimization exemption.
  /// Returns true if granted or already exempt.
  static Future<bool> requestBatteryOptimizationExemption() async {
    final status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isGranted) return true;

    final result = await Permission.ignoreBatteryOptimizations.request();
    return result.isGranted;
  }

  /// Check if battery optimization is disabled for this app.
  static Future<bool> isBatteryOptimizationDisabled() async {
    return await Permission.ignoreBatteryOptimizations.isGranted;
  }

  /// Request exact alarm permission (Android 12+).
  /// Returns true if granted.
  static Future<bool> requestExactAlarmPermission() async {
    final status = await Permission.scheduleExactAlarm.status;
    if (status.isGranted) return true;

    final result = await Permission.scheduleExactAlarm.request();
    return result.isGranted;
  }

  /// Check if exact alarm permission is granted.
  static Future<bool> hasExactAlarmPermission() async {
    return await Permission.scheduleExactAlarm.isGranted;
  }

  /// Request all permissions needed for reliable notifications.
  /// Returns a map of permission names to their granted status.
  static Future<Map<String, bool>> requestAllNotificationPermissions() async {
    final results = <String, bool>{};

    // Notification permission
    var notifStatus = await Permission.notification.status;
    if (!notifStatus.isGranted) {
      notifStatus = await Permission.notification.request();
    }
    results['notification'] = notifStatus.isGranted;

    // Exact alarm permission
    results['exactAlarm'] = await requestExactAlarmPermission();

    // Battery optimization exemption
    results['batteryOptimization'] =
        await requestBatteryOptimizationExemption();

    return results;
  }

  /// Request all permissions needed for the app to function.
  /// Returns a map of permission names to their granted status.
  static Future<Map<String, bool>> requestAllPermissions() async {
    final results = <String, bool>{};

    // Calendar permission (must come first - core functionality)
    var calStatus = await Permission.calendarFullAccess.status;
    if (!calStatus.isGranted) {
      calStatus = await Permission.calendarFullAccess.request();
    }
    results['calendar'] = calStatus.isGranted;

    // Notification permission
    var notifStatus = await Permission.notification.status;
    if (!notifStatus.isGranted) {
      notifStatus = await Permission.notification.request();
    }
    results['notification'] = notifStatus.isGranted;

    // Exact alarm permission
    results['exactAlarm'] = await requestExactAlarmPermission();

    // Battery optimization exemption
    results['batteryOptimization'] =
        await requestBatteryOptimizationExemption();

    return results;
  }

  /// Check if all essential permissions are granted.
  static Future<bool> hasAllEssentialPermissions() async {
    final calendar = await Permission.calendarFullAccess.isGranted;
    final notification = await Permission.notification.isGranted;
    return calendar && notification;
  }
}
