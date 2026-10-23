import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'connection_manager.dart';
import 'mobile_push_api.dart';
import 'notification_prefs.dart';

/// A verified event route, not a URL or approval. Recheck [isRouteCurrent] after
/// any asynchronous session lookup, immediately before navigating.
class MobilePushRoute {
  const MobilePushRoute(
    this.connection,
    this.sessionId,
    this.eventId,
    this.authority,
  );
  final SavedConnection connection;
  final String sessionId;
  final String eventId;
  final Map<String, dynamic> authority;
}

/// Optional, one explicitly selected saved connection per Android installation.
/// Native encrypted storage is the source of truth. Startup never requests
/// permission, registers a distributor, or blocks credential hydration.
class MobilePushService extends ChangeNotifier with WidgetsBindingObserver {
  MobilePushService({
    MethodChannel? channel,
    DashboardClient Function(SavedConnection)? clientFactory,
    bool? supported,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _clientFactory = clientFactory ?? _dashboard,
       supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  static const channelName = 'com.hermesagent.hermes_android/mobile_push';
  static final shared = MobilePushService();
  final MethodChannel _channel;
  final DashboardClient Function(SavedConnection) _clientFactory;
  final bool supported;
  ConnectionManager? _manager;
  Future<void>? _initialization;
  Map<String, dynamic> _state = {};
  Map<String, dynamic>? _tap;
  Future<void>? _flight;
  bool _dirty = false;
  bool _closed = false;
  int _epoch = 0;
  String status = 'Off';
  String? error;
  List<Map<String, dynamic>> events = [];
  String get connectionId => _state['connection'] as String? ?? '';
  bool get enabled => _state['enabled'] == true;
  bool get active => enabled && _state['active'] == true;
  List<String> get sessionIds =>
      List<String>.from(_state['sessions'] as List? ?? []);
  bool get hasPendingTap => _tap != null;
  int get pendingRevocations => (_state['revocations'] as List? ?? []).length;

  static DashboardClient _dashboard(SavedConnection c) => DashboardClient(
    host: c.host,
    port: c.dashboardPort,
    useHttps: c.useHttps,
    pathPrefix: c.dashboardPrefix ?? '',
    proxied: c.dashboardProxied,
    username: c.dashboardUsername,
    password: c.dashboardPassword,
    gatewayProfile: c.gatewayProfile,
  );
  static String binding(SavedConnection c) => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            ...c.toMap(),
            'api_key': c.apiKey,
            'dashboard_password': c.dashboardPassword,
          }),
        ),
      )
      .toString();
  SavedConnection? _connection(String id) =>
      _manager?.getConnections().where((c) => c.id == id).firstOrNull;
  Future<Map<String, dynamic>> _call(
    String method, [
    Map<String, dynamic>? args,
  ]) async => Map<String, dynamic>.from(
    await _channel.invokeMapMethod<String, dynamic>(method, args) ?? {},
  );

  Future<void> initialize(ConnectionManager manager) {
    _manager = manager;
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    if (!supported) {
      status = 'Android only';
      return;
    }
    // Do not briefly overwrite a persisted disabled native preference with
    // Dart's startup defaults while the root's preference hydration is pending.
    await NotificationPrefsStore.load();
    if (_closed) return;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') await refresh();
    });
    notificationPrefs.addListener(_preferencesChanged);
    await syncPreferences(notificationPrefs.value);
    await refresh();
  }

  void _preferencesChanged() {
    unawaited(syncPreferences(notificationPrefs.value));
  }

  /// Explicit parity hook for the app's current master/per-kind preferences.
  /// Await this when settings change so headless delivery uses the same policy.
  /// Consent is separately revoked immediately by [disable], not by a toggle
  /// that only suppresses local notifications.
  Future<void> syncPreferences(NotificationPrefs prefs) async {
    if (!supported || _closed) return;
    try {
      await _call('preferences', {
        'master': prefs.enabled,
        'kinds': [
          if (prefs.kindEnabled(HermesNotificationKind.turnDone)) 'turn_done',
          if (prefs.kindEnabled(HermesNotificationKind.turnError)) 'turn_error',
          if (prefs.kindEnabled(HermesNotificationKind.input)) ...[
            'input',
            'input_resolved',
          ],
        ],
      });
    } catch (_) {
      error = 'Native notification preferences could not be synchronized.';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<List<String>> distributors() async {
    if (!supported) return [];
    return List<String>.from(
      await _channel.invokeListMethod<String>('distributors') ?? [],
    );
  }

  Future<void> enable(
    SavedConnection connection,
    String distributor,
    List<String> sessions,
  ) async {
    final ids = sessions
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (!supported ||
        _manager == null ||
        ids.isEmpty ||
        ids.length > 256 ||
        ids.any((s) => s.length > 256)) {
      throw StateError(
        'Choose durable session IDs and an Android distributor first.',
      );
    }
    final epoch = ++_epoch;
    final fingerprint = binding(connection);
    bool current() =>
        !_closed &&
        epoch == _epoch &&
        _connection(connection.id) != null &&
        binding(_connection(connection.id)!) == fingerprint;
    final client = _clientFactory(connection);
    error = null;
    status = 'Checking server authorization';
    notifyListeners();
    try {
      final caps = await MobilePushApi(client).capabilities();
      if (!current()) return;
      final permission =
          await _channel.invokeMethod<bool>('permission') == true;
      if (!current()) return;
      if (!permission) {
        throw StateError(
          'Allow Android notifications before enabling mobile push.',
        );
      }
      final prefs = notificationPrefs.value;
      final state = await _call('enable', {
        'connection': connection.id,
        'binding': fingerprint,
        'distributor': distributor,
        'sessions': ids,
        'vapid': caps['vapid_public_key'],
        'master': prefs.enabled,
        'kinds': [
          if (prefs.kindEnabled(HermesNotificationKind.turnDone)) 'turn_done',
          if (prefs.kindEnabled(HermesNotificationKind.turnError)) 'turn_error',
          if (prefs.kindEnabled(HermesNotificationKind.input)) ...[
            'input',
            'input_resolved',
          ],
        ],
      });
      if (!current()) return;
      _state = state;
    } catch (e) {
      if (current()) {
        // A connector error can occur after native consent was durably stored.
        // Reflect that authority so Disable is still visible and effective.
        try {
          final live = await _call('snapshot');
          if (current()) _state = live;
        } catch (_) {
          /* preserve original, non-secret error below */
        }
      }
      if (current()) {
        status = 'Error';
        error = _message(e);
        notifyListeners();
      }
      rethrow;
    } finally {
      client.close();
    }
    if (current()) await refresh();
  }

  /// Invalidates in-flight Dart callbacks synchronously; native consent, queued
  /// hints and notifications are revoked before attempting authenticated DELETE.
  Future<void> disable() async {
    ++_epoch;
    _tap = null;
    events = [];
    status = 'Off';
    notifyListeners();
    if (!supported || _closed) return;
    try {
      _state = await _call('disable');
    } catch (_) {
      error =
          'Could not persist revocation. Retry disabling before leaving the app.';
      notifyListeners();
      rethrow;
    }
    await refresh();
  }

  Future<void> retry() async {
    if (!supported || _closed) return;
    if (enabled && (_state['endpoint'] == null || _state['error'] != null)) {
      await _call('retryDistributor');
    }
    await refresh();
  }

  /// Single flight with a dirty tail: a challenge arriving during PUT is not
  /// lost, and disable/renewal invalidates every subsequent async continuation.
  Future<void> refresh() {
    if (!supported || _closed) return Future.value();
    _dirty = true;
    if (_flight != null) return _flight!;
    final flight = _drain();
    _flight = flight;
    flight.whenComplete(() {
      if (identical(_flight, flight)) _flight = null;
      if (_dirty && !_closed) unawaited(refresh());
    }).ignore();
    return flight;
  }

  Future<void> _drain() async {
    while (_dirty && !_closed) {
      _dirty = false;
      try {
        await _refresh();
      } catch (e) {
        if (!_closed) {
          error = _message(e);
          status = 'Error';
          notifyListeners();
        }
      }
    }
  }

  Future<bool> _current(Map<String, dynamic> expected, int epoch) async {
    if (_closed || epoch != _epoch) return false;
    final live = await _call('snapshot');
    if (_closed || epoch != _epoch) return false;
    final c = _connection(expected['connection'] as String? ?? '');
    return c != null &&
        binding(c) == expected['binding'] &&
        live['enabled'] == true &&
        live['installation'] == expected['installation'] &&
        live['nonce'] == expected['nonce'] &&
        live['generation'] == expected['generation'] &&
        live['revision'] == expected['revision'];
  }

  Future<void> _refresh() async {
    final epoch = _epoch;
    final snapshot = await _call('snapshot');
    if (_closed || epoch != _epoch) return;
    _state = snapshot;
    // Retry recorded failed revokes, but never against changed credentials or a
    // different origin/profile. Such records remain visibly pending.
    for (final raw in snapshot['revocations'] as List? ?? []) {
      final item = Map<String, dynamic>.from(raw as Map);
      final c = _connection(item['connection'] as String);
      if (c == null || binding(c) != item['binding']) continue;
      final client = _clientFactory(c);
      try {
        await MobilePushApi(client).revoke(item['installation'] as String);
        if (_closed || epoch != _epoch) return;
        final revoked = await _call('revoked', {
          'revokedInstallation': item['installation'],
        });
        if (_closed || epoch != _epoch) return;
        _state = revoked;
      } catch (_) {
        /* durable record retained for next foreground retry */
      } finally {
        client.close();
      }
    }
    if (!enabled) {
      status = pendingRevocations > 0
          ? 'Off; server revocation pending'
          : 'Off';
      notifyListeners();
      return;
    }
    final connection = _connection(connectionId);
    if (connection == null || binding(connection) != snapshot['binding']) {
      // A removed/edited account cannot retain authority from a former login.
      ++_epoch;
      _tap = null;
      _state = await _call('disable');
      status = 'Off; saved connection changed';
      notifyListeners();
      return;
    }
    final client = _clientFactory(connection);
    final api = MobilePushApi(client);
    var state = snapshot;
    try {
      if (state['error'] != null) throw StateError(state['error'] as String);
      if (state['endpoint'] == null) {
        status = 'Pending distributor endpoint';
        notifyListeners();
        return;
      }
      if (state['generation'] == 0) {
        status = 'Registering';
        notifyListeners();
        final response = await api.register(state);
        if (!await _current(state, epoch)) return;
        final generation = response['generation'];
        if (generation is! int ||
            generation <= 0 ||
            response['status'] != 'pending' ||
            response['registration_nonce'] != state['nonce']) {
          throw const FormatException('Invalid registration response.');
        }
        state = await _call('generation', {...state, 'generation': generation});
        if (!await _current(state, epoch)) return;
        _state = state;
      }
      if (state['active'] != true) {
        final live = await _call('snapshot');
        if (!await _current(state, epoch)) return;
        final challenges = live['challenges'] as List? ?? [];
        for (final raw in challenges) {
          final hint = Map<String, dynamic>.from(raw as Map);
          if (hint['generation'] != state['generation'] ||
              hint['registration_nonce'] != state['nonce'] ||
              hint['expires_at'] is! int ||
              (hint['expires_at'] as int) <=
                  DateTime.now().millisecondsSinceEpoch ~/ 1000) {
            continue;
          }
          final response = await api.confirm(
            state['installation'] as String,
            state['generation'] as int,
            hint['challenge'] as String,
          );
          if (!await _current(state, epoch)) return;
          if (response['status'] != 'active') {
            throw const FormatException('Server did not confirm activation.');
          }
          state = await _call('activate', state);
          if (!await _current(state, epoch)) return;
          _state = state;
          break;
        }
      }
      status = state['active'] == true
          ? 'Active'
          : 'Pending encrypted challenge (open Hermes to confirm)';
      error = null;
      if (state['active'] == true) {
        final reconciled = await _events(api, state, epoch);
        if (!await _current(state, epoch)) return;
        events = reconciled;
        final rawTap = await _channel.invokeMapMethod<String, dynamic>(
          'takeTap',
        );
        if (!await _current(state, epoch)) return;
        if (rawTap != null) _tap = Map<String, dynamic>.from(rawTap);
      }
      notifyListeners();
    } finally {
      client.close();
    }
  }

  Future<List<Map<String, dynamic>>> _events(
    MobilePushApi api,
    Map<String, dynamic> state,
    int epoch,
  ) async {
    var cursor = '0';
    final result = <String, Map<String, dynamic>>{};
    final visited = <String>{};
    // Cursor paging, never a latest-100 window used as deletion/completion proof.
    for (var page = 0; page < 100; page++) {
      if (!visited.add(cursor)) {
        throw const FormatException('Event cursor did not advance.');
      }
      final response = await api.events(cursor);
      if (!await _current(state, epoch)) return [];
      if (response['events'] is! List || response['has_more'] is! bool) {
        throw const FormatException('Invalid events response.');
      }
      for (final raw in response['events'] as List) {
        if (raw is! Map) continue;
        final event = Map<String, dynamic>.from(raw);
        if (event['event_id'] is! String ||
            event['session_id'] is! String ||
            !(state['sessions'] as List).contains(event['session_id']) ||
            !const [
              'turn_done',
              'turn_error',
              'input',
              'input_resolved',
            ].contains(event['kind']) ||
            event['expires_at'] is! num ||
            (event['expires_at'] as num) <=
                DateTime.now().millisecondsSinceEpoch / 1000) {
          continue;
        }
        result[event['event_id'] as String] = event;
      }
      if (response['has_more'] == false) return result.values.toList();
      cursor = '${response['next_cursor']}';
    }
    throw StateError(
      'Event reconciliation incomplete; retry after the server backlog is reduced.',
    );
  }

  /// Called by root on service changes/resume. Resolves only through the
  /// authenticated event feed; no arbitrary URL, message body, or auto-approval.
  Future<MobilePushRoute?> takePendingNotificationRoute() async {
    final tap = _tap;
    _tap = null;
    if (tap == null) return null;
    final state = Map<String, dynamic>.from(_state);
    final epoch = _epoch;
    if (tap['nonce'] != state['nonce'] ||
        tap['revision'] != state['revision'] ||
        tap['generation'] != state['generation'] ||
        tap['expires_at'] is! num ||
        (tap['expires_at'] as num) <=
            DateTime.now().millisecondsSinceEpoch / 1000 ||
        !await _current(state, epoch)) {
      return null;
    }
    final event = events
        .where((e) => e['event_id'] == tap['event_id'])
        .firstOrNull;
    final connection = _connection(state['connection'] as String);
    if (event == null ||
        connection == null ||
        !notificationPrefs.value.enabled ||
        !_kindEnabled(event['kind'])) {
      return null;
    }
    return MobilePushRoute(
      connection,
      event['session_id'] as String,
      event['event_id'] as String,
      {
        for (final key in [
          'connection',
          'binding',
          'installation',
          'nonce',
          'generation',
          'revision',
        ])
          key: state[key],
        'route_kind': event['kind'],
        'route_expires_at': event['expires_at'],
      },
    );
  }

  bool _kindEnabled(Object? kind) => switch (kind) {
    'turn_done' => notificationPrefs.value.kindEnabled(
      HermesNotificationKind.turnDone,
    ),
    'turn_error' => notificationPrefs.value.kindEnabled(
      HermesNotificationKind.turnError,
    ),
    'input' || 'input_resolved' => notificationPrefs.value.kindEnabled(
      HermesNotificationKind.input,
    ),
    _ => false,
  };
  Future<bool> isRouteCurrent(MobilePushRoute route) async {
    final current = await _current(route.authority, _epoch);
    return current &&
        notificationPrefs.value.enabled &&
        _kindEnabled(route.authority['route_kind']) &&
        (route.authority['route_expires_at'] as num) >
            DateTime.now().millisecondsSinceEpoch / 1000;
  }

  static String _message(Object error) {
    if (error is DashboardHttpException) {
      if (error.statusCode == 404) {
        return 'Optional mobile-push server plugin is not installed.';
      }
      if (error.statusCode == 401 || error.statusCode == 403) {
        return 'Server denied mobile push. Ask the operator to authorize this principal and these sessions.';
      }
    }
    // Never surface server/platform exception bodies (endpoint/auth secrets).
    return 'Mobile push is not ready. Check server plugin authorization, distributor and network, then retry.';
  }

  @override
  void dispose() {
    _closed = true;
    ++_epoch;
    notificationPrefs.removeListener(_preferencesChanged);
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
