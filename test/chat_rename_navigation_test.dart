import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/workspace_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';
import 'support/inert_turn_application_session.dart';

Map<String, dynamic> _row(String title) => {
  'id': 'chat-id',
  'title': title,
  'model': 'test-model',
  'source': 'api_server',
  'message_count': 2,
  'preview': 'Original preview',
  'started_at': 1,
  'last_active': 1,
};

SavedConnection _connection() => SavedConnection(
  id: 'rename-navigation',
  label: 'Test connection',
  host: 'fixture',
  port: 8642,
  apiKey: 'test-key',
  gatewayPrefix: '/mobile',
);

MaterialApp _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: hermesTheme(Brightness.dark),
  home: child,
);

Future<void> _rename(WidgetTester tester, String title) async {
  await tester.tap(find.byTooltip('Chat actions').last);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Rename'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextFormField), title);
  await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'verbose_mode': false}));

  testWidgets(
    'classic API-only list offers Rename and persists across reopening',
    (tester) async {
      var savedTitle = 'Original chat';
      final writes = <http.Request>[];
      http.Client makeClient() => MockClient((request) async {
        expect(request.url.path, startsWith('/mobile/'));
        if (request.method == 'PATCH') {
          writes.add(request);
          expect(request.url.path, '/mobile/api/sessions/chat-id');
          expect(jsonDecode(request.body), {'title': 'Renamed chat'});
          savedTitle = 'Renamed chat';
          return http.Response(jsonEncode({'session': _row(savedTitle)}), 200);
        }
        if (request.url.path == '/mobile/health') {
          return http.Response('{"status":"ok"}', 200);
        }
        if (request.url.path == '/mobile/api/sessions') {
          return http.Response(
            jsonEncode({
              'data': [_row(savedTitle)],
              'has_more': false,
            }),
            200,
          );
        }
        return http.Response('{"data":[]}', 200);
      });
      final controller = GatewayTurnApplicationController(
        sessionFactory: (_) => InertTurnApplicationSession(),
      );
      addTearDown(controller.close);
      Widget screen() => SessionListScreen(
        connection: _connection(),
        turnApplicationController: controller,
        testHttpClient: makeClient(),
      );
      await tester.pumpWidget(_app(screen()));
      await tester.pumpAndSettle();
      expect(find.text('Original chat'), findsOneWidget);
      await _rename(tester, 'Renamed chat');
      expect(writes, hasLength(1));
      expect(find.text('Renamed chat'), findsOneWidget);
      expect(find.text('Original preview'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(screen()));
      await tester.pumpAndSettle();
      expect(find.text('Renamed chat'), findsOneWidget);
      expect(writes, hasLength(1));
    },
  );

  testWidgets(
    'Workspace Chats wires Rename to API and refreshes after chat return',
    (tester) async {
      var savedTitle = 'Original chat';
      final writes = <http.Request>[];
      http.Client makeClient() => MockClient((request) async {
        expect(request.url.path, startsWith('/mobile/'));
        if (request.method == 'PATCH') {
          writes.add(request);
          savedTitle = (jsonDecode(request.body) as Map)['title'] as String;
          return http.Response(jsonEncode({'session': _row(savedTitle)}), 200);
        }
        if (request.url.path.endsWith('/messages')) {
          return http.Response('{"data":[]}', 200);
        }
        if (request.url.path == '/mobile/api/sessions') {
          return http.Response(
            jsonEncode({
              'data': [_row(savedTitle)],
              'has_more': false,
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final connection = _connection();
      await tester.pumpWidget(
        _app(
          WorkspaceScreen(
            connection: connection,
            testSessionsHttpClient: makeClient(),
            sessionScreenBuilder: (session) => ChatScreen(
              connection: connection,
              session: session,
              testApiClient: ApiClient(
                baseUrl: connection.baseUrl,
                pathPrefix: connection.gatewayPrefix!,
                apiKey: 'test-key',
                httpClient: makeClient(),
              ),
              testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chats').last);
      await tester.pumpAndSettle();
      expect(find.text('Original chat'), findsOneWidget);
      await _rename(tester, 'From Chats');
      expect(writes, hasLength(1));
      expect(find.text('From Chats'), findsOneWidget);
      await tester.tap(find.text('From Chats'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatScreen), findsOneWidget);
      await _rename(tester, 'From open chat');
      expect(writes, hasLength(2));
      expect(find.text('From open chat'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('From open chat'), findsOneWidget);
      expect(find.text('From Chats'), findsNothing);
      expect(find.text('Original preview'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
