import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:device_calendar/device_calendar.dart';
import 'package:awesome_notifications/awesome_notifications.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;
import 'active_notification_store.dart';
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
  final ActiveNotificationStore _activeStore;
  final DateTime? _firstRunTimestamp;
  final Set<int> _alreadyScheduledIds;
  final tz.Location _localTimezone;

  static const String channelKey = 'anchorcal_events';
  static const String channelName = 'Calendar Events';
  static const String channelDescription = 'Notifications for calendar events';

  EventProcessor({
    required DismissedEventsStore dismissedStore,
    required ActiveNotificationStore activeStore,
    required tz.Location localTimezone,
    DateTime? firstRunTimestamp,
    Set<int>? alreadyScheduledIds,
  }) : _dismissedStore = dismissedStore,
       _activeStore = activeStore,
       _localTimezone = localTimezone,
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

    final DateTime? eventStart = event.start?.toUtc();
    final DateTime? eventEnd = event.end?.toUtc();
    if (eventStart == null || eventEnd == null) return {};

    final nowUtc = now.toUtc();

    final reminders = event.reminders;
    if (reminders == null || reminders.isEmpty) return {};

    // Skip events that ended more than 1 day ago (UTC-normalized comparison)
    final cutoffUtc = nowUtc.subtract(const Duration(days: 1));
    if (eventEnd.isBefore(cutoffUtc)) return {};

    final isAllDay = event.allDay ?? false;
    final location = event.location;

    final processedIds = <int>{};

    for (final reminder in reminders) {
      final minutes = reminder.minutes;
      if (minutes == null) continue;

      final reminderTime = eventStart.subtract(Duration(minutes: minutes));
      final reminderHash = computeEventHash(event, reminderMinutes: minutes);
      // Parse first 8 hex chars of SHA-1 hash for stable ID across restarts
      final notificationId =
          int.parse(reminderHash.substring(0, 8), radix: 16) & 0x7FFFFFFF;
      processedIds.add(notificationId);

      final body = _buildNotificationBody(
        eventStart: eventStart,
        eventEnd: eventEnd,
        reminderTime: reminderTime,
        isAllDay: isAllDay,
        location: location,
      );

      // Skip reminders that were due before the app was first run.
      final firstRun = _firstRunTimestamp?.toUtc();
      if (firstRun != null && reminderTime.isBefore(firstRun)) {
        final localReminder = tz.TZDateTime.from(reminderTime, _localTimezone);
        final localFirstRun = tz.TZDateTime.from(firstRun, _localTimezone);
        _log(
          '    Reminder $minutes min: before first run (reminder=$localReminder, firstRun=$localFirstRun), skipping',
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
      if (snoozedUntil != null && nowUtc.isBefore(snoozedUntil.toUtc())) {
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
      if (reminderTime.isAfter(nowUtc)) {
        // Skip if already scheduled
        if (_alreadyScheduledIds.contains(notificationId)) {
          _log('    Reminder $minutes min: already scheduled, skipping');
          continue;
        }
        final localReminder = tz.TZDateTime.from(reminderTime, _localTimezone);
        _log('    Reminder $minutes min: SCHEDULING for $localReminder');
        await _createNotification(
          notificationId: notificationId,
          title: event.title ?? 'Calendar Event',
          body: body,
          payload: payload,
          scheduledTime: reminderTime,
        );
        await _activeStore.add(notificationId);
        await NotificationLogStore.instance.log(
          eventType: NotificationEventType.scheduled,
          eventTitle: event.title ?? 'Calendar Event',
          eventHash: reminderHash,
          notificationId: notificationId,
          extra: 'Scheduled for $localReminder',
        );
      } else {
        _log('    Reminder $minutes min: SHOWING notification!');
        await _createNotification(
          notificationId: notificationId,
          title: event.title ?? 'Calendar Event',
          body: body,
          payload: payload,
        );
        await _activeStore.add(notificationId);
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

  /// Create a notification, optionally scheduled for a future time.
  Future<void> _createNotification({
    required int notificationId,
    required String title,
    required String body,
    required Map<String, String> payload,
    DateTime? scheduledTime,
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
      schedule: scheduledTime != null
          ? NotificationCalendar.fromDate(
              date: scheduledTime,
              preciseAlarm: true,
              allowWhileIdle: true,
            )
          : null,
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

  /// Build notification body with event times in the device's local timezone.
  String _buildNotificationBody({
    required DateTime eventStart,
    required DateTime eventEnd,
    required DateTime reminderTime,
    required bool isAllDay,
    String? location,
  }) {
    final localStart = tz.TZDateTime.from(eventStart, _localTimezone);
    final localEnd = tz.TZDateTime.from(eventEnd, _localTimezone);
    final localReminder = tz.TZDateTime.from(reminderTime, _localTimezone);

    final daysDiff = _calendarDaysDiff(localReminder, localStart);

    String timeLine;
    if (isAllDay) {
      if (daysDiff == 0) {
        timeLine = 'All day';
      } else if (daysDiff == 1) {
        timeLine = 'Tomorrow, all day';
      } else {
        timeLine = '${DateFormat.MMMd().format(localStart)}, all day';
      }
    } else {
      final timeRange =
          '${DateFormat.jm().format(localStart)} – ${DateFormat.jm().format(localEnd)}';

      if (daysDiff == 0) {
        timeLine = timeRange;
      } else if (daysDiff == 1) {
        timeLine = 'Tomorrow, $timeRange';
      } else {
        timeLine = '${DateFormat.MMMd().format(localStart)}, $timeRange';
      }
    }

    return location?.isNotEmpty == true ? '$timeLine\n$location' : timeLine;
  }

  /// Calendar days between two local DateTimes (ignoring time-of-day).
  static int _calendarDaysDiff(DateTime from, DateTime to) {
    return DateTime(
      to.year,
      to.month,
      to.day,
    ).difference(DateTime(from.year, from.month, from.day)).inDays;
  }
}
