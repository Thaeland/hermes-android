import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/session_browser_loader.dart';

Session _row(String title) => Session.fromJson({'id': 'same', 'title': title});

void main() {
  test(
    'invalidated flights cannot replay into, publish to, or clear a new flight',
    () async {
      final completions = <Completer<List<Session>>>[];
      final publishers = <SessionScanProgress>[];
      final scan = SharedSessionScan((publish) {
        publishers.add(publish);
        final result = Completer<List<Session>>();
        completions.add(result);
        return result.future;
      });
      addTearDown(scan.close);
      final oldSeen = <String>[];
      final newSeen = <String>[];
      final first = scan.load(
        onProgress: (rows) => oldSeen.add(rows.single.title),
      );
      publishers.single([_row('Before rename')]);
      scan.invalidate();
      final second = scan.load(
        onProgress: (rows) => newSeen.add(rows.single.title),
      );
      expect(completions, hasLength(2));
      expect(newSeen, isEmpty);
      completions.first.complete([_row('Before rename')]);
      await first;
      publishers.first([_row('Late callback')]);
      expect(oldSeen, ['Before rename']);
      expect(newSeen, isEmpty);
      final third = scan.load();
      expect(
        completions,
        hasLength(2),
        reason: 'old completion must not clear the newer shared flight',
      );
      publishers.last([_row('After rename')]);
      completions.last.complete([_row('After rename')]);
      expect((await second).single.title, 'After rename');
      expect((await third).single.title, 'After rename');
      expect(newSeen, ['After rename']);
    },
  );

  test(
    'failure of an old flight does not cancel or replace its successor',
    () async {
      final old = Completer<List<Session>>();
      final current = Completer<List<Session>>();
      var calls = 0;
      final scan = SharedSessionScan(
        (_) => ++calls == 1 ? old.future : current.future,
      );
      addTearDown(scan.close);
      final failed = expectLater(scan.load(), throwsStateError);
      scan.invalidate();
      final fresh = scan.load();
      old.completeError(StateError('old authority failed'));
      await failed;
      final joined = scan.load();
      expect(calls, 2);
      current.complete([_row('Fresh')]);
      expect((await fresh).single.title, 'Fresh');
      expect((await joined).single.title, 'Fresh');
    },
  );

  test('a synchronous reader error releases its flight for Retry', () async {
    var calls = 0;
    final scan = SharedSessionScan((_) {
      if (++calls == 1) throw StateError('reader setup failed');
      return Future.value([_row('Recovered')]);
    });
    addTearDown(scan.close);
    await expectLater(scan.load(), throwsStateError);
    expect((await scan.load()).single.title, 'Recovered');
    expect(calls, 2);
  });

  test(
    'synchronous progress is replayed once and settled callbacks are rejected',
    () async {
      late SessionScanProgress emit;
      final scan = SharedSessionScan((publish) {
        emit = publish;
        publish([_row('Immediate')]);
        return Future.value([_row('Immediate')]);
      });
      addTearDown(scan.close);
      final seen = <String>[];
      await scan.load(onProgress: (rows) => seen.add(rows.single.title));
      emit([_row('After settlement')]);
      expect(seen, ['Immediate']);
    },
  );

  test(
    'close rejects in-flight results, callbacks and subsequent loads',
    () async {
      final held = Completer<List<Session>>();
      late SessionScanProgress emit;
      final scan = SharedSessionScan((publish) {
        emit = publish;
        return held.future;
      });
      final seen = <List<Session>>[];
      final rejected = expectLater(
        scan.load(onProgress: seen.add),
        throwsStateError,
      );
      scan.close();
      emit([_row('Too late')]);
      held.complete([_row('Too late')]);
      await rejected;
      expect(seen, isEmpty);
      await expectLater(scan.load(), throwsStateError);
    },
  );
}
