// Review blocker #1: the stock gateway back-fills pinned sessions PAST the
// requested `limit` (api_server.py: list_sessions_rich include_pinned=True)
// and repeats those pins on later pages. A client that advances its offset
// by the RETURNED row count skips the window rows between the window and
// the back-fill, and a client that doesn't dedupe by id shows every pin
// once per page. This test drives both session-list loaders (the
// standalone SessionListScreen and Home's loader in WorkspaceScreen)
// against a fake that reproduces the stock paging semantics.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/session_list_screen.dart';
import 'package:hermes_android/core/screens/workspace_screen.dart';
import 'package:hermes_android/core/screens/workspace_sessions_screen.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/projects_gateway_client.dart';
import 'package:hermes_android/core/services/projects_repository.dart';
import 'package:hermes_android/core/theme/hermes_theme.dart';
import 'package:hermes_android/core/widgets/hermes_shell.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/inert_turn_application_session.dart';

const _now = 1750000000.0;

Map<String, dynamic> _windowRow(int index) => {
  'id': 'w$index',
  'title': 'Window chat $index',
  'model': 'gpt-oss-20b',
  'source': 'gateway',
  'message_count': 2,
  'preview': 'hello',
  'started_at': _now - index,
  'last_active': _now - index,
};

/// A pinned row: newest activity so it sorts to the top of every rendered
/// list, and `pinned: true` so the stock back-fill semantics apply.
Map<String, dynamic> _pinnedRow(String id) => {
  'id': id,
  'title': 'Pinned chat',
  'model': 'gpt-oss-20b',
  'source': 'gateway',
  'message_count': 2,
  'preview': 'pinned preview',
  'started_at': _now + 1000,
  'last_active': _now + 1000,
  'pinned': true,
};

/// Fake of the stock `GET /api/sessions` paging contract:
/// - serves `limit` window rows for the requested offset,
/// - APPENDS the pinned rows beyond `limit` (back-fill),
/// - repeats the pins on EVERY page,
/// - `has_more` is decided by the window rows only (pins don't count).
///
/// Records every paged offset so the test can assert the client advanced
/// by the REQUESTED window rather than the returned row count.
class _PinnedBackfillClient extends http.BaseClient {
  _PinnedBackfillClient({required this.totalWindow, required this.pinnedIds});

  final int totalWindow;
  final List<String> pinnedIds;
  final List<String> requestedOffsets = [];

  http.StreamedResponse _json(Map<String, dynamic> body, {int status = 200}) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
        headers: {'content-type': 'application/json'},
      );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if (uri.path.endsWith('/health')) {
      return _json({'status': 'ok'});
    }
    if (uri.path.endsWith('/api/sessions')) {
      final offsetParam = uri.queryParameters['offset'];
      if (offsetParam == null) {
        // Health-check auth confirmation: no paging params, answer empty.
        return _json({'object': 'list', 'data': [], 'has_more': false});
      }
      final offset = int.parse(offsetParam);
      requestedOffsets.add(offsetParam);
      final limit = int.tryParse(uri.queryParameters['limit'] ?? '') ?? 50;
      final windowRows = [
        for (var i = offset; i < offset + limit && i < totalWindow; i++)
          _windowRow(i),
      ];
      // Pins lead the payload so they always render in the viewport; the
      // stock gateway repeats them on every page.
      final rows = [...pinnedIds.map(_pinnedRow), ...windowRows];
      final windowed = windowRows.length;
      return _json({
        'object': 'list',
        'data': rows,
        'limit': limit,
        'offset': offset,
        'has_more': windowed >= limit,
      });
    }
    return _json({'error': 'unexpected request ${uri.path}'}, status: 404);
  }
}

SavedConnection _connection(String id) => SavedConnection(
  id: id,
  label: 'Paging fixture',
  host: 'paging.fixture',
  port: 8642,
  apiKey: 'fixture-key',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SessionListScreen paging vs pinned back-fill', () {
    testWidgets('advances by the requested window and never duplicates pins', (
      tester,
    ) async {
      // 60 window rows, page size 50, two pins back-filled on every page.
      final fake = _PinnedBackfillClient(
        totalWindow: 60,
        pinnedIds: const ['pin-a', 'pin-b'],
      );
      final controller = GatewayTurnApplicationController(
        sessionFactory: (_) => InertTurnApplicationSession(),
      );
      addTearDown(controller.close);

      await tester.pumpWidget(
        MaterialApp(
          home: SessionListScreen(
            connection: _connection('paging-1'),
            turnApplicationController: controller,
            testHttpClient: fake,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // First page rendered: pins on top, window rows behind them.
      expect(find.text('Pinned chat'), findsNWidgets(2));
      expect(find.text('Window chat 0'), findsOneWidget);

      final list = find.descendant(
        of: find.byType(RefreshIndicator),
        matching: find.byType(ListView),
      );
      // scrollUntilVisible wants the Scrollable itself: ListView WRAPS it
      // (ListView -> Scrollable -> Viewport), so it is a descendant of the
      // ListView finder — find.byType(ListView) fails the Scrollable cast.
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );

      // Scroll to the bottom to trigger the load-more path.
      await tester.drag(list, const Offset(0, -3000));
      await tester.pumpAndSettle();
      await tester.drag(list, const Offset(0, -3000));
      await tester.pumpAndSettle();

      // The second page must be requested at the REQUESTED window offset
      // (50), not at 52 — advancing by the returned row count (50 window
      // + 2 back-filled pins) would skip 'Window chat 50' and 51.
      expect(fake.requestedOffsets, ['0', '50']);

      // Skip proof: the rows the old offset bug skipped exist in the
      // list — scrollUntilVisible only succeeds for rows actually built.
      await tester.scrollUntilVisible(
        find.text('Window chat 50'),
        500,
        scrollable: scrollable,
        maxScrolls: 60,
      );
      await tester.pumpAndSettle();
      expect(find.text('Window chat 50'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Window chat 59'),
        500,
        scrollable: scrollable,
        maxScrolls: 60,
      );
      await tester.pumpAndSettle();
      expect(find.text('Window chat 59'), findsOneWidget);
    });
  });

  group('WorkspaceScreen Home loader paging vs pinned back-fill', () {
    testWidgets('advances by the requested window and never duplicates pins', (
      tester,
    ) async {
      // Home pages at 100; 120 window rows forces a second page.
      final fake = _PinnedBackfillClient(
        totalWindow: 120,
        pinnedIds: const ['pin-a'],
      );
      tester.view.physicalSize = const Size(500, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repository = ProjectsRepository(
        client: ProjectsGatewayClient((method, params) async {
          if (method == 'projects.list') {
            return {
              'jsonrpc': '2.0',
              'id': 1,
              'result': {'projects': const [], 'active_id': null},
            };
          }
          if (method == 'projects.tree') {
            return {
              'jsonrpc': '2.0',
              'id': 1,
              'result': {
                'projects': const [],
                'active_id': null,
                'scoped_session_ids': const [],
              },
            };
          }
          return {'jsonrpc': '2.0', 'id': 1, 'result': const {}};
        }),
        preferences: await SharedPreferences.getInstance(),
        connectionId: 'paging-2',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: hermesTheme(Brightness.dark),
          home: WorkspaceScreen(
            connection: _connection('paging-2'),
            repositoryFactory: (_) => repository,
            testSessionsHttpClient: fake,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Open the Chats browser over the same paged list.
      await tester.tap(find.text(HermesDestination.chats.label).last);
      await tester.pumpAndSettle();
      expect(find.byType(WorkspaceSessionsScreen), findsOneWidget);

      // Second page requested at the window offset (100), not 101 —
      // advancing by the returned rows (100 window + 1 pin) would skip
      // 'Window chat 100'. The loader legitimately runs more than once
      // (Home refresh + Chats data), so assert the offset SET is exactly
      // the window boundaries and never a back-fill-shifted value.
      expect(fake.requestedOffsets.toSet(), {'0', '100'});

      final chatsScope = find.byType(WorkspaceSessionsScreen);
      // The Chats browser's ListView CLIPS: rows outside the viewport are
      // not in the widget tree at all, so every row assertion must scroll
      // the row into view first (scrollUntilVisible only succeeds for
      // rows actually built). scrollUntilVisible wants the Scrollable
      // ancestor, not the ListView child.
      // The pane also holds a horizontal chip SingleChildScrollView —
      // target only the vertical list Scrollable.
      final chatsScrollable = find.descendant(
        of: chatsScope,
        matching: find.byWidgetPredicate(
          (w) => w is Scrollable && w.axis == Axis.vertical,
        ),
      );

      // The pin repeated on page two appears exactly once (dedupe).
      await tester.scrollUntilVisible(
        find.descendant(of: chatsScope, matching: find.text('Pinned chat')),
        400,
        scrollable: chatsScrollable,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: chatsScope, matching: find.text('Pinned chat')),
        findsOneWidget,
      );

      // Rows past the first-page window boundary — the ones the old
      // offset-by-returned-count bug skipped — are present.
      await tester.scrollUntilVisible(
        find.descendant(of: chatsScope, matching: find.text('Window chat 100')),
        400,
        scrollable: chatsScrollable,
        maxScrolls: 80,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: chatsScope, matching: find.text('Window chat 100')),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.descendant(of: chatsScope, matching: find.text('Window chat 119')),
        400,
        scrollable: chatsScrollable,
        maxScrolls: 80,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: chatsScope, matching: find.text('Window chat 119')),
        findsOneWidget,
      );
    });
  });
}
