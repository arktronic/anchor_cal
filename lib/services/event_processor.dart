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

    // Skip events that ended more than 1 day ago (UTC-normalized comparison)
    final cutoffUtc = now.toUtc().subtract(const Duration(days: 1));
    if (eventEnd.toUtc().isBefore(cutoffUtc)) return {};

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

      // Normalize to UTC for timezone-safe comparisons
      final reminderTimeUtc = reminderTime.toUtc();
      final nowUtc = now.toUtc();

      // Build notification body with times in local timezone.
      // Include date context if reminder fires on a different day than event.
      final body = _buildNotificationBody(
        eventStart: eventStart,
        eventEnd: eventEnd,
        reminderTime: reminderTime,
        isAllDay: isAllDay,
        location: location,
      );

      // Skip reminders that were due before the app was first run.
      final firstRun = _firstRunTimestamp;
      if (firstRun != null && reminderTimeUtc.isBefore(firstRun.toUtc())) {
        _log(
          '    Reminder $minutes min: before first run (reminder=$reminderTimeUtc, firstRun=${firstRun.toUtc()})',
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
      if (reminderTimeUtc.isAfter(nowUtc)) {
        // Skip if already scheduled
        if (_alreadyScheduledIds.contains(notificationId)) {
          _log('    Reminder $minutes min: already scheduled, skipping');
          continue;
        }
        _log(
          '    Reminder $minutes min: SCHEDULING for $reminderTime (UTC: $reminderTimeUtc)',
        );
        await _scheduleNotification(
          notificationId: notificationId,
          scheduledTime: reminderTime,
          title: event.title ?? 'Calendar Event',
          body: body,
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
          body: body,
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
    // Convert to UTC for NotificationCalendar.fromDate.
    // fromDate checks isUtc and uses UTC timezone identifier, ensuring the
    // notification fires at the correct absolute moment regardless of device
    // timezone or DST changes.
    final utcScheduledTime = scheduledTime.toUtc();

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
        date: utcScheduledTime,
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

  /// Build notification body with event times in local timezone.
  /// Includes date prefix if reminder fires on a different day than the event.
  String _buildNotificationBody({
    required DateTime eventStart,
    required DateTime eventEnd,
    required DateTime reminderTime,
    required bool isAllDay,
    String? location,
  }) {
    // Convert to local timezone for display
    final localStart = eventStart.toLocal();
    final localEnd = eventEnd.toLocal();
    final localReminder = reminderTime.toLocal();

    String timeLine;
    if (isAllDay) {
      // For all-day events, check if reminder is on a different day
      final reminderDate = DateTime(
        localReminder.year,
        localReminder.month,
        localReminder.day,
      );
      final eventDate = DateTime(
        localStart.year,
        localStart.month,
        localStart.day,
      );
      final daysDiff = eventDate.difference(reminderDate).inDays;

      if (daysDiff == 0) {
        timeLine = 'All day';
      } else if (daysDiff == 1) {
        timeLine = 'Tomorrow, all day';
      } else {
        timeLine = '${DateFormat.MMMd().format(localStart)}, all day';
      }
    } else {
      // Check if reminder fires on a different calendar day than event start
      final reminderDate = DateTime(
        localReminder.year,
        localReminder.month,
        localReminder.day,
      );
      final eventDate = DateTime(
        localStart.year,
        localStart.month,
        localStart.day,
      );
      final daysDiff = eventDate.difference(reminderDate).inDays;

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
}
