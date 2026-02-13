import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anchor_cal/services/dismissed_events_store.dart';

void main() {
  group('DismissedEventsStore', () {
    late DismissedEventsStore store;
    final eventEnd = DateTime(2026, 2, 12, 12, 0);

    // Use realistic-length hashes (SHA-1 = 40 hex chars)
    const hashA = 'aaaa0000aaaa0000aaaa0000aaaa0000aaaa0000';
    const hashB = 'bbbb0000bbbb0000bbbb0000bbbb0000bbbb0000';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      store = DismissedEventsStore.forTest();
    });

    test('dismiss marks event as dismissed', () async {
      await store.dismiss(hashA, eventEnd);
      expect(await store.isDismissed(hashA), isTrue);
    });

    test('undismissed event is not dismissed', () async {
      expect(await store.isDismissed(hashA), isFalse);
    });

    test('concurrent dismissals are not lost', () async {
      // Simulate what happens when Android delivers two grouped
      // notification dismissals at the same time.
      final dismiss1 = store.dismiss(hashA, eventEnd);
      final dismiss2 = store.dismiss(hashB, eventEnd);
      await Future.wait([dismiss1, dismiss2]);

      expect(
        await store.isDismissed(hashA),
        isTrue,
        reason: 'First concurrent dismissal should persist',
      );
      expect(
        await store.isDismissed(hashB),
        isTrue,
        reason: 'Second concurrent dismissal should persist',
      );
    });

    test('concurrent dismiss and snooze are not lost', () async {
      final snoozeUntil = DateTime.now().add(const Duration(minutes: 30));
      final dismiss = store.dismiss(hashA, eventEnd);
      final snooze = store.snooze(hashB, eventEnd, snoozeUntil);
      await Future.wait([dismiss, snooze]);

      expect(await store.isDismissed(hashA), isTrue);
      expect(await store.getSnoozedUntil(hashB), isNotNull);
    });
  });
}
