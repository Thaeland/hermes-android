import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/widgets/background_report_card.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

const _quote =
    '[ASYNC DELEGATION COMPLETE] I am quoting a report, not sending one.';
const _body =
    ' \r\n<untrusted_tool_result>raw output</untrusted_tool_result>'
    '\n literal \\n\n  FINAL_MARKER  \n ';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (_) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
  });

  for (final width in [400.0, 1000.0]) {
    for (final verbose in [false, true]) {
      testWidgets(
        'fetched USER reports, ordinary gold bubble, refresh and lazy pins '
        'width=$width verbose=$verbose',
        (tester) async {
          SharedPreferences.setMockInitialValues({'verbose_mode': verbose});
          await tester.binding.setSurfaceSize(Size(width, 1400));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final fixture = _History();
          final controller = GatewayTurnApplicationController();
          try {
            await tester.pumpWidget(_app(fixture, controller));
            await tester.pumpAndSettle();
            expect(fixture.reads, greaterThan(0));
            expect(fixture.requests.every((r) => r.method == 'GET'), isTrue);
            expect(find.byType(BackgroundReportCard), findsNWidgets(2));
            final screen = tester.state(find.byType(ChatScreen));
            final report = _report('Task summary');
            final other = _report('Process summary');
            final key = tester.widget(report).key;
            expect(_expanded(tester, report), isFalse);
            expect(_expanded(tester, other), isFalse);
            expect(find.text(_body, skipOffstage: false), findsNothing);
            expect(
              find.text('Issues reported — expand for details.'),
              findsOneWidget,
            );
            final humans = tester
                .widgetList<MessageBubble>(find.byType(MessageBubble))
                .where((bubble) => bubble.isUser)
                .toList();
            expect(humans, hasLength(1));
            expect(humans.single.content, _quote);
            expect(humans.single.onEdit, isNotNull);
            expect(humans.single.verbose, verbose);
            expect(
              find.descendant(
                of: find.byWidget(humans.single),
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Container &&
                      w.decoration is BoxDecoration &&
                      (w.decoration! as BoxDecoration).color ==
                          hermesUserMessageBubbleBackground,
                ),
              ),
              findsWidgets,
            );
            await tester.enterText(
              find.byType(TextField),
              'Unsent draft stays here',
            );
            await tester.tap(
              find.descendant(of: report, matching: find.text('Expand report')),
            );
            await tester.pumpAndSettle();
            expect(find.text(_body), findsOneWidget);
            expect(_expanded(tester, other), isFalse);
            expect(
              find.descendant(of: report, matching: find.byType(SelectionArea)),
              findsOneWidget,
            );
            expect(
              find.descendant(of: report, matching: find.byType(MessageBubble)),
              findsNothing,
            );
            await _refresh(tester);
            expect(tester.state(find.byType(ChatScreen)), same(screen));
            expect(tester.widget(report).key, key);
            expect(_expanded(tester, report), isTrue);
            expect(_expanded(tester, other), isFalse);
            expect(_draft(tester), 'Unsent draft stays here');

            // Real lazy sliver eviction (not just a widget rebuilt at one index).
            fixture.rows.add({
              'id': 5,
              'role': 'assistant',
              'content': List.generate(
                200,
                (i) => 'Filler line $i',
              ).join('\n\n'),
            });
            await _refresh(tester);
            final scroll = tester
                .widget<ListView>(find.byType(ListView).first)
                .controller!;
            scroll.jumpTo(scroll.position.maxScrollExtent);
            await tester.pumpAndSettle();
            expect(report, findsNothing);
            scroll.jumpTo(0);
            await tester.pumpAndSettle();
            expect(_expanded(tester, report), isTrue);
            expect(_expanded(tester, other), isFalse);
            expect(tester.widget(report).key, key);
            expect(tester.state(find.byType(ChatScreen)), same(screen));
            expect(_draft(tester), 'Unsent draft stays here');
            await tester.tap(
              find.descendant(
                of: report,
                matching: find.text('Collapse report'),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.text(_body, skipOffstage: false), findsNothing);
            expect(_expanded(tester, report), isFalse);
            final canonical = controller
                .normalSessionFor(fixture.connection)
                .findChat('stored-reports')!
                .snapshot
                .historyRows;
            expect(canonical.first['role'], 'user');
            expect(canonical.first['content'], _body);
            expect(
              canonical.first['display_kind'],
              'async_delegation_complete',
            );
            expect(fixture.submits, 0);
            expect(tester.takeException(), isNull);
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await controller.close();
            await tester.pump();
          }
        },
      );
    }
  }

  testWidgets(
    'same-State scope replacement and actual new visits start collapsed',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': true});
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = _History();
      final controller = GatewayTurnApplicationController();
      try {
        await tester.pumpWidget(_app(fixture, controller));
        await tester.pumpAndSettle();
        final report = _report('Task summary');
        final screen = tester.state(find.byType(ChatScreen));
        await tester.tap(
          find.descendant(of: report, matching: find.text('Expand report')),
        );
        await tester.pumpAndSettle();
        expect(_expanded(tester, report), isTrue);
        controller
            .presentationFor(fixture.connection)
            .bind('stored-reports', 'canonical-reports');
        await tester.pumpWidget(
          _app(fixture, controller, id: 'canonical-reports'),
        );
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ChatScreen)), same(screen));
        expect(_expanded(tester, report), isTrue);
        final navigator = Navigator.of(tester.element(find.byType(ChatScreen)));
        final covered = navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Covered route')),
          ),
        );
        await tester.pumpAndSettle();
        navigator.pop();
        await covered;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ChatScreen)), same(screen));
        expect(_expanded(tester, report), isTrue);
        // Keep the State and row ID while switching the actual chat preference scope.
        await tester.pumpWidget(_app(fixture, controller, id: 'other-chat'));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ChatScreen)), same(screen));
        expect(_expanded(tester, report), isFalse);
        await tester.tap(
          find.descendant(of: report, matching: find.text('Expand report')),
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(_app(fixture, controller));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(ChatScreen)), isNot(same(screen)));
        expect(_expanded(tester, report), isFalse);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.close();
        await tester.pump();
      }
    },
  );
  testWidgets(
    'same-State account/controller replacement resets report controllers only',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(1000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = _History();
      final original = GatewayTurnApplicationController();
      final replacement = GatewayTurnApplicationController();
      final account = SavedConnection(
        id: fixture.connection.id,
        label: 'Replacement',
        host: 'fixture.invalid',
        port: 8642,
        apiKey: 'different-fixture-account',
      );
      try {
        await tester.pumpWidget(_app(fixture, original));
        await tester.pumpAndSettle();
        final report = _report('Task summary');
        final screen = tester.state(find.byType(ChatScreen));
        for (final controller in [original, replacement]) {
          await tester.tap(
            find.descendant(of: report, matching: find.text('Expand report')),
          );
          await tester.pumpAndSettle();
          expect(_expanded(tester, report), isTrue);
          await tester.pumpWidget(
            _app(fixture, controller, connection: account),
          );
          await tester.pumpAndSettle();
          expect(tester.state(find.byType(ChatScreen)), same(screen));
          expect(_expanded(tester, report), isFalse);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await original.close();
        await replacement.close();
        await tester.pump();
      }
    },
  );
}

Finder _report(String summary) => find.byWidgetPredicate(
  (w) => w is BackgroundReportCard && w.report.summary == summary,
);
bool _expanded(WidgetTester tester, Finder card) => tester
    .widget<ExpansionTile>(
      find.descendant(of: card, matching: find.byType(ExpansionTile)),
    )
    .controller!
    .isExpanded;
String _draft(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;
Future<void> _refresh(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Chat actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Refresh'));
  await tester.pumpAndSettle();
}

Widget _app(
  _History fixture,
  GatewayTurnApplicationController controller, {
  String id = 'stored-reports',
  SavedConnection? connection,
}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ChatScreen(
    connection: connection ?? fixture.connection,
    session: Session(
      id: id,
      title: 'Report fixture',
      model: 'fixture',
      source: 'api_server',
      messageCount: 4,
      isActive: false,
      preview: '',
      startedAt: 1,
    ),
    turnApplicationController: controller,
    testApiClient: ApiClient(
      baseUrl: fixture.connection.baseUrl,
      apiKey: 'fixture',
      httpClient: MockClient(fixture.respond),
    ),
    testRemotePromptSubmit:
        ({
          required sessionId,
          required text,
          required onEvent,
          required onSent,
        }) async {
          fixture.submits++;
        },
    testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
  ),
);

class _History {
  int reads = 0;
  int submits = 0;
  final requests = <http.Request>[];
  final connection = SavedConnection(
    id: 'background-report-fixture',
    label: 'Fixture',
    host: 'fixture.invalid',
    port: 8642,
    apiKey: 'fixture',
  );
  final rows = <Map<String, dynamic>>[
    {
      'id': 1,
      'role': 'user',
      'content': _body,
      'display_kind': 'async_delegation_complete',
      'display_metadata': {'display_text': 'Task summary', 'failed_count': 1},
    },
    {
      'id': 2,
      'role': 'user',
      'content': 'Second report\nFULL_PROCESS_TAIL',
      'display_kind': 'process_complete',
      'display_metadata': {'display_text': 'Process summary'},
    },
    {'id': 3, 'role': 'user', 'content': _quote},
    {'id': 4, 'role': 'assistant', 'content': 'Ordinary answer'},
  ];
  Future<http.Response> respond(http.Request request) async {
    requests.add(request);
    if (!request.url.path.endsWith('/messages')) {
      return http.Response('{}', 404);
    }
    reads++;
    return http.Response(
      jsonEncode({'data': rows}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}
