import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notification_prefs.dart';
import 'package:hermes_android/core/widgets/mobile_push_settings.dart';

import 'mobile_push_service_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late fixture.Fixture f;
  setUp(() async {
    notificationPrefs.value = NotificationPrefs.defaults;
    f = fixture.Fixture();
    await f.setup();
  });
  tearDown(() => f.close());

  Future<void> submit(WidgetTester tester, String raw) async {
    await tester.runAsync(() => f.service.initialize(f.manager));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MobilePushSettings(
              connection: f.connection,
              connectionManager: f.manager,
              service: f.service,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => f.service.distributors());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), raw);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    final enable = find.widgetWithText(
      FilledButton,
      'Enable for selected sessions',
    );
    await tester.ensureVisible(enable);
    await tester.tap(enable);
    await tester.pumpAndSettle();
  }

  final invalid = <String, String>{
    'empty': '',
    'leading LF': '\nsession-a',
    'trailing LF': 'session-a\n',
    'internal blank LF': 'session-a\n\nsession-b',
    'leading comma': ',session-a',
    'trailing comma': 'session-a,',
    'internal blank comma': 'session-a,,session-b',
    'mixed blank': 'session-a,\nsession-b',
    'blank CRLF': 'session-a\r\n\r\nsession-b',
    'leading whitespace': ' session-a',
    'trailing whitespace': 'session-a ',
    'blank whitespace': 'session-a\n \nsession-b',
    'lone CR': 'session-a\rsession-b',
    'non ASCII': 'session-é',
    'too long': 'x' * 201,
    'too many': List.generate(129, (i) => 's$i').join('\n'),
  };
  for (final entry in invalid.entries) {
    testWidgets('Settings rejects ${entry.key} before any setup effects', (
      tester,
    ) async {
      await submit(tester, entry.value);
      expect(f.native['enabled'], isNot(true));
      expect(f.requests, isEmpty);
      expect(f.methods, isNot(contains('permission')));
      expect(f.methods, isNot(contains('enable')));
      expect(find.textContaining('1–128 durable session IDs'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        entry.value,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  final valid = <String, List<String>>{
    'one byte': ['a'],
    'punctuation': ['AZaz09_.:@-'],
    'max length': ['x' * 200],
    'max count': List.generate(128, (i) => 's$i'),
    'CRLF': ['session-a', 'session-b'],
  };
  for (final entry in valid.entries) {
    testWidgets('Settings preserves exact valid ${entry.key} scope', (
      tester,
    ) async {
      await submit(
        tester,
        entry.value.join(entry.key == 'CRLF' ? '\r\n' : '\n'),
      );
      expect(f.native['sessions'], entry.value);
      expect(f.methods.where((m) => m == 'permission'), hasLength(1));
      expect(f.methods.where((m) => m == 'enable'), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
