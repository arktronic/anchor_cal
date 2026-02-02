import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'background_service.dart';
import 'dismissed_events_store.dart';
import 'calendar_launcher.dart';
import 'calendar_refresh_service.dart';
import 'settings_service.dart';

/// Service that monitors calendar events and manages their notifications.
class EventMonitorService {
  static final EventMonitorService _instance = EventMonitorService._();
  static EventMonitorService get instance => _instance;
  EventMonitorService._();

  final DismissedEventsStore _dismissedStore = DismissedEventsStore.instance;
  final SettingsService _settings = SettingsService.instance;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  late final CalendarRefreshService _refreshService;
  bool _initialized = false;

  /// Snooze duration in minutes (synced from settings).
  int get snoozeDurationMinutes => _settings.snoozeDurationMinutes;
  set snoozeDurationMinutes(int value) => _settings.setSnoozeDurationMinutes(value);

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationResponse,
    );

    _refreshService = CalendarRefreshService(
      notificationsPlugin: _notificationsPlugin,
      dismissedStore: _dismissedStore,
    );

    _initialized = true;
  }

  /// Handle a notification response (tap or action button).
  /// Can be called from main.dart when app is launched from notification.
  Future<void> handleNotificationAction(NotificationResponse response) async {
    final payload = response.actionId ?? response.payload;
    final action = NotificationAction.parse(payload);
    if (action == null) return;

    if (action.action == 'dismiss') {
      await _dismissEvent(action.eventHash, action.eventEnd);
    } else if (action.action == 'snooze') {
      await _snoozeEvent(action.eventHash, action.eventEnd);
    } else if (action.action == 'open') {
      await _dismissEvent(action.eventHash, action.eventEnd);
      await CalendarLauncher.openEvent(action.eventId);
    }
  }

  Future<void> _onNotificationResponse(NotificationResponse response) async {
    await handleNotificationAction(response);
    final payload = response.actionId ?? response.payload;
    if (payload != null && payload.startsWith('open|')) {
      SystemNavigator.pop();
    }
  }

  Future<void> _dismissEvent(String eventHash, DateTime eventEnd) async {
    await _dismissedStore.dismiss(eventHash, eventEnd);
    await _notificationsPlugin.cancel(eventHash.hashCode);
  }

  Future<void> _snoozeEvent(String eventHash, DateTime eventEnd) async {
    final now = DateTime.now();
    final snoozeDuration = Duration(minutes: snoozeDurationMinutes);
    final until = now.add(snoozeDuration);
    await _dismissedStore.snooze(eventHash, eventEnd, until);
    await _notificationsPlugin.cancel(eventHash.hashCode);
    await BackgroundService.instance.scheduleSnoozeWakeup(eventHash, snoozeDuration);
  }

  /// Refresh notifications for all active events across all calendars.
  Future<void> refreshNotifications() async {
    await _refreshService.fullRefresh();
  }
}
