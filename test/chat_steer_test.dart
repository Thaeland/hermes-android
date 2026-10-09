import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

const kFixtureKey = 'fixture';

void main() {
  group('WsClient.steerSession', () {
    test('returns the gateway status for queued and rejected', () async {
      final gateway = await SteerGatewayFixture.start(steerStatus: 'queued');
      addTearDown(gateway.stop);
      final client = WsClient(
        'http://127.0.0.1:${gateway.port}',
        token: 'fixture-key',
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(client.close);
      await client.connect().timeout(const Duration(seconds: 5));

      expect(await client.steerSession('runtime-1', 'left'), 'queued');
      expect(gateway.steerParamsList.single, {
        'session_id': 'runtime-1',
        'text': 'left',
      });

      gateway.steerStatus = 'rejected';
      expect(await client.steerSession('runtime-1', 'late'), 'rejected');
    });

    test('throws a JsonRpcError when the gateway rejects the RPC', () async {
      final gateway = await SteerGatewayFixture.start(errorCode: 4010);
      addTearDown(gateway.stop);
      final client = WsClient(
        'http://127.0.0.1:${gateway.port}',
        token: 'fixture-key',
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(client.close);
      await client.connect().timeout(const Duration(seconds: 5));

      await expectLater(
        client.steerSession('runtime-1', 'text'),
        throwsA(isA<JsonRpcError>()),
      );
    });
  });

  group('chat screen steer affordance', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
    });

    testWidgets(
      'accepted steer clears the composer and paints the note as a user bubble',
      (tester) async {
        final submitGate = Completer<void>();
        var submitCount = 0;
        final steerCalls = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitCount += 1;
            onSent();
            await submitGate.future;
          },
          steer: (sessionId, text) async {
            steerCalls.add('$sessionId:$text');
            return SteerOutcome.accepted;
          },
        );

        await tester.enterText(find.byType(TextField), 'start the task');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();
        expect(submitCount, 1);

        // Mid-turn the composer stays editable and the steer button shows.
        final composer = tester.widget<TextField>(find.byType(TextField));
        expect(composer.enabled, isTrue);
        expect(find.byKey(const Key('chat-steer-button')), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'use the short version');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        await tester.pump();

        expect(steerCalls, ['steer-session:use the short version']);
        expect(
          find.widgetWithText(MessageBubble, 'use the short version'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('message-steer-chip')), findsOneWidget);
        final cleared = tester.widget<TextField>(find.byType(TextField));
        expect(cleared.controller!.text, isEmpty);

        submitGate.complete();
        await tester.pumpAndSettle();
        // An accepted steer must not be re-sent when the turn settles.
        expect(submitCount, 1);
      },
    );

    testWidgets(
      'rejected steer is held and re-sent as a normal prompt at settle',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.rejected,
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'late correction');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        // Rejected: composer clears, snackbar explains, nothing sent yet.
        expect(submitted, ['first prompt']);
        expect(
          find.text('Turn is finishing — your note will be sent next'),
          findsOneWidget,
        );

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // The settle drain re-sent the rejected text as a normal prompt.
        expect(submitted, ['first prompt', 'late correction']);
      },
    );

    testWidgets(
      'rejected steer held during dictation drains when the mic stops',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        final voice = FakeVoiceComposerAdapter();
        await _pumpChat(
          tester,
          voiceAdapter: voice,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.rejected,
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        // Steer is rejected just before settle; text is held.
        await tester.enterText(find.byType(TextField), 'late correction');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        expect(submitted, ['first prompt']);

        // User starts dictating while the turn is still live.
        await tester.tap(find.byKey(const Key('chat-mic-button')));
        await tester.pump();
        expect(find.bySemanticsLabel('Stop voice input'), findsOneWidget);

        // Turn settles mid-dictation: the drain must NOT auto-send
        // (_sendMessage would silently no-op while listening) and must not
        // touch the composer the recognizer owns.
        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(submitted, ['first prompt']);

        // Stopping the mic re-drains: the held steer goes out as a prompt.
        await tester.tap(find.bySemanticsLabel('Stop voice input'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(submitted, ['first prompt', 'late correction']);
      },
    );

    testWidgets(
      'steer while dictating finalizes the transcript before sending',
      (tester) async {
        final submitGate = Completer<void>();
        final steerCalls = <String>[];
        final voice = FakeVoiceComposerAdapter(
          finalTranscriptOnStop: 'use the short version',
        );
        await _pumpChat(
          tester,
          voiceAdapter: voice,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            onSent();
            await submitGate.future;
          },
          steer: (sessionId, text) async {
            steerCalls.add(text);
            return SteerOutcome.accepted;
          },
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.byKey(const Key('chat-mic-button')));
        await tester.pump();
        voice.emitPartial('use the sh');
        await tester.pump();

        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        await tester.pump();

        // The live dictation session was stopped first, so the steer
        // carried the finalized transcript, not the partial.
        expect(voice.stopCount, 1);
        expect(steerCalls, ['use the short version']);
        submitGate.complete();
      },
    );

    testWidgets(
      'stop drains a steer the gateway rejected earlier',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.rejected,
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'late correction');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        expect(submitted, ['first prompt']);

        // Stop ends the turn by definition; the held steer must go out now,
        // not wait for some future turn to settle.
        await tester.tap(find.byTooltip('Stop response'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(submitted, ['first prompt', 'late correction']);
        submitGate.complete();
      },
    );
    testWidgets(
      'a delayed steer acknowledgement does not erase a newer draft',
      (tester) async {
        final submitGate = Completer<void>();
        final steerGate = Completer<SteerOutcome>();
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            onSent();
            await submitGate.future;
          },
          steer: (sessionId, text) => steerGate.future,
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'steer note');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        // The ack is still in flight; the user starts a brand-new draft.
        await tester.enterText(find.byType(TextField), 'fresh draft');
        await tester.pump();

        steerGate.complete(SteerOutcome.accepted);
        await tester.pump();
        await tester.pump();

        // The late ack consumed only its own snapshot: the newer draft
        // survives untouched (the snapshot is no longer in the field).
        final composer = tester.widget<TextField>(find.byType(TextField));
        expect(composer.controller!.text, 'fresh draft');
        expect(
          find.widgetWithText(MessageBubble, 'steer note'),
          findsOneWidget,
        );
        submitGate.complete();
      },
    );

    testWidgets(
      'two rejected steers both re-send at settle (first is not lost)',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.rejected,
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'first rejected');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'second rejected');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        expect(submitted, ['first prompt']);

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // Both held notes go out, in order, as one next-turn prompt.
        expect(submitted, ['first prompt', 'first rejected\n\nsecond rejected']);
      },
    );

    testWidgets(
      'an uncertain steer already present in server history is not re-sent',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.uncertain,
          steerHistory: (sessionId) async => [
            {'role': 'user', 'content': 'first prompt'},
            {
              'role': 'user',
              'display_kind': 'steer',
              'display_content': 'ghost steer',
            },
          ],
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'ghost steer');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        expect(submitted, ['first prompt']);

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // Reconciliation found the steer in server history: it landed, so
        // the settle drain must NOT re-send it as a duplicate prompt.
        expect(submitted, ['first prompt']);
      },
    );

    testWidgets(
      'an uncertain steer missing from server history re-sends once',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.uncertain,
          steerHistory: (sessionId) async => [
            {'role': 'user', 'content': 'first prompt'},
          ],
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'lost steer');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        expect(submitted, ['first prompt']);

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // Reconciliation proved it never landed: exactly one resend.
        expect(submitted, ['first prompt', 'lost steer']);
      },
    );

    testWidgets(
      'two uncertain steers both survive and reconcile in order',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.uncertain,
          steerHistory: (sessionId) async => [
            {'role': 'user', 'content': 'first prompt'},
          ],
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'lost one');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'lost two');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        expect(submitted, ['first prompt']);

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // Neither lost ack may be dropped: both reconcile as not-landed
        // and go out together, in order.
        expect(submitted, ['first prompt', 'lost one\n\nlost two']);
      },
    );

    testWidgets(
      'an uncertain steer and a rejected steer resend in submission order',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        var steerCall = 0;
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async {
            steerCall += 1;
            // First steer loses its ack (uncertain), second is rejected.
            return steerCall == 1
                ? SteerOutcome.uncertain
                : SteerOutcome.rejected;
          },
          steerHistory: (sessionId) async => [
            {'role': 'user', 'content': 'first prompt'},
          ],
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'uncertain note');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'rejected note');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();
        expect(submitted, ['first prompt']);

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // Reconciliation must not reorder: the uncertain note was
        // submitted first, so it leads the joined resend.
        expect(
          submitted,
          ['first prompt', 'uncertain note\n\nrejected note'],
        );
      },
    );

    testWidgets(
      'a failed drain send does not requeue and duplicate on the next drain',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        final voice = FakeVoiceComposerAdapter();
        await _pumpChat(
          tester,
          voiceAdapter: voice,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            if (submitted.length == 1) {
              onSent();
              await submitGate.future;
              return;
            }
            // Drain send: the turn was added, then the submit failed —
            // the desktop catch strips the optimistic rows and restores
            // the composer text.
            onSent();
            throw Exception('gateway rejected submission');
          },
          steer: (sessionId, text) async => SteerOutcome.rejected,
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'held note');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // The drain sent once and the failure path restored the text to
        // the composer for the user to retry.
        expect(submitted, ['first prompt', 'held note']);
        final composer = tester.widget<TextField>(find.byType(TextField));
        expect(composer.controller!.text, 'held note');

        // Any later drain trigger (mic cycle) must NOT re-send or append
        // the note again: a submitted-but-failed send is the user's to
        // retry from the composer, not the queue's to duplicate.
        // (Dismiss the queued snackbars; they overlay the mic button.)
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
            .clearSnackBars();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chat-mic-button')));
        await tester.pump();
        await tester.tap(find.bySemanticsLabel('Stop voice input'));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(submitted, ['first prompt', 'held note']);
        final after = tester.widget<TextField>(find.byType(TextField));
        expect(after.controller!.text, 'held note');
      },
    );

    testWidgets(
      'an uncertain steer whose turn settled mid-RPC drains immediately',
      (tester) async {
        final submitGate = Completer<void>();
        final steerGate = Completer<SteerOutcome>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) => steerGate.future,
          steerHistory: (sessionId) async => [
            {'role': 'user', 'content': 'first prompt'},
          ],
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'slow lost ack');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        // The turn settles while the steer RPC is still in flight (the
        // ack times out later): the settle drain runs with nothing
        // queued, so the uncertain result must trigger its own drain.
        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(submitted, ['first prompt']);

        steerGate.complete(SteerOutcome.uncertain);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // Reconciled as not-landed and resent without any further turn
        // event — no indefinite stall.
        expect(submitted, ['first prompt', 'slow lost ack']);
      },
    );

    testWidgets(
      'two identical uncertain steers need two landed rows to both clear',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          remoteSubmit: ({
            required sessionId,
            required text,
            required onEvent,
            required onSent,
          }) async {
            submitted.add(text);
            onSent();
            if (submitted.length == 1) {
              await submitGate.future;
            }
          },
          steer: (sessionId, text) async => SteerOutcome.uncertain,
          steerHistory: (sessionId) async => [
            {'role': 'user', 'content': 'first prompt'},
            {
              'role': 'user',
              'display_kind': 'steer',
              'display_content': 'continue',
            },
          ],
        );

        await tester.enterText(find.byType(TextField), 'first prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();

        for (final _ in [1, 2]) {
          await tester.enterText(find.byType(TextField), 'continue');
          await tester.tap(find.byKey(const Key('chat-steer-button')));
          await tester.pump();
        }

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // Only one 'continue' landed server-side, so exactly one of the
        // two queued entries may be considered landed: the other must
        // still be resent as a prompt.
        expect(submitted, ['first prompt', 'continue']);
      },
    );
  });
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required TestRemotePromptSubmit remoteSubmit,
  required Future<SteerOutcome> Function(String sessionId, String text) steer,
  FakeVoiceComposerAdapter? voiceAdapter,
  Future<List<Map<String, dynamic>>> Function(String sessionId)? steerHistory,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://steer.fixture',
    apiKey: 'fixture-key',
    httpClient: _EmptyChatHttpClient(),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
        connection: SavedConnection(
          id: 'steer-fixture',
          label: 'Steer fixture',
          host: 'steer.fixture',
          port: 8642,
          apiKey: kFixtureKey,
        ),
        session: const Session(
          id: 'steer-session',
          title: 'Steer chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testRemotePromptSubmit: remoteSubmit,
        testDesktopSteer: steer,
        testSteerHistoryReconcile: steerHistory,
        testVoiceComposerAdapter: voiceAdapter ?? FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

/// Minimal newline-delimited JSON-RPC gateway fixture that answers
/// `session.create` and records/answers `session.steer` requests.
class SteerGatewayFixture {
  SteerGatewayFixture(
    this._server,
    this.steerStatus,
    this.errorCode, [
    this.steerErrorMessage = 'agent does not support steer',
  ]);

  final HttpServer _server;
  String steerStatus;
  final int? errorCode;
  String steerErrorMessage;

  /// When true, a `session.steer` frame is recorded and then the socket is
  /// closed without ever answering — the lost-acknowledgement scenario.
  bool dropSteerAck = false;
  final List<Map<String, dynamic>> steerParamsList = [];

  int get port => _server.port;

  static Future<SteerGatewayFixture> start({
    String steerStatus = 'queued',
    int? errorCode,
    String steerErrorMessage = 'agent does not support steer',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway =
        SteerGatewayFixture(server, steerStatus, errorCode, steerErrorMessage);
    server.listen(gateway._handle);
    return gateway;
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'POST' &&
        request.uri.path == '/auth/password-login') {
      request.response
        ..statusCode = 200
        ..headers.set('set-cookie', 'hermes_session_at=fixture; Path=/')
        ..write('{"ok":true}');
      await request.response.close();
      return;
    }
    if (request.method == 'POST' &&
        request.uri.path == '/api/auth/ws-ticket') {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ticket":"fixture-ticket"}');
      await request.response.close();
      return;
    }
    if (request.uri.path != '/api/ws') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((raw) {
      final frame = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
      final method = frame['method'];
      final id = frame['id'];
      if (method == 'client.capabilities') {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'server_requests': ['clarify', 'approval', 'sudo', 'secret'],
            },
          }),
        );
        return;
      }
      if (method == 'session.resume') {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': 4007, 'message': 'session not found'},
          }),
        );
        return;
      }
      if (method == 'session.create') {
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'session_id': 'runtime-1',
              'stored_session_id': 'stored-1',
            },
          }),
        );
        return;
      }
      if (method == 'session.steer') {
        steerParamsList.add(
          Map<String, dynamic>.from(frame['params'] as Map),
        );
        if (dropSteerAck) {
          // Frame received, acknowledgement never sent: the socket dies
          // with the request pending, exactly like a mid-flight outage.
          unawaited(socket.close());
          return;
        }
        if (errorCode != null) {
          socket.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': errorCode, 'message': steerErrorMessage},
            }),
          );
          return;
        }
        socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'status': steerStatus,
              'text': frame['params']['text'],
            },
          }),
        );
      }
    });
  }
}
