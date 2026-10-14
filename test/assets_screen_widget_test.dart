// Widget tests for the assets screen over a fake RPC: gallery rendering,
// size tiers, the timezone-labeled subtitle, filter reloads, and the
// unsupported/error degradations. No sockets — everything goes through the
// testRpc seam.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/assets_screen.dart';
import 'package:hermes_android/core/services/projects_gateway_client.dart'
    show GatewayRpcCall;
import 'package:hermes_android/core/theme/hermes_theme.dart';

final _connection = SavedConnection(
  id: 'conn-widget',
  label: 'Widget',
  host: 'example.invalid',
  port: 8648,
  apiKey: 'fixture-key',
  useHttps: false,
);

Future<void> _pump(WidgetTester tester, GatewayRpcCall rpc) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: hermesTheme(Brightness.dark),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: AssetsScreen(connection: _connection, testRpc: rpc),
    ),
  );
}

Map<String, dynamic> _asset({
  required String id,
  required String name,
  String kind = 'artifact',
  String mime = 'application/pdf',
  int sizeBytes = 2048,
  double modifiedAt = 1760000000.0,
  String? projectName,
}) {
  return {
    'id': id,
    'kind': kind,
    'name': name,
    'path': '/srv/attachments/$name',
    'mime_type': mime,
    'size_bytes': sizeBytes,
    'modified_at': modifiedAt,
    'session_id': 's-$id',
    'session_title': 'Session $id',
    'project_name': projectName,
  };
}

/// The zone label the screen is expected to render right now (same rule as
/// the production helper: abbreviation when the platform provides one,
/// otherwise a UTC±HH:MM offset).
String _expectedZoneLabel() {
  final now = DateTime.now();
  final name = now.timeZoneName.trim();
  if (name.isNotEmpty) return name;
  final offset = now.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final abs = offset.abs();
  return 'UTC$sign${abs.inHours.toString().padLeft(2, '0')}:'
      '${(abs.inMinutes % 60).toString().padLeft(2, '0')}';
}

GatewayRpcCall _healthy({List<Map<String, dynamic>>? assets}) {
  return (method, params) async {
    switch (method) {
      case 'assets.status':
        return {'result': {
          'available': true,
          'attachments_dir': '/srv/attachments',
          'attachments_present': true,
        }};
      case 'assets.list':
        final kind = params['kind'];
        final rows = assets ??
            [
              _asset(id: 'a1', name: 'plan.pdf', projectName: 'River Road'),
              _asset(
                id: 'a2',
                name: 'clip.mp4',
                kind: 'media',
                mime: 'video/mp4',
                sizeBytes: 3 * 1024 * 1024 * 1024,
              ),
            ];
        return {
          'result': {
            'assets': kind == null
                ? rows
                : rows.where((r) => r['kind'] == kind).toList(),
          },
        };
    }
    return {
      'error': {'code': -32601, 'message': 'method not found: $method'},
    };
  };
}

void main() {
  testWidgets('renders asset cards with size tiers and zone-labeled time',
      (tester) async {
    await _pump(tester, _healthy());
    await tester.pumpAndSettle();

    expect(find.text('plan.pdf'), findsOneWidget);
    expect(find.text('clip.mp4'), findsOneWidget);
    // 2048 B → 2.0 KB; 3 GiB → 3.0 GB (the GB tier must exist).
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('3.0 GB'), findsOneWidget);

    // Subtitle carries the project and a wall time WITH a zone label.
    final subtitle = find.textContaining('River Road · 20');
    expect(subtitle, findsOneWidget);
    final text = (subtitle.evaluate().single.widget as Text).data!;
    expect(text, endsWith(_expectedZoneLabel()));
  });

  testWidgets('unknown time when modified_at missing', (tester) async {
    await _pump(
      tester,
      _healthy(
        assets: [
          _asset(id: 'a3', name: 'no-time.pdf', modifiedAt: 0),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('unknown time'), findsOneWidget);
  });

  testWidgets('empty index shows the no-assets state', (tester) async {
    await _pump(tester, _healthy(assets: []));
    await tester.pumpAndSettle();
    expect(find.text('No assets yet'), findsOneWidget);
  });

  testWidgets('filter chip reloads with the kind param', (tester) async {
    final seenKinds = <Object?>[];
    await _pump(tester, (method, params) async {
      if (method == 'assets.list') seenKinds.add(params['kind']);
      return _healthy()(method, params);
    });
    await tester.pumpAndSettle();
    expect(seenKinds.last, isNull);

    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();
    expect(seenKinds.last, 'media');
    expect(find.text('clip.mp4'), findsOneWidget);
    expect(find.text('plan.pdf'), findsNothing);
  });

  testWidgets('missing assets family degrades to unsupported',
      (tester) async {
    await _pump(tester, (method, params) async {
      return {
        'error': {'code': -32601, 'message': 'method not found'},
      };
    });
    await tester.pumpAndSettle();
    expect(
      find.textContaining('not available on this server'),
      findsOneWidget,
    );
  });

  testWidgets('RPC error surfaces the error state with retry',
      (tester) async {
    await _pump(tester, (method, params) async {
      if (method == 'assets.status') {
        return {
          'error': {'code': -32000, 'message': 'disk on fire'},
        };
      }
      return _healthy()(method, params);
    });
    await tester.pumpAndSettle();
    expect(find.text('Assets check failed'), findsOneWidget);
    expect(find.textContaining('disk on fire'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
