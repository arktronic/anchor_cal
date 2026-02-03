import 'package:flutter/services.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'background_service.dart';
import 'dismissed_events_store.dart';
import 'calendar_launcher.dart';
import 'calendar_refresh_service.dart';
import 'settings_service.dart';
import 'event_processor.dart';

/// Notification controller with static methods for awesome_notifications.
@pragma('vm:entry-point')
class NotificationController {
  /// Called when a notification is created
  @pragma('vm:entry-point')
  static Future<void> onNotificationCreatedMethod(
    ReceivedNotification receivedNotification,
  ) async {
    // Not used, but required by awesome_notifications
  }

  /// Called when a notification is displayed
  @pragma('vm:entry-point')
  static Future<void> onNotificationDisplayedMethod(
    ReceivedNotification receivedNotification,
  ) async {
    // Not used, but required by awesome_notifications
  }

  /// Called when a notification is dismissed by swipe
  @pragma('vm:entry-point')
  static Future<void> onDismissActionReceivedMethod(
    ReceivedAction receivedAction,
  ) async {
    await EventMonitorService.instance._handleDismissAction(receivedAction);
  }

  /// Called when user taps notification or action button
  @pragma('vm:entry-point')
  static Future<void> onActionReceivedMethod(
    ReceivedAction receivedAction,
  ) async {
    await EventMonitorService.instance.handleAction(receivedAction);
  }
}

/// Service that monitors calendar events and manages their notifications.
class EventMonitorService {
  static final EventMonitorService _instance = EventMonitorService._();
  static EventMonitorService get instance => _instance;
  EventMonitorService._();

  final DismissedEventsStore _dismissedStore = DismissedEventsStore.instance;
  final SettingsService _settings = SettingsService.instance;

  late final CalendarRefreshService _refreshService;
  bool _initialized = false;

  /// Snooze duration in minutes (synced from settings).
  int get snoozeDurationMinutes => _settings.snoozeDurationMinutes;
  set snoozeDurationMinutes(int value) =>
      _settings.setSnoozeDurationMinutes(value);

  Future<void> init() async {
    if (_initialized) return;

    // Initialize awesome_notifications
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

    // Set up notification listeners
    await AwesomeNotifications().setListeners(
      onActionReceivedMethod: NotificationController.onActionReceivedMethod,
      onNotificationCreatedMethod:
          NotificationController.onNotificationCreatedMethod,
      onNotificationDisplayedMethod:
          NotificationController.onNotificationDisplayedMethod,
      onDismissActionReceivedMethod:
          NotificationController.onDismissActionReceivedMethod,
    );

    _refreshService = CalendarRefreshService(dismissedStore: _dismissedStore);

    _initialized = true;
  }

  /// Handle swipe-dismiss action
  Future<void> _handleDismissAction(ReceivedAction receivedAction) async {
    final payload = receivedAction.payload;
    if (payload == null) return;

    final eventHash = payload['eventHash'];
    final eventEndMs = int.tryParse(payload['eventEnd'] ?? '');
    if (eventHash == null || eventEndMs == null) return;

    final eventEnd = DateTime.fromMillisecondsSinceEpoch(eventEndMs);
    await _dismissEvent(eventHash, eventEnd, receivedAction.id);
  }

  /// Handle tap or action button press
  Future<void> handleAction(ReceivedAction receivedAction) async {
    final payload = receivedAction.payload;
    if (payload == null) return;

    final eventId = payload['eventId'];
    final eventHash = payload['eventHash'];
    final eventEndMs = int.tryParse(payload['eventEnd'] ?? '');
    if (eventHash == null || eventEndMs == null) return;

    final eventEnd = DateTime.fromMillisecondsSinceEpoch(eventEndMs);
    final buttonKey = receivedAction.buttonKeyPressed;

    if (buttonKey == 'dismiss') {
      await _dismissEvent(eventHash, eventEnd, receivedAction.id);
    } else if (buttonKey == 'snooze') {
      await _snoozeEvent(eventHash, eventEnd, receivedAction.id);
    } else {
      // 'open' button or tap on notification body
      await _dismissEvent(eventHash, eventEnd, receivedAction.id);
      if (eventId != null) {
        await CalendarLauncher.openEvent(eventId);
      }
      SystemNavigator.pop();
    }
  }

  Future<void> _dismissEvent(
    String eventHash,
    DateTime eventEnd,
    int? notificationId,
  ) async {
    await _dismissedStore.dismiss(eventHash, eventEnd);
    if (notificationId != null) {
      await AwesomeNotifications().cancel(notificationId);
    }
  }

  Future<void> _snoozeEvent(
    String eventHash,
    DateTime eventEnd,
    int? notificationId,
  ) async {
    final now = DateTime.now();
    final snoozeDuration = Duration(minutes: snoozeDurationMinutes);
    final until = now.add(snoozeDuration);
    await _dismissedStore.snooze(eventHash, eventEnd, until);
    if (notificationId != null) {
      await AwesomeNotifications().cancel(notificationId);
    }
    await BackgroundService.instance.scheduleSnoozeWakeup(
      eventHash,
      snoozeDuration,
    );
  }

  /// Refresh notifications for all active events across all calendars.
  Future<void> refreshNotifications() async {
    await _refreshService.fullRefresh();
  }
}
