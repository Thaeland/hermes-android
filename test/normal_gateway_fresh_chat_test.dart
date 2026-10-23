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
  testWidgets(
    'fresh local ChatScreen settles stock message-complete-only turn after initial 404',
    (tester) async {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
      final connection = SavedConnection(
        id: 'new-stock-probe',
        label: 'Fixture',
        host: 'fixture.invalid',
        port: 8642,
        apiKey: 'fixture',
      );
      final controller = GatewayTurnApplicationController();
      addTearDown(controller.close);
      final rpc = Completer<void>();
      StreamCallback? event;
      var submits = 0;
      int? floorAtSubmit;
      String? phaseAtSubmit;
      final baseline = Completer<http.Response>();
      final paths = <String>[];
      var rows = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatScreen(
            connection: connection,
            session: Session(
              id: 'mob-new-chat',
              title: 'New chat',
              model: 'fixture',
              source: 'test',
              messageCount: 0,
              isActive: true,
              preview: '',
              startedAt: 1,
              isLocalDraft: true,
            ),
            turnApplicationController: controller,
            testApiClient: ApiClient(
              baseUrl: connection.baseUrl,
              apiKey: 'fixture',
              httpClient: MockClient((request) async {
                paths.add(request.url.path);
                if (request.url.path.contains('/mob-new-chat/')) {
                  return http.Response('{"error":"session not found"}', 404);
                }
                if (!baseline.isCompleted) return baseline.future;
                return http.Response(jsonEncode({'data': rows}), 200);
              }),
            ),
            testRemotePromptSubmit:
                ({
                  required sessionId,
                  required text,
                  required onEvent,
                  required onSent,
                }) async {
                  submits++;
                  event = onEvent;
                  final session = controller.normalSessionFor(connection);
                  final receipt = (await session.pendingStore.load(
                    session.scope,
                  )).single;
                  floorAtSubmit = receipt.rowFloor;
                  phaseAtSubmit = receipt.phase;
                  onSent();
                  return rpc.future;
                },
            testNormalResume:
                ({required localSessionId, required storedSessionId}) async =>
                    const ResumedGatewaySession(
                      runtimeSessionId: 'runtime',
                      running: false,
                      status: 'idle',
                    ),
            testStoredSessionKey: (_) => 'stored-new-chat',
            testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(paths, ['/api/sessions/mob-new-chat/messages']);
      await tester.enterText(find.byType(TextField), 'First prompt');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();
      final session = controller.normalSessionFor(connection);
      final owner = session.findChat('stored-new-chat')!;
      expect(paths, [
        '/api/sessions/mob-new-chat/messages',
        '/api/sessions/stored-new-chat/messages',
      ]);
      expect(submits, 0, reason: 'The canonical baseline must precede wire.');
      expect(owner.snapshot.wireEmitted, isFalse);
      expect(
        owner.snapshot.rowFloor,
        isNull,
        reason: '404 is not empty history.',
      );
      expect(await session.pendingStore.load(session.scope), isEmpty);
      baseline.complete(http.Response('{"data":[]}', 200));
      await tester.pump();
      await tester.pump();
      expect(submits, 1);
      expect(floorAtSubmit, 0);
      expect(phaseAtSubmit, 'write_ahead');
      void emit(String type, Map<String, dynamic> data) =>
          event!(StreamEvent(type: type, data: data));
      emit('message.start', {});
      emit('message.delta', {'text': 'Final answer'});
      rows = [
        {'id': 1, 'role': 'user', 'content': 'First prompt'},
        {'id': 2, 'role': 'assistant', 'content': 'Final answer'},
      ];
      emit('message.complete', {'text': 'Final answer', 'status': 'complete'});
      rpc.complete();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      final active = owner.snapshot.hasActiveTurn;
      expect(owner.snapshot.phase, NormalGatewayTurnPhase.completed);
      expect(find.text('Final answer'), findsOneWidget);
      expect(find.text('First prompt'), findsOneWidget);
      expect(find.byTooltip('Stop response'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Next prompt');
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.send))
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
        active,
        isFalse,
        reason: 'A successful first stock turn must release send admission.',
      );
      expect(owner.snapshot.rowFloor, 0);
      expect(await session.pendingStore.load(session.scope), isEmpty);
      expect(submits, 1);
    },
  );
}
