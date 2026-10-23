import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/gateway_turn_application_controller.dart';
import 'package:hermes_android/core/services/normal_gateway_application_session.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({'verbose_mode': false}));

  for (final mode in [
    'stored-held-initial',
    'local-initial-404',
    'known-empty-control',
    'known-context-unknown-floor',
  ]) {
    testWidgets(
      'canonical hydration does not duplicate materialized reply: $mode',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1000, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final controller = GatewayTurnApplicationController();
        addTearDown(controller.close);
        final first = Completer<http.Response>();
        final rpc = Completer<void>();
        late StreamCallback emit;
        var submissions = 0;
        final requests = <String>[];
        final connection = SavedConnection(
          id: 'unknown-floor-$mode',
          label: 'Fixture',
          host: 'fixture.invalid',
          port: 8642,
          apiKey: 'fixture-key',
        );
        const canonical = [
          {'id': 1, 'role': 'user', 'content': 'Early prompt'},
          {'id': 2, 'role': 'assistant', 'content': 'Early answer'},
        ];
        final client = ApiClient(
          baseUrl: connection.baseUrl,
          apiKey: connection.apiKey,
          httpClient: MockClient((request) async {
            requests.add(request.url.toString());
            if (requests.length == 1) {
              if (mode == 'stored-held-initial') return first.future;
              if (mode == 'local-initial-404') {
                return http.Response('not found', 404);
              }
              if (mode == 'known-context-unknown-floor') {
                return http.Response(
                  jsonEncode({
                    'data': [
                      {
                        'id': 'legacy',
                        'role': 'assistant',
                        'content': 'Older known context',
                      },
                    ],
                  }),
                  200,
                );
              }
              return http.Response(jsonEncode({'data': []}), 200);
            }
            return http.Response(jsonEncode({'data': canonical}), 200);
          }),
        );
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatScreen(
              connection: connection,
              session: Session(
                id: mode == 'local-initial-404' ? 'local-draft' : 'stored-chat',
                title: 'Early chat',
                model: 'fixture',
                source: 'test',
                messageCount: 0,
                isActive: false,
                preview: '',
                startedAt: 1,
                isLocalDraft: mode == 'local-initial-404',
              ),
              turnApplicationController: controller,
              testApiClient: client,
              testStoredSessionKey: (_) => 'stored-chat',
              testRemotePromptSubmit:
                  ({
                    required sessionId,
                    required text,
                    required onEvent,
                    required onSent,
                  }) {
                    submissions++;
                    emit = onEvent;
                    onSent();
                    return rpc.future;
                  },
              testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
            ),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        expect(requests, hasLength(1));
        await tester.enterText(find.byType(TextField), 'Early prompt');
        await tester.tap(find.byTooltip('Send'));
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
        final owner = controller
            .normalSessionFor(connection)
            .findChat('stored-chat')!;
        expect(submissions, 1);
        expect(
          owner.snapshot.rowFloor,
          mode == 'known-empty-control' ? 0 : isNull,
        );
        emit(
          StreamEvent(type: 'message.delta', data: {'text': 'Early answer'}),
        );
        await tester.pump();
        emit(
          StreamEvent(type: 'message.complete', data: {'text': 'Early answer'}),
        );
        rpc.complete();
        for (var i = 0; i < 10; i++) {
          await tester.pump();
        }
        expect(owner.phase, NormalGatewayTurnPhase.completed);
        expect(owner.snapshot.historyRows, canonical);
        if (!first.isCompleted) {
          first.complete(http.Response(jsonEncode({'data': []}), 200));
        }
        await tester.pumpAndSettle();
        final bubbles = tester
            .widgetList<MessageBubble>(find.byType(MessageBubble))
            .map(
              (b) => {
                'role': b.isUser ? 'user' : 'assistant',
                'content': b.content,
              },
            )
            .toList();

        if (mode == 'known-context-unknown-floor') {
          expect(
            bubbles.where((b) => b['content'] == 'Older known context'),
            hasLength(1),
          );
          expect(
            owner.snapshot.presentationHistoryRows!.single['id'],
            'legacy',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(
          bubbles.where(
            (b) => b['role'] == 'user' && b['content'] == 'Early prompt',
          ),
          hasLength(1),
        );
        expect(
          bubbles.where(
            (b) => b['role'] == 'assistant' && b['content'] == 'Early answer',
          ),
          hasLength(1),
        );
      },
    );
  }
}
