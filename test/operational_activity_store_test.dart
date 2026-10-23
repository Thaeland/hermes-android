import 'dart:async';
import 'dart:convert';

// flutter_test supplies this deterministic microtask clock via its SDK.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/operational_activity_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const now = 2000000000000;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'all states survive preference replacement with only metadata',
    () async {
      final store = OperationalActivityStore(nowEpochMs: () => now);
      for (final state in OperationalActivityState.values) {
        await store.put(_record(state.name, state: state, updated: now));
      }
      final prefs = await SharedPreferences.getInstance();
      final encoded = prefs.getString(OperationalActivityStore.preferenceKey)!;
      final raw = jsonDecode(encoded) as List;
      for (final row in raw.cast<Map<String, dynamic>>()) {
        expect(row.keys.toSet(), {
          'scope',
          'localSessionId',
          'storedSessionId',
          'turnId',
          'state',
          'updatedAtEpochMs',
        });
      }
      SharedPreferences.setMockInitialValues({
        OperationalActivityStore.preferenceKey: encoded,
      });
      final restored = await OperationalActivityStore(
        nowEpochMs: () => now,
      ).load('scope');
      expect(
        restored.map((row) => row.state).toSet(),
        OperationalActivityState.values.toSet(),
      );
      expect(restored.every((row) => row.storedSessionId == null), isTrue);
      expect(restored.every((row) => row.updatedAtEpochMs == now), isTrue);
    },
  );

  test('one row per actual turn, including changed chat aliases', () async {
    final store = OperationalActivityStore(nowEpochMs: () => now);
    await store.put(_record('a', updated: now));
    await store.put(
      OperationalActivityRecord(
        scope: 'scope',
        localSessionId: 'stored-alias',
        storedSessionId: 'stored',
        turnId: 'a',
        state: OperationalActivityState.completed,
        updatedAtEpochMs: now + 1,
      ),
    );
    await store.put(_record('b', updated: now + 2));
    final rows = await store.load('scope');
    expect(rows.map((row) => row.turnId), ['b', 'a']);
    expect(rows.last.state, OperationalActivityState.completed);
    expect(rows.last.localSessionId, 'stored-alias');
  });

  test('scope isolation and clear preserve sibling work', () async {
    final store = OperationalActivityStore(nowEpochMs: () => now);
    await store.put(_record('same-turn', updated: now));
    await store.put(_record('same-turn', scope: 'other', updated: now));
    expect(await store.load('absent'), isEmpty);
    expect(await store.load('scope'), hasLength(1));
    expect(await store.load('other'), hasLength(1));
    await store.clearScope('scope');
    expect(await OperationalActivityStore().load('scope'), isEmpty);
    expect(await OperationalActivityStore().load('other'), hasLength(1));
  });

  test('replacement writes and reads join a globally held write', () async {
    final gate = Completer<SharedPreferences>();
    final first = OperationalActivityStore(
      preferences: () => gate.future,
      nowEpochMs: () => now,
    );
    var secondEntered = false;
    final second = OperationalActivityStore(
      preferences: () async {
        secondEntered = true;
        return SharedPreferences.getInstance();
      },
      nowEpochMs: () => now,
    );
    final a = first.put(_record('a', updated: now));
    final b = second.put(_record('b', updated: now));
    var readCompleted = false;
    final read = second.load('scope').then((rows) {
      readCompleted = true;
      return rows;
    });
    await Future<void>.value();
    expect(secondEntered, isFalse);
    expect(readCompleted, isFalse);
    gate.complete(await SharedPreferences.getInstance());
    await Future.wait([a, b]);
    expect((await read).map((row) => row.turnId).toSet(), {'a', 'b'});
    expect((await first.load('scope')).map((row) => row.turnId).toSet(), {
      'a',
      'b',
    });
  });

  test('settled queue releases the originating fake-async zone', () async {
    final prefs = await SharedPreferences.getInstance();
    for (final turn in ['first-zone', 'replacement-zone']) {
      fakeAsync((clock) {
        var completed = false;
        final store = OperationalActivityStore(
          preferences: () async => prefs,
          nowEpochMs: () => now,
        );
        store.put(_record(turn, updated: now)).then((_) => completed = true);
        clock.flushMicrotasks();
        expect(completed, isTrue);
      });
    }
    expect(await OperationalActivityStore().load('scope'), hasLength(2));
  });

  test('failed physical writes do not poison the cache or queue', () async {
    final platform = _RejectingStore();
    SharedPreferencesStorePlatform.instance = platform;
    final store = OperationalActivityStore(nowEpochMs: () => now);
    await expectLater(
      store.put(_record('rejected', updated: now)),
      throwsStateError,
    );
    expect(await store.load('scope'), isEmpty);
    platform.reject = false;
    await store.put(_record('accepted', updated: now));
    expect(
      (await OperationalActivityStore().load('scope')).single.turnId,
      'accepted',
    );
  });

  test(
    'retention expires and bounds only finished and unknown turns',
    () async {
      final store = OperationalActivityStore(nowEpochMs: () => now);
      final old =
          now - OperationalActivityStore.finishedRetention.inMilliseconds - 1;
      for (final state in OperationalActivityState.values) {
        await store.put(
          _record('old-${state.name}', state: state, updated: old),
        );
      }
      final unresolved = (await store.load(
        'scope',
      )).map((row) => row.state).toSet();
      expect(unresolved, {
        OperationalActivityState.submitted,
        OperationalActivityState.running,
        OperationalActivityState.needsInput,
        OperationalActivityState.reconciling,
      });
      for (
        var i = 0;
        i < OperationalActivityStore.maxFinishedRecords + 3;
        i++
      ) {
        await store.put(
          _record(
            'finished-$i',
            state: i.isEven
                ? OperationalActivityState.completed
                : OperationalActivityState.unknown,
            updated: now + i,
          ),
        );
      }
      final rows = await store.load('scope');
      expect(
        rows.where((row) => !row.isUnresolved),
        hasLength(OperationalActivityStore.maxFinishedRecords),
      );
      expect(
        rows.where((row) => row.isUnresolved),
        hasLength(unresolved.length),
      );
      expect(rows.any((row) => row.turnId == 'finished-0'), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        (jsonDecode(prefs.getString(OperationalActivityStore.preferenceKey)!)
            as List),
        hasLength(rows.length),
      );
    },
  );

  test('malformed presentation metadata is not recovery authority', () async {
    SharedPreferences.setMockInitialValues({
      OperationalActivityStore.preferenceKey: 'not-json',
    });
    final store = OperationalActivityStore(nowEpochMs: () => now);
    expect(await store.load('scope'), isEmpty);
    await store.put(_record('valid', updated: now));
    expect((await store.load('scope')).single.turnId, 'valid');
    expect(
      OperationalActivityRecord.parse({
        ..._record('x').toJson(),
        'state': 'invented',
      }),
      isNull,
    );
    expect(
      OperationalActivityRecord.parse({
        ..._record('x').toJson(),
        'updatedAtEpochMs': -1,
      }),
      isNull,
    );
    expect(
      OperationalActivityRecord.parse({
        ..._record('x').toJson(),
        'storedSessionId': 123,
      }),
      isNull,
    );
  });
}

OperationalActivityRecord _record(
  String turn, {
  String scope = 'scope',
  OperationalActivityState state = OperationalActivityState.running,
  int updated = 2000000000000,
}) => OperationalActivityRecord(
  scope: scope,
  localSessionId: 'local',
  storedSessionId: null,
  turnId: turn,
  state: state,
  updatedAtEpochMs: updated,
);

class _RejectingStore extends InMemorySharedPreferencesStore {
  bool reject = true;
  _RejectingStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (reject && key.endsWith(OperationalActivityStore.preferenceKey)) {
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}
