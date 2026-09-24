// Review blocker #3: a mid-turn socket drop must actually reattach. The
// gateway keeps the turn alive detached (activity-staleness gate), so on
// reconnect the screen must re-bind the session and refetch history —
// and the submit catch path must not clobber the freshly-resynced
// transcript with a composer-restore.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets(
    'mid-turn drop then reconnect re-binds the session and resyncs history',
    (tester) async {
      final hook = TestDesktopConnectionHook();
      var ensureCount = 0;
      final submission = Completer<void>();
      final history = _ReattachChatHttpClient();
      final apiClient = ApiClient(
        baseUrl: 'http://reattach.fixture',
        apiKey: 'fixture-key',
        httpClient: history,
      );
      await _pumpChat(
        tester,
        hook: hook,
        apiClient: apiClient,
        ensureCount: () => ensureCount++,
        remoteSubmit:
            ({required sessionId, required text, required onEvent}) {
              return submission.future;
            },
      );
      // Baseline: no Desktop gateway is configured for this fixture, so
      // initState never ensured a session; history was fetched once.
      expect(ensureCount, 0);
      expect(history.messageRequestCount, 1);

      // The socket is live, then the user sends and the turn goes in flight.
      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Long running task');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Socket drops mid-turn: the snackbar promises automatic reattach.
      hook.handler?.call(DesktopConnectionState.reconnecting);
      await tester.pump();
      expect(
        find.text(
          'Connection switched — the running reply continues on the '
          'server and will reattach automatically.',
        ),
        findsOneWidget,
      );
      // Nothing has been resynced yet — the promise is still pending.
      expect(ensureCount, 0);
      expect(history.messageRequestCount, 1);

      // The reconnect succeeds: the screen must re-bind and refetch now,
      // without waiting for any user action. The server finished the turn
      // detached during the outage. (No pumpAndSettle: the submit is
      // still pending and the streaming-follow loop keeps pumping.)
      history.includeCompletedTurn = true;
      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(ensureCount, 1, reason: 'reattach must re-ensure the session');
      expect(history.messageRequestCount, 2, reason: 'reattach must refetch history');
      expect(find.text('Server-side final response'), findsOneWidget);

      // The still-pending submit now fails with the socket-closed error.
      // The catch path must NOT clobber the resynced transcript or shove
      // the prompt back into the composer.
      submission.completeError(
        JsonRpcError('prompt.submit', 'Desktop gateway connection closed'),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Server-side final response'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
        reason: 'resynced history wins; composer must not be restored',
      );
      // And the resync is one-shot: no further fetches were triggered.
      expect(history.messageRequestCount, 2);
    },
  );

  testWidgets(
    'submit failure with no resync landed still restores the composer',
    (tester) async {
      final hook = TestDesktopConnectionHook();
      final history = _ReattachChatHttpClient();
      final apiClient = ApiClient(
        baseUrl: 'http://reattach.fixture',
        apiKey: 'fixture-key',
        httpClient: history,
      );
      await _pumpChat(
        tester,
        hook: hook,
        apiClient: apiClient,
        ensureCount: () {},
        remoteSubmit:
            ({required sessionId, required text, required onEvent}) async {
              throw JsonRpcError('prompt.submit', 'Desktop gateway connection closed');
            },
      );

      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Plain failure');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pumpAndSettle();

      // No reconnect happened, so the classic restore behavior stands.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Plain failure',
      );
      expect(history.messageRequestCount, 1);
    },
  );

  testWidgets(
    'reconnect with no turn in flight does not trigger a resync',
    (tester) async {
      final hook = TestDesktopConnectionHook();
      var ensureCount = 0;
      final history = _ReattachChatHttpClient();
      final apiClient = ApiClient(
        baseUrl: 'http://reattach.fixture',
        apiKey: 'fixture-key',
        httpClient: history,
      );
      await _pumpChat(
        tester,
        hook: hook,
        apiClient: apiClient,
        ensureCount: () => ensureCount++,
        remoteSubmit:
            ({required sessionId, required text, required onEvent}) async {},
      );

      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      hook.handler?.call(DesktopConnectionState.reconnecting);
      await tester.pump();
      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pumpAndSettle();

      // Idle drop: no snackbar, no extra ensure, no extra history fetch.
      expect(
        find.text(
          'Connection switched — the running reply continues on the '
          'server and will reattach automatically.',
        ),
        findsNothing,
      );
      expect(ensureCount, 0);
      expect(history.messageRequestCount, 1);
    },
  );
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required TestDesktopConnectionHook hook,
  required ApiClient apiClient,
  required VoidCallback ensureCount,
  required TestRemotePromptSubmit remoteSubmit,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: 'reattach-fixture',
          label: 'Reattach fixture',
          host: 'reattach.fixture',
          port: 8642,
          apiKey: 'fixture-key',
        ),
        session: const Session(
          id: 'reattach-session',
          title: 'Reattach chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testRemotePromptSubmit: remoteSubmit,
        testDesktopConnectionHook: hook,
        testDesktopSessionEnsured: ensureCount,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

class _ReattachChatHttpClient extends http.BaseClient {
  int messageRequestCount = 0;
  bool includeCompletedTurn = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      messageRequestCount += 1;
      final messages = includeCompletedTurn
          ? <Map<String, dynamic>>[
              {'role': 'user', 'content': 'Long running task'},
              {'role': 'assistant', 'content': 'Server-side final response'},
            ]
          : <Map<String, dynamic>>[];
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'data': messages}))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'error': 'unexpected request'}))),
      404,
      headers: {'content-type': 'application/json'},
    );
  }
}
