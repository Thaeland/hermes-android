// The gateway's auto-titler renames a session inside the turn prologue and
// pushes a `session.title` event ({session_id, title}; session_id is the
// stored key). Before this fix the client parsed the event generically but
// no listener claimed it, so a fresh chat kept showing "Untitled chat"
// until the session list was re-pulled. ChatScreen now applies the pushed
// title live — on the active-turn submit stream and via the async bridge —
// and the AppBar, share subject, export header, and turn-notification
// summary all read the effective title.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

const _fixtureKey = 'fixture-key';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets(
    'pushed session.title relabels the chat header live during the turn',
    (tester) async {
      await _pumpChat(
        tester,
        remoteSubmit: ({required sessionId, required text, required onEvent}) async {
          // Mirrors prompt_turn.py: the auto-title push arrives mid-turn,
          // before message.complete.
          onEvent(
            StreamEvent(
              type: 'session.title',
              data: {
                'session_id': 'stored-key-1',
                'title': 'Fix the flaky login test',
              },
            ),
          );
          onEvent(
            StreamEvent(
              type: 'message.complete',
              data: {'text': 'Done.'},
              isComplete: true,
            ),
          );
        },
      );

      expect(find.text('Fix the flaky login test'), findsOneWidget);
      expect(find.text('Untitled chat'), findsNothing);
    },
  );

  testWidgets(
    'empty or malformed session.title push keeps the current title',
    (tester) async {
      await _pumpChat(
        tester,
        remoteSubmit: ({required sessionId, required text, required onEvent}) async {
          onEvent(
            StreamEvent(
              type: 'session.title',
              data: {'session_id': 'stored-key-1', 'title': '   '},
            ),
          );
          onEvent(
            StreamEvent(
              type: 'session.title',
              data: {'session_id': 'stored-key-1'},
            ),
          );
          onEvent(
            StreamEvent(
              type: 'message.complete',
              data: {'text': 'Done.'},
              isComplete: true,
            ),
          );
        },
      );

      // Untouched: the blank push must not blank the header, and the
      // missing-title push must not crash or clear it.
      expect(find.text('Untitled chat'), findsOneWidget);
    },
  );
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required TestRemotePromptSubmit remoteSubmit,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://title.fixture',
    apiKey: _fixtureKey,
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: ChatScreen(
        connection: SavedConnection(
          id: 'title-fixture',
          label: 'Title fixture',
          host: 'title.fixture',
          port: 8642,
          apiKey: _fixtureKey,
        ),
        session: const Session(
          id: 'title-session',
          title: '',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testRemotePromptSubmit: remoteSubmit,
        testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField), 'hello');
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump();
}

class _EmptyChatHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode({'data': <Object>[]}))),
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
