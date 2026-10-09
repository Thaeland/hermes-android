import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  group('steer race regressions', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({'verbose_mode': false});
    });

    testWidgets(
      'delayed acknowledgement preserves a replacement with the same prefix',
      (tester) async {
        final submitGate = Completer<void>();
        final steerGate = Completer<SteerOutcome>();
        await _pumpChat(
          tester,
          remoteSubmit:
              ({
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

        await _startTurn(tester);
        await tester.enterText(find.byType(TextField), 'go');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        // A replacement draft can share the steer snapshot's prefix.
        await tester.enterText(find.byType(TextField), 'good follow-up');
        steerGate.complete(SteerOutcome.accepted);
        await tester.pump();
        await tester.pump();

        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'good follow-up',
        );
        submitGate.complete();
      },
    );

    testWidgets(
      'history failure cannot turn an uncertain steer into a resend',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        var historyCalls = 0;
        await _pumpChat(
          tester,
          remoteSubmit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {
                submitted.add(text);
                onSent();
                if (submitted.length == 1) await submitGate.future;
              },
          steer: (sessionId, text) async => SteerOutcome.uncertain,
          steerHistory: (sessionId) async {
            historyCalls += 1;
            if (historyCalls == 1) throw Exception('temporary history outage');
            return [
              {
                'id': 2,
                'role': 'user',
                'display_kind': 'steer',
                'display_content': 'uncertain note',
              },
            ];
          },
        );

        await _startTurn(tester);
        await _submitSteer(tester, 'uncertain note');
        submitGate.complete();
        await tester.pump();
        await tester.pump();

        // Failure is not evidence of absence, so no blind resend is allowed.
        expect(submitted, ['first prompt']);

        // A later retry can prove the steer landed and retire it safely.
        await tester.pump(const Duration(seconds: 2));
        expect(historyCalls, greaterThanOrEqualTo(2));
        expect(submitted, ['first prompt']);
      },
    );

    testWidgets(
      'an old identical steer cannot satisfy current lost-ack reconciliation',
      (tester) async {
        final submitGate = Completer<void>();
        final submitted = <String>[];
        await _pumpChat(
          tester,
          initialMessages: [
            {'id': 8, 'role': 'user', 'content': 'old prompt'},
            {
              'id': 9,
              'role': 'user',
              'display_kind': 'steer',
              'display_content': 'continue',
            },
            {'id': 10, 'role': 'assistant', 'content': 'old answer'},
          ],
          remoteSubmit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {
                submitted.add(text);
                onSent();
                if (submitted.length == 1) await submitGate.future;
              },
          steer: (sessionId, text) async => SteerOutcome.uncertain,
          steerHistory: (sessionId) async => [
            {
              'id': 9,
              'role': 'user',
              'display_kind': 'steer',
              'display_content': 'continue',
            },
            {'id': 11, 'role': 'user', 'content': 'first prompt'},
            {'id': 12, 'role': 'assistant', 'content': 'first answer'},
          ],
        );

        await _startTurn(tester);
        await _submitSteer(tester, 'continue');
        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // The only matching row predates this steer attempt.
        expect(submitted, ['first prompt', 'continue']);
      },
    );

    testWidgets(
      'a newer turn invalidates an in-flight empty reconciliation page',
      (tester) async {
        final firstSubmitGate = Completer<void>();
        final secondSubmitGate = Completer<void>();
        final firstHistoryGate = Completer<List<Map<String, dynamic>>>();
        final firstHistoryStarted = Completer<void>();
        final submitted = <String>[];
        var historyCalls = 0;
        await _pumpChat(
          tester,
          remoteSubmit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {
                submitted.add(text);
                onSent();
                if (submitted.length == 1) await firstSubmitGate.future;
                if (submitted.length == 2) await secondSubmitGate.future;
              },
          steer: (sessionId, text) async => SteerOutcome.uncertain,
          steerHistory: (sessionId) async {
            historyCalls += 1;
            if (historyCalls == 1) {
              firstHistoryStarted.complete();
              return firstHistoryGate.future;
            }
            return [
              {
                'id': 2,
                'role': 'user',
                'display_kind': 'steer',
                'display_content': 'uncertain note',
              },
            ];
          },
        );

        await _startTurn(tester);
        await _submitSteer(tester, 'uncertain note');
        firstSubmitGate.complete();
        await tester.pump();
        await tester.pump();
        await firstHistoryStarted.future;

        // Start a newer turn while the old reconciliation read is suspended.
        await tester.enterText(find.byType(TextField), 'second prompt');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await tester.pump();
        expect(submitted, ['first prompt', 'second prompt']);

        firstHistoryGate.complete(const []);
        await tester.pump();
        await tester.pump();
        secondSubmitGate.complete();
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        // The post-second-turn retry sees the landed row, so no duplicate
        // third prompt is sent.
        expect(historyCalls, greaterThanOrEqualTo(2));
        expect(submitted, ['first prompt', 'second prompt']);
      },
    );

    testWidgets(
      'an uncertain steer added during reconciliation gets its own history read',
      (tester) async {
        final submitGate = Completer<void>();
        final secondSteerGate = Completer<SteerOutcome>();
        final firstHistoryGate = Completer<List<Map<String, dynamic>>>();
        final firstHistoryStarted = Completer<void>();
        final submitted = <String>[];
        var steerCalls = 0;
        var historyCalls = 0;
        await _pumpChat(
          tester,
          remoteSubmit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {
                submitted.add(text);
                onSent();
                if (submitted.length == 1) await submitGate.future;
              },
          steer: (sessionId, text) {
            steerCalls += 1;
            return steerCalls == 1
                ? Future.value(SteerOutcome.uncertain)
                : secondSteerGate.future;
          },
          steerHistory: (sessionId) async {
            historyCalls += 1;
            if (historyCalls == 1) {
              firstHistoryStarted.complete();
              return firstHistoryGate.future;
            }
            return [
              {
                'id': 3,
                'role': 'user',
                'display_kind': 'steer',
                'display_content': 'second uncertain',
              },
            ];
          },
        );

        await _startTurn(tester);
        await _submitSteer(tester, 'first uncertain');
        await tester.enterText(find.byType(TextField), 'second uncertain');
        await tester.tap(find.byKey(const Key('chat-steer-button')));
        await tester.pump();

        submitGate.complete();
        await tester.pump();
        await tester.pump();
        await firstHistoryStarted.future;

        // The second lost acknowledgement arrives while the first entry's
        // history read is still in flight.
        secondSteerGate.complete(SteerOutcome.uncertain);
        await tester.pump();
        firstHistoryGate.complete([
          {
            'id': 2,
            'role': 'user',
            'display_kind': 'steer',
            'display_content': 'first uncertain',
          },
        ]);
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));

        expect(historyCalls, greaterThanOrEqualTo(2));
        expect(submitted, ['first prompt']);
      },
    );

    testWidgets(
      'dictation stays disabled during attachment upload before streaming',
      (tester) async {
        final uploadGate = Completer<String>();
        final voice = FakeVoiceComposerAdapter();
        final draft = AttachmentDraft(
          id: 'upload',
          cachedPath: 'synthetic-upload',
          name: 'note.txt',
          byteLength: 4,
          mediaType: 'text/plain',
          kind: AttachmentDraftKind.genericFile,
        );
        await _pumpChat(
          tester,
          voiceAdapter: voice,
          attachmentDraftService: _GatedAttachmentDraftService(uploadGate),
          initialDrafts: [draft],
          remoteAttachmentUpload: ({required draft, required dataUrl}) async =>
              const AttachmentUploadReceipt(refText: '@file:note.txt'),
          remoteSubmit:
              ({
                required sessionId,
                required text,
                required onEvent,
                required onSent,
              }) async {
                onSent();
              },
          steer: (sessionId, text) async => SteerOutcome.accepted,
        );

        await tester.enterText(find.byType(TextField), 'send attachment');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();

        final micButton = tester.widget<IconButton>(
          find
              .descendant(
                of: find.byKey(const Key('chat-mic-button')),
                matching: find.byType(IconButton),
              )
              .first,
        );
        expect(micButton.onPressed, isNull);
        expect(voice.listenCount, 0);

        uploadGate.complete('data:text/plain;base64,bm90ZQ==');
        await tester.pumpAndSettle();
      },
    );
  });
}

Future<void> _startTurn(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'first prompt');
  await tester.tap(find.byTooltip('Send'));
  await tester.pump();
  await tester.pump();
}

Future<void> _submitSteer(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byKey(const Key('chat-steer-button')));
  await tester.pump();
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required TestRemotePromptSubmit remoteSubmit,
  required Future<SteerOutcome> Function(String sessionId, String text) steer,
  FakeVoiceComposerAdapter? voiceAdapter,
  Future<List<Map<String, dynamic>>> Function(String sessionId)? steerHistory,
  List<Map<String, dynamic>> initialMessages = const [],
  AttachmentDraftService? attachmentDraftService,
  List<AttachmentDraft> initialDrafts = const [],
  TestRemoteAttachmentUpload? remoteAttachmentUpload,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://steer-regression.fixture',
    apiKey: 'fixture-key',
    httpClient: _ChatHttpClient(initialMessages),
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(
        connection: SavedConnection(
          id: 'steer-regression-fixture',
          label: 'Steer regression fixture',
          host: 'steer-regression.fixture',
          port: 8642,
          apiKey: 'fixture-key',
        ),
        session: const Session(
          id: 'steer-regression-session',
          title: 'Steer regression chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: 0,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testAttachmentDraftService: attachmentDraftService,
        testRemotePromptSubmit: remoteSubmit,
        testDesktopSteer: steer,
        testSteerHistoryReconcile: steerHistory,
        testRemoteAttachmentUpload: remoteAttachmentUpload,
        testInitialAttachmentDrafts: initialDrafts,
        testVoiceComposerAdapter: voiceAdapter ?? FakeVoiceComposerAdapter(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _ChatHttpClient extends http.BaseClient {
  _ChatHttpClient(this.messages);

  final List<Map<String, dynamic>> messages;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
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

class _GatedAttachmentDraftService extends AttachmentDraftService {
  _GatedAttachmentDraftService(this.dataUrlGate);

  final Completer<String> dataUrlGate;

  @override
  Future<String> readDataUrl(AttachmentDraft draft) => dataUrlGate.future;

  @override
  Future<void> removeCachedFile(AttachmentDraft draft) async {}
}
