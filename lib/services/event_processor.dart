import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:intl/intl.dart';
import 'dismissed_events_store.dart';
import 'notification_log_store.dart';

void _log(String message) {
  if (kDebugMode) {
    developer.log(message, name: 'AnchorCal');
  }
}

/// Shared event processing logic for both foreground and background contexts.
class EventProcessor {
  final DismissedEventsStore _dismissedStore;
  final DateTime? _firstRunTimestamp;
  final Set<int> _alreadyScheduledIds;

  static const String channelKey = 'anchorcal_events';
  static const String channelName = 'Calendar Events';
  static const String channelDescription = 'Notifications for calendar events';

  EventProcessor({
    required DismissedEventsStore dismissedStore,
    DateTime? firstRunTimestamp,
    Set<int>? alreadyScheduledIds,
  }) : _dismissedStore = dismissedStore,
       _firstRunTimestamp = firstRunTimestamp,
       _alreadyScheduledIds = alreadyScheduledIds ?? {};

  /// Compute a deterministic hash of event content and timing.
  /// Uses calendarId + title + start + end to identify occurrences.
  /// Excludes eventId since it can change during Exchange/Outlook sync.
  /// If [reminderMinutes] is provided, includes it to make each reminder unique.
  /// Uses SHA-1 for consistent hashing across app restarts.
  static String computeEventHash(Event event, {int? reminderMinutes}) {
    final str = [
      event.calendarId ?? '',
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
      // Parse first 8 hex chars of SHA-1 hash for stable ID across restarts
      final notificationId =
          int.parse(reminderHash.substring(0, 8), radix: 16) % 2147483647;
      processedIds.add(notificationId);

      // Skip reminders that were due before the app was first run.
      final firstRun = _firstRunTimestamp;
      if (firstRun != null && reminderTime.isBefore(firstRun)) {
        _log(
          '    Reminder $minutes min: before first run (reminder=$reminderTime, firstRun=$firstRun)',
        );
        continue;
      }

      // Skip if already dismissed
      if (await _dismissedStore.isDismissed(reminderHash)) {
        _log('    Reminder $minutes min: already dismissed');
        continue;
      }

      // Skip if snoozed
      final snoozedUntil = await _dismissedStore.getSnoozedUntil(reminderHash);
      if (snoozedUntil != null && now.isBefore(snoozedUntil)) {
        _log('    Reminder $minutes min: snoozed until $snoozedUntil');
        continue;
      }

      // Build payload for action handling
      final payload = {
        'eventId': eventId,
        'eventHash': reminderHash,
        'eventEnd': eventEnd.millisecondsSinceEpoch.toString(),
      };

      // Schedule future reminder or show immediately if already due
      if (reminderTime.isAfter(now)) {
        // Skip if already scheduled
        if (_alreadyScheduledIds.contains(notificationId)) {
          _log('    Reminder $minutes min: already scheduled, skipping');
          continue;
        }
        _log('    Reminder $minutes min: SCHEDULING for $reminderTime');
        await _scheduleNotification(
          notificationId: notificationId,
          scheduledTime: reminderTime,
          title: event.title ?? 'Calendar Event',
          body: fullBody,
          payload: payload,
        );
        await NotificationLogStore.instance.log(
          eventType: NotificationEventType.scheduled,
          eventTitle: event.title ?? 'Calendar Event',
          eventHash: reminderHash,
          notificationId: notificationId,
          extra: 'Scheduled for $reminderTime',
        );
      } else {
        _log('    Reminder $minutes min: SHOWING notification!');
        await _showNotification(
          notificationId: notificationId,
          title: event.title ?? 'Calendar Event',
          body: fullBody,
          payload: payload,
        );
        await NotificationLogStore.instance.log(
          eventType: NotificationEventType.shown,
          eventTitle: event.title ?? 'Calendar Event',
          eventHash: reminderHash,
          notificationId: notificationId,
        );
      }
    }

    return processedIds;
  }

  /// Schedule a notification for a future time.
  Future<void> _scheduleNotification({
    required int notificationId,
    required DateTime scheduledTime,
    required String title,
    required String body,
    required Map<String, String> payload,
  }) async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: notificationId,
        channelKey: channelKey,
        title: title,
        body: body,
        category: NotificationCategory.Event,
        notificationLayout: NotificationLayout.Default,
        payload: payload,
        autoDismissible: true,
        locked: false,
        showWhen: false,
      ),
      actionButtons: _buildActionButtons(),
      schedule: NotificationCalendar.fromDate(
        date: scheduledTime,
        preciseAlarm: true,
        allowWhileIdle: true,
      ),
    );
  }

  Future<void> _showNotification({
    required int notificationId,
    required String title,
    required String body,
    required Map<String, String> payload,
  }) async {
    await AwesomeNotifications().createNotification(
      content: NotificationContent(
        id: notificationId,
        channelKey: channelKey,
        title: title,
        body: body,
        category: NotificationCategory.Event,
        notificationLayout: NotificationLayout.Default,
        payload: payload,
        autoDismissible: true,
        locked: false,
        showWhen: false,
      ),
      actionButtons: _buildActionButtons(),
    );
  }

  List<NotificationActionButton> _buildActionButtons() {
    return [
      NotificationActionButton(
        key: 'open',
        label: 'Open',
        actionType: ActionType.Default,
      ),
      NotificationActionButton(
        key: 'snooze',
        label: 'Snooze',
        actionType: ActionType.SilentAction,
      ),
    ];
  }

  String _formatTime(DateTime dt) {
    return DateFormat.jm().format(dt);
  }
}
