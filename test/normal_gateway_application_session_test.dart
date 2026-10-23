import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
// flutter_test supplies this deterministic timer clock via its SDK dependency.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/normal_gateway_application_session.dart';
import 'package:hermes_android/core/services/normal_gateway_pending_store.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'duplicate routes and durable/local aliases share synchronous admission',
    () async {
      final f = _Fixture();
      await f.session.ready;
      final a = f.chat('draft', stored: 'stored');
      final alias = f.chat('stored', stored: 'stored');
      expect(identical(a, alias), isTrue);
      final reservation = a.reserve()!;
      expect(alias.reserve(), isNull);
      expect(f.chat('other', stored: 'other-stored').reserve(), isNotNull);
      a.cancelPreparation(reservation);
      expect(alias.reserve(), isNotNull);
      await f.close();
    },
  );

  test(
    'unsubscribed owner reduces tokens, tools and reasoning; reattach is immediate',
    () async {
      final f = _Fixture();
      await f.start();
      var calls = 0;
      final token = f.owner.subscribe((_) => calls++);
      f.owner.unsubscribe(token);
      final before = calls;
      f.emit('message.delta', {'text': 'While absent'});
      f.emit('tool.start', {'tool': 'read_file', 'tool_id': 't1'});
      f.emit('tool.complete', {
        'tool': 'read_file',
        'tool_id': 't1',
        'status': 'completed',
      });
      f.emit('reasoning.delta', {'text': 'Considering'});
      expect(calls, before);
      NormalGatewayChatSnapshot? restored;
      f.owner.subscribe((value) => restored = value);
      expect(restored!.displayRows.last['content'], 'While absent');
      expect(restored!.tools, hasLength(1));
      expect(restored!.tools.single.isTerminal, isTrue);
      expect(f.submissions, 1);
      f.emit('message.complete', {'text': 'Finished while absent'});
      await _flush();
      expect(f.owner.snapshot.hasActiveTurn, isFalse);
      expect(
        f.owner.snapshot.displayRows.last['content'],
        'Finished while absent',
      );
      expect(await f.store.load('scope'), isEmpty);
      await f.close();
    },
  );

  test('RPC acknowledgement alone is unresolved, never terminal', () async {
    final f = _Fixture();
    await f.start();
    f.rpc.complete();
    await f.flight;
    expect(f.owner.snapshot.hasActiveTurn, isTrue);
    expect(f.owner.phase, NormalGatewayTurnPhase.reconciling);
    expect(f.submissions, 1);
    await f.close();
  });

  test(
    'pre-wire rejection clears receipt; post-wire loss never resends',
    () async {
      final rejected = _Fixture()..emitOnSubmit = false;
      await rejected.start();
      rejected.rpc.completeError(StateError('before wire'));
      await expectLater(rejected.flight, throwsStateError);
      expect(rejected.owner.snapshot.hasActiveTurn, isFalse);
      expect(rejected.owner.snapshot.displayRows, isEmpty);
      expect(await rejected.store.load('scope'), isEmpty);
      await rejected.close();

      final lost = _Fixture();
      await lost.start();
      lost.rpc.completeError(StateError('after wire'));
      await lost.flight;
      expect(lost.owner.snapshot.hasActiveTurn, isTrue);
      expect(lost.owner.snapshot.wireEmitted, isTrue);
      expect(await lost.store.load('scope'), hasLength(1));
      lost.session.connectionChanged(DesktopConnectionState.connected);
      await _flush();
      expect(lost.submissions, 1);
      expect(lost.resumes, greaterThan(0));
      await lost.close();
    },
  );

  test(
    'write-ahead receipt exists before submit and contains no prompt/runtime/credential',
    () async {
      final f = _Fixture();
      await f.start();
      final marker = f.atInvocation.single;
      expect(marker.phase, 'write_ahead');
      expect(marker.rowFloor, 10);
      expect(marker.storedSessionId, 'stored');
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(NormalGatewayPendingStore.preferenceKey)!;
      expect(json, isNot(contains('private prompt')));
      expect(json, isNot(contains('private-key')));
      expect(json, isNot(contains('runtime')));
      expect(jsonDecode(json).single.keys.toSet(), {
        'schema',
        'scope',
        'local_id',
        'stored_id',
        'local_turn_id',
        'row_floor',
        'phase',
        'created_at',
        'updated_at',
      });
      await f.close();
    },
  );

  for (final phase in ['write_ahead', 'emitted']) {
    test(
      'crash receipt $phase restores reconciling, resume-only, no create/submit',
      () async {
        final store = NormalGatewayPendingStore();
        await store.put(_marker('local', phase: phase));
        final resumed = Completer<ResumedGatewaySession>();
        var submissions = 0;
        var resumes = 0;
        final session = NormalGatewayApplicationSession(
          connection: _connection,
          scope: 'scope',
          pendingStore: store,
          submit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {
                submissions++;
              },
          resume: ({required localSessionId, required storedSessionId}) {
            expect(localSessionId, 'local');
            expect(storedSessionId, 'stored');
            resumes++;
            return resumed.future;
          },
          history: (_) async => [
            {'id': 12, 'role': 'agent', 'content': 'Recovered final'},
          ],
        );
        await session.ready;
        final owner = session.findChat('stored')!;
        expect(owner.phase, NormalGatewayTurnPhase.reconciling);
        expect(owner.reserve(), isNull);
        expect(resumes, 1);
        resumed.complete(
          const ResumedGatewaySession(
            runtimeSessionId: 'runtime',
            running: false,
          ),
        );
        await _flush();
        expect(owner.snapshot.hasActiveTurn, isFalse);
        expect(owner.snapshot.historyRows.single['role'], 'agent');
        expect(submissions, 0);
        expect(await store.load('scope'), isEmpty);
        await session.close();
      },
    );
  }

  test(
    'fresh sliding rows required; running, tool and interim rows cannot settle',
    () async {
      final f = _Fixture();
      await f.start();
      f.rpc.completeError(StateError('wire lost'));
      await f.flight;
      f.running = false;
      for (final row in [
        {'id': 10, 'role': 'assistant', 'content': 'Old retained final'},
        {'id': 11, 'role': 'user', 'content': 'Prompt'},
        {
          'id': 12,
          'role': 'assistant',
          'content': 'tool',
          'tool_calls': [
            {'id': 'tc'},
          ],
        },
        {'id': 13, 'role': 'assistant', 'content': 'Interim', 'interim': true},
      ]) {
        f.rows = [row];
        f.owner.requestRecovery();
        await _flush();
        expect(f.owner.snapshot.hasActiveTurn, isTrue, reason: '$row');
      }
      f.rows = [
        {'id': 999, 'role': 'agent', 'content': 'Fresh final, no overlap'},
      ];
      f.running = true;
      f.owner.requestRecovery();
      await _flush();
      expect(f.owner.snapshot.hasActiveTurn, isTrue);
      f.running = null;
      f.owner.requestRecovery();
      await _flush();
      expect(
        f.owner.snapshot.hasActiveTurn,
        isTrue,
        reason: 'unknown running state is unresolved',
      );
      f.running = false;
      f.owner.requestRecovery();
      await _flush();
      expect(f.owner.snapshot.hasActiveTurn, isFalse);
      expect(f.owner.snapshot.historyRows.single['id'], 999);
      await f.close();
    },
  );

  test(
    'history failures and unknown baseline never manufacture empty completion',
    () async {
      final f = _Fixture()..historyFails = true;
      await f.start(seedHistory: false);
      expect(f.owner.snapshot.rowFloor, isNull);
      f.rpc.completeError(StateError('lost'));
      await f.flight;
      f.historyFails = false;
      f.running = false;
      f.rows = [
        {'id': 100, 'role': 'assistant', 'content': 'May be older'},
      ];
      f.owner.requestRecovery();
      await _flush();
      expect(f.owner.snapshot.hasActiveTurn, isTrue);
      await f.close();
    },
  );

  test(
    'recovery single flight hands old held history to next generation',
    () async {
      final f = _Fixture();
      await f.start();
      f.rpc.completeError(StateError('lost'));
      await f.flight;
      await _flush();
      final held = Completer<List<Map<String, dynamic>>>();
      f.historyGate = held;
      f.owner.requestRecovery();
      await _flush();
      final firstTurn = f.owner.turnId;
      f.emit('turn.end', {'status': 'completed'});
      await _flush();
      expect(f.owner.snapshot.hasActiveTurn, isFalse);
      f.resetRpc();
      await f.start(seedHistory: true);
      expect(f.owner.turnId, isNot(firstTurn));
      f.rpc.completeError(StateError('second lost'));
      await f.flight;
      f.rows = [
        {'id': 30, 'role': 'agent', 'content': 'Second final'},
      ];
      f.running = false;
      f.historyGate = null;
      held.complete([
        {'id': 11, 'role': 'agent', 'content': 'Stale first final'},
      ]);
      await _flush();
      expect(f.submissions, 2);
      expect(f.owner.snapshot.hasActiveTurn, isFalse);
      expect(f.owner.snapshot.historyRows.single['id'], 30);
      await f.close();
    },
  );

  test(
    'background policy pauses recovery without cancelling remote work',
    () async {
      final f = _Fixture();
      await f.start();
      f.session.setLifecycle(background: true, backgroundWorkEnabled: false);
      f.rpc.completeError(StateError('lost'));
      await f.flight;
      final count = f.resumes;
      f.owner.requestRecovery();
      await _flush();
      expect(f.resumes, count);
      expect(f.owner.snapshot.hasActiveTurn, isTrue);
      f.session.setLifecycle(background: false);
      await _flush();
      expect(f.resumes, greaterThan(count));
      expect(f.submissions, 1);
      await f.close();
    },
  );

  test(
    'retained approvals survive unsubscribe; socket replacement invalidates old identity',
    () async {
      final f = _Fixture();
      await f.start();
      final registration = f.owner.subscribe((_) {});
      f.owner.unsubscribe(registration);
      f.emit('approval.request', {
        'server_request_id': 'socket-a:42',
        'command': 'test',
      });
      expect(
        f.owner.snapshot.pendingInput.single.data['server_request_id'],
        'socket-a:42',
      );
      f.session.connectionChanged(DesktopConnectionState.disconnected);
      expect(f.owner.snapshot.pendingInput, isEmpty);
      f.emit('approval.request', {
        'server_request_id': 'socket-b:42',
        'command': 'test',
      });
      expect(
        await f.session.tryRespondToApproval(
          sessionId: 'stored',
          requestId: 'socket-a:42',
          choice: 'approve',
        ),
        isFalse,
      );
      expect(
        f.owner.snapshot.pendingInput.single.data['server_request_id'],
        'socket-b:42',
      );
      await f.close();
    },
  );

  test('pending stores serialize read/modify/write across instances', () async {
    final a = NormalGatewayPendingStore();
    final b = NormalGatewayPendingStore();
    await Future.wait([a.put(_marker('a')), b.put(_marker('b'))]);
    expect((await a.load('scope')).map((row) => row.localSessionId).toSet(), {
      'a',
      'b',
    });
    await Future.wait([a.remove(_marker('a')), b.put(_marker('c'))]);
    expect((await b.load('scope')).map((row) => row.localSessionId).toSet(), {
      'b',
      'c',
    });
    await a.put(_marker('b').withPhase('settled'));
    expect((await b.load('scope')).map((row) => row.localSessionId), ['c']);
  });

  test(
    'long outage has no attempt exhaustion and policy resume restarts immediately',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await NormalGatewayPendingStore().put(_marker('local'));
      fakeAsync((clock) {
        var attempts = 0;
        final session = NormalGatewayApplicationSession(
          connection: _connection,
          scope: 'scope',
          pendingStore: NormalGatewayPendingStore(
            preferences: () async => prefs,
          ),
          submit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {
                fail('Recovery must never submit');
              },
          resume: ({required localSessionId, required storedSessionId}) async {
            attempts++;
            throw StateError('Still offline');
          },
          history: (_) async => [],
        );
        clock.flushMicrotasks();
        clock.elapse(const Duration(hours: 2));
        expect(attempts, greaterThan(100));
        expect(session.hasActiveTurn, isTrue);
        session.setLifecycle(background: true, backgroundWorkEnabled: false);
        final paused = attempts;
        clock.elapse(const Duration(hours: 1));
        expect(attempts, paused);
        session.setLifecycle(background: false);
        clock.flushMicrotasks();
        expect(attempts, paused + 1);
        session.close();
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  test(
    'terminal state stays active until the settlement receipt is durable',
    () async {
      final store = _HeldSettlementStore();
      final session = NormalGatewayApplicationSession(
        connection: _connection,
        scope: 'scope',
        pendingStore: store,
        submit:
            ({
              required sessionId,
              required text,
              required onEvent,
              required onSent,
            }) async {
              onSent();
            },
        resume: ({required localSessionId, required storedSessionId}) async =>
            const ResumedGatewaySession(
              runtimeSessionId: 'runtime',
              running: true,
            ),
        history: (_) async => [],
      );
      await session.ready;
      final chat = session.chatFor(
        'local',
        storedSessionId: 'stored',
        title: 'Chat',
      );
      chat.observeHistory([]);
      await chat.submitPrepared(
        reservation: chat.reserve()!,
        text: 'Run',
        localContent: 'Run',
      );
      session.receiveEvent(
        'local',
        StreamEvent(type: 'turn.end', data: const {'status': 'completed'}),
      );
      await store.entered.future;
      expect(session.hasActiveTurn, isTrue);
      expect(
        (await NormalGatewayPendingStore().load('scope')).single.phase,
        'emitted',
      );
      store.release.complete();
      await _flush();
      expect(session.hasActiveTurn, isFalse);
      expect(await store.load('scope'), isEmpty);
      await session.close();
    },
  );

  test('configuration fingerprint invalidates the old normal owner', () async {
    final controller = GatewayTurnApplicationController();
    NormalGatewayApplicationSession get(SavedConnection connection) =>
        controller.normalSessionFor(
          connection,
          submit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {},
          history: (_) async => [],
        );
    final old = get(_connection);
    await old.ready;
    final changed = get(_connection.copyWith(gatewayProfile: 'other'));
    expect(identical(old, changed), isFalse);
    expect(() => old.chatFor('x', title: 'X'), throwsStateError);
    await changed.ready;
    final changedHost = get(_connection.copyWith(host: 'other.fixture'));
    expect(identical(changed, changedHost), isFalse);
    await changedHost.ready;
    controller.revokeConnection(_connection.id);
    expect(() => changedHost.chatFor('x', title: 'X'), throwsStateError);
    await controller.close();
  });
}

final _connection = SavedConnection(
  id: 'normal-fixture',
  label: 'Normal',
  host: 'normal.fixture',
  port: 8642,
  apiKey: 'private-key',
);

NormalGatewayPendingMarker _marker(String local, {String phase = 'emitted'}) =>
    NormalGatewayPendingMarker(
      scope: 'scope',
      localSessionId: local,
      storedSessionId: 'stored',
      turnId: 'turn-$local',
      rowFloor: 10,
      phase: phase,
      createdAt: 1,
      updatedAt: 1,
    );

Future<void> _flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _HeldSettlementStore extends NormalGatewayPendingStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> put(NormalGatewayPendingMarker marker) async {
    if (marker.phase == 'settled') {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.put(marker);
  }
}

class _Fixture {
  final store = NormalGatewayPendingStore();
  late final NormalGatewayApplicationSession session;
  late NormalGatewayChatOwner owner;
  Completer<void> rpc = Completer<void>();
  Future<void>? flight;
  int submissions = 0;
  int resumes = 0;
  bool emitOnSubmit = true;
  bool? running = true;
  bool historyFails = false;
  Completer<List<Map<String, dynamic>>>? historyGate;
  List<Map<String, dynamic>> rows = [
    {'id': 10, 'role': 'assistant', 'content': 'Before'},
  ];
  List<NormalGatewayPendingMarker> atInvocation = [];

  _Fixture() {
    session = NormalGatewayApplicationSession(
      connection: _connection,
      scope: 'scope',
      pendingStore: store,
      submit:
          ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            atInvocation = await store.load('scope');
            submissions++;
            if (emitOnSubmit) onSent();
            return rpc.future;
          },
      resume: ({required localSessionId, required storedSessionId}) async {
        resumes++;
        return ResumedGatewaySession(
          runtimeSessionId: 'runtime',
          running: running,
        );
      },
      history: (_) async {
        if (historyFails) throw StateError('history unavailable');
        return historyGate?.future ?? rows;
      },
    );
  }
  NormalGatewayChatOwner chat(String local, {String? stored}) =>
      session.chatFor(local, storedSessionId: stored, title: local);
  Future<void> start({bool seedHistory = true}) async {
    await session.ready;
    owner = chat('local', stored: 'stored');
    if (seedHistory) {
      owner.observeHistory([
        {'id': 10, 'role': 'assistant', 'content': 'Before'},
      ]);
    }
    flight = owner.submitPrepared(
      reservation: owner.reserve()!,
      text: 'private prompt',
      localContent: 'private prompt',
    );
    // Observe errors immediately; assertions join the original future later.
    flight!.ignore();
    await _flush();
  }

  void emit(String type, Map<String, dynamic> data) =>
      session.receiveEvent('local', StreamEvent(type: type, data: data));
  void resetRpc() {
    rpc = Completer<void>();
  }

  Future<void> close() async {
    await session.close();
    if (!rpc.isCompleted) rpc.complete();
    await flight?.catchError((Object _) {});
  }
}
