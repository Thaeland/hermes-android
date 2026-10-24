import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/controllers/delegated_task_controller.dart';
import 'package:hermes_android/core/widgets/background_report_card.dart';
import 'package:hermes_android/core/widgets/delegated_task_timeline.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'delegated_task_history_test.dart' show FakeHistory, task;
import 'support/internal_background_message_fixture.dart';

void main() {
  testWidgets(
    'delegated internal rows use collapsed tasks, never User labels',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = internalBackgroundMessageFixtures()['model_switch']!;
      final row = Map<String, dynamic>.from(fixture['row'] as Map)..['id'] = 2;
      final history = FakeHistory()
        ..data = [
          {'id': 1, 'role': 'user', 'content': 'Actual delegated request'},
          row,
        ];
      Future<DelegatedTaskController> open() async {
        final controller = DelegatedTaskController(
          task: task,
          history: history,
        );
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: DelegatedTaskTimeline(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();
        return controller;
      }

      final controller = await open();
      final card = find.byType(BackgroundReportCard);
      expect(card, findsOneWidget);
      expect(find.text('User · row 1'), findsOneWidget);
      expect(find.text('User · row 2'), findsNothing);
      expect(find.text('Background task'), findsOneWidget);
      expect(find.text(row['content'] as String), findsNothing);
      ExpansionTile tile() => tester.widget<ExpansionTile>(
        find.descendant(of: card, matching: find.byType(ExpansionTile)),
      );
      expect(tile().controller!.isExpanded, isFalse);
      await tester.tap(find.text('Expand report'));
      await tester.pumpAndSettle();
      expect(tile().controller!.isExpanded, isTrue);
      expect(find.text(row['content'] as String), findsOneWidget);
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(tile().controller!.isExpanded, isTrue);
      expect(controller.rows.singleWhere((row) => row['id'] == 2), row);
      await tester.pumpWidget(const SizedBox.shrink());
      await open();
      expect(tile().controller!.isExpanded, isFalse);
      expect(find.text(row['content'] as String), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );
}
