import 'package:device_calendar/device_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:anchor_cal/services/calendar_refresh_service.dart';
import 'package:anchor_cal/services/dismissed_events_store.dart';

class MockDeviceCalendarPlugin extends Mock implements DeviceCalendarPlugin {}

class MockFlutterLocalNotificationsPlugin extends Mock
    implements FlutterLocalNotificationsPlugin {}

class MockDismissedEventsStore extends Mock implements DismissedEventsStore {}

void main() {
  late MockDeviceCalendarPlugin mockCalendar;
  late MockFlutterLocalNotificationsPlugin mockNotifications;
  late MockDismissedEventsStore mockStore;

  setUp(() {
    mockCalendar = MockDeviceCalendarPlugin();
    mockNotifications = MockFlutterLocalNotificationsPlugin();
    mockStore = MockDismissedEventsStore();
  });

  group('CalendarRefreshService.fullRefresh', () {
    test('does not cancel orphans when calendar access fails', () async {
      // This guards against accidentally clearing all notifications
      // when the calendar plugin fails (permissions revoked, crash, etc.)
      when(
        () => mockCalendar.retrieveCalendars(),
      ).thenThrow(Exception('Failed'));

      final service = CalendarRefreshService(
        calendarPlugin: mockCalendar,
        notificationsPlugin: mockNotifications,
        dismissedStore: mockStore,
      );

      await service.fullRefresh();

      verifyNever(() => mockNotifications.getActiveNotifications());
      verifyNever(() => mockNotifications.cancel(any()));
    });
  });
}
