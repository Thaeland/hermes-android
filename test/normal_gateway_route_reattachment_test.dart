import 'dart:async';

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
import 'support/recording_turn_notification_sink.dart';
import 'package:hermes_android/core/services/turn_notification_service.dart';
import 'package:hermes_android/core/services/notification_prefs.dart';
import 'package:hermes_android/core/services/delegated_task_history.dart';
import 'package:hermes_android/core/widgets/delegated_task_timeline.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'verbose_mode': false}));

  for (final (following, width) in [
    (true, 400.0),
    (false, 400.0),
    (true, 1000.0),
    (false, 1000.0),
  ]) {
    testWidgets(
      'owner stream updates open task aliases and final history without changing parent (following=$following, width=$width)',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = GatewayTurnApplicationController();
        addTearDown(controller.close);
        final remote = _Remote();
        final history = _OwnerTaskHistory();
        final sink = RecordingTurnNotificationSink();
        final notifications = TurnNotificationService(sink: sink);
        notificationPrefs.value = NotificationPrefs.defaults;
        controller.normalSessionFor(
          _connection,
          submit: remote.submit,
          notifications: notifications,
        );
        await _open(tester, controller, remote, taskHistory: history);
        await tester.enterText(find.byType(TextField), 'Delegate');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();
        remote.event('subagent.start', {
          'subagent_id': 'runtime-root',
          'child_session_id': 'child-root',
          'goal': 'Inspect',
        });
        await tester.pump();
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'Keep next draft');
        final card = tester.widget<GatewaySubagentCard>(
          find.byType(GatewaySubagentCard),
        );
        remote.event('message.delta', {
          'text': List.filled(80, 'Parent stream line.\n\n').join(),
        });
        await tester.pump();
        await tester.pump();
        final parentScroll = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(ChatScreen),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        expect(parentScroll.maxScrollExtent, greaterThan(0));
        // Finish the composer's reveal/expansion animations before pinning a
        // reader position; the stream itself remains controlled and pending.
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        parentScroll.jumpTo(parentScroll.maxScrollExtent);
        if (!following) {
          await tester.drag(find.byType(ListView).first, const Offset(0, 400));
          parentScroll.jumpTo(parentScroll.pixels);
          await tester.pump();
        }
        final offset = parentScroll.pixels;
        // Queue an owner follow callback, then open before it can execute.
        remote.event('message.delta', {'text': 'Queued before modal.\n'});
        card.onOpenTask!(card.activities.single);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        final overlay = tester.widget<DelegatedTaskTimeline>(
          find.byType(DelegatedTaskTimeline),
        );
        expect(history.requests, [('child-root', null)]);
        expect(
          parentScroll.pixels,
          offset,
          reason: 'Opening the overlay preserves parent offset',
        );
        // Hold a read while a new advertised tip and terminal status arrive.
        final held = Completer<TaskHistoryPage>();
        history.gate = held;
        unawaited(overlay.controller.refresh());
        await tester.pump();
        remote.event('subagent.text', {
          'subagent_id': 'runtime-root',
          'child_session_id': 'child-tip',
          'text': 'Child progressing',
        });
        remote.event('subagent.text', {
          'subagent_id': 'new-runtime-alias',
          'child_session_id': 'child-tip',
          'text': 'Alias progressing',
        });
        remote.event('message.delta', {
          'text': List.filled(20, 'More parent text.\n\n').join(),
        });
        await tester.pump();
        expect(overlay.controller.task.livePreview, 'Alias progressing');
        await tester.tap(find.text('Live preview from parent events'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('Alias progressing'), findsOneWidget);
        expect(parentScroll.pixels, offset);
        remote.event('subagent.complete', {
          'subagent_id': 'new-runtime-alias',
          'child_session_id': 'child-tip',
          'status': 'failed',
        });
        await tester.pump();
        expect(find.text('Status: Failed'), findsOneWidget);
        history.gate = null;
        history.finalRow = true;
        held.complete(
          const TaskHistoryPage(
            rows: [],
            sessionId: 'child-root',
            offset: 0,
            lineage: ['child-root'],
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(history.requests.last, ('child-root', 'child-tip'));
        expect(
          overlay.controller.rows.single['content'],
          'Recorded child final',
        );
        await tester.scrollUntilVisible(
          find.text('Recorded child final', findRichText: true),
          200,
          scrollable: find
              .descendant(
                of: find.byType(DelegatedTaskTimeline),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          find.text('Recorded child final', findRichText: true),
          findsOneWidget,
        );
        expect(
          controller
              .normalSessionFor(_connection)
              .findChat('local-chat')!
              .snapshot
              .subagents,
          hasLength(1),
        );
        expect(parentScroll.pixels, offset);
        expect(
          tester
              .widget<TextField>(find.byType(TextField, skipOffstage: false))
              .controller!
              .text,
          'Keep next draft',
        );
        if (following) {
          await tester.tap(find.widgetWithText(TextButton, 'Close'));
        } else {
          await tester.binding.handlePopRoute();
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(history.closed, isTrue);
        expect(parentScroll.pixels, offset);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Keep next draft',
        );
        expect(remote.submissions, 1);
        expect(sink.shown, isEmpty);
        // Parent settlement belongs to the application, not the modal or route.
        controller.setLifecycle(background: true, backgroundWorkEnabled: true);
        await tester.pumpWidget(const SizedBox.shrink());
        remote.event('message.complete', {'text': 'Parent final'});
        remote.event('turn.end', {'status': 'completed'});
        remote.rpc.complete();
        for (var i = 0; i < 6; i++) {
          await tester.pump();
        }
        expect(sink.shown.where((n) => !n.ongoing), hasLength(1));
        expect(sink.shown.single.payload, contains('stored-chat'));
        expect(sink.shown.single.payload, contains(_connection.id));
        expect(controller.hasActiveTurn, isFalse);
      },
    );
  }

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
  TaskHistorySource? taskHistory,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
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
          httpClient: MockClient(
            (_) async => http.Response('{"data":[]}', 200),
          ),
        ),
        testRemotePromptSubmit: remote.submit,
        testStoredSessionKey: (_) => 'stored-chat',
        testLegacyProjectSessionEnsure: prepare,
        testTaskHistorySource: taskHistory == null ? null : () => taskHistory,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class _OwnerTaskHistory implements TaskHistorySource {
  final requests = <(String, String?)>[];
  Completer<TaskHistoryPage>? gate;
  bool finalRow = false;
  bool closed = false;

  @override
  Future<TaskHistoryPage> fetch(
    String childId,
    int offset, {
    String? latestChildId,
    String? currentSessionId,
  }) async {
    requests.add((childId, latestChildId));
    if (gate != null) return gate!.future;
    return TaskHistoryPage(
      rows: [
        if (finalRow)
          {'id': 1, 'role': 'assistant', 'content': 'Recorded child final'},
      ],
      sessionId: latestChildId ?? childId,
      offset: offset,
      lineage: [childId, ?latestChildId],
    );
  }

  @override
  void close() {
    closed = true;
  }
}

class _Remote {
  final rpc = Completer<void>();
  StreamCallback? onEvent;
  int submissions = 0;
  bool emitOnSent = true;
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

  void event(String type, Map<String, dynamic> data) =>
      onEvent!(StreamEvent(type: type, data: data));
}
