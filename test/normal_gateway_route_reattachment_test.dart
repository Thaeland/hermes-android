import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/widgets/gateway_activity_card.dart';
import 'package:hermes_android/core/widgets/gateway_insight_card.dart';
import 'package:hermes_android/core/services/composer_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'verbose_mode': false}));

  testWidgets(
    'notification-style push keeps both real ChatScreens mounted without build-time notifications',
    (tester) async {
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final remote = _Remote();
      await _open(tester, controller, remote);
      await tester.enterText(find.byType(TextField), 'One prompt');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      remote.event('message.delta', {'text': 'Active B'});
      await tester.pump();
      final owner = controller
          .normalSessionFor(_connection)
          .findChat('local-chat')!;
      final turn = owner.turnId;
      await _open(
        tester,
        controller,
        remote,
        id: 'stored-chat',
        key: const ValueKey('notification-route'),
        push: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ChatScreen, skipOffstage: false), findsNWidgets(2));
      expect(find.text('Active B'), findsOneWidget);
      expect(owner.turnId, turn);
      expect(owner.snapshot.hasActiveTurn, isTrue);
      expect(remote.submissions, 1);
      remote.event('message.delta', {'text': ' continued'});
      await tester.pump();
      expect(find.text('Active B continued'), findsOneWidget);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(ChatScreen))).pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Active B continued'), findsOneWidget);
      expect(remote.submissions, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'pop/reopen restores owner deltas and tools, terminal while absent settles',
    (tester) async {
      final controller = GatewayTurnApplicationController();
      final remote = _Remote();
      await _open(tester, controller, remote);
      await tester.enterText(find.byType(TextField), 'One prompt');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      expect(remote.submissions, 1);
      remote.event('message.delta', {'text': 'Before pop. '});
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      remote.event('message.delta', {'text': 'Continued while absent.'});
      remote.event('tool.start', {'tool': 'read_file', 'tool_id': 'call-1'});
      expect(controller.hasActiveTurn, isTrue);
      await _open(tester, controller, remote, id: 'stored-chat');
      expect(find.textContaining('Continued while absent.'), findsOneWidget);
      expect(remote.submissions, 1);
      expect(find.byTooltip('Stop response'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      remote.event('tool.complete', {
        'tool': 'read_file',
        'tool_id': 'call-1',
        'status': 'completed',
      });
      remote.event('message.complete', {
        'text': 'Finished while no route existed.',
      });
      remote.rpc.complete();
      await tester.pump();
      await tester.pump();
      expect(controller.hasActiveTurn, isFalse);
      await _open(tester, controller, remote, id: 'stored-chat');
      expect(find.text('Finished while no route existed.'), findsOneWidget);
      expect(find.byTooltip('Stop response'), findsNothing);
      expect(remote.submissions, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await controller.close();
    },
  );

  testWidgets(
    'late latest history retires a settled optimistic timeline on real route reopen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final remote = _Remote()..history = [];
      await _open(tester, controller, remote);
      await tester.enterText(find.byType(TextField), 'One prompt');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      remote.event('message.start', {}, turnId: 'A');
      remote.event('message.delta', {'text': 'Wire reply'}, turnId: 'A');
      remote.event('tool.start', {
        'tool': 'read_file',
        'tool_id': 'optimistic-only',
      }, turnId: 'A');
      remote.event('message.complete', {'text': 'Wire reply'}, turnId: 'A');
      // A correlated lifecycle can finish before HTTP persistence is visible.
      // Stock ID-less terminals are separately covered by reconciliation tests.
      remote.event('turn.end', {'status': 'completed'}, turnId: 'A');
      remote.rpc.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final owner = controller
          .normalSessionFor(_connection)
          .findChat('stored-chat')!;
      expect(controller.hasActiveTurn, isFalse);
      expect(find.text('Wire reply'), findsOneWidget);
      expect(find.byType(GatewayActivityCard), findsOneWidget);
      expect(owner.snapshot.tools, hasLength(1));
      final before = remote.historyRequests;
      remote.history = [
        {'id': 1, 'role': 'user', 'content': 'One prompt'},
        {'id': 2, 'role': 'assistant', 'content': 'Canonical reply'},
      ];
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await _open(
        tester,
        controller,
        remote,
        id: 'stored-chat',
        key: const ValueKey('late-canonical'),
      );
      await tester.pump();
      expect(remote.historyRequests, greaterThan(before));
      expect(find.text('One prompt'), findsOneWidget);
      expect(find.text('Canonical reply'), findsOneWidget);
      expect(find.text('Wire reply'), findsNothing);
      expect(find.byType(GatewayActivityCard), findsNothing);
      expect(owner.snapshot.displayRows, isEmpty);
      expect(owner.snapshot.tools, isEmpty);
      expect(owner.snapshot.timeline.runs, isEmpty);
      expect(remote.submissions, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'retained owner preserves timeline order across snapshots and route reattachment',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final remote = _Remote();
      await _open(tester, controller, remote);
      await tester.enterText(find.byType(TextField), 'One prompt');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      remote.event('message.delta', {'text': 'Commentary A'});
      remote.event('message.interim', {
        'text': 'Commentary A',
        'already_streamed': true,
      });
      remote.event('tool.start', {'tool': 'read_file', 'tool_id': 't1'});
      remote.event('message.delta', {'text': 'Commentary B'});
      remote.event('reasoning.delta', {'text': 'Exposed reasoning'});
      remote.event('tool.start', {'tool': 'read_file', 'tool_id': 't2'});
      await tester.pump();
      List<String> labels() => tester
          .widgetList(
            find.byWidgetPredicate(
              (w) =>
                  w is MessageBubble ||
                  w is GatewayReasoningCard ||
                  w is GatewayActivityCard,
            ),
          )
          .map(
            (w) => switch (w) {
              MessageBubble b => b.content,
              GatewayReasoningCard _ => 'reasoning',
              GatewayActivityCard c =>
                c.activities.map((a) => a.toolId).join(','),
              _ => throw StateError('Unexpected timeline widget'),
            },
          )
          .toList();
      expect(labels(), [
        'One prompt',
        'Commentary A',
        't1',
        'Commentary B',
        'reasoning',
        't2',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      remote.event('tool.complete', {
        'tool': 'read_file',
        'tool_id': 't1',
        'status': 'completed',
      });
      remote.event('message.delta', {'text': ' continued'});
      await _open(
        tester,
        controller,
        remote,
        id: 'stored-chat',
        key: const ValueKey('timeline-remount'),
      );
      expect(labels(), [
        'One prompt',
        'Commentary A',
        't1',
        'Commentary B',
        'reasoning',
        't2',
        ' continued',
      ]);
      expect(remote.submissions, 1);
      remote.event('message.complete', {'text': 'Commentary B continued'});
      remote.rpc.complete();
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'duplicate route cannot send a second turn through stored alias',
    (tester) async {
      final controller = GatewayTurnApplicationController();
      final remote = _Remote();
      await _open(tester, controller, remote);
      await tester.enterText(find.byType(TextField), 'First turn');
      final oldSend = tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
          .onPressed!;
      oldSend();
      oldSend();
      await tester.pump();
      await tester.pump();
      await _open(
        tester,
        controller,
        remote,
        id: 'stored-chat',
        key: const ValueKey('replacement'),
      );
      await tester.enterText(find.byType(TextField), 'Keep this newer draft');
      expect(find.byTooltip('Send'), findsNothing);
      expect(remote.submissions, 1);
      remote.event('turn.end', {'status': 'completed'});
      remote.rpc.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep this newer draft',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await controller.close();
    },
  );

  for (final newer in <String?>[null, 'A newer draft', '']) {
    testWidgets(
      'pre-wire rejection after pop restores only the owned draft: $newer',
      (tester) async {
        final controller = GatewayTurnApplicationController();
        final remote = _Remote()..emitOnSent = false;
        await _open(tester, controller, remote);
        await tester.enterText(find.byType(TextField), 'Unsent after handoff');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();
        expect(remote.submissions, 1);
        if (newer != null) {
          await tester.enterText(find.byType(TextField), 'Intervening edit');
          await tester.enterText(find.byType(TextField), newer);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        remote.rpc.completeError(StateError('Definite pre-wire rejection'));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(controller.hasActiveTurn, isFalse);
        await _open(
          tester,
          controller,
          remote,
          key: const ValueKey('reattached'),
        );
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          newer ?? 'Unsent after handoff',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await controller.close();
      },
    );

    testWidgets(
      'dispose before handoff cancels admission and preserves draft: $newer',
      (tester) async {
        final controller = GatewayTurnApplicationController();
        final remote = _Remote();
        final ensure = Completer<void>();
        await _open(
          tester,
          controller,
          remote,
          prepare: (_, _) => ensure.future,
        );
        await tester.enterText(
          find.byType(TextField),
          'Admitted unsent prompt',
        );
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        if (newer != null) {
          await tester.enterText(find.byType(TextField), 'Intervening edit');
          await tester.enterText(find.byType(TextField), newer);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(controller.hasActiveTurn, isFalse);
        ensure.complete();
        await tester.pump();
        await tester.pump();
        expect(remote.submissions, 0);
        expect(
          await ComposerDraftStore.read(
            connectionId: _connection.id,
            sessionId: 'local-chat',
          ),
          (newer ?? 'Admitted unsent prompt').isEmpty
              ? isNull
              : newer ?? 'Admitted unsent prompt',
        );
        await _open(tester, controller, remote, prepare: (_, _) async {});
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          newer ?? 'Admitted unsent prompt',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await controller.close();
      },
    );
  }
}

final _connection = SavedConnection(
  id: 'app-owner-widget',
  label: 'Fixture',
  host: 'fixture.invalid',
  port: 8642,
  apiKey: 'fixture',
);

Future<void> _open(
  WidgetTester tester,
  GatewayTurnApplicationController controller,
  _Remote remote, {
  String id = 'local-chat',
  Key? key,
  Future<void> Function(String, String)? prepare,
  bool push = false,
}) async {
  final screen = ChatScreen(
    key: key,
    connection: _connection,
    session: Session(
      id: id,
      title: 'Owner chat',
      model: 'fixture',
      source: 'test',
      messageCount: 0,
      isActive: true,
      preview: '',
      startedAt: 1,
      isLocalDraft: prepare != null,
    ),
    projectWorkingDirectory: prepare == null ? null : '/project',
    turnApplicationController: controller,
    testApiClient: ApiClient(
      baseUrl: _connection.baseUrl,
      apiKey: 'fixture',
      httpClient: MockClient((_) async {
        remote.historyRequests++;
        return http.Response(remote.historyJson, 200);
      }),
    ),
    testRemotePromptSubmit: remote.submit,
    testNormalResume:
        ({required localSessionId, required storedSessionId}) async =>
            ResumedGatewaySession(
              runtimeSessionId: 'runtime',
              running: !remote.completed,
            ),
    testStoredSessionKey: (_) => 'stored-chat',
    testLegacyProjectSessionEnsure: prepare,
    testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
  );
  if (push) {
    unawaited(
      Navigator.of(
        tester.element(find.byType(ChatScreen)),
      ).push<void>(MaterialPageRoute(builder: (_) => screen)),
    );
  } else {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: screen,
      ),
    );
  }
  await tester.pump();
  await tester.pump();
  if (push) {
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }
}

class _Remote {
  final rpc = Completer<void>();
  StreamCallback? onEvent;
  int submissions = 0;
  bool emitOnSent = true;
  bool completed = false;
  String finalText = '';
  int historyRequests = 0;
  List<Map<String, dynamic>>? history;
  String get historyJson => jsonEncode({
    'data':
        history ??
        (completed
            ? [
                {'id': 2, 'role': 'assistant', 'content': finalText},
              ]
            : []),
  });
  Future<void> submit({
    required String sessionId,
    required String text,
    required StreamCallback onEvent,
    required void Function() onSent,
  }) {
    submissions++;
    this.onEvent = onEvent;
    if (emitOnSent) onSent();
    return rpc.future;
  }

  void event(String type, Map<String, dynamic> data, {String? turnId}) {
    if (type == 'message.complete' || type == 'turn.end') {
      completed = true;
      finalText = data['text']?.toString() ?? 'Final';
    }
    onEvent!(StreamEvent(type: type, data: data, turnId: turnId));
  }
}
