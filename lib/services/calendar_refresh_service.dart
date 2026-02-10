import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'active_notification_store.dart';
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
  final ActiveNotificationStore _activeStore;
  final tz.Location _localTimezone;

  /// In-flight refresh future, if any. Prevents concurrent refreshes.
  static Future<void>? _activeRefresh;

  CalendarRefreshService({
    DeviceCalendarPlugin? calendarPlugin,
    required DismissedEventsStore dismissedStore,
    required ActiveNotificationStore activeStore,
    required tz.Location localTimezone,
  }) : _calendarPlugin = calendarPlugin ?? DeviceCalendarPlugin(),
       _dismissedStore = dismissedStore,
       _activeStore = activeStore,
       _localTimezone = localTimezone;

  /// Refresh notifications for all active events across all calendars.
  /// Returns the set of valid event hashes, or null on error.
  Future<Set<String>?> refreshNotifications() async {
    final validHashes = <String>{};

    try {
      final calendarsResult = await _calendarPlugin.retrieveCalendars();
      if (!calendarsResult.isSuccess) {
        _log('Failed to retrieve calendars');
        return null;
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
        activeStore: _activeStore,
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
            final processedHashes = await processor.processEvent(event, now);
            if (processedHashes.isNotEmpty) {
              _log('    Processed hashes: ${processedHashes.length}');
            }
            validHashes.addAll(processedHashes);
          }
        } catch (e) {
          _log('Error processing calendar ${calendar.name}: $e');
          continue;
        }
      }
      _log('Total valid hashes: ${validHashes.length}');
    } catch (e, st) {
      _log('Calendar plugin error: $e\n$st');
      return null;
    }

    return validHashes;
  }

  /// Cancel notifications that no longer correspond to calendar events.
  /// Checks both scheduled (pending) and tracked active (displayed)
  /// notifications, so deleted events have their reminders dismissed.
  Future<void> cancelOrphanedNotifications(Set<String> validHashes) async {
    final validIds = validHashes
        .map(EventProcessor.notificationIdFromHash)
        .toSet();

    // Cancel orphaned scheduled (pending) notifications
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

    // Cancel orphaned displayed notifications via tracked hashes
    final trackedHashes = await _activeStore.getAll();
    for (final hash in trackedHashes) {
      if (!validHashes.contains(hash)) {
        final id = EventProcessor.notificationIdFromHash(hash);
        _log('Cancelling orphaned displayed notification: $id');
        await AwesomeNotifications().cancel(id);
        await NotificationLogStore.instance.log(
          eventType: NotificationEventType.cancelled,
          eventTitle: 'Unknown Event',
          eventHash: hash,
          notificationId: id,
          extra: 'Orphaned displayed (event removed or changed)',
        );
      }
    }

    // Update tracked set to only valid hashes
    await _activeStore.replaceAll(validHashes);
  }

  /// Full refresh: update notifications and cancel orphans.
  /// Only one refresh runs at a time; concurrent calls await the active one.
  Future<void> fullRefresh() async {
    if (_activeRefresh != null) {
      _log('Refresh already in progress, waiting...');
      await _activeRefresh;
      return;
    }

    final completer = Completer<void>();
    _activeRefresh = completer.future;
    try {
      final validHashes = await refreshNotifications();
      // Only cancel orphans if calendar retrieval succeeded (null = error)
      if (validHashes != null) {
        await cancelOrphanedNotifications(validHashes);
      }
    } catch (_) {
      // Swallow errors in background context
    } finally {
      _activeRefresh = null;
      completer.complete();
    }
  }
}
