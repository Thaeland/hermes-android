import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

/// While a desktop-transport turn streams, the input row packs attach +
/// composer + mic + voice-reply + steer + stop. These sizes are the tight
/// realistic corners: 320dp budget phones, a 360dp common Android width,
/// and a tablet — each at normal and large accessibility text scale.
/// Any RenderFlex overflow surfaces as a test failure automatically.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  for (final (width, height, scale) in [
    (320.0, 640.0, 1.0),
    (360.0, 720.0, 1.0),
    (320.0, 640.0, 1.3),
    (360.0, 720.0, 1.3),
    (800.0, 1200.0, 1.0),
  ]) {
    testWidgets(
      'streaming input row lays out cleanly at ${width.toInt()}x'
      '${height.toInt()} textScale $scale',
      (tester) async {
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final gate = Completer<void>();
        await _pumpStreamingChat(tester, gate, scale);

        expect(find.byKey(const Key('chat-steer-button')), findsOneWidget);
        expect(find.byTooltip('Stop response'), findsOneWidget);
        // Dictation must stay reachable AND enabled mid-turn so it can
        // feed a steer (presence alone once hid a disabled-button bug).
        expect(find.byTooltip('Speak to Hermes'), findsOneWidget);
        final micButton = tester.widget<IconButton>(
          find
              .descendant(
                of: find.byKey(const Key('chat-mic-button')),
                matching: find.byType(IconButton),
              )
              .first,
        );
        expect(micButton.onPressed, isNotNull);
        // The composer keeps usable width even with all six controls shown.
        final fieldWidth = tester.getSize(find.byType(TextField)).width;
        expect(fieldWidth, greaterThan(120.0));
        // No overflow: pump would have thrown a RenderFlex overflow error.
        expect(tester.takeException(), isNull);
        gate.complete();
        await tester.pumpAndSettle();
      },
    );
  }
}

Future<void> _pumpStreamingChat(
  WidgetTester tester,
  Completer<void> gate,
  double scale,
) async {
  final apiClient = ApiClient(
    baseUrl: 'http://layout.fixture',
    apiKey: 'fixture-key',
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: ChatScreen(
        connection: SavedConnection(
          id: 'layout-fixture',
          label: 'Layout fixture',
          host: 'layout.fixture',
          port: 8642,
          apiKey: 'fixture-key',
        ),
        session: const Session(
          id: 'layout-session',
          title: 'Layout chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testRemotePromptSubmit: ({
          required sessionId,
          required text,
          required onEvent,
          required onSent,
        }) async {
          onSent();
          await gate.future;
        },
        testDesktopSteer: (sessionId, text) async => SteerOutcome.accepted,
          testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'start the task');
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
