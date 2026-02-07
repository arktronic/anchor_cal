import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:anchor_cal/services/event_processor.dart';
import 'package:anchor_cal/services/dismissed_events_store.dart';

class MockDismissedEventsStore extends Mock implements DismissedEventsStore {}

void main() {
  tz.initializeTimeZones();
  final location = tz.getLocation('America/New_York');
  tz.setLocalLocation(location);
  final baseStart = tz.TZDateTime(location, 2026, 2, 1, 10, 0);
  final baseEnd = tz.TZDateTime(location, 2026, 2, 1, 11, 0);

  Event createEvent({
    String calendarId = 'calendar-1',
    String? eventId = 'event-123',
    String? title = 'Test Event',
    tz.TZDateTime? start,
    tz.TZDateTime? end,
    String? eventLocation = 'Room A',
    String? description = 'Test description',
    bool allDay = false,
  }) {
    final event = Event(calendarId, eventId: eventId);
    event.title = title;
    event.start = start ?? baseStart;
    event.end = end ?? baseEnd;
    event.location = eventLocation;
    event.description = description;
    event.allDay = allDay;
    return event;
  }

  group('EventProcessor.computeEventHash', () {
    test('same event produces same hash', () {
      final event1 = createEvent();
      final event2 = createEvent();

      expect(
        EventProcessor.computeEventHash(event1),
        equals(EventProcessor.computeEventHash(event2)),
      );
    });

    test('different event fields produce different hashes', () {
      final baseEvent = createEvent();
      final baseHash = EventProcessor.computeEventHash(baseEvent);

      // Each field change should produce a different hash
      expect(
        EventProcessor.computeEventHash(createEvent(calendarId: 'other')),
        isNot(baseHash),
      );
      expect(
        EventProcessor.computeEventHash(createEvent(title: 'other')),
        isNot(baseHash),
      );
      expect(
        EventProcessor.computeEventHash(
          createEvent(start: tz.TZDateTime(location, 2026, 2, 1, 11, 0)),
        ),
        isNot(baseHash),
      );
      expect(
        EventProcessor.computeEventHash(
          createEvent(end: tz.TZDateTime(location, 2026, 2, 1, 12, 0)),
        ),
        isNot(baseHash),
      );
      expect(
        EventProcessor.computeEventHash(createEvent(eventLocation: 'other')),
        isNot(baseHash),
      );
      expect(
        EventProcessor.computeEventHash(createEvent(description: 'other')),
        isNot(baseHash),
      );
      expect(
        EventProcessor.computeEventHash(createEvent(allDay: true)),
        isNot(baseHash),
      );
    });

    test('different reminderMinutes produces different hash', () {
      final event = createEvent();

      final hash15 = EventProcessor.computeEventHash(
        event,
        reminderMinutes: 15,
      );
      final hash30 = EventProcessor.computeEventHash(
        event,
        reminderMinutes: 30,
      );
      final hashNull = EventProcessor.computeEventHash(event);

      expect(hash15, isNot(equals(hash30)));
      expect(hash15, isNot(equals(hashNull)));
    });

    test('same event with same reminderMinutes produces same hash', () {
      final event1 = createEvent();
      final event2 = createEvent();

      expect(
        EventProcessor.computeEventHash(event1, reminderMinutes: 15),
        equals(EventProcessor.computeEventHash(event2, reminderMinutes: 15)),
      );
    });

    test('handles null fields gracefully', () {
      final event = createEvent(
        eventId: null,
        title: null,
        eventLocation: null,
        description: null,
      );

      final hash = EventProcessor.computeEventHash(event);

      expect(hash, isNotEmpty);
      expect(hash.length, equals(40)); // SHA-1 produces 40 hex chars
    });

    test('same absolute time in different timezones produces same hash', () {
      // Create same moment in two different timezone representations
      final nyLocation = tz.getLocation('America/New_York');
      final laLocation = tz.getLocation('America/Los_Angeles');

      // 10:00 AM in New York = 7:00 AM in Los Angeles (same UTC moment)
      final nyTime = tz.TZDateTime(nyLocation, 2026, 2, 1, 10, 0);
      final laTime = tz.TZDateTime(laLocation, 2026, 2, 1, 7, 0);

      // Verify they represent the same UTC moment
      expect(nyTime.toUtc(), equals(laTime.toUtc()));

      final eventNy = createEvent(
        start: nyTime,
        end: nyTime.add(const Duration(hours: 1)),
      );
      final eventLa = Event('calendar-1', eventId: 'event-123');
      eventLa.title = 'Test Event';
      eventLa.start = laTime;
      eventLa.end = laTime.add(const Duration(hours: 1));
      eventLa.location = 'Room A';
      eventLa.description = 'Test description';
      eventLa.allDay = false;

      // Same absolute time should produce same hash
      expect(
        EventProcessor.computeEventHash(eventNy),
        equals(EventProcessor.computeEventHash(eventLa)),
      );
    });
  });

  group('Notification ID generation', () {
    test('notification ID from hash is always positive', () {
      final event = createEvent();

      for (final minutes in [5, 10, 15, 30, 60, 120]) {
        final hash = EventProcessor.computeEventHash(
          event,
          reminderMinutes: minutes,
        );
        final notificationId =
            int.parse(hash.substring(0, 8), radix: 16) & 0x7FFFFFFF;

        expect(notificationId, greaterThan(0));
        expect(notificationId, lessThanOrEqualTo(0x7FFFFFFF));
      }
    });

    test('notification ID is consistent for same hash', () {
      final event = createEvent();
      final hash = EventProcessor.computeEventHash(event, reminderMinutes: 15);

      final id1 = int.parse(hash.substring(0, 8), radix: 16) & 0x7FFFFFFF;
      final id2 = int.parse(hash.substring(0, 8), radix: 16) & 0x7FFFFFFF;

      expect(id1, equals(id2));
    });

    test('different events produce different notification IDs', () {
      final event1 = createEvent(title: 'Meeting A');
      final event2 = createEvent(title: 'Meeting B');

      final hash1 = EventProcessor.computeEventHash(
        event1,
        reminderMinutes: 15,
      );
      final hash2 = EventProcessor.computeEventHash(
        event2,
        reminderMinutes: 15,
      );

      final id1 = int.parse(hash1.substring(0, 8), radix: 16) & 0x7FFFFFFF;
      final id2 = int.parse(hash2.substring(0, 8), radix: 16) & 0x7FFFFFFF;

      expect(id1, isNot(equals(id2)));
    });
  });

  group('Timezone-safe DateTime handling', () {
    test('millisecondsSinceEpoch round-trip preserves absolute time', () {
      final nyLocation = tz.getLocation('America/New_York');
      final original = tz.TZDateTime(nyLocation, 2026, 2, 1, 10, 0);

      // Simulate payload storage and retrieval
      final epochMs = original.millisecondsSinceEpoch;
      final restored = DateTime.fromMillisecondsSinceEpoch(
        epochMs,
        isUtc: true,
      );

      // Epoch milliseconds should match (same absolute moment)
      expect(
        restored.millisecondsSinceEpoch,
        equals(original.millisecondsSinceEpoch),
      );
      // UTC time components should match
      expect(restored.year, equals(original.toUtc().year));
      expect(restored.month, equals(original.toUtc().month));
      expect(restored.day, equals(original.toUtc().day));
      expect(restored.hour, equals(original.toUtc().hour));
      expect(restored.minute, equals(original.toUtc().minute));
    });

    test('UTC comparison works correctly across timezones', () {
      final nyLocation = tz.getLocation('America/New_York');
      final laLocation = tz.getLocation('America/Los_Angeles');

      // 10:00 AM NY vs 10:00 AM LA (LA is 3 hours behind)
      final nyTime = tz.TZDateTime(nyLocation, 2026, 2, 1, 10, 0);
      final laTime = tz.TZDateTime(laLocation, 2026, 2, 1, 10, 0);

      // In local time they look the same, but LA is actually later in UTC
      expect(laTime.toUtc().isAfter(nyTime.toUtc()), isTrue);

      // 10:00 AM NY = 7:00 AM LA (same moment)
      final laSameMoment = tz.TZDateTime(laLocation, 2026, 2, 1, 7, 0);
      expect(nyTime.toUtc(), equals(laSameMoment.toUtc()));
    });

    test('reminder time calculation preserves timezone', () {
      final centralLocation = tz.getLocation('America/Chicago');
      final eventStart = tz.TZDateTime(centralLocation, 2026, 2, 1, 10, 0);

      // 15 minutes before
      final reminderTime = eventStart.subtract(const Duration(minutes: 15));

      // Should still be 9:45 AM Central
      expect(reminderTime.hour, equals(9));
      expect(reminderTime.minute, equals(45));

      // UTC offset should be preserved
      expect(reminderTime.timeZoneOffset, equals(eventStart.timeZoneOffset));
    });
  });

  // Note: processEvent tests are skipped because awesome_notifications
  // uses a singleton that cannot be easily mocked in unit tests.
  // Integration tests should be used to verify notification behavior.
}
