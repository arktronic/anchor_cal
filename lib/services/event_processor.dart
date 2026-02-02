import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'dismissed_events_store.dart';

/// Shared event processing logic for both foreground and background contexts.
class EventProcessor {
  final DismissedEventsStore _dismissedStore;
  final FlutterLocalNotificationsPlugin _notificationsPlugin;
  final DateTime? _firstRunTimestamp;

  static const String channelId = 'anchor_cal_events';
  static const String channelName = 'Calendar Events';
  static const String channelDescription =
      'Persistent notifications for calendar events';

  EventProcessor({
    required DismissedEventsStore dismissedStore,
    required FlutterLocalNotificationsPlugin notificationsPlugin,
    DateTime? firstRunTimestamp,
  }) : _dismissedStore = dismissedStore,
       _notificationsPlugin = notificationsPlugin,
       _firstRunTimestamp = firstRunTimestamp;

  /// Compute a deterministic hash of event identity and mutable fields.
  /// Includes eventId so each occurrence of a recurring event has unique hash.
  /// If [reminderMinutes] is provided, includes it to make each reminder unique.
  /// Uses SHA-1 for consistent hashing across app restarts.
  static String computeEventHash(Event event, {int? reminderMinutes}) {
    final str = [
      event.eventId ?? '',
      event.title ?? '',
      event.start?.millisecondsSinceEpoch.toString() ?? '',
      event.end?.millisecondsSinceEpoch.toString() ?? '',
      event.location ?? '',
      event.description ?? '',
      event.allDay.toString(),
      if (reminderMinutes != null) 'reminder:$reminderMinutes',
    ].join('|');

    final bytes = utf8.encode(str);
    final digest = sha1.convert(bytes);
    return digest.toString();
  }

  /// Process a single event: for each configured reminder, show notification if due.
  /// Returns the set of notification IDs (hash codes) that were processed.
  /// If the event has no reminders configured, no notifications are shown.
  Future<Set<int>> processEvent(Event event, DateTime now) async {
    final eventId = event.eventId;
    if (eventId == null) return {};

    final eventStart = event.start;
    final eventEnd = event.end;
    if (eventStart == null || eventEnd == null) return {};

    final reminders = event.reminders;
    if (reminders == null || reminders.isEmpty) return {};

    // Skip events that ended more than 1 day ago
    final cutoff = now.subtract(const Duration(days: 1));
    if (eventEnd.isBefore(cutoff)) return {};

    final isAllDay = event.allDay ?? false;
    final timeLine = isAllDay
        ? 'All day'
        : '${_formatTime(eventStart)} – ${_formatTime(eventEnd)}';
    final fullBody = event.location?.isNotEmpty == true
        ? '$timeLine\n${event.location}'
        : timeLine;

    final processedIds = <int>{};

    for (final reminder in reminders) {
      final minutes = reminder.minutes;
      if (minutes == null) continue;

      final reminderTime = eventStart.subtract(Duration(minutes: minutes));
      final reminderHash = computeEventHash(event, reminderMinutes: minutes);
      processedIds.add(reminderHash.hashCode);

      // Skip if not yet time for this reminder
      if (reminderTime.isAfter(now)) continue;

      // Skip reminders that were due before the app was first run.
      // We filter by reminder time (not event time) intentionally:
      // - Avoids confusing "late" reminders arriving hours after they were due
      // - Prevents a flood of stale reminders on first run
      // - Future reminders for the same event will still fire correctly
      final firstRun = _firstRunTimestamp;
      if (firstRun != null && reminderTime.isBefore(firstRun)) continue;

      // Skip if already dismissed
      if (await _dismissedStore.isDismissed(reminderHash)) continue;

      // Skip if snoozed
      final snoozedUntil = await _dismissedStore.getSnoozedUntil(reminderHash);
      if (snoozedUntil != null && now.isBefore(snoozedUntil)) continue;

      // Show notification for this reminder
      await _showNotification(
        eventId: eventId,
        eventHash: reminderHash,
        eventStart: eventStart,
        eventEnd: eventEnd,
        title: event.title ?? 'Calendar Event',
        body: fullBody,
      );
    }

    return processedIds;
  }

  Future<void> _showNotification({
    required String eventId,
    required String eventHash,
    required DateTime eventStart,
    required DateTime eventEnd,
    required String title,
    required String body,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true,
      autoCancel: false,
      onlyAlertOnce: true, // Don't re-alert on updates
      groupKey: eventId, // Unique per event to prevent auto-bundling
      actions: [
        AndroidNotificationAction(
          'open|$eventId|$eventHash|${eventEnd.millisecondsSinceEpoch}',
          'Open',
          showsUserInterface: true,
        ),
        AndroidNotificationAction(
          'snooze|$eventId|$eventHash|${eventEnd.millisecondsSinceEpoch}',
          'Snooze',
        ),
        AndroidNotificationAction(
          'dismiss|$eventId|$eventHash|${eventEnd.millisecondsSinceEpoch}',
          'Dismiss',
        ),
      ],
    );

    await _notificationsPlugin.show(
      eventHash.hashCode,
      title,
      body,
      NotificationDetails(android: androidDetails),
      payload: 'open|$eventId|$eventHash|${eventEnd.millisecondsSinceEpoch}',
    );
  }

  String _formatTime(DateTime dt) {
    return DateFormat.jm().format(dt);
  }
}
