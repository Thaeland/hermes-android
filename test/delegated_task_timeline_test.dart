import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/controllers/delegated_task_controller.dart';
import 'package:hermes_android/core/models/gateway_insight.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/widgets/delegated_task_timeline.dart';
import 'package:hermes_android/core/widgets/gateway_insight_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_voice_composer_adapter.dart';
import 'delegated_task_history_test.dart' show FakeHistory, rows, task;

Widget app(Widget home) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: home,
);
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'widget lifecycle pauses polling and disposal fences a pending response',
    (tester) async {
      final history = FakeHistory()..data = rows(1, 2);
      final controller = DelegatedTaskController(task: task, history: history);
      await tester.pumpWidget(
        app(Scaffold(body: DelegatedTaskTimeline(controller: controller))),
      );
      await tester.pump();
      expect(history.offsets, [0]);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(seconds: 10));
      expect(history.offsets, [0]);
      history.gate = Completer<List<Map<String, dynamic>>>();
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(history.offsets, [0, 0]);
      await tester.pumpWidget(const SizedBox());
      history.gate!.complete(rows(1, 3));
      await tester.pump();
      expect(controller.rows, hasLength(2));
      expect(history.closed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  for (final retained in [true, false]) {
    testWidgets(
      'completed stored delegation reopens with retained reference=$retained',
      (tester) async {
        final history = FakeHistory()
          ..data = [
            {'id': 1, 'role': 'assistant', 'content': 'Recorded child reply'},
          ];
        await tester.pumpWidget(
          app(
            ChatScreen(
              connection: SavedConnection(
                id: 'stored-c',
                label: 'c',
                host: 'parent.fixture',
                port: 8642,
                apiKey: 'fixture',
              ),
              session: const Session(
                id: 'stored-parent',
                title: 'Parent',
                model: 'fixture',
                source: 'api_server',
                messageCount: 3,
                isActive: false,
                preview: '',
                startedAt: 1,
              ),
              testApiClient: ApiClient(
                baseUrl: 'http://parent.fixture',
                apiKey: 'fixture',
                httpClient: MockClient(
                  (request) async => http.Response(
                    jsonEncode({
                      'data': [
                        {'id': 1, 'role': 'user', 'content': 'Delegate this'},
                        {
                          'id': 2,
                          'role': 'assistant',
                          'content': '',
                          'tool_calls': [
                            {
                              'id': 'delegation-call',
                              'function': {
                                'name': 'delegate_task',
                                'arguments': '{"goal":"Stored task"}',
                              },
                            },
                          ],
                        },
                        {
                          'id': 3,
                          'role': 'tool',
                          'tool_call_id': 'delegation-call',
                          'content': jsonEncode({
                            'results': [
                              {
                                'status': 'completed',
                                'summary': 'Task finished',
                                if (retained)
                                  'child_session_id': 'stored-child',
                              },
                            ],
                          }),
                        },
                      ],
                    }),
                    200,
                  ),
                ),
              ),
              testTaskHistorySource: () => history,
              testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final card = find.byType(GatewaySubagentCard);
        expect(card, findsOneWidget);
        await tester.tap(
          find.descendant(of: card, matching: find.byType(ExpansionTile)),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Stored task'));
        await tester.tap(find.text('Stored task'));
        await tester.pumpAndSettle();
        expect(find.byType(ChatScreen), findsOneWidget);
        expect(find.text('Status: completed'), findsOneWidget);
        if (retained) {
          expect(history.offsets, [0]);
          expect(find.text('Stored session: stored-child'), findsOneWidget);
          expect(find.byType(MarkdownBody), findsWidgets);
        } else {
          expect(history.offsets, isEmpty);
          expect(
            find.textContaining('did not retain its session reference'),
            findsOneWidget,
          );
        }
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'overlay loading/error/retry, rich transcript and stable collapsed details',
    (tester) async {
      final history = FakeHistory()
        ..gate = Completer<List<Map<String, dynamic>>>();
      final controller = DelegatedTaskController(task: task, history: history);
      await tester.pumpWidget(
        app(Scaffold(body: DelegatedTaskTimeline(controller: controller))),
      );
      expect(find.text('Loading task history…'), findsOneWidget);
      history.gate!.completeError(Exception('offline'));
      await tester.pump();
      expect(find.textContaining('offline'), findsOneWidget);
      history.gate = null;
      history.data = [
        {
          'id': 1,
          'role': 'assistant',
          'content': '**Recorded prose**',
          'reasoning_details': '[{"text":"Exposed thought"}]',
          'tool_calls': [
            {
              'id': 'c',
              'function': {
                'name': 'terminal',
                'arguments': '{"command":"pwd"}',
              },
            },
          ],
        },
        {
          'id': 2,
          'role': 'tool',
          'tool_call_id': 'c',
          'content': 'actual result',
        },
      ];
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(find.byType(MarkdownBody), findsOneWidget);
      final reasoning = find.widgetWithText(ExpansionTile, 'Reasoning');
      expect(
        tester.widget<ExpansionTile>(reasoning).initiallyExpanded,
        isFalse,
      );
      await tester.tap(find.text('Reasoning'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Exposed thought').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Tool call · terminal'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.textContaining('"command":"pwd"').hitTestable(),
        findsOneWidget,
      );
      history.data.first['reasoning'] = 'New sidecar';
      await controller.refresh();
      await tester.pump();
      expect(find.text('Exposed thought').hitTestable(), findsOneWidget);
      final newReasoning = find.byKey(
        const PageStorageKey('reasoning:1:reasoning:0'),
      );
      expect(
        tester.widget<ExpansionTile>(newReasoning).initiallyExpanded,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
      expect(history.closed, isTrue);
    },
  );

  testWidgets(
    'empty differs from unavailable metadata and older paging is explicit',
    (tester) async {
      final history = FakeHistory()..data = rows(51, 100);
      final controller = DelegatedTaskController(task: task, history: history);
      await tester.pumpWidget(
        app(Scaffold(body: DelegatedTaskTimeline(controller: controller))),
      );
      await tester.pump();
      expect(history.offsets, [0]);
      expect(find.text('Load older'), findsOneWidget);
      history.data = rows(1, 50);
      await tester.tap(find.text('Load older'));
      await tester.pump();
      expect(history.offsets, [0, 50]);
      expect(controller.rows, hasLength(100));
      await tester.pumpWidget(const SizedBox());

      final empty = DelegatedTaskController(task: task, history: FakeHistory());
      await tester.pumpWidget(
        app(Scaffold(body: DelegatedTaskTimeline(controller: empty))),
      );
      await tester.pump();
      expect(find.textContaining('No recorded messages yet'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final absent = DelegatedTaskController(
        task: const GatewaySubagentActivity(
          id: 'r',
          goal: 'Legacy',
          phase: GatewaySubagentPhase.completed,
        ),
        history: FakeHistory(),
      );
      await tester.pumpWidget(
        app(Scaffold(body: DelegatedTaskTimeline(controller: absent))),
      );
      expect(
        find.textContaining('did not retain its session reference'),
        findsOneWidget,
      );
      expect(find.textContaining('No recorded messages yet'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final width in [430.0, 1000.0]) {
    testWidgets(
      'ChatScreen task tap at width $width retains mounted parent, composer and scroll; no child RPC',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final hook = TestDesktopAsyncEventHook();
        final requests = <Uri>[];
        var childSourceCount = 0;
        final history = FakeHistory()
          ..data = [
            {'id': 1, 'role': 'agent', 'content': 'Child answer'},
          ];
        final chatKey = GlobalKey();
        await tester.pumpWidget(
          app(
            ChatScreen(
              key: chatKey,
              connection: SavedConnection(
                id: 'c',
                label: 'c',
                host: 'parent.fixture',
                port: 8642,
                apiKey: 'fixture',
              ),
              session: const Session(
                id: 'parent',
                title: 'Parent',
                model: 'fixture',
                source: 'api_server',
                messageCount: 2,
                isActive: true,
                preview: '',
                startedAt: 1,
              ),
              testApiClient: ApiClient(
                baseUrl: 'http://parent.fixture',
                apiKey: 'fixture',
                httpClient: MockClient((request) async {
                  requests.add(request.url);
                  expectSync(request.method, 'GET');
                  return http.Response(
                    jsonEncode({
                      'data': [
                        {'id': 1, 'role': 'user', 'content': 'Parent question'},
                        {
                          'id': 2,
                          'role': 'assistant',
                          'content': 'Parent answer\n\n' * 25,
                        },
                      ],
                    }),
                    200,
                  );
                }),
              ),
              testDesktopAsyncEventHook: hook,
              testTaskHistorySource: () {
                childSourceCount++;
                return history;
              },
              testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        hook.handler!(
          StreamEvent(
            type: 'subagent.start',
            data: {
              'subagent_id': 'runtime',
              'child_session_id': 'stored-child',
              'goal': 'Inspect',
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final row = find.byKey(const ValueKey('delegated-task-runtime'));
        await tester.ensureVisible(row);
        await tester.pump();
        final composer = find.byType(TextField).first;
        await tester.enterText(composer, 'Keep this draft');
        final parentState = chatKey.currentState;
        final parentScrollable = find
            .descendant(
              of: find.byType(ChatScreen),
              matching: find.byType(Scrollable),
            )
            .first;
        final position = tester
            .state<ScrollableState>(parentScrollable)
            .position;
        final offset = position.pixels;
        final requestsBefore = requests.length;
        await tester.tap(row);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Task timeline'), findsOneWidget);
        expect(
          width >= 700 ? find.byType(Dialog) : find.byType(BottomSheet),
          findsOneWidget,
        );
        expect(childSourceCount, 1);
        expect(history.offsets, [0]);
        expect(chatKey.currentState, same(parentState));
        hook.handler!(
          StreamEvent(
            type: 'subagent.complete',
            data: {
              'subagent_id': 'runtime',
              'status': 'failed',
              'summary': 'Failed safely',
            },
          ),
        );
        await tester.pump();
        expect(find.text('Status: failed'), findsOneWidget);
        expect(requests, hasLength(requestsBefore));
        expect(position.pixels, offset);
        if (width < 700) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.text('Close'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Task timeline'), findsNothing);
        expect(chatKey.currentState, same(parentState));
        expect(
          tester.widget<TextField>(composer).controller!.text,
          'Keep this draft',
        );
        expect(position.pixels, offset);
        expect(history.closed, isTrue);
        // A late task progress event cannot regress failure or target another ID.
        hook.handler!(
          StreamEvent(
            type: 'subagent.text',
            data: {'subagent_id': 'runtime', 'text': 'Late'},
          ),
        );
        await tester.pump();
        expect(find.textContaining('failed'), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
