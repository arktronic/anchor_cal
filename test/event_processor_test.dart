import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:anchor_cal/services/event_processor.dart';
import 'package:anchor_cal/services/dismissed_events_store.dart';

class MockDismissedEventsStore extends Mock implements DismissedEventsStore {}

class MockFlutterLocalNotificationsPlugin extends Mock
    implements FlutterLocalNotificationsPlugin {}

class FakeTZDateTime extends Fake implements tz.TZDateTime {}

void main() {
  tz.initializeTimeZones();
  final location = tz.getLocation('America/New_York');
  tz.setLocalLocation(location);
  final baseStart = tz.TZDateTime(location, 2026, 2, 1, 10, 0);
  final baseEnd = tz.TZDateTime(location, 2026, 2, 1, 11, 0);

  setUpAll(() {
    registerFallbackValue(FakeTZDateTime());
    registerFallbackValue(const NotificationDetails());
    registerFallbackValue(AndroidScheduleMode.exactAllowWhileIdle);
    registerFallbackValue(UILocalNotificationDateInterpretation.absoluteTime);
  });

  Event createEvent({
    String? eventId = 'event-123',
    String? title = 'Test Event',
    tz.TZDateTime? start,
    tz.TZDateTime? end,
    String? eventLocation = 'Room A',
    String? description = 'Test description',
    bool allDay = false,
  }) {
    final event = Event('calendar-1', eventId: eventId);
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
        EventProcessor.computeEventHash(createEvent(eventId: 'other')),
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

  group('EventProcessor.processEvent', () {
    late MockDismissedEventsStore mockStore;
    late MockFlutterLocalNotificationsPlugin mockNotifications;

    setUp(() {
      mockStore = MockDismissedEventsStore();
      mockNotifications = MockFlutterLocalNotificationsPlugin();

      when(() => mockStore.isDismissed(any())).thenAnswer((_) async => false);
      when(
        () => mockStore.getSnoozedUntil(any()),
      ).thenAnswer((_) async => null);
      when(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => mockNotifications.zonedSchedule(
          any(),
          any(),
          any(),
          any(),
          any(),
          androidScheduleMode: any(named: 'androidScheduleMode'),
          uiLocalNotificationDateInterpretation: any(
            named: 'uiLocalNotificationDateInterpretation',
          ),
          payload: any(named: 'payload'),
        ),
      ).thenAnswer((_) async {});
    });

    Event createEventWithReminder({
      String eventId = 'event-123',
      required tz.TZDateTime start,
      required tz.TZDateTime end,
      int reminderMinutes = 15,
    }) {
      final event = Event('calendar-1', eventId: eventId);
      event.title = 'Test Event';
      event.start = start;
      event.end = end;
      event.reminders = [Reminder(minutes: reminderMinutes)];
      return event;
    }

    test(
      'returns empty for invalid events (no id, times, or reminders)',
      () async {
        final processor = EventProcessor(
          dismissedStore: mockStore,
          notificationsPlugin: mockNotifications,
        );

        // No eventId
        final noId = Event('calendar-1');
        noId.start = baseStart;
        noId.end = baseEnd;
        expect(
          await processor.processEvent(noId, DateTime(2026, 2, 1, 10, 0)),
          isEmpty,
        );

        // No start/end
        final noTimes = Event('calendar-1', eventId: 'event-123');
        expect(
          await processor.processEvent(noTimes, DateTime(2026, 2, 1, 10, 0)),
          isEmpty,
        );

        // No reminders
        final noReminders = Event('calendar-1', eventId: 'event-123');
        noReminders.start = baseStart;
        noReminders.end = baseEnd;
        noReminders.reminders = [];
        expect(
          await processor.processEvent(
            noReminders,
            DateTime(2026, 2, 1, 10, 0),
          ),
          isEmpty,
        );

        verifyNever(
          () => mockNotifications.show(
            any(),
            any(),
            any(),
            any(),
            payload: any(named: 'payload'),
          ),
        );
      },
    );

    test('skips events that ended more than 1 day ago', () async {
      final event = createEventWithReminder(
        start: tz.TZDateTime(location, 2026, 1, 29, 10, 0),
        end: tz.TZDateTime(location, 2026, 1, 29, 11, 0),
      );

      final processor = EventProcessor(
        dismissedStore: mockStore,
        notificationsPlugin: mockNotifications,
      );

      final result = await processor.processEvent(
        event,
        DateTime(2026, 2, 1, 10, 0),
      );

      expect(result, isEmpty);
    });

    test('shows notification when reminder time has passed', () async {
      final event = createEventWithReminder(
        start: tz.TZDateTime(location, 2026, 2, 1, 10, 0),
        end: tz.TZDateTime(location, 2026, 2, 1, 11, 0),
        reminderMinutes: 15,
      );

      final processor = EventProcessor(
        dismissedStore: mockStore,
        notificationsPlugin: mockNotifications,
      );

      // Now is 10:00, reminder was due at 9:45
      final result = await processor.processEvent(
        event,
        tz.TZDateTime(location, 2026, 2, 1, 10, 0),
      );

      expect(result, isNotEmpty);
      verify(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      ).called(1);
    });

    test('schedules notification if reminder time has not passed', () async {
      final event = createEventWithReminder(
        start: tz.TZDateTime(location, 2026, 2, 1, 10, 0),
        end: tz.TZDateTime(location, 2026, 2, 1, 11, 0),
        reminderMinutes: 15,
      );

      final processor = EventProcessor(
        dismissedStore: mockStore,
        notificationsPlugin: mockNotifications,
      );

      // Now is 9:30, reminder is due at 9:45
      final result = await processor.processEvent(
        event,
        tz.TZDateTime(location, 2026, 2, 1, 9, 30),
      );

      expect(result, isNotEmpty); // Returns ID for orphan cleanup
      // Should schedule, not show immediately
      verifyNever(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      );
      verify(
        () => mockNotifications.zonedSchedule(
          any(),
          any(),
          any(),
          any(),
          any(),
          androidScheduleMode: any(named: 'androidScheduleMode'),
          uiLocalNotificationDateInterpretation: any(
            named: 'uiLocalNotificationDateInterpretation',
          ),
          payload: any(named: 'payload'),
        ),
      ).called(1);
    });

    test('skips notification if already dismissed', () async {
      final event = createEventWithReminder(
        start: tz.TZDateTime(location, 2026, 2, 1, 10, 0),
        end: tz.TZDateTime(location, 2026, 2, 1, 11, 0),
      );

      when(() => mockStore.isDismissed(any())).thenAnswer((_) async => true);

      final processor = EventProcessor(
        dismissedStore: mockStore,
        notificationsPlugin: mockNotifications,
      );

      await processor.processEvent(
        event,
        tz.TZDateTime(location, 2026, 2, 1, 10, 0),
      );

      verifyNever(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      );
    });

    test('skips notification if snoozed, shows after snooze expires', () async {
      final event = createEventWithReminder(
        start: tz.TZDateTime(location, 2026, 2, 1, 10, 0),
        end: tz.TZDateTime(location, 2026, 2, 1, 11, 0),
      );

      final snoozeUntil = tz.TZDateTime(location, 2026, 2, 1, 10, 30);
      when(
        () => mockStore.getSnoozedUntil(any()),
      ).thenAnswer((_) async => snoozeUntil);

      final processor = EventProcessor(
        dismissedStore: mockStore,
        notificationsPlugin: mockNotifications,
      );

      // Before snooze ends - should not show
      await processor.processEvent(
        event,
        tz.TZDateTime(location, 2026, 2, 1, 10, 0),
      );
      verifyNever(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      );

      // After snooze ends - should show
      await processor.processEvent(
        event,
        tz.TZDateTime(location, 2026, 2, 1, 10, 45),
      );
      verify(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      ).called(1);
    });

    test('skips reminders due before firstRunTimestamp', () async {
      final event = createEventWithReminder(
        start: tz.TZDateTime(location, 2026, 2, 1, 10, 0),
        end: tz.TZDateTime(location, 2026, 2, 1, 11, 0),
        reminderMinutes: 15, // Reminder at 9:45
      );

      final processor = EventProcessor(
        dismissedStore: mockStore,
        notificationsPlugin: mockNotifications,
        firstRunTimestamp: tz.TZDateTime(
          location,
          2026,
          2,
          1,
          9,
          50,
        ), // App started at 9:50
      );

      await processor.processEvent(
        event,
        tz.TZDateTime(location, 2026, 2, 1, 10, 0),
      );

      verifyNever(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      );
    });

    test('processes multiple reminders for same event', () async {
      final event = Event('calendar-1', eventId: 'event-123');
      event.title = 'Test Event';
      event.start = tz.TZDateTime(location, 2026, 2, 1, 10, 0);
      event.end = tz.TZDateTime(location, 2026, 2, 1, 11, 0);
      event.reminders = [
        Reminder(minutes: 15), // Due at 9:45
        Reminder(minutes: 30), // Due at 9:30
      ];

      final processor = EventProcessor(
        dismissedStore: mockStore,
        notificationsPlugin: mockNotifications,
      );

      final result = await processor.processEvent(
        event,
        tz.TZDateTime(location, 2026, 2, 1, 10, 0),
      );

      expect(result.length, equals(2));
      verify(
        () => mockNotifications.show(
          any(),
          any(),
          any(),
          any(),
          payload: any(named: 'payload'),
        ),
      ).called(2);
    });
  });
}
