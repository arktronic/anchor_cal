import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anchor_cal/services/active_notification_store.dart';

void main() {
  group('ActiveNotificationStore', () {
    late ActiveNotificationStore store;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      store = ActiveNotificationStore.forTest();
    });

    test('starts empty', () async {
      final ids = await store.getAll();
      expect(ids, isEmpty);
    });

    test('add stores a notification ID', () async {
      await store.add(42);
      final ids = await store.getAll();
      expect(ids, equals({42}));
    });

    test('add multiple IDs', () async {
      await store.add(1);
      await store.add(2);
      await store.add(3);
      final ids = await store.getAll();
      expect(ids, equals({1, 2, 3}));
    });

    test('add is idempotent', () async {
      await store.add(42);
      await store.add(42);
      final ids = await store.getAll();
      expect(ids, equals({42}));
    });

    test('remove deletes a tracked ID', () async {
      await store.add(1);
      await store.add(2);
      await store.remove(1);
      final ids = await store.getAll();
      expect(ids, equals({2}));
    });

    test('remove non-existent ID is a no-op', () async {
      await store.add(1);
      await store.remove(99);
      final ids = await store.getAll();
      expect(ids, equals({1}));
    });

    test('replaceAll overwrites tracked IDs', () async {
      await store.add(1);
      await store.add(2);
      await store.add(3);
      await store.replaceAll({10, 20});
      final ids = await store.getAll();
      expect(ids, equals({10, 20}));
    });

    test('replaceAll with empty clears all', () async {
      await store.add(1);
      await store.add(2);
      await store.replaceAll({});
      final ids = await store.getAll();
      expect(ids, isEmpty);
    });
  });
}
