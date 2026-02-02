import 'package:flutter_test/flutter_test.dart';
import 'package:anchor_cal/services/calendar_refresh_service.dart';

void main() {
  group('NotificationAction.parse', () {
    test('parses valid payload with all parts', () {
      final action = NotificationAction.parse(
        'open|event-123|abc123hash|1738368000000',
      );

      expect(action, isNotNull);
      expect(action!.action, equals('open'));
      expect(action.eventId, equals('event-123'));
      expect(action.eventHash, equals('abc123hash'));
      expect(
        action.eventEnd,
        equals(DateTime.fromMillisecondsSinceEpoch(1738368000000)),
      );
    });

    test('returns null for null or empty payload', () {
      expect(NotificationAction.parse(null), isNull);
      expect(NotificationAction.parse(''), isNull);
    });

    test('returns null for payload with fewer than 3 parts', () {
      expect(NotificationAction.parse('open'), isNull);
      expect(NotificationAction.parse('open|event-123'), isNull);
    });

    test('falls back to now when eventEnd missing or invalid', () {
      // Missing eventEnd (only 3 parts)
      final action1 = NotificationAction.parse('open|event-123|hash123');
      expect(action1, isNotNull);
      expect(
        action1!.eventEnd.difference(DateTime.now()).inSeconds.abs(),
        lessThan(5),
      );

      // Invalid eventEnd
      final action2 = NotificationAction.parse(
        'open|event-123|hash123|invalid',
      );
      expect(action2, isNotNull);
      expect(
        action2!.eventEnd.difference(DateTime.now()).inSeconds.abs(),
        lessThan(5),
      );
    });

    test('extra pipe characters split into separate parts', () {
      // Documents that hash containing pipes will be truncated
      final action = NotificationAction.parse(
        'open|event-123|hash|with|pipes|1738368000000',
      );

      expect(action, isNotNull);
      expect(
        action!.eventHash,
        equals('hash'),
      ); // Only gets first part after split
    });
  });
}
