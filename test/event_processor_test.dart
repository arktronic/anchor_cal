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
  });

  // Note: processEvent tests are skipped because awesome_notifications
  // uses a singleton that cannot be easily mocked in unit tests.
  // Integration tests should be used to verify notification behavior.
}
