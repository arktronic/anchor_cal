import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dismissed_events_store.dart';
import 'event_processor.dart';
import 'settings_service.dart';

/// Parsed notification action payload.
class NotificationAction {
  final String action;
  final String eventId;
  final String eventHash;
  final DateTime eventEnd;

  NotificationAction({
    required this.action,
    required this.eventId,
    required this.eventHash,
    required this.eventEnd,
  });

  /// Parse a notification payload string into an action.
  /// Returns null if payload is invalid.
  static NotificationAction? parse(String? payload) {
    if (payload == null) return null;

    final parts = payload.split('|');
    if (parts.length < 3) return null;

    final eventEndMs = parts.length > 3 ? int.tryParse(parts[3]) : null;
    final eventEnd = eventEndMs != null
        ? DateTime.fromMillisecondsSinceEpoch(eventEndMs)
        : DateTime.now();

    return NotificationAction(
      action: parts[0],
      eventId: parts[1],
      eventHash: parts[2],
      eventEnd: eventEnd,
    );
  }
}

/// Shared calendar refresh logic for foreground and background execution.
class CalendarRefreshService {
  final DeviceCalendarPlugin _calendarPlugin;
  final FlutterLocalNotificationsPlugin _notificationsPlugin;
  final DismissedEventsStore _dismissedStore;

  CalendarRefreshService({
    DeviceCalendarPlugin? calendarPlugin,
    required FlutterLocalNotificationsPlugin notificationsPlugin,
    required DismissedEventsStore dismissedStore,
  }) : _calendarPlugin = calendarPlugin ?? DeviceCalendarPlugin(),
       _notificationsPlugin = notificationsPlugin,
       _dismissedStore = dismissedStore;

  /// Refresh notifications for all active events across all calendars.
  /// Returns the set of valid notification IDs, or empty set on error.
  Future<Set<int>> refreshNotifications() async {
    final validNotificationIds = <int>{};

    try {
      final calendarsResult = await _calendarPlugin.retrieveCalendars();
      if (!calendarsResult.isSuccess) {
        // Calendar access failed (permissions revoked, etc.)
        return validNotificationIds;
      }
      final calendars = calendarsResult.data ?? [];

      final now = DateTime.now();
      final start = now.subtract(const Duration(days: 1));
      final end = now.add(const Duration(days: 7));

      final processor = EventProcessor(
        dismissedStore: _dismissedStore,
        notificationsPlugin: _notificationsPlugin,
        firstRunTimestamp: SettingsService.instance.firstRunTimestamp,
      );

      for (final calendar in calendars) {
        if (calendar.id == null) continue;

        try {
          final eventsResult = await _calendarPlugin.retrieveEvents(
            calendar.id,
            RetrieveEventsParams(startDate: start, endDate: end),
          );
          final events = eventsResult.data ?? [];

          for (final event in events) {
            final processedIds = await processor.processEvent(event, now);
            validNotificationIds.addAll(processedIds);
          }
        } catch (_) {
          // Skip this calendar on error, continue with others
          continue;
        }
      }
    } catch (_) {
      // Calendar plugin error - return empty set (no orphan cleanup)
    }

    return validNotificationIds;
  }

  /// Cancel notifications that no longer correspond to calendar events.
  Future<void> cancelOrphanedNotifications(Set<int> validIds) async {
    final activeNotifications = await _notificationsPlugin
        .getActiveNotifications();
    for (final notification in activeNotifications) {
      if (!validIds.contains(notification.id)) {
        await _notificationsPlugin.cancel(notification.id!);
      }
    }
  }

  /// Full refresh: update notifications and cancel orphans.
  /// Silently handles errors to prevent background task crashes.
  Future<void> fullRefresh() async {
    try {
      final validIds = await refreshNotifications();
      // Only cancel orphans if we successfully retrieved events
      if (validIds.isNotEmpty) {
        await cancelOrphanedNotifications(validIds);
      }
    } catch (_) {
      // Swallow errors in background context
    }
  }
}
