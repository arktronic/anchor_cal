import 'package:workmanager/workmanager.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dismissed_events_store.dart';
import 'calendar_refresh_service.dart';
import 'settings_service.dart';

const String _taskName = 'anchorCalRefresh';
const String _taskUniqueName = 'com.arktronic.anchor_cal.refresh';
const String _snoozeTaskName = 'anchorCalSnoozeWakeup';

/// Background notification response handler - must be top-level function.
@pragma('vm:entry-point')
@pragma('vm:entry-point')
Future<void> onBackgroundNotificationResponse(
  NotificationResponse response,
) async {
  try {
    final payload = response.actionId ?? response.payload;
    final action = NotificationAction.parse(payload);
    if (action == null) return;

    await _handleBackgroundAction(action);
  } catch (_) {
    // Silently fail - notification action in background isolate
  }
}

Future<void> _handleBackgroundAction(NotificationAction action) async {
  final dismissedStore = DismissedEventsStore.instance;
  final notificationsPlugin = FlutterLocalNotificationsPlugin();

  if (action.action == 'dismiss') {
    await dismissedStore.dismiss(action.eventHash, action.eventEnd);
    await notificationsPlugin.cancel(action.eventHash.hashCode);
  } else if (action.action == 'snooze') {
    final settings = SettingsService.instance;
    await settings.init();
    final snoozeDuration = Duration(minutes: settings.snoozeDurationMinutes);
    final until = DateTime.now().add(snoozeDuration);
    await dismissedStore.snooze(action.eventHash, action.eventEnd, until);
    await notificationsPlugin.cancel(action.eventHash.hashCode);
    await BackgroundService.instance.scheduleSnoozeWakeup(
      action.eventHash,
      snoozeDuration,
    );
  }
}

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
    final calendarPlugin = DeviceCalendarPlugin();
    final notificationsPlugin = FlutterLocalNotificationsPlugin();

    // Initialize settings service for background context
    await SettingsService.instance.init();

    // Initialize notifications with background response handler
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);
    await notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: onBackgroundNotificationResponse,
      onDidReceiveBackgroundNotificationResponse:
          onBackgroundNotificationResponse,
    );

    // Check calendar permissions
    final permResult = await calendarPlugin.hasPermissions();
    if (!(permResult.data ?? false)) return;

    final dismissedStore = DismissedEventsStore.instance;

    // Clear expired snoozes so notifications can re-appear
    await dismissedStore.clearExpiredSnoozes();

    // Cleanup old dismissed entries (older than 30 days)
    await dismissedStore.cleanupOldEntries();

    final refreshService = CalendarRefreshService(
      calendarPlugin: calendarPlugin,
      notificationsPlugin: notificationsPlugin,
      dismissedStore: dismissedStore,
    );

    await refreshService.fullRefresh();
  } catch (_) {
    // Silently fail - WorkManager will retry on next scheduled run
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
