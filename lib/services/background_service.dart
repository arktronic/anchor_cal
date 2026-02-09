import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'active_notification_store.dart';
import 'dismissed_events_store.dart';
import 'calendar_refresh_service.dart';
import 'settings_service.dart';
import 'event_processor.dart';

void _log(String message) {
  if (kDebugMode) {
    developer.log(message, name: 'AnchorCal');
  }
}

const String _taskName = 'anchorCalRefresh';
const String _taskUniqueName = 'com.arktronic.anchor_cal.refresh';
const String _snoozeTaskName = 'anchorCalSnoozeWakeup';

/// Callback dispatcher for background work - must be top-level function.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == _taskName || task == _snoozeTaskName) {
      await _refreshNotificationsInBackground();
    }
    return true;
  });
}

/// Background notification refresh logic (runs without Flutter UI).
/// Wrapped in try-catch to prevent WorkManager task failures.
Future<void> _refreshNotificationsInBackground() async {
  try {
    _log('Background refresh starting...');
    final calendarPlugin = DeviceCalendarPlugin();

    // Detect local timezone for display formatting.
    tz_data.initializeTimeZones();
    final tzInfo = await FlutterTimezone.getLocalTimezone();
    final localTimezone = tz.getLocation(tzInfo.identifier);
    _log('Detected local timezone: ${localTimezone.name}');

    // Initialize settings service for background context
    await SettingsService.instance.init();
    _log(
      'Settings initialized, firstRun: ${SettingsService.instance.firstRunTimestamp}',
    );

    // Initialize awesome_notifications in background
    await AwesomeNotifications()
        .initialize('resource://drawable/ic_notification', [
          NotificationChannel(
            channelKey: EventProcessor.channelKey,
            channelName: EventProcessor.channelName,
            channelDescription: EventProcessor.channelDescription,
            defaultColor: const Color(0xFF7C3AED),
            importance: NotificationImportance.High,
            channelShowBadge: true,
            onlyAlertOnce: true,
          ),
        ], debug: false);

    // Check calendar permissions
    final permResult = await calendarPlugin.hasPermissions();
    _log('Calendar permissions: ${permResult.data}');
    if (!(permResult.data ?? false)) {
      _log('No calendar permissions, aborting');
      return;
    }

    final dismissedStore = DismissedEventsStore.instance;

    // Clear expired snoozes so notifications can re-appear
    await dismissedStore.clearExpiredSnoozes();

    // Cleanup old dismissed entries (older than 30 days)
    await dismissedStore.cleanupOldEntries();

    final refreshService = CalendarRefreshService(
      calendarPlugin: calendarPlugin,
      dismissedStore: dismissedStore,
      activeStore: ActiveNotificationStore.instance,
      localTimezone: localTimezone,
    );

    await refreshService.fullRefresh();
    _log('Background refresh completed successfully');
  } catch (e, st) {
    _log('Background refresh error: $e\n$st');
  }
}

/// Service to manage background calendar monitoring.
class BackgroundService {
  static final BackgroundService _instance = BackgroundService._();
  static BackgroundService get instance => _instance;
  BackgroundService._();

  bool _initialized = false;

  /// Initialize the background service. Call once at app startup.
  Future<void> init() async {
    if (_initialized) return;

    await Workmanager().initialize(callbackDispatcher);
    _initialized = true;
  }

  /// Register periodic background task (every 15 minutes).
  Future<void> registerPeriodicTask() async {
    await Workmanager().registerPeriodicTask(
      _taskUniqueName,
      _taskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  }

  /// Cancel all background tasks.
  Future<void> cancelAll() async {
    await Workmanager().cancelAll();
  }

  /// Schedule a one-off task to re-show snoozed notification.
  /// Uses WorkManager which may not be exactly on time, but the periodic
  /// refresh will also catch expired snoozes.
  Future<void> scheduleSnoozeWakeup(String eventHash, Duration delay) async {
    final uniqueName = 'com.arktronic.anchor_cal.snooze.$eventHash';
    await Workmanager().registerOneOffTask(
      uniqueName,
      _snoozeTaskName,
      initialDelay: delay,
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: false,
        requiresCharging: false,
        requiresDeviceIdle: false,
        requiresStorageNotLow: false,
      ),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }
}
