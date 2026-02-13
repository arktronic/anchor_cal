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
      final hashes = await store.getAll();
      expect(hashes, isEmpty);
    });

    test('add stores a hash', () async {
      await store.add('abc123');
      final hashes = await store.getAll();
      expect(hashes, equals({'abc123'}));
    });

    test('add multiple hashes', () async {
      await store.add('hash1');
      await store.add('hash2');
      await store.add('hash3');
      final hashes = await store.getAll();
      expect(hashes, equals({'hash1', 'hash2', 'hash3'}));
    });

    test('add is idempotent', () async {
      await store.add('abc123');
      await store.add('abc123');
      final hashes = await store.getAll();
      expect(hashes, equals({'abc123'}));
    });

    test('remove deletes a tracked hash', () async {
      await store.add('hash1');
      await store.add('hash2');
      await store.remove('hash1');
      final hashes = await store.getAll();
      expect(hashes, equals({'hash2'}));
    });

    test('remove non-existent hash is a no-op', () async {
      await store.add('hash1');
      await store.remove('nonexistent');
      final hashes = await store.getAll();
      expect(hashes, equals({'hash1'}));
    });

    test('concurrent adds are not lost', () async {
      final add1 = store.add('hashA');
      final add2 = store.add('hashB');
      await Future.wait([add1, add2]);
      final hashes = await store.getAll();
      expect(hashes, containsAll(['hashA', 'hashB']));
    });

    test('concurrent add and remove are consistent', () async {
      await store.add('hashA');
      final add = store.add('hashB');
      final remove = store.remove('hashA');
      await Future.wait([add, remove]);
      final hashes = await store.getAll();
      expect(hashes.contains('hashB'), isTrue);
      expect(hashes.contains('hashA'), isFalse);
    });
  });
}
