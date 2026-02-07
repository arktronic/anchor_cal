import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'dismissed_events_store.dart';
import 'event_processor.dart';
import 'settings_service.dart';
import 'notification_log_store.dart';

void _log(String message) {
  if (kDebugMode) {
    developer.log(message, name: 'AnchorCal');
  }
}

/// Shared calendar refresh logic for foreground and background execution.
class CalendarRefreshService {
  final DeviceCalendarPlugin _calendarPlugin;
  final DismissedEventsStore _dismissedStore;
  final tz.Location _localTimezone;

  CalendarRefreshService({
    DeviceCalendarPlugin? calendarPlugin,
    required DismissedEventsStore dismissedStore,
    required tz.Location localTimezone,
  }) : _calendarPlugin = calendarPlugin ?? DeviceCalendarPlugin(),
       _dismissedStore = dismissedStore,
       _localTimezone = localTimezone;

  /// Refresh notifications for all active events across all calendars.
  /// Returns the set of valid notification IDs, or empty set on error.
  Future<Set<int>> refreshNotifications() async {
    final validNotificationIds = <int>{};

    try {
      final calendarsResult = await _calendarPlugin.retrieveCalendars();
      if (!calendarsResult.isSuccess) {
        _log('Failed to retrieve calendars');
        return validNotificationIds;
      }
      final calendars = calendarsResult.data ?? [];
      _log('Found ${calendars.length} calendars');

      final now = DateTime.now();
      final start = now.subtract(const Duration(days: 1));
      final end = now.add(const Duration(days: 7));

      // Get already scheduled notification IDs to avoid re-scheduling
      final scheduledNotifications = await AwesomeNotifications()
          .listScheduledNotifications();
      final alreadyScheduledIds = scheduledNotifications
          .map((n) => n.content?.id)
          .whereType<int>()
          .toSet();
      _log('Already scheduled: ${alreadyScheduledIds.length} notifications');

      final processor = EventProcessor(
        dismissedStore: _dismissedStore,
        localTimezone: _localTimezone,
        firstRunTimestamp: SettingsService.instance.firstRunTimestamp,
        alreadyScheduledIds: alreadyScheduledIds,
      );

      for (final calendar in calendars) {
        if (calendar.id == null) {
          _log('Skipping calendar "${calendar.name}" - null id');
          continue;
        }

        try {
          _log('Processing calendar "${calendar.name}" (id=${calendar.id})');
          final eventsResult = await _calendarPlugin.retrieveEvents(
            calendar.id,
            RetrieveEventsParams(startDate: start, endDate: end),
          );
          if (!eventsResult.isSuccess) {
            _log('  Failed to retrieve events: ${eventsResult.errors}');
            continue;
          }
          final events = eventsResult.data ?? [];
          _log('Calendar "${calendar.name}": ${events.length} events');

          for (final event in events) {
            final reminders = event.reminders ?? [];
            _log(
              '  Event "${event.title}": ${reminders.length} reminders, start=${event.start}',
            );
            final processedIds = await processor.processEvent(event, now);
            if (processedIds.isNotEmpty) {
              _log('    Processed IDs: $processedIds');
            }
            validNotificationIds.addAll(processedIds);
          }
        } catch (e) {
          _log('Error processing calendar ${calendar.name}: $e');
          continue;
        }
      }
      _log('Total valid notification IDs: ${validNotificationIds.length}');
    } catch (e, st) {
      _log('Calendar plugin error: $e\n$st');
    }

    return validNotificationIds;
  }

  /// Cancel notifications that no longer correspond to calendar events.
  /// Cancels both active (visible) and pending (scheduled) notifications.
  Future<void> cancelOrphanedNotifications(Set<int> validIds) async {
    // Get all scheduled notifications
    final scheduledNotifications = await AwesomeNotifications()
        .listScheduledNotifications();
    for (final notification in scheduledNotifications) {
      final id = notification.content?.id;
      if (id != null && !validIds.contains(id)) {
        _log('Cancelling orphaned scheduled notification: $id');
        await AwesomeNotifications().cancel(id);
        await NotificationLogStore.instance.log(
          eventType: NotificationEventType.cancelled,
          eventTitle: notification.content?.title ?? 'Unknown Event',
          eventHash: notification.content?.payload?['eventHash'] ?? 'unknown',
          notificationId: id,
          extra: 'Orphaned (event removed or changed)',
        );
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
