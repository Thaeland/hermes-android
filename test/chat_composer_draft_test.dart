import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
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

Future<void> _pumpChat(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
        connection: SavedConnection(
          id: 'draft-fixture',
          label: 'Draft fixture',
          host: 'draft.fixture',
          port: 8642,
          apiKey: '',
        ),
        session: const Session(
          id: 'draft-session',
          title: 'Draft chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: ApiClient(
          baseUrl: 'http://draft.fixture',
          apiKey: '',
          httpClient: _EmptyChatHttpClient(),
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
    SharedPreferences.setMockInitialValues({
      'verbose_mode': false,
      'composer_draft:draft-session': 'stale draft',
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ChatScreen(
          connection: SavedConnection(
            id: 'draft-fixture',
            label: 'Draft fixture',
            host: 'draft.fixture',
            port: 8642,
            apiKey: '',
          ),
          session: const Session(
            id: 'draft-session',
            title: 'Draft chat',
            model: 'fixture-model',
            source: 'test',
            messageCount: 0,
            isActive: true,
            preview: '',
            startedAt: 1,
          ),
          initialComposerText: 'shared text',
          testApiClient: ApiClient(
            baseUrl: 'http://draft.fixture',
            apiKey: '',
            httpClient: _EmptyChatHttpClient(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('shared text'), findsOneWidget);
    expect(find.text('stale draft'), findsNothing);
  });
}
