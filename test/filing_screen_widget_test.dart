// Widget tests for the filing screen over a fake RPC: the screen's state
// machine (loading → suggestions → accept/reject reload → error → unsupported)
// is exercised through the testRpc seam, so no socket or real IO is needed.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/screens/filing_screen.dart';
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
      home: FilingScreen(connection: _connection, testRpc: rpc),
    ),
  );
}

const _suggestionRow = {
  'session_id': 's1',
  'title': 'River Road Recon',
  'project_id': 'p-river',
  'project_name': 'River Road',
  'cwd': '/srv/projects/river-road',
  'reason': 'cwd_match',
  'confidence': 0.9,
};

GatewayRpcCall _healthy({bool hookInstalled = true}) {
  return (method, params) async {
    switch (method) {
      case 'filing.status':
        return {'result': {
          'available': true,
          'hook_installed': hookInstalled,
          'contract_path': '/srv/.filing/contract.json',
          'rules': 2,
          'exclusions': 1,
          'audit_entries': 3,
      }};
      case 'filing.suggest':
        return {
          'result': {'suggestions': [_suggestionRow]},
        };
      case 'filing.rules':
        return {
          'result': {
            'rules': [
              {'path': '/srv/projects/river-road', 'project': 'River Road'},
            ],
            'exclusions': [
              {'path': '/srv/tmp', 'project': null},
            ],
          },
        };
      case 'filing.apply':
        return {'result': {'note': 'filed: applied'}};
      case 'filing.reject':
        return {'result': {'note': 'filed: rejected'}};
    }
    return {
      'error': {'code': -32601, 'message': 'method not found: $method'},
    };
  };
}

void main() {
  testWidgets('renders suggestion, banner, and contract rows', (tester) async {
    await _pump(tester, _healthy());
    await tester.pumpAndSettle();

    expect(find.text('River Road Recon'), findsOneWidget);
    expect(find.text('/srv/projects/river-road'), findsWidgets);
    expect(find.textContaining('Working directory matches River Road (90%)'),
        findsOneWidget);
    expect(find.textContaining('Filing contract live'), findsOneWidget);
    expect(find.textContaining('River Road'), findsWidgets);
    expect(find.text('File it'), findsOneWidget);
    expect(find.text('Never here'), findsOneWidget);
  });

  testWidgets('empty suggestions show the nothing-to-file state',
      (tester) async {
    await _pump(
      tester,
      (method, params) async {
        if (method == 'filing.suggest') {
          return {'result': {'suggestions': []}};
        }
        return _healthy()(method, params);
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing to file'), findsOneWidget);
  });

  testWidgets('accept files and reloads with the new state', (tester) async {
    var applies = 0;
    await _pump(tester, (method, params) async {
      if (method == 'filing.apply') {
        applies++;
        return {'result': {'note': 'filed: applied #$applies'}};
      }
      return _healthy()(method, params);
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('File it'));
    await tester.pumpAndSettle();

    // The apply went through and the screen settled back to the suggestion
    // list without an error state.
    expect(applies, 1);
    expect(find.text('Filing check failed'), findsNothing);
    expect(find.text('River Road Recon'), findsOneWidget);
  });

  testWidgets('reject records and reloads', (tester) async {
    var rejects = 0;
    await _pump(tester, (method, params) async {
      if (method == 'filing.reject') {
        rejects++;
        return {'result': {'note': 'filed: rejected #$rejects'}};
      }
      return _healthy()(method, params);
    });
    await tester.pumpAndSettle();

    await tester.tap(find.text('Never here'));
    await tester.pumpAndSettle();

    expect(rejects, 1);
    expect(find.text('Filing check failed'), findsNothing);
    expect(find.text('River Road Recon'), findsOneWidget);
  });

  testWidgets('RPC error surfaces the error state with retry',
      (tester) async {
    var calls = 0;
    await _pump(tester, (method, params) async {
      calls++;
      if (method == 'filing.status') {
        return {
          'error': {'code': -32000, 'message': 'boom'},
        };
      }
      return _healthy()(method, params);
    });
    await tester.pumpAndSettle();
    expect(find.text('Filing check failed'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(calls, greaterThan(0));
  });

  testWidgets('missing filing family degrades to unsupported',
      (tester) async {
    await _pump(tester, (method, params) async {
      return {
        'error': {'code': -32601, 'message': 'method not found'},
      };
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('not available on this server'), findsOneWidget);
  });

  testWidgets('inactive hook shows the hook-inactive banner', (tester) async {
    await _pump(tester, _healthy(hookInstalled: false));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('correction hook is not active'),
      findsOneWidget,
    );
  });
}
