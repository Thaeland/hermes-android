import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_activity.dart';
import 'package:hermes_android/core/widgets/gateway_activity_card.dart';

import 'support/l10n_test_utils.dart';

GatewayToolActivity _running(String name, String id) => GatewayToolActivity(
  name: name,
  phase: GatewayToolActivityPhase.running,
  toolId: id,
);

GatewayToolActivity _finished(String name, String id) => GatewayToolActivity(
  name: name,
  phase: GatewayToolActivityPhase.completed,
  toolId: id,
  durationSeconds: 1.5,
);

/// The rows only exist in the tree while the card is open, so their presence
/// doubles as the expansion assertion.
/// The row title is prefixed with the tool emoji, so match on the name.
bool _isExpanded(WidgetTester tester) =>
    find.textContaining('Terminal').evaluate().isNotEmpty;

Future<void> _pumpCard(
  WidgetTester tester,
  List<GatewayToolActivity> activities, {
  bool verbose = false,
}) async {
  await tester.pumpWidget(
    testAppWithL10n(
      Scaffold(
        body: ListView(
          children: [
            GatewayActivityCard(activities: activities, verbose: verbose),
          ],
        ),
      ),
    ),
  );
  // Not pumpAndSettle: a running activity spins an indeterminate progress
  // indicator, which never settles.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapHeader(WidgetTester tester) async {
  await tester.tap(find.text('Tool activity'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a card the user collapsed stays collapsed as tools arrive', (
    tester,
  ) async {
    await _pumpCard(tester, [_running('terminal', 'call-1')]);
    expect(_isExpanded(tester), isTrue);

    await _tapHeader(tester);
    expect(_isExpanded(tester), isFalse);

    // The next tool call lands while the card is closed.
    await _pumpCard(tester, [
      _running('terminal', 'call-1'),
      _running('read_file', 'call-2'),
    ]);

    expect(_isExpanded(tester), isFalse);
    // ...and the closed header still says what is going on.
    expect(find.text('Hermes is using 2 tools'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets(
    'a pinned-closed card updates last observed time without reopening',
    (tester) async {
      final start = DateTime(2026, 10, 21, 1, 2, 3);
      final progress = start.add(const Duration(seconds: 5));
      final running = GatewayToolActivity.fromGatewayEvent('tool.start', {
        'tool_id': 'call-1',
        'name': 'terminal',
      }, observedAt: start)!;
      await _pumpCard(tester, [running]);
      await _tapHeader(tester);
      expect(_isExpanded(tester), isFalse);
      await _pumpCard(tester, [
        running.merge(
          GatewayToolActivity.fromGatewayEvent('tool.progress', {
            'tool_id': 'call-1',
            'name': 'terminal',
          }, observedAt: progress)!,
        ),
      ]);
      expect(_isExpanded(tester), isFalse);
      expect(find.text('Last observed 01:02:08 (local)'), findsOneWidget);
    },
  );

  testWidgets('a collapsed card reports the turn finishing', (tester) async {
    await _pumpCard(tester, [_running('terminal', 'call-1')]);
    await _tapHeader(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _pumpCard(tester, [_finished('terminal', 'call-1')]);

    expect(_isExpanded(tester), isFalse);
    expect(find.text('1 completed'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an untouched card still opens and closes with the turn', (
    tester,
  ) async {
    await _pumpCard(tester, [_running('terminal', 'call-1')]);
    expect(_isExpanded(tester), isTrue);

    await _pumpCard(tester, [_finished('terminal', 'call-1')]);
    expect(_isExpanded(tester), isFalse);

    // A later turn of the same group must not inherit a stale pin either.
    await _pumpCard(tester, [
      _finished('terminal', 'call-1'),
      _running('read_file', 'call-2'),
    ]);
    expect(_isExpanded(tester), isTrue);
  });

  testWidgets('a card the user expanded stays expanded when tools settle', (
    tester,
  ) async {
    await _pumpCard(tester, [_finished('terminal', 'call-1')]);
    expect(_isExpanded(tester), isFalse);

    await _tapHeader(tester);
    expect(_isExpanded(tester), isTrue);

    await _pumpCard(tester, [
      _finished('terminal', 'call-1'),
      _finished('read_file', 'call-2'),
    ]);

    expect(_isExpanded(tester), isTrue);
    expect(find.text('2 completed'), findsOneWidget);
  });

  testWidgets('verbose opens the card without counting as a tap', (
    tester,
  ) async {
    await _pumpCard(tester, [_finished('terminal', 'call-1')], verbose: true);
    expect(_isExpanded(tester), isTrue);

    // Opening on its own must not pin: turning verbose off closes the card.
    await _pumpCard(tester, [_finished('terminal', 'call-1')]);
    expect(_isExpanded(tester), isFalse);
  });

  testWidgets('the user can reopen a card that auto-collapsed', (tester) async {
    await _pumpCard(tester, [_running('terminal', 'call-1')]);
    await _pumpCard(tester, [_finished('terminal', 'call-1')]);
    expect(_isExpanded(tester), isFalse);

    await _tapHeader(tester);
    expect(_isExpanded(tester), isTrue);
  });
}
