import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/composer_draft_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

/// Answers the chat screen's initial reads with empty payloads.
class _EmptyChatHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"messages": []}')),
      200,
    );
  }
}

/// Answers reads with empty payloads but refuses prompt submissions, so the
/// REST send fails at the request level while the screen stays usable.
class _FailingSendChatHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET') {
      return http.StreamedResponse(
        Stream.value(utf8.encode('{"messages": []}')),
        200,
      );
    }
    throw http.ClientException('connection refused');
  }
}

final _fixtureConnection = SavedConnection(
  id: 'draft-fixture',
  label: 'Draft fixture',
  host: 'draft.fixture',
  port: 8642,
  apiKey: '',
);

String get _fixtureIdentity =>
    '${_fixtureConnection.baseUrl}|'
    '${_fixtureConnection.gatewayPrefix ?? ''}|'
    '${_fixtureConnection.desktopGatewayUrl ?? ''}';

const _fixtureSession = Session(
  id: 'draft-session',
  title: 'Draft chat',
  model: 'fixture-model',
  source: 'test',
  messageCount: 0,
  isActive: true,
  preview: '',
  startedAt: 1,
);

Future<void> _pumpChat(
  WidgetTester tester, {
  http.Client? client,
  String? initialComposerText,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
        connection: _fixtureConnection,
        session: _fixtureSession,
        initialComposerText: initialComposerText,
        testApiClient: ApiClient(
          baseUrl: 'http://draft.fixture',
          apiKey: '',
          httpClient: client ?? _EmptyChatHttpClient(),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets('leaving a chat keeps its composer draft', (tester) async {
    await _pumpChat(tester);
    await tester.enterText(find.byType(TextField).first, 'half typed');
    await tester.pump();

    // Leave the chat: the screen is disposed and the draft persisted.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // Reopen the same session: the draft comes back.
    await _pumpChat(tester);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('half typed'), findsOneWidget);
  });

  testWidgets('a share-sheet prefill wins over a stored draft', (tester) async {
    await ComposerDraftStore.save(
      connectionIdentity: _fixtureIdentity,
      sessionId: 'draft-session',
      text: 'stale draft',
    );

    await _pumpChat(tester, initialComposerText: 'shared text');
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('shared text'), findsOneWidget);
    expect(find.text('stale draft'), findsNothing);
  });

  testWidgets('a definite send rejection restores the draft', (tester) async {
    await _pumpChat(tester, client: _FailingSendChatHttpClient());
    await tester.enterText(find.byType(TextField).first, 'resend me');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The composer has the text back…
    expect(find.text('resend me'), findsOneWidget);
    // …and the stored draft was restored, not left cleared.
    expect(
      await ComposerDraftStore.read(
        connectionIdentity: _fixtureIdentity,
        sessionId: 'draft-session',
      ),
      'resend me',
    );
  });
}
