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
      verifyNever(() => mockNotifications.pendingNotificationRequests());
      verifyNever(() => mockNotifications.cancel(any()));
    });
  });

  group('CalendarRefreshService.cancelOrphanedNotifications', () {
    test('cancels both orphaned active and pending notifications', () async {
      final validIds = {100, 200};

      // Active notifications: 100 (valid), 300 (orphan)
      when(() => mockNotifications.getActiveNotifications()).thenAnswer(
        (_) async => [
          const ActiveNotification(id: 100, title: 'Valid', body: ''),
          const ActiveNotification(id: 300, title: 'Orphan Active', body: ''),
        ],
      );

      // Pending notifications: 200 (valid), 400 (orphan)
      when(() => mockNotifications.pendingNotificationRequests()).thenAnswer(
        (_) async => [
          const PendingNotificationRequest(200, 'Valid', 'body', 'payload'),
          const PendingNotificationRequest(
            400,
            'Orphan Pending',
            'body',
            'payload',
          ),
        ],
      );

      when(() => mockNotifications.cancel(any())).thenAnswer((_) async {});

      final service = CalendarRefreshService(
        calendarPlugin: mockCalendar,
        notificationsPlugin: mockNotifications,
        dismissedStore: mockStore,
      );

      await service.cancelOrphanedNotifications(validIds);

      // Should cancel orphans but not valid IDs
      verify(() => mockNotifications.cancel(300)).called(1);
      verify(() => mockNotifications.cancel(400)).called(1);
      verifyNever(() => mockNotifications.cancel(100));
      verifyNever(() => mockNotifications.cancel(200));
    });
  });
}
