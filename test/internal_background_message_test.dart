import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/background_report.dart';
import 'package:hermes_android/core/models/chat_timeline.dart';
import 'package:hermes_android/core/services/delegated_task_history.dart';
import 'package:hermes_android/core/utils/chat_conversation_projection.dart';
import 'package:hermes_android/core/utils/chat_display_items.dart';

import 'support/internal_background_message_fixture.dart';

const _modelSwitch =
    '[System: The active model for this chat has changed to gpt-6-sol-900k '
    'via provider openai-codex. From this point forward, use this runtime '
    'metadata when answering questions about what model/provider is active.]';

void main() {
  for (final entry in internalBackgroundMessageFixtures().entries) {
    test('backend-produced ${entry.key} is background in every projection', () {
      final fixture = entry.value;
      final row = Map<String, dynamic>.from(fixture['row'] as Map);
      final before = jsonEncode(row);
      final report = BackgroundReport.fromMessage(row);
      expect(report, isNotNull, reason: row['content'] as String);
      expect(report!.kind.name, fixture['expected']);
      expect(report.body, same(row['content']));
      final messages = [
        {'id': 1, 'role': 'user', 'content': 'Real question'},
        row,
        {
          'id': 1000,
          'role': 'assistant',
          'content': 'Completed answer',
          'finish_reason': 'stop',
        },
      ];
      final detailed = buildChatDisplayItems(messages: messages);
      expect(detailed, hasLength(3));
      expect((detailed.last as Map)['_retry_prompt'], 'Real question');
      final quiet = buildConversationDisplayItems(messages: messages);
      expect(quiet.map((item) => item['id']), [1, 1000]);
      expect(quiet.last['_retry_prompt'], 'Real question');
      final sections = buildNormalChatDisplaySections(
        canonicalRows: [row],
        receivedRows: [Map<String, dynamic>.from(row)],
        receivedTimeline: ChatTimeline(),
      );
      expect(sections.map((section) => section.source), [
        ChatDisplaySource.canonical,
        ChatDisplaySource.received,
      ]);
      expect(sections.every((section) => section.items.length == 1), isTrue);
      expect(
        parseTaskTranscript([row]).single.backgroundReport!.body,
        report.body,
      );
      expect(jsonEncode(row), before);

      // Remove metadata for the legacy-negative checks; explicit server kinds
      // intentionally classify arbitrary bodies and are not text heuristics.
      final content = row['content'] as String;
      for (final quoted in [
        '"$content"',
        '> ${content.replaceAll('\n', '\n> ')}',
        '```text\n$content\n```',
        'Why does this appear?\n$content',
      ]) {
        expect(
          BackgroundReport.fromMessage({'role': 'user', 'content': quoted}),
          isNull,
          reason: '${entry.key}: $quoted',
        );
      }
      if (fixture['sealed'] == true) {
        expect(
          BackgroundReport.fromMessage({
            'role': 'user',
            'content': '$content\n\nNew human question',
          }),
          isNull,
        );
      }
      if (row['display_kind'] == null) {
        expect(
          BackgroundReport.fromMessage({
            ...row,
            'content': content.replaceAll('\n', '\r\n'),
          })!.body,
          content.replaceAll('\n', '\r\n'),
        );
      }
    });
  }

  test('hidden/model-only and public projections outrank compatibility', () {
    for (final kind in [null, 'model_switch', 'internal_notification']) {
      final row = <String, dynamic>{
        'role': 'user',
        'content': _modelSwitch,
        'display_kind': kind,
      };
      final hidden = {...row, 'display_kind': 'hidden'};
      final modelOnly = {
        ...row,
        'display_metadata': {'model_only': true},
      };
      for (final suppressed in [hidden, modelOnly]) {
        expect(BackgroundReport.fromMessage(suppressed), isNull);
        expect(buildChatDisplayItems(messages: [suppressed]), isEmpty);
        expect(
          parseTaskTranscript([
            {'id': 1, ...suppressed},
          ]),
          isEmpty,
        );
      }
      for (final projection in [null, '', 'Actual public text']) {
        final projected = {...row, 'display_content': projection};
        if (projection == null || projection == '') {
          expect(
            parseTaskTranscript([
              {'id': 1, ...projected},
            ]),
            isEmpty,
          );
        }
        final report = BackgroundReport.fromMessage(projected);
        if (kind != null && projection == 'Actual public text') {
          expect(report!.body, projection);
        } else {
          expect(report, isNull);
        }
        final items = buildChatDisplayItems(messages: [projected]);
        expect(
          items.whereType<Map>().any(
            (item) => item['_display_content'] == _modelSwitch,
          ),
          isFalse,
        );
      }
    }
  });

  test('large malformed delegation fields avoid wildcard backtracking', () {
    final fixture =
        internalBackgroundMessageFixtures()['legacy_delegation_single']!;
    final body = (fixture['row'] as Map)['content'] as String;
    final intro = body.substring(0, body.indexOf('Original goal: '));
    final malformed =
        '$intro${'Original goal: fixture\nRole: leaf   Model: fixture\nStatus: invalid\n' * 1000}';
    expect(
      BackgroundReport.fromMessage({'role': 'user', 'content': malformed}),
      isNull,
    );
  });

  test(
    'annotations classify arbitrary internal text but never human controls',
    () {
      for (final kind in [
        'model_switch',
        'personality_switch',
        'auto_continue',
        'internal_notification',
      ]) {
        final report = BackgroundReport.fromMessage({
          'role': 'user',
          'display_kind': kind,
          'content': 'Arbitrary future producer wording',
        });
        expect(report!.kind, BackgroundReportKind.task);
      }
      for (final role in ['assistant', 'agent', 'tool', 'system', null]) {
        expect(
          BackgroundReport.fromMessage({'role': role, 'content': _modelSwitch}),
          isNull,
        );
      }
    },
  );

  for (final kind in ['model_switch', null, '']) {
    test('model switch uses a background task with display_kind=$kind', () {
      final row = <String, dynamic>{
        'id': 2,
        'role': 'user',
        'content': _modelSwitch,
        'display_kind': ?kind,
      };
      final before = jsonEncode(row);
      final report = BackgroundReport.fromMessage(row);
      expect(report, isNotNull);
      expect(report!.kind, BackgroundReportKind.task);
      expect(report.body, _modelSwitch);
      expect(report.hasIssues, isFalse);
      final messages = [
        {'id': 1, 'role': 'user', 'content': 'Real question'},
        row,
        {
          'id': 3,
          'role': 'assistant',
          'content': 'Completed answer',
          'finish_reason': 'stop',
        },
      ];
      final detailed = buildChatDisplayItems(messages: messages);
      expect(detailed, hasLength(3));
      expect((detailed.last as Map)['_retry_prompt'], 'Real question');
      final quiet = buildConversationDisplayItems(messages: messages);
      expect(quiet.map((item) => item['id']), [1, 3]);
      expect(quiet.last['_retry_prompt'], 'Real question');
      expect(jsonEncode(row), before);
    });
  }

  test('human quotes and explicitly human rows are not background tasks', () {
    for (final content in [
      '"$_modelSwitch"',
      '> $_modelSwitch',
      '```text\n$_modelSwitch\n```',
      'Why does this appear?\n$_modelSwitch',
      '$_modelSwitch\nWhy does this appear?',
      '[System: a label I typed, not a runtime notice]',
    ]) {
      expect(
        BackgroundReport.fromMessage({'role': 'user', 'content': content}),
        isNull,
        reason: content,
      );
    }
    for (final kind in ['steer', 'skill_invocation', 'hidden', 'unknown']) {
      expect(
        BackgroundReport.fromMessage({
          'role': 'user',
          'content': _modelSwitch,
          'display_kind': kind,
        }),
        isNull,
        reason: kind,
      );
    }
  });
}
