import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:anchor_cal/services/calendar_refresh_service.dart';
import 'package:anchor_cal/services/dismissed_events_store.dart';

class MockDeviceCalendarPlugin extends Mock implements DeviceCalendarPlugin {}

class MockDismissedEventsStore extends Mock implements DismissedEventsStore {}

void main() {
  tz.initializeTimeZones();
  final location = tz.getLocation('America/New_York');

  late MockDeviceCalendarPlugin mockCalendar;
  late MockDismissedEventsStore mockStore;

  setUp(() {
    mockCalendar = MockDeviceCalendarPlugin();
    mockStore = MockDismissedEventsStore();
  });

  group('CalendarRefreshService.fullRefresh', () {
    test('handles calendar access failure gracefully', () async {
      // This guards against crashing when the calendar plugin fails
      when(
        () => mockCalendar.retrieveCalendars(),
      ).thenThrow(Exception('Failed'));

      final service = CalendarRefreshService(
        calendarPlugin: mockCalendar,
        dismissedStore: mockStore,
        localTimezone: location,
      );

      // Should not throw
      await service.fullRefresh();
    });
  });

  // Note: cancelOrphanedNotifications tests are skipped because
  // awesome_notifications uses a singleton that cannot be easily mocked.
  // Integration tests should be used to verify orphan cleanup behavior.
}
