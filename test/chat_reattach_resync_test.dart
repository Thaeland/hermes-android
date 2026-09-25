// Review blocker #3: a mid-turn socket drop must actually reattach, with
// the REAL production close ordering. WsClient._handleClosedConnection
// rejects every pending RPC the instant the socket closes — so the submit
// catch fires BEFORE the reconnect (composer restore, optimistic turn
// stripped), and the resync runs later, on the fresh socket, while the
// detached server turn may still be settling. The resync must therefore:
// - fetch by the gateway's STORED session key (a newly created stock
//   session's DB row is not addressable by the mobile session id),
// - retry until the detached reply lands rather than trusting one fetch,
// - never clear the transcript on a 404 (row not readable yet ≠ empty).
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
    'production close ordering: submit fails at close, reconnect resyncs '
    'by stored session id and lands the detached reply',
    (tester) async {
      final hook = TestDesktopConnectionHook();
      var ensureCount = 0;
      final submission = Completer<void>();
      final history = _ReattachChatHttpClient();
      final apiClient = ApiClient(
        baseUrl: 'http://reattach.fixture',
        apiKey: 'reattach-key',
        httpClient: history,
      );
      await _pumpChat(
        tester,
        hook: hook,
        apiClient: apiClient,
        ensureCount: () => ensureCount++,
        storedKey: 'stored_sess_9f3a',
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

      // PRODUCTION ORDERING: WsClient rejects the pending prompt.submit AT
      // CLOSE, before any reconnect. The catch restores the composer and
      // strips the optimistic turn — this happens BEFORE the resync runs.
      history.includeCompletedTurn = true;
      submission.completeError(
        JsonRpcError('prompt.submit', 'Desktop gateway connection closed'),
      );
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Long running task',
        reason: 'the catch-at-close path restores the composer before reconnect',
      );
      expect(history.messageRequestCount, 1, reason: 'no resync before reconnect');

      // The reconnect succeeds: the screen must re-bind and refetch now,
      // without waiting for any user action. The server finished the turn
      // detached during the outage.
      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(ensureCount, 1, reason: 'reattach must re-ensure the session');
      expect(
        history.messageRequestCount,
        2,
        reason: 'reattach must refetch history',
      );
      // STORED IDENTITY: the refetch must target the gateway's stored DB
      // key, not the mobile session id — a newly created stock session is
      // not addressable by the mobile id, and a 404 there would wipe the
      // transcript.
      expect(
        history.requestedMessagePaths.last,
        contains('stored_sess_9f3a'),
        reason: 'resync must fetch by the stored session identity',
      );
      expect(find.text('Server-side final response'), findsOneWidget);

      // The reply landed (transcript grew past the pre-resync count), so
      // the resync is done: no further fetches were triggered.
      await tester.pump(const Duration(seconds: 3));
      expect(history.messageRequestCount, 2);
    },
  );

  testWidgets(
    'resync retries while the detached turn settles and never clears the '
    'transcript on 404',
    (tester) async {
      final hook = TestDesktopConnectionHook();
      final submission = Completer<void>();
      // The initial history fetch (request 1) succeeds; the resync fetch
      // (request 2) 404s — the stored row isn't readable yet.
      final history = _ReattachChatHttpClient()..failMessagesAfterFirst = 1;
      final apiClient = ApiClient(
        baseUrl: 'http://reattach.fixture',
        apiKey: 'reattach-key',
        httpClient: history,
      );
      await _pumpChat(
        tester,
        hook: hook,
        apiClient: apiClient,
        ensureCount: () {},
        storedKey: 'stored_sess_retry',
        remoteSubmit:
            ({required sessionId, required text, required onEvent}) {
              return submission.future;
            },
      );

      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Slow settling turn');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      // Close-ordering: submit fails at close, composer restored.
      hook.handler?.call(DesktopConnectionState.reconnecting);
      await tester.pump();
      submission.completeError(
        JsonRpcError('prompt.submit', 'Desktop gateway connection closed'),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      // Reconnect: the stored row is NOT readable yet — the first resync
      // fetch 404s. The transcript must survive (never cleared by a
      // failed resync) and the resync must retry, not give up on one shot.
      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final afterFirstResync = history.messageRequestCount;
      expect(afterFirstResync, 2, reason: 'first resync fetch attempted');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Slow settling turn',
        reason: 'a failed resync must not touch the composer either',
      );

      // The row becomes readable: the next retry must land the reply.
      history.failMessagesAfterFirst = 0;
      history.includeCompletedTurn = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));

      expect(
        history.messageRequestCount,
        greaterThan(afterFirstResync),
        reason: 'resync must retry until the settling turn lands',
      );
      expect(find.text('Server-side final response'), findsOneWidget);
    },
  );

  testWidgets(
    'resync does not stop on the synchronously-persisted user row; it '
    'waits for the terminal assistant reply beyond the old 3.5s budget',
    (tester) async {
      // The reviewer's real sequence: old history (ending in an assistant
      // row) -> the stock prompt.submit-persisted USER row appears first
      // -> the assistant reply lands LATER, past the old 4-attempt /
      // 3.5-second budget. Length-based completion would return on the
      // user row and strand the reply; the watermark must hold the resync
      // open until a terminal assistant row exists beyond the pre-drop
      // transcript.
      final hook = TestDesktopConnectionHook();
      final submission = Completer<void>();
      // Requests 2..5 (the whole old budget) serve user-only; the reply
      // lands on request 6 — ~7.5s after reconnect, beyond the old
      // horizon.
      final history = _ReattachChatHttpClient()
        ..oldHistory = const [
          {'role': 'user', 'content': 'Earlier question'},
          {'role': 'assistant', 'content': 'Earlier answer'},
        ]
        ..userOnlyUntilRequest = 5;
      final apiClient = ApiClient(
        baseUrl: 'http://reattach.fixture',
        apiKey: 'test-key',
        httpClient: history,
      );
      await _pumpChat(
        tester,
        hook: hook,
        apiClient: apiClient,
        ensureCount: () {},
        storedKey: 'stored_sess_longturn',
        remoteSubmit:
            ({required sessionId, required text, required onEvent}) {
              return submission.future;
            },
      );

      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Long running task');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      hook.handler?.call(DesktopConnectionState.reconnecting);
      await tester.pump();
      submission.completeError(
        JsonRpcError('prompt.submit', 'Desktop gateway connection closed'),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      // Reconnect: resync starts. Requests 2..5 grow the transcript (the
      // user row) but must NOT end the resync.
      hook.handler?.call(DesktopConnectionState.connected);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(history.messageRequestCount, 2);
      expect(
        find.text('Server-side final response'),
        findsNothing,
        reason: 'the user-only row must not render as a finished turn',
      );

      // Walk past the OLD budget (500+1000+2000+4000 = 7500ms of capped
      // backoff): the new budget keeps retrying.
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));

      // Request 6 lands the reply: it renders, and the resync stops.
      expect(
        history.messageRequestCount,
        greaterThan(5),
        reason: 'the retry budget must cover a turn longer than 3.5s',
      );
      expect(find.text('Server-side final response'), findsOneWidget);
      final settledCount = history.messageRequestCount;
      await tester.pump(const Duration(seconds: 5));
      expect(
        history.messageRequestCount,
        settledCount,
        reason: 'the terminal assistant watermark must end the resync',
      );
    },
  );

  testWidgets(
    'submit failure with no resync landed still restores the composer',
    (tester) async {
      final hook = TestDesktopConnectionHook();
      final history = _ReattachChatHttpClient();
      final apiClient = ApiClient(
        baseUrl: 'http://reattach.fixture',
        apiKey: 'reattach-key',
        httpClient: history,
      );
      await _pumpChat(
        tester,
        hook: hook,
        apiClient: apiClient,
        ensureCount: () {},
        remoteSubmit:
            ({required sessionId, required text, required onEvent}) async {
              throw JsonRpcError(
                'prompt.submit',
                'Desktop gateway connection closed',
              );
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
        apiKey: 'reattach-key',
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
  String? storedKey,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: 'reattach-fixture',
          label: 'Reattach fixture',
          host: 'reattach.fixture',
          port: 8642,
          apiKey: 'reattach-key',
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
        testStoredSessionKey: storedKey == null ? null : (_) => storedKey,
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

  /// Rows served BEFORE the detached turn's rows — the transcript that
  /// existed before the drop. The resync watermark counts growth past
  /// this, so an old trailing assistant row must not satisfy it.
  List<Map<String, dynamic>> oldHistory = const [];

  /// Serve the synchronously-persisted USER row of the detached turn
  /// without the assistant reply — the stock `prompt.submit` ordering the
  /// resync must not mistake for completion.
  bool userOnlyTurn = false;

  /// While the /messages request count is at or below this number, serve
  /// the user-only turn; after it, the completed turn. Models a long
  /// model turn whose reply lands beyond the resync retry budget's OLD
  /// 3.5-second horizon.
  int userOnlyUntilRequest = 0;

  /// /messages requests BEYOND this count get a 404 (simulates the
  /// stored row not being readable yet while the detached turn settles).
  /// 0 = never fail.
  int failMessagesAfterFirst = 0;

  final List<String> requestedMessagePaths = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      messageRequestCount += 1;
      requestedMessagePaths.add(request.url.path);
      if (failMessagesAfterFirst > 0 &&
          messageRequestCount > failMessagesAfterFirst) {
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'error': 'not found'}))),
          404,
          headers: {'content-type': 'application/json'},
        );
      }
      final messages = [
        ...oldHistory,
        if (includeCompletedTurn ||
            (userOnlyUntilRequest > 0 &&
                messageRequestCount > userOnlyUntilRequest)) ...[
          {'role': 'user', 'content': 'Long running task'},
          {'role': 'assistant', 'content': 'Server-side final response'},
        ] else if (userOnlyTurn || userOnlyUntilRequest > 0)
          {'role': 'user', 'content': 'Long running task'},
      ];
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
