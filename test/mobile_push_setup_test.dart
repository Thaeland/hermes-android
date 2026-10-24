import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notification_prefs.dart';
import 'package:hermes_android/core/widgets/mobile_push_settings.dart';
import 'package:http/http.dart' as http;

import 'mobile_push_service_test.dart' as fixture;
import 'support/l10n_test_utils.dart';

const _launcher = MethodChannel('plugins.flutter.io/url_launcher');
const _guide =
    'https://github.com/rusty4444/hermes-android/blob/main/docs/mobile-push-server.md'
    '#operator-installation-not-performed-by-this-implementation';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late fixture.Fixture f;
  final launches = <MethodCall>[];
  late Future<bool> Function() launch;

  setUp(() async {
    notificationPrefs.value = NotificationPrefs.defaults;
    f = fixture.Fixture();
    await f.setup();
    launches.clear();
    launch = () async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_launcher, (call) async {
          expect(call.method, 'launch');
          launches.add(call);
          return launch();
        });
  });
  tearDown(() {
    f.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_launcher, null);
  });

  Widget card() => SingleChildScrollView(
    child: MobilePushSettings(
      connection: f.connection,
      connectionManager: f.manager,
      service: f.service,
    ),
  );

  Future<void> show(WidgetTester tester) async {
    await tester.runAsync(() => f.service.initialize(f.manager));
    await tester.pumpWidget(testAppWithL10n(Scaffold(body: card())));
    await tester.runAsync(() => f.service.transportOptions());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNotNull);
  }

  void expectNoConsent() {
    expect(f.service.enabled, isFalse);
    for (final method in ['permission', 'enable', 'retryDistributor']) {
      expect(f.methods, isNot(contains(method)));
    }
    expect(
      f.requests.where(
        (r) =>
            r.method != 'GET' && !r.url.path.endsWith('/auth/password-login'),
      ),
      isEmpty,
    );
  }

  Future<void> openGuide(WidgetTester tester) async {
    final guide = find.text('Server setup guide');
    await tester.ensureVisible(guide);
    await tester.tap(guide);
    await tester.pumpAndSettle();
  }

  testWidgets('off settings explains separate server setup without opting in', (
    tester,
  ) async {
    await show(tester);
    expect(
      find.textContaining('server-side mobile-push companion'),
      findsOneWidget,
    );
    expect(find.textContaining('Android cannot install'), findsOneWidget);
    expect(find.textContaining('Updating the APK alone'), findsOneWidget);
    expect(find.text('Server setup guide'), findsOneWidget);
    expect(find.textContaining('rechecks'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(launches, isEmpty);
    expect(f.requests, isEmpty);
    expectNoConsent();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    '404 keeps guide available and refresh only rechecks capabilities',
    (tester) async {
      f.onCapabilities = (_) async => http.Response('secret-server-body', 404);
      await show(tester);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.textContaining('may be missing or disabled'), findsOneWidget);
      expect(find.textContaining('wrong dashboard'), findsOneWidget);
      expect(find.textContaining('Install or enable'), findsOneWidget);
      expect(find.textContaining('secret-server-body'), findsNothing);
      expect(find.text('Server setup guide'), findsOneWidget);
      expectNoConsent();
      await openGuide(tester);
      expect(launches, hasLength(1));

      final before = f.requests
          .where((r) => r.url.path.endsWith('/capabilities'))
          .length;
      final retry = find.text('Refresh / retry');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.runAsync(() => f.service.transportOptions());
      await tester.pumpAndSettle();
      expect(
        f.requests.where((r) => r.url.path.endsWith('/capabilities')),
        hasLength(before + 1),
      );
      expectNoConsent();

      f.onCapabilities = null;
      await tester.tap(retry);
      await tester.runAsync(() => f.service.transportOptions());
      await tester.pumpAndSettle();
      expect(f.service.error, isNull);
      expect(find.textContaining('server API ready'), findsOneWidget);
      expectNoConsent();
      await openGuide(tester);
      expect(launches, hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'off refresh still retries pending revocation without opting in',
    (tester) async {
      f.seed(active: true);
      await show(tester);
      f.failRevoke = true;
      await tester.runAsync(f.service.disable);
      await tester.pumpAndSettle();
      expect(f.service.pendingRevocations, 1);
      f.failRevoke = false;
      final retry = find.text('Refresh / retry');
      await tester.ensureVisible(retry);
      await tester.tap(retry);
      await tester.runAsync(() => f.service.transportOptions());
      await tester.pumpAndSettle();
      expect(f.service.pendingRevocations, 0);
      expect(f.service.enabled, isFalse);
      expect(f.methods, isNot(contains('permission')));
      expect(f.methods, isNot(contains('enable')));
      expect(f.requests.where((r) => r.method == 'PUT'), isEmpty);
      expect(find.textContaining('server API ready'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('guide opens exact public URI externally on explicit tap only', (
    tester,
  ) async {
    await show(tester);
    expect(launches, isEmpty);
    await openGuide(tester);
    final args = launches.single.arguments as Map;
    expect(args['url'], _guide);
    expect(args['useWebView'], isFalse);
    expect(args['useSafariVC'], isFalse);
    expect(args['headers'], isEmpty);
    final uri = Uri.parse(args['url'] as String);
    expect(uri.scheme, 'https');
    expect(uri.userInfo, isEmpty);
    expect(uri.hasQuery, isFalse);
    expect(f.requests, isEmpty);
    expectNoConsent();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('guide fragment matches the current operator heading', () {
    final doc = File('docs/mobile-push-server.md').readAsStringSync();
    expect(
      doc,
      contains(
        '## Operator installation (not performed by this implementation)',
      ),
    );
    expect(
      Uri.parse(_guide).fragment,
      'operator-installation-not-performed-by-this-implementation',
    );
  });

  for (final throws in [false, true]) {
    testWidgets(
      'guide launch ${throws ? 'throw' : 'failure'} shows safe feedback',
      (tester) async {
        launch = () async {
          if (throws) throw PlatformException(code: 'private-platform-detail');
          return false;
        };
        await show(tester);
        await openGuide(tester);
        expect(find.text('Could not open this link.'), findsOneWidget);
        expect(find.textContaining('private-platform-detail'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      'late guide ${throws ? 'throw' : 'failure'} after disposal is inert',
      (tester) async {
        final release = Completer<bool>();
        launch = () => release.future;
        await show(tester);
        await openGuide(tester);
        expect(launches, hasLength(1));
        await tester.pumpWidget(
          testAppWithL10n(const Scaffold(body: Text('Other route'))),
        );
        if (throws) {
          release.completeError(PlatformException(code: 'late-private-detail'));
        } else {
          release.complete(false);
        }
        await tester.pumpAndSettle();
        expect(find.text('Other route'), findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
