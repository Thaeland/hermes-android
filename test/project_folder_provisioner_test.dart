import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/project_folder_provisioner.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A dashboard stand-in: serves the managed-files routes the provisioner
/// uses and records every request so tests can assert what was created.
class _FakeDashboard {
  final List<String> _mkdirs = [];
  List<String> get mkdirs => _mkdirs;

  /// Paths that already exist on the host (GET /api/files answers 200).
  final Set<String> existing;

  /// Paths whose mkdir is refused with 403.
  final Set<String> forbiddenMkdirs;

  /// Directory paths where marker WRITES are refused (read-only mount).
  final Set<String> readOnlyDirs;

  /// When set, every fs/read-text returns this content instead of what
  /// was written — simulates a host whose read cannot be trusted to echo
  /// the claim back.
  String? corruptReadText;

  /// Marker files written via fs/write-text, keyed by path.
  final Map<String, String> writtenFiles = {};

  /// Locked-root value for GET /api/files (null = unlocked, browses home).
  final String? lockedRoot;

  /// The browsed-home path value for GET /api/files.
  final String homePath = '/home/tester';

  _FakeDashboard({
    Set<String>? existing,
    Set<String>? forbiddenMkdirs,
    Set<String>? readOnlyDirs,
    this.lockedRoot,
  }) : existing = existing ?? {},
       forbiddenMkdirs = forbiddenMkdirs ?? {},
       readOnlyDirs = readOnlyDirs ?? {};

  DashboardClient client() => DashboardClient(
    host: 'localhost',
    port: 9119,
    proxied: true,
    httpClient: MockClient(_handle),
  );

  Future<http.Response> _handle(http.Request request) async {
    final uri = request.url;
    if (uri.path == '/api/files' && request.method == 'GET') {
      final path = uri.queryParameters['path'];
      if (path == null) {
        return http.Response(
          jsonEncode({
            'path': homePath,
            'parent': null,
            'entries': <dynamic>[],
            'locked_root': lockedRoot,
          }),
          200,
        );
      }
      if (existing.contains(path)) {
        // List whatever marker files were written directly inside this dir
        // (mirrors the stock scandir-backed listing the claim check reads).
        final entries = writtenFiles.entries
            .where((e) {
              final idx = e.key.lastIndexOf('/');
              return idx > 0 && e.key.substring(0, idx) == path;
            })
            .map((e) => {
              'name': e.key.substring(e.key.lastIndexOf('/') + 1),
              'is_directory': false,
            })
            .toList();
        return http.Response(
          jsonEncode({'path': path, 'entries': entries}),
          200,
        );
      }
      return http.Response('{"detail":"Path not found"}', 404);
    }
    if (uri.path == '/api/files/mkdir' && request.method == 'POST') {
      final path = (jsonDecode(request.body) as Map)['path'] as String;
      if (forbiddenMkdirs.contains(path)) {
        return http.Response('{"detail":"not writable"}', 403);
      }
      _mkdirs.add(path);
      existing.add(path);
      return http.Response(jsonEncode({'ok': true, 'path': path}), 200);
    }
    if (uri.path == '/api/fs/write-text' && request.method == 'POST') {
      final body = jsonDecode(request.body) as Map;
      final path = body['path'] as String;
      final content = body['content'] as String;
      // The stock route requires the parent dir to exist; a read-only
      // directory refuses the write like a mounted-ro folder would.
      final parent = path.substring(0, path.lastIndexOf('/'));
      if (!existing.contains(parent)) {
        return http.Response('{"detail":"Parent does not exist"}', 400);
      }
      if (readOnlyDirs.contains(parent)) {
        return http.Response('{"detail":"File is not writable"}', 403);
      }
      writtenFiles[path] = content;
      return http.Response(jsonEncode({'ok': true, 'path': path}), 200);
    }
    if (uri.path == '/api/fs/read-text' && request.method == 'GET') {
      final path = uri.queryParameters['path'];
      final content = writtenFiles[path];
      if (content == null) {
        return http.Response('{"detail":"File not found"}', 404);
      }
      return http.Response(
        jsonEncode({
          'binary': false,
          'text': corruptReadText ?? content,
          'path': path,
        }),
        200,
      );
    }
    return http.Response('not found', 404);
  }
}

void main() {
  group('provision', () {
    test('creates a fresh folder under <home>/Projects when unlocked', () async {
      final dash = _FakeDashboard();
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'widget-lab',
      );
      expect(folder, '/home/tester/Projects/widget-lab');
      expect(dash.mkdirs, ['/home/tester/Projects/widget-lab']);
    });

    test('provisions inside the locked root when the dashboard is locked', () async {
      final dash = _FakeDashboard(lockedRoot: '/opt/data');
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'widget-lab',
      );
      expect(folder, '/opt/data/widget-lab');
    });

    test('NEVER adopts an already-existing folder; takes the next suffix', () async {
      final dash = _FakeDashboard(
        existing: {'/home/tester/Projects/widget-lab'},
      );
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'widget-lab',
      );
      expect(folder, '/home/tester/Projects/widget-lab-1');
      // Only the fresh path was ever created; the pre-existing one was
      // probed, never written into.
      expect(dash.mkdirs, ['/home/tester/Projects/widget-lab-1']);
    });

    test('skips every taken name until a free one is found', () async {
      final dash = _FakeDashboard(
        existing: {
          '/home/tester/Projects/app',
          '/home/tester/Projects/app-0',
          '/home/tester/Projects/app-1',
        },
      );
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'app',
      );
      expect(folder, '/home/tester/Projects/app-2');
    });

    test('a refused mkdir (403) stops the loop instead of suffix-spamming', () async {
      final dash = _FakeDashboard(
        forbiddenMkdirs: {'/home/tester/Projects/pairing'},
      );
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'pairing',
      );
      expect(folder, isNull);
      expect(dash.mkdirs, isEmpty);
    });

    test('an unreadable projects root yields null, never a guess', () async {
      final failing = DashboardClient(
        host: 'localhost',
        port: 9119,
        proxied: true,
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      );
      final folder = await DashboardFolderProvisioner(failing).provision('thing');
      expect(folder, isNull);
    });

    test('an empty or unsanitizable slug provisions nothing', () async {
      final dash = _FakeDashboard();
      final provisioner = DashboardFolderProvisioner(dash.client());
      expect(await provisioner.provision(''), isNull);
      expect(await provisioner.provision('  .  '), isNull);
      expect(await provisioner.provision('---'), isNull);
      expect(dash.mkdirs, isEmpty);
    });

    test('sanitizes separators and traversal out of the slug', () async {
      final dash = _FakeDashboard();
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        '../../evil Name',
      );
      expect(folder, '/home/tester/Projects/evil-name');
      expect(folder!.contains('..'), isFalse);
    });

    test('a concurrent creator that won the race is NOT adopted', () async {
      // The probe sees the candidate as free (not in `existing`), mkdir
      // succeeds exist_ok-style, but the directory already carries the
      // racer's marker — the claim check must reject it and move on.
      final dash = _FakeDashboard();
      dash.writtenFiles['/home/tester/Projects/raced/hermes-provision-aaa.owner'] =
          'aaa';
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'raced',
      );
      // Never adopted the contested path; the -1 suffix is clean.
      expect(folder, '/home/tester/Projects/raced-1');
      expect(dash.mkdirs.first, '/home/tester/Projects/raced');
    });

    test('a read-only candidate directory is abandoned, never adopted', () async {
      final dash = _FakeDashboard(
        readOnlyDirs: {'/home/tester/Projects/locked-thing'},
      );
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'locked-thing',
      );
      // Marker write refused → claim fails → next suffix succeeds.
      expect(folder, '/home/tester/Projects/locked-thing-1');
    });

    test('a corrupt marker read (token mismatch) never adopts', () async {
      final dash = _FakeDashboard()..corruptReadText = 'not-what-we-wrote';
      final folder = await DashboardFolderProvisioner(dash.client()).provision(
        'weird-host',
      );
      // Every candidate fails verification; the loop exhausts and
      // degrades to folderless rather than adopting on a bad proof.
      expect(folder, isNull);
    });
  });
}
