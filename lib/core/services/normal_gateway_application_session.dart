import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../models/chat_timeline.dart';
import '../models/gateway_activity.dart';
import '../models/gateway_insight.dart';
import 'connection_manager.dart';
import 'composer_draft_store.dart';
import 'chat_presentation_state.dart';
import 'desktop_gateway_client.dart';
import 'normal_gateway_pending_store.dart';
import 'notification_prefs.dart';
import 'turn_notification_service.dart';
import 'ws_client.dart';

typedef NormalGatewayPromptSubmit =
    Future<void> Function({
      required String sessionId,
      required String text,
      required StreamCallback onEvent,
      required void Function() onSent,
    });
typedef NormalGatewayResume =
    Future<ResumedGatewaySession> Function({
      required String localSessionId,
      required String storedSessionId,
    });
typedef NormalGatewayHistory =
    Future<List<Map<String, dynamic>>> Function(String id);

enum NormalGatewayTurnPhase {
  idle,
  preparing,
  submitting,
  running,
  reconciling,
  completed,
  failed,
}

/// Plain metadata consumed by the application root, never a widget or callback.
class NormalGatewayChatActivity {
  final String connectionId;
  final String localSessionId;
  final String? storedSessionId;
  final String title;
  final String turnId;
  final String status;
  const NormalGatewayChatActivity({
    required this.connectionId,
    required this.localSessionId,
    required this.storedSessionId,
    required this.title,
    required this.turnId,
    required this.status,
  });
}

/// Durable history and transient presentation are deliberately separate. Never
/// write displayRows into the history window: they have no durable row identity.
class NormalGatewayChatSnapshot {
  final String? turnId;
  final String? storedSessionId;
  final NormalGatewayTurnPhase phase;
  final bool wireEmitted;
  final int? rowFloor;
  final List<Map<String, dynamic>> displayRows;
  final List<Map<String, dynamic>> historyRows;
  final List<GatewayToolActivity> tools;
  final List<GatewaySubagentActivity> subagents;
  final List<StreamEvent> pendingInput;
  final List<StreamEvent> inputUpdates;
  final List<StreamEvent> auxiliaryEvents;
  final GatewayTurnStatus? status;
  final String? error;
  final String? rejectedDraft;
  final DesktopConnectionState connectionState;
  final ChatTimeline timeline;
  const NormalGatewayChatSnapshot({
    required this.turnId,
    required this.storedSessionId,
    required this.phase,
    required this.wireEmitted,
    required this.rowFloor,
    required this.displayRows,
    required this.historyRows,
    required this.tools,
    required this.subagents,
    required this.pendingInput,
    required this.inputUpdates,
    required this.auxiliaryEvents,
    required this.status,
    required this.error,
    required this.rejectedDraft,
    required this.connectionState,
    this.timeline = const ChatTimeline(),
  });
  bool get hasActiveTurn => const {
    NormalGatewayTurnPhase.preparing,
    NormalGatewayTurnPhase.submitting,
    NormalGatewayTurnPhase.running,
    NormalGatewayTurnPhase.reconciling,
  }.contains(phase);
  bool get reconciling => phase == NormalGatewayTurnPhase.reconciling;
}

/// One stock client and independent history client per configuration scope.
/// Routes only subscribe; this object owns ingress, recovery and notifications.
class NormalGatewayApplicationSession {
  final SavedConnection connection;
  final String scope;
  final DesktopGatewayClient? client;
  final ApiClient? _historyClient;
  final NormalGatewayPendingStore pendingStore;
  final NormalGatewayPromptSubmit _submit;
  final NormalGatewayResume _resume;
  final NormalGatewayHistory _history;
  final TurnNotificationService notifications;
  final void Function()? onActivityChanged;
  final ChatPresentationRegistry? presentation;
  final Map<String, NormalGatewayChatOwner> _aliases = {};
  late final Future<void> ready;
  bool _initialized = false;
  bool _closed = false;
  bool _background = false;
  bool _backgroundWorkEnabled = true;
  DesktopConnectionState _connectionState = DesktopConnectionState.disconnected;

  NormalGatewayApplicationSession({
    required this.connection,
    required this.scope,
    DesktopGatewayClient? client,
    ApiClient? historyClient,
    NormalGatewayPendingStore? pendingStore,
    NormalGatewayPromptSubmit? submit,
    NormalGatewayResume? resume,
    NormalGatewayHistory? history,
    TurnNotificationService? notifications,
    this.onActivityChanged,
    this.presentation,
  }) : client = client,
       _historyClient = historyClient,
       pendingStore = pendingStore ?? NormalGatewayPendingStore(),
       notifications = notifications ?? TurnNotificationService.shared,
       _submit = submit ?? client!.submitPrompt,
       _resume = resume ?? client!.resumeSubmittedSession,
       _history =
           history ??
           ((id) => historyClient!.getMessages(id, limit: 50, latest: true)) {
    client?.setSessionBoundListener((local, stored) {
      final owner = _aliases[local];
      if (owner != null) _bind(owner, stored);
    });
    client?.setSessionEventListener(receiveEvent);
    client?.setAsyncEventListener((local, event) {
      // Raw stream frames have a separate, single ingress. This path carries
      // only socket-owned requests (including transformed identities). Resume
      // state is reduced after its await/generation check, never via a stale
      // synthetic terminal side-channel.
      if (_interactive(event.type)) {
        receiveEvent(local, event);
      }
    }, acceptsSession: _aliases.containsKey);
    client?.setConnectionListener(connectionChanged);
    ready = _restore();
    ready.ignore();
    unawaited(this.notifications.ensureInitialized());
  }

  factory NormalGatewayApplicationSession.fromConnection(
    SavedConnection connection, {
    required String scope,
    ChatPresentationRegistry? presentation,
    void Function()? onActivityChanged,
  }) {
    return NormalGatewayApplicationSession(
      connection: connection,
      scope: scope,
      presentation: presentation,
      client: DesktopGatewayClient.fromConnection(connection),
      historyClient: ApiClient(
        baseUrl: connection.baseUrl,
        apiKey: connection.apiKey,
        pathPrefix: connection.gatewayPrefix ?? '',
      ),
      onActivityChanged: onActivityChanged,
    );
  }

  Iterable<NormalGatewayChatOwner> get chats => _aliases.values.toSet();
  bool get hasActiveTurn =>
      !_closed && chats.any((chat) => chat.snapshot.hasActiveTurn);
  Iterable<NormalGatewayChatActivity> get activeChatActivities => chats
      .where((chat) => chat.snapshot.hasActiveTurn && chat.turnId != null)
      .map(
        (chat) => NormalGatewayChatActivity(
          connectionId: connection.id,
          localSessionId: chat.localSessionId,
          storedSessionId: chat.storedSessionId,
          title: chat.title,
          turnId: chat.turnId!,
          status: chat.phase.name,
        ),
      );
  NormalGatewayChatOwner? findChat(String id) => _aliases[id];

  NormalGatewayChatOwner chatFor(
    String localSessionId, {
    String? storedSessionId,
    required String title,
    String? workingDirectory,
  }) {
    if (_closed) {
      throw StateError('Normal gateway application session is closed.');
    }
    final owner =
        _aliases[localSessionId] ??
        _aliases[storedSessionId] ??
        NormalGatewayChatOwner._(this, localSessionId, title, workingDirectory);
    _aliases[localSessionId] = owner;
    owner.title = title;
    if (storedSessionId != null) _bind(owner, storedSessionId);
    if (owner.storedSessionId != null) {
      client?.bindStoredSession(localSessionId, owner.storedSessionId!);
    }
    return owner;
  }

  void _bind(NormalGatewayChatOwner owner, String stored) {
    final other = _aliases[stored];
    if (other != null && !identical(other, owner)) {
      throw StateError('Durable chat alias already owned.');
    }
    final changed = owner.storedSessionId != stored || !identical(other, owner);
    owner.storedSessionId = stored;
    _aliases[stored] = owner;
    client?.bindStoredSession(owner.localSessionId, stored);
    presentation?.bind(owner.localSessionId, stored);
    // A notification route can attach to this same owner while its previous
    // ChatScreen remains mounted. An unchanged binding is not a state change,
    // and synchronous fan-out here would dirty that sibling during its build.
    if (changed) owner._notify();
  }

  Future<void> _restore() async {
    var loaded = false;
    try {
      final markers = await pendingStore.load(scope);
      if (_closed) return;
      for (final marker in markers) {
        final chat = chatFor(
          marker.localSessionId,
          storedSessionId: marker.storedSessionId,
          title: 'Chat',
        );
        chat._restore(marker);
      }
      loaded = true;
    } finally {
      _initialized = loaded;
      if (!_closed) {
        for (final chat in chats) {
          chat._notify();
          chat.requestRecovery();
        }
      }
    }
  }

  void receiveEvent(String localSessionId, StreamEvent event) {
    if (!_closed) _aliases[localSessionId]?._event(event);
  }

  void connectionChanged(DesktopConnectionState state) {
    if (_closed) return;
    final changed = _connectionState != state;
    _connectionState = state;
    for (final chat in chats) {
      if (state != DesktopConnectionState.connected) {
        chat._pendingInput.clear(); // exact socket identity is no longer valid
        if (chat.wireEmitted && chat.snapshot.hasActiveTurn) {
          chat.phase = NormalGatewayTurnPhase.reconciling;
        }
      }
      chat._notify();
      if (state == DesktopConnectionState.connected && changed) {
        chat._retry = 0;
        chat.requestRecovery();
      }
    }
  }

  void setLifecycle({required bool background, bool? backgroundWorkEnabled}) {
    _background = background;
    if (backgroundWorkEnabled != null) {
      _backgroundWorkEnabled = backgroundWorkEnabled;
    }
    client?.setReconnectAllowed(_canRecover);
    for (final chat in chats) {
      if (_canRecover) {
        chat.requestRecovery();
      } else {
        chat._retryTimer?.cancel();
        chat._retryTimer = null;
      }
    }
  }

  bool get _canRecover => !_closed && (!_background || _backgroundWorkEnabled);

  bool ownsApprovalRequest({
    required String sessionId,
    required String requestId,
  }) {
    final chat = _aliases[sessionId];
    return chat != null &&
        (client?.ownsApprovalRequest(
              chat.localSessionId,
              requestId: requestId,
            ) ??
            false);
  }

  Future<bool> tryRespondToApproval({
    required String sessionId,
    required String requestId,
    required String choice,
  }) async {
    final chat = _aliases[sessionId];
    if (chat == null ||
        !ownsApprovalRequest(sessionId: sessionId, requestId: requestId)) {
      return false;
    }
    await client!.respondToApproval(
      sessionId: chat.localSessionId,
      choice: choice,
      serverRequestId: requestId,
    );
    chat._pendingInput.remove(requestId);
    chat._notify();
    return true;
  }

  void forgetAnsweredInput(String requestId) {
    for (final chat in chats) {
      if (chat._pendingInput.remove(requestId) != null) chat._notify();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true; // synchronous fence before any resource cleanup
    for (final chat in chats) {
      chat._close();
    }
    client?.close();
    _historyClient?.close();
  }
}

class NormalGatewayChatOwner {
  final NormalGatewayApplicationSession _session;
  final String localSessionId;
  String? storedSessionId;
  String title;
  final String? workingDirectory;
  String? turnId;
  NormalGatewayTurnPhase phase = NormalGatewayTurnPhase.idle;
  bool wireEmitted = false;
  String? _wireTurnId;
  final Set<String> _settledWireTurnIds = {};
  int? _floor;
  int _generation = 0;
  Object? _reservation;
  NormalGatewayPendingMarker? _marker;
  final List<Map<String, dynamic>> _display = [];
  final List<Map<String, dynamic>> _priorDisplay = [];
  List<Map<String, dynamic>> _history = [];
  bool _historyKnown = false;
  final List<GatewayToolActivity> _tools = [];
  final List<GatewaySubagentActivity> _subagents = [];
  ChatTimeline _timeline = const ChatTimeline();
  final Map<String, StreamEvent> _pendingInput = {};
  final List<StreamEvent> _inputUpdates = [];
  final List<StreamEvent> _auxiliaryEvents = [];
  final Map<Object, void Function(NormalGatewayChatSnapshot)> _listeners = {};
  GatewayTurnStatus? _status;
  String? _error;
  String? _draftToRestore;
  bool _draftRestoreAllowed = false;
  Timer? _retryTimer;
  Timer? _baselineTimer;
  Completer<List<Map<String, dynamic>>?>? _baselineRead;
  int _retry = 0;
  bool _recovering = false;

  bool _recoveryQueued = false;
  bool _settling = false;
  bool _submissionPending = false;
  ({bool completed, String? error, int generation})? _terminalReceipt;
  NormalGatewayChatOwner._(
    this._session,
    this.localSessionId,
    this.title,
    this.workingDirectory,
  );

  NormalGatewayChatSnapshot get snapshot => NormalGatewayChatSnapshot(
    turnId: turnId,
    storedSessionId: storedSessionId,
    phase: phase,
    wireEmitted: wireEmitted,
    rowFloor: _floor,
    displayRows: [..._priorDisplay, ..._display]
        .map((row) => Map<String, dynamic>.unmodifiable(row))
        .toList(growable: false),
    historyRows: _history
        .map((row) => Map<String, dynamic>.unmodifiable(row))
        .toList(growable: false),
    tools: List.unmodifiable(_tools),
    subagents: List.unmodifiable(_subagents),
    pendingInput: List.unmodifiable(_pendingInput.values),
    inputUpdates: List.unmodifiable(_inputUpdates),
    auxiliaryEvents: List.unmodifiable(_auxiliaryEvents),
    status: _status,
    error: _error,
    rejectedDraft:
        phase == NormalGatewayTurnPhase.failed &&
            !wireEmitted &&
            _draftRestoreAllowed
        ? _draftToRestore
        : null,
    connectionState: _session._connectionState,
    timeline: _timeline,
  );

  void bindStoredSession(String storedSessionId) {
    if (this.storedSessionId != storedSessionId) {
      _session._bind(this, storedSessionId);
    }
  }

  Object subscribe(void Function(NormalGatewayChatSnapshot) listener) {
    final token = Object();
    _listeners[token] = listener;
    listener(snapshot); // reattachment is immediate, not a later stream tick
    return token;
  }

  void unsubscribe(Object token) => _listeners.remove(token);

  /// The route retains revision authority. Any later edit, including an edit
  /// followed by clearing, permanently relinquishes this restoration receipt.
  void invalidateDraftRecovery() {
    _draftRestoreAllowed = false;
    _draftToRestore = null;
  }

  /// Observe a successful latest-window read, never an older-only paging merge.
  /// Active overlays and their admission baseline remain generation-owned.
  /// A later read can retire a completed projection even when the first
  /// post-settlement read lagged persistence, but only with fresh durable IDs.
  void observeHistory(List<Map<String, dynamic>> rows) {
    if (snapshot.hasActiveTurn) return;
    _history = rows.map((row) => Map<String, dynamic>.from(row)).toList();
    _historyKnown = true;
    if (_retireCompletedProjection(rows)) _notify();
  }

  bool _retireCompletedProjection(List<Map<String, dynamic>> fresh) {
    if (phase != NormalGatewayTurnPhase.completed ||
        _floor == null ||
        !fresh.any((row) => _terminalRow(row, _floor!))) {
      return false;
    }
    final changed =
        _display.isNotEmpty ||
        _priorDisplay.isNotEmpty ||
        _timeline.runs.isNotEmpty ||
        _tools.isNotEmpty ||
        _subagents.isNotEmpty;
    _display.clear();
    _priorDisplay.clear();
    _timeline = _timeline.clear();
    _tools.clear();
    _subagents.clear();
    return changed;
  }

  void _notify() {
    if (_session._closed) return;
    final state = snapshot;
    for (final listener in _listeners.values.toList(growable: false)) {
      listener(state);
    }
    _session.onActivityChanged?.call();
  }

  bool _current(int generation) =>
      !_session._closed && generation == _generation;

  /// Synchronous admission across duplicate routes and both durable/local ids.
  Object? reserve() {
    if (_session._closed || !_session._initialized || snapshot.hasActiveTurn) {
      return null;
    }
    _generation++;
    turnId = const Uuid().v4();
    _reservation = Object();
    phase = NormalGatewayTurnPhase.preparing;
    wireEmitted = false;
    _wireTurnId = null;
    _error = null;
    _notify();
    return _reservation;
  }

  void cancelPreparation(Object reservation) {
    if (!identical(_reservation, reservation) ||
        phase != NormalGatewayTurnPhase.preparing) {
      return;
    }
    _reservation = null;
    phase = NormalGatewayTurnPhase.idle;
    _notify();
  }

  /// An interrupt ack is not a terminal receipt. Keep the marker active until
  /// the terminal event or an authoritative resume/history reconciliation.
  Future<bool> interrupt() async {
    if (!snapshot.hasActiveTurn || !wireEmitted) return false;
    return await _session.client?.interruptPrompt(sessionId: localSessionId) ??
        false;
  }

  /// The boundary at which a prepared submission leaves the route. Nothing
  /// below captures screen state; even a route disposed during write-ahead
  /// cannot drop callbacks, clear activity or close the client.
  Future<void> submitPrepared({
    required Object reservation,
    required String text,
    required String localContent,
    NormalGatewayPromptSubmit? submit,
    String? knownStoredSessionId,
    String? rawDraftText,
    bool canRestoreDraft = false,
  }) async {
    if (!identical(_reservation, reservation) ||
        phase != NormalGatewayTurnPhase.preparing) {
      throw StateError('Submission reservation is no longer owned.');
    }
    _reservation = null;
    final generation = _generation;
    _draftToRestore = rawDraftText;
    _draftRestoreAllowed = canRestoreDraft;
    phase = NormalGatewayTurnPhase.submitting;
    _priorDisplay.addAll(_display);
    if (_priorDisplay.length > 256) {
      _priorDisplay.removeRange(0, _priorDisplay.length - 256);
    }
    _display.clear();
    _tools.clear();
    _subagents.clear();
    _pendingInput.clear();
    _display.add({'role': 'user', 'content': localContent});
    _display.add({
      'role': 'assistant',
      'content': '',
      '_normal_projection_id': const Uuid().v4(),
      '_gateway_pending_response': true,
    });
    _notify();
    try {
      if (storedSessionId == null && knownStoredSessionId != null) {
        _session._bind(this, knownStoredSessionId);
      }
      if (storedSessionId == null) {
        await _session.client!.ensureSession(
          localSessionId,
          workingDirectory: workingDirectory,
        );
        if (!_current(generation)) return;
        final stored = _session.client!.storedSessionKeyFor(localSessionId);
        if (stored == null) {
          throw StateError('No durable session binding before submit.');
        }
        _session._bind(this, stored);
      }
      if (!_current(generation)) return;
      // A local draft's initial GET can legitimately 404 before session.create.
      // Once durably bound, try one canonical read BEFORE write-ahead/wire if
      // no successful history was observed. Existing baselines need no extra
      // latency; the bounded fallback cannot hold a send on a slow endpoint.
      // A 404/failure/timeout stays unknown, never an invented empty baseline.
      if (!_historyKnown) {
        final stored = storedSessionId!;
        final baseline = await _readAdmissionBaseline(stored);
        if (!_current(generation)) return;
        if (stored == storedSessionId && baseline != null) {
          _history = baseline;
          _historyKnown = true;
        }
      }
      _floor = _historyKnown ? _numericFloor(_history) : null;
      _historyKnown = false;
      if (!_current(generation)) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      _marker = NormalGatewayPendingMarker(
        scope: _session.scope,
        localSessionId: localSessionId,
        storedSessionId: storedSessionId!,
        turnId: turnId!,
        rowFloor: _floor,
        phase: 'write_ahead',
        createdAt: now,
        updatedAt: now,
      );
      await _session.pendingStore.put(_marker!);
      if (!_current(generation)) return;
      _submissionPending = true;
      await (submit ?? _session._submit)(
        sessionId: localSessionId,
        text: text,
        // Production ingress is the global observer; the seam feeds exactly
        // the same reducer, rather than bypassing the owner in widget tests.
        onEvent: submit == null
            ? (_) {}
            : (event) {
                if (_current(generation)) _event(event);
              },
        onSent: () {
          if (!_current(generation) || !snapshot.hasActiveTurn) return;
          wireEmitted = true;
          invalidateDraftRecovery();
          phase = NormalGatewayTurnPhase.running;
          _marker = _marker!.withPhase('emitted');
          // The write-ahead receipt already covers this crash window. Failure
          // to update its phase must not convert a sent prompt to a rejection.
          unawaited(
            _session.pendingStore.put(_marker!).catchError((Object _) {}),
          );
          _notify();
        },
      );
      if (_current(generation)) _submissionPending = false;
      if (!_current(generation) || !snapshot.hasActiveTurn || _settling) return;
      // A completed RPC future is NOT terminal evidence (including test seams).
      phase = NormalGatewayTurnPhase.reconciling;
      _notify();
      requestRecovery();
    } catch (error) {
      if (_current(generation)) _submissionPending = false;
      if (!_current(generation) || !snapshot.hasActiveTurn || _settling) return;
      if (wireEmitted) {
        phase = NormalGatewayTurnPhase.reconciling;
        if (error is! JsonRpcError || error.reason != 'stream_terminal') {
          _error = error.toString();
        }
        _notify();
        requestRecovery();
        return;
      }
      await _settle(false, error.toString(), generation: generation);
      rethrow;
    }
  }

  Future<List<Map<String, dynamic>>?> _readAdmissionBaseline(
    String stored,
  ) async {
    final read = Completer<List<Map<String, dynamic>>?>();
    _baselineRead = read;
    _baselineTimer = Timer(
      const Duration(seconds: 2),
      () => read.complete(null),
    );
    // A late response may finish after timeout, wire emission or close. It
    // resolves only this read, never mutates the owner's baseline/history.
    unawaited(
      Future.sync(() => _session._history(stored)).then(
        (rows) {
          if (!read.isCompleted) read.complete(rows);
        },
        onError: (Object _, StackTrace _) {
          if (!read.isCompleted) read.complete(null);
        },
      ),
    );
    try {
      return await read.future;
    } finally {
      _baselineTimer?.cancel();
      _baselineTimer = null;
      _baselineRead = null;
    }
  }

  void _restore(NormalGatewayPendingMarker marker) {
    _generation++;
    turnId = marker.turnId;
    _floor = marker.rowFloor;
    _marker = marker;
    // Even write_ahead may have emitted before process death. Never resend.
    wireEmitted = true;
    phase = NormalGatewayTurnPhase.reconciling;
  }

  void _event(StreamEvent event) {
    if (_session._closed) return;
    if (const {
      'notification.show',
      'notification.clear',
      'background.complete',
      'review.summary',
    }.contains(event.type)) {
      _auxiliaryEvents.add(event);
      if (_auxiliaryEvents.length > 20) _auxiliaryEvents.removeAt(0);
      _notifyAuxiliary(event);
      _notify();
      return;
    }
    if (_interactive(event.type)) {
      final id =
          event.data['server_request_id']?.toString() ??
          event.data['request_id']?.toString() ??
          event.data['id']?.toString();
      if (!event.type.endsWith('.request')) {
        _inputUpdates.add(event);
        if (_inputUpdates.length > 64) _inputUpdates.removeAt(0);
      }
      if (event.type == 'clarify.remaining') {
        final raw = event.data['remaining'];
        final remaining = raw is List
            ? raw.map((value) => value.toString()).toSet()
            : <String>{};
        final previous = _pendingInput[id];
        final questions = previous?.data['questions'];
        if (remaining.isEmpty) {
          _pendingInput.remove(id);
        } else if (previous != null && questions is List) {
          _pendingInput[id!] = StreamEvent(
            type: previous.type,
            data: {
              ...previous.data,
              'questions': questions
                  .where(
                    (question) =>
                        question is Map &&
                        remaining.contains(question['qid']?.toString()),
                  )
                  .toList(),
            },
            sessionId: previous.sessionId,
          );
        }
        _notify();
        return;
      }
      if (event.type == 'request.cancel' || event.type.endsWith('.expire')) {
        _pendingInput.remove(id);
      } else if (id != null) {
        _pendingInput[id] = event;
        if (_pendingInput.length > 64) {
          _pendingInput.remove(_pendingInput.keys.first);
        }
        _notifyAttention(event, id);
      }
      _notify();
      return;
    }
    if (!snapshot.hasActiveTurn ||
        phase == NormalGatewayTurnPhase.preparing ||
        !wireEmitted ||
        _settling) {
      return;
    }
    final wireTurn = event.turnId;
    final terminal = const {
      'message.complete',
      'turn.end',
      'turn.error',
      'error',
    }.contains(event.type);
    if (wireTurn != null) {
      if (_settledWireTurnIds.contains(wireTurn) ||
          _wireTurnId != null && _wireTurnId != wireTurn) {
        return;
      }
      // A terminal cannot establish ownership: it may be A's delayed bookend
      // arriving after B's onSent, before B has emitted any activity.
      if (!terminal) _wireTurnId ??= wireTurn;
    }
    if (phase == NormalGatewayTurnPhase.reconciling &&
        (event.type == 'message.delta' || event.type.startsWith('tool.'))) {
      phase = NormalGatewayTurnPhase.running;
    }
    if (_display.isEmpty &&
        (event.type.startsWith('message.') ||
            event.type.startsWith('tool.') ||
            event.type.startsWith('reasoning.'))) {
      _display.add({
        'role': 'assistant',
        'content': '',
        '_normal_projection_id': const Uuid().v4(),
        '_gateway_pending_response': true,
      });
    }
    final reasoning = GatewayReasoningUpdate.fromGatewayEvent(
      event.type,
      event.data,
    );
    final assistant =
        _display.isNotEmpty && _display.last['role'] == 'assistant'
        ? _display.last
        : null;
    if (reasoning != null && assistant != null) {
      _timeline = _timeline.reasoning(
        assistant['_normal_projection_id']!,
        reasoning,
      );
      assistant['_gateway_reasoning'] = reasoning.applyTo(
        assistant['_gateway_reasoning']?.toString() ?? '',
      );
      assistant['_gateway_reasoning_verbose'] = reasoning.verbose;
      assistant['_gateway_reasoning_replaces'] =
          assistant['_gateway_reasoning_replaces'] == true ||
          reasoning.mode == GatewayReasoningEventMode.replace;
    } else if (event.type == 'message.start' && assistant != null) {
      assistant.remove('_gateway_interim_boundary');
    } else if (event.type == 'message.delta' && assistant != null) {
      final token = event.data['text']?.toString() ?? '';
      assistant['content'] = '${assistant['content'] ?? ''}$token';
      _timeline = _timeline.appendText(
        assistant['_normal_projection_id']!,
        token,
      );
      _status = null;
    } else if (event.type == 'message.interim' && assistant != null) {
      final transition = GatewayInterimTransition.resolve(
        currentText: assistant['content']?.toString() ?? '',
        interimText: event.data['text']?.toString() ?? '',
        alreadyStreamed: event.data['already_streamed'] == true,
      );
      assistant['content'] = transition.sealedText;
      _timeline = _timeline.textSnapshot(
        assistant['_normal_projection_id']!,
        transition.sealedText,
      );
      if (transition.startsNewMessage) {
        assistant['_gateway_interim'] = true;
        assistant['_gateway_pending_response'] = false;
        _display.add({
          'role': 'assistant',
          'content': '',
          '_normal_projection_id': const Uuid().v4(),
          '_gateway_pending_response': true,
          '_gateway_interim_boundary': true,
        });
      }
    } else if (event.type == 'message.complete' && assistant != null) {
      final text =
          event.data['rendered']?.toString() ??
          event.data['text']?.toString() ??
          '';
      final target = _completionAssistantMessage(
        event.data,
        event.data['text']?.toString() ?? text,
      );
      if (target != null) {
        if (text.isNotEmpty) {
          target['content'] = text;
          _timeline = _timeline.textSnapshot(
            target['_normal_projection_id']!,
            text,
            preservePosition:
                event.data['response_previewed'] == true ||
                event.data['response_reused'] == true ||
                event.data['response_transformed'] == true,
          );
        }
        target['_gateway_pending_response'] = false;
      }
    } else if (event.type.startsWith('tool.')) {
      final update = GatewayToolActivity.fromGatewayEvent(
        event.type,
        event.data,
        observedAt: DateTime.now(),
      );
      if (update != null) {
        var index = update.toolId == null
            ? -1
            : _tools.indexWhere((tool) => tool.toolId == update.toolId);
        if (index < 0) {
          index = _tools.lastIndexWhere(
            (tool) =>
                !tool.isTerminal &&
                (update.toolId == null || tool.toolId == null) &&
                tool.name.toLowerCase() == update.name.toLowerCase(),
          );
        }
        if (index < 0) {
          _tools.add(update);
        } else {
          _tools[index] = _tools[index].merge(update);
        }
        final activity = index < 0 ? _tools.last : _tools[index];
        if (assistant != null) {
          _timeline = _timeline.tool(
            assistant['_normal_projection_id']!,
            activity,
          );
          _tools.removeWhere(
            (tool) =>
                tool.identity == activity.identity &&
                !_timeline.runs.any(
                  (run) => run.activity?.identity == tool.identity,
                ),
          );
        }
        if (_tools.length > 512) _tools.removeAt(0);
      }
    } else if (event.type.startsWith('subagent.')) {
      final update = GatewaySubagentActivity.fromGatewayEvent(
        event.type,
        event.data,
      );
      if (update != null) {
        final index = _subagents.indexWhere((agent) => agent.id == update.id);
        if (index < 0) {
          _subagents.add(update);
        } else {
          _subagents[index] = _subagents[index].merge(update);
        }
        if (_subagents.length > 128) _subagents.removeAt(0);
      }
    } else {
      _status =
          GatewayTurnStatus.fromGatewayEvent(event.type, event.data) ?? _status;
    }
    // Bound transient memory, but never turn a truncated projection into
    // canonical history. The server remains the only transcript authority.
    if (_display.length > 256) _display.removeRange(1, _display.length - 255);
    for (final row in _display) {
      for (final key in ['content', '_gateway_reasoning']) {
        final value = row[key];
        if (value is String && value.length > 262144) {
          row[key] = value.substring(value.length - 262144);
        }
      }
    }
    _timeline = _timeline.retainScopes(
      [
        ..._priorDisplay,
        ..._display,
      ].map((row) => row['_normal_projection_id']).whereType<String>(),
    );
    final failure = _failure(event.data);
    _tools.removeWhere(_timeline.excludesTool);
    final ownedLifecycleTerminal =
        wireTurn != null &&
        wireTurn == _wireTurnId &&
        const {'turn.end', 'turn.error'}.contains(event.type);
    if (ownedLifecycleTerminal &&
        (event.type == 'turn.error' || failure != null)) {
      unawaited(
        _settle(
          false,
          failure ?? event.data['message']?.toString() ?? 'Gateway turn failed',
        ),
      );
    } else if (ownedLifecycleTerminal) {
      unawaited(_settle(true, null));
    } else if (terminal) {
      // Stock message.complete precedes running=false (prompt_turn.py), and
      // stock does not promise turn.end. Neither an ID-less trailing bookend
      // nor a message completion proves the admitted lifecycle is settled.
      // Resume/history are the authority; never infer ownership from arrival.
      requestRecovery();
    }
    _notify();
  }

  Map<String, dynamic>? _completionAssistantMessage(
    Map<String, dynamic> data,
    String rawCompleteText,
  ) {
    final pendingIndex = _display.lastIndexWhere(
      (message) => message['role'] == 'assistant',
    );
    if (pendingIndex < 0) return null;
    final pending = _display[pendingIndex];
    if (pending['_gateway_pending_response'] != true ||
        (pending['content']?.toString() ?? '').isNotEmpty ||
        pending['_gateway_interim_boundary'] != true) {
      return pending;
    }
    // Flags describe the final response, but do not identify which interim
    // it settles. Only an exact raw-text match may consume a sealed interim.
    if (data['response_previewed'] != true &&
        data['response_transformed'] != true &&
        data['response_reused'] != true) {
      return pending;
    }
    if (rawCompleteText.isEmpty) return pending;

    // A completion settles a matching preview from this turn, not the empty
    // bubble prepared for a continuation or distinct interim commentary.
    for (var index = pendingIndex - 1; index >= 0; index--) {
      final candidate = _display[index];
      if (candidate['role'] == 'user') break;
      if (candidate['role'] != 'assistant' ||
          candidate['_gateway_interim'] != true ||
          candidate['content'] != rawCompleteText) {
        continue;
      }
      final pendingReasoning = pending['_gateway_reasoning']?.toString() ?? '';
      if (pendingReasoning.isNotEmpty) {
        final currentReasoning =
            candidate['_gateway_reasoning']?.toString() ?? '';
        candidate['_gateway_reasoning'] = GatewayReasoningUpdate(
          text: pendingReasoning,
          mode: pending['_gateway_reasoning_replaces'] == true
              ? GatewayReasoningEventMode.replace
              : GatewayReasoningEventMode.append,
          verbose: pending['_gateway_reasoning_verbose'] == true,
        ).applyTo(currentReasoning);
        candidate['_gateway_reasoning_verbose'] =
            pending['_gateway_reasoning_verbose'] == true;
      }
      _timeline = _timeline.reassignScope(
        pending['_normal_projection_id']!,
        candidate['_normal_projection_id']!,
        replaceReasoning: pending['_gateway_reasoning_replaces'] == true,
      );
      _display.removeAt(pendingIndex);
      candidate.remove('_gateway_interim');
      return candidate;
    }
    return pending;
  }

  void requestRecovery() {
    if (!snapshot.hasActiveTurn ||
        (!wireEmitted && _terminalReceipt == null) ||
        _settling ||
        !_session._canRecover) {
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = null;
    _recoveryQueued = true;
    if (!_recovering) unawaited(_recover());
  }

  Future<void> _recover() async {
    if (_recovering || !_session._canRecover) return;
    _recovering = true;
    _recoveryQueued = false;
    final generation = _generation;

    try {
      final terminal = _terminalReceipt;
      if (terminal != null && terminal.generation == generation) {
        await _settle(
          terminal.completed,
          terminal.error,
          generation: generation,
        );
        return;
      }
      final stored = storedSessionId;
      if (stored == null) return; // no safe recovery without a durable identity
      // Recovery may attach while the submit wait is pending, but that read
      // cannot become settlement authority merely by arriving after the ACK.
      // Generation plus this immutable observation boundary identify its epoch.
      final submissionWasPending = _submissionPending;
      final resumed = await (_session.client == null
          ? _session._resume(
              localSessionId: localSessionId,
              storedSessionId: stored,
            )
          : _session.client!.resumeSubmittedSession(
              localSessionId: localSessionId,
              storedSessionId: stored,
              acceptsResult: () =>
                  _current(generation) &&
                  snapshot.hasActiveTurn &&
                  !submissionWasPending &&
                  !_submissionPending,
            ));
      if (!_current(generation) || !snapshot.hasActiveTurn || _settling) return;
      if (!_session._canRecover) return;
      // The submit completion queues a fresh recovery. Never inspect retained
      // errors, idle status or history from a pre-wait observation, even if its
      // response is delivered after this submission's wait has finished.
      if (submissionWasPending || _submissionPending) return;
      final status = (resumed.inflight?['status'] ?? resumed.status)
          ?.toString()
          .toLowerCase();
      final running =
          resumed.running == true ||
          const {'running', 'queued', 'pending', 'streaming'}.contains(status);
      final inactive =
          resumed.running == false ||
          const {'completed', 'complete', 'done', 'idle'}.contains(status);
      final failure = _failure({
        ...?resumed.inflight,
        'status': resumed.inflight?['status'] ?? resumed.status,
      });
      if (!running && failure != null) {
        await _settle(false, failure, generation: generation);
        return;
      }
      final fresh = await _session._history(stored);
      if (!_current(generation) || !snapshot.hasActiveTurn || _settling) return;
      if (!_session._canRecover) return;
      _history = fresh;
      _historyKnown = true;
      // Unknown/running resume state cannot establish that an assistant row is
      // final: Hermes persists interim commentary during an active tool loop.

      if (running) phase = NormalGatewayTurnPhase.running;
      if (inactive &&
          !running &&
          _floor != null &&
          fresh.any((row) => _terminalRow(row, _floor!))) {
        await _settle(true, null, generation: generation);
      } else {
        _notify();
      }
    } catch (_) {
      // A failed resume/history read is unknown, never an empty completion.
    } finally {
      _recovering = false;

      // Old flight A must hand off to a queued generation B, even when A was
      // invalidated by terminal settlement while its read was held.
      if (!_session._closed && _recoveryQueued && _session._canRecover) {
        requestRecovery();
      } else if (snapshot.hasActiveTurn &&
          (wireEmitted || _terminalReceipt != null) &&
          !_settling &&
          _session._canRecover) {
        final shift = (_retry++).clamp(0, 6);
        _retryTimer = Timer(
          Duration(milliseconds: (500 * (1 << shift)).clamp(500, 30000)),
          requestRecovery,
        );
      }
    }
  }

  Future<void> _settle(bool completed, String? error, {int? generation}) async {
    final owned = generation ?? _generation;
    if (!_current(owned) || _settling || !snapshot.hasActiveTurn) return;
    final settledTurnId = turnId;
    final settledSessionId = storedSessionId ?? localSessionId;
    final settledTitle = title;
    _terminalReceipt = (completed: completed, error: error, generation: owned);
    _settling = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    final marker = _marker;
    try {
      if (marker != null) {
        await _session.pendingStore.put(marker.withPhase('settled'));
        if (!_current(owned)) return;
        // A durable tombstone prevents restart from resurrecting this turn if
        // the optional physical removal fails.
        await _session.pendingStore.remove(marker).catchError((Object _) {});
        if (!_current(owned)) return;
      }
      if (!completed &&
          !wireEmitted &&
          _listeners.isEmpty &&
          _draftRestoreAllowed &&
          _draftToRestore != null) {
        await ComposerDraftStore.save(
          connectionId: _session.connection.id,
          sessionId: localSessionId,
          text: _draftToRestore!,
          isCurrent: () =>
              _current(owned) &&
              _draftRestoreAllowed &&
              _listeners.isEmpty &&
              _session.presentation?.isClosed != true,
        );
        if (!_current(owned)) return;
      }
      phase = completed
          ? NormalGatewayTurnPhase.completed
          : NormalGatewayTurnPhase.failed;
      if (_wireTurnId != null) {
        _settledWireTurnIds.add(_wireTurnId!);
        if (_settledWireTurnIds.length > 32) {
          _settledWireTurnIds.remove(_settledWireTurnIds.first);
        }
      }
      if (!wireEmitted) {
        _display.clear();
        _timeline = _timeline.retainScopes(
          _priorDisplay
              .map((row) => row['_normal_projection_id'])
              .whereType<String>(),
        );
      }
      final canonical =
          completed &&
          _floor != null &&
          _history.any((row) => _terminalRow(row, _floor!));
      if (canonical) {
        _display.clear();
        _priorDisplay.clear();
        _timeline = _timeline.clear();
        _tools.clear();
        _subagents.clear();
      }
      _error = error;
      _status = null;
      _pendingInput.clear();
      if (wireEmitted) {
        _session.client?.forgetSettledServerRequestsForSession(localSessionId);
      }
      for (final row in _display) {
        row['_gateway_pending_response'] = false;
      }
      _marker = null;
      _terminalReceipt = null;
      _settling = false;
      _notify();
      if (!canonical && wireEmitted) unawaited(_refreshSettledHistory(owned));
      if (_session._background && settledTurnId != null) {
        final kind = completed
            ? HermesNotificationKind.turnDone
            : HermesNotificationKind.turnError;
        if (notificationKindEnabled(kind)) {
          await _session.notifications.showKind(
            kind: kind,
            title: completed ? 'Hermes response ready' : 'Hermes turn failed',
            body: settledTitle,
            eventId: settledTurnId,
            sessionId: settledSessionId,
            connectionId: _session.connection.id,
            payload: jsonEncode({
              'sessionId': settledSessionId,
              'connectionId': _session.connection.id,
              'turnId': settledTurnId,
            }),
          );
        }
      }
    } catch (_) {
      if (_current(owned) && snapshot.hasActiveTurn) {
        phase = NormalGatewayTurnPhase.reconciling;
        _notify();
      }
    } finally {
      if (_current(owned)) {
        _settling = false;
        if (snapshot.hasActiveTurn) requestRecovery();
      }
    }
  }

  void _notifyAuxiliary(StreamEvent event) {
    if (!_session._background) return;
    final notification = event.type == 'notification.show'
        ? GatewayNotification.fromEventData(event.data)
        : null;
    final notice = GatewayNotice.fromGatewayEvent(event.type, event.data);
    if (notification == null && notice == null) return;
    final kind = notification != null
        ? (notification.key.startsWith('credits.')
              ? HermesNotificationKind.credits
              : HermesNotificationKind.plugin)
        : (notice!.kind == GatewayNoticeKind.background
              ? HermesNotificationKind.backgroundDone
              : HermesNotificationKind.plugin);
    unawaited(
      _session.notifications
          .showKind(
            kind: kind,
            title: 'Hermes — $title',
            body: notification?.text ?? notice!.text,
            eventId: notification?.key ?? notice!.identity,
            sessionId: storedSessionId ?? localSessionId,
            connectionId: _session.connection.id,
            payload: jsonEncode({
              'sessionId': storedSessionId ?? localSessionId,
              'connectionId': _session.connection.id,
            }),
          )
          .catchError((Object _) => false),
    );
  }

  void _notifyAttention(StreamEvent event, String requestId) {
    if (!_session._background) return;
    final approval = event.type == 'approval.request';
    unawaited(
      _session.notifications
          .showKind(
            kind: approval
                ? HermesNotificationKind.approval
                : HermesNotificationKind.input,
            title: approval
                ? 'Approval needed — $title'
                : 'Input needed — $title',
            // Sensitive request text and secrets never enter a notification.
            body: approval
                ? 'Open the chat to review the requested action.'
                : 'Open the chat to respond.',
            eventId: requestId,
            sessionId: storedSessionId ?? localSessionId,
            connectionId: _session.connection.id,
            actions: approval
                ? const [
                    TurnNotificationAction(id: 'approve', label: 'Approve'),
                    TurnNotificationAction(id: 'reject', label: 'Deny'),
                  ]
                : const [],
            payload: jsonEncode({
              'sessionId': storedSessionId ?? localSessionId,
              'connectionId': _session.connection.id,
              'requestId': requestId,
            }),
          )
          .catchError((Object _) => false),
    );
  }

  Future<void> _refreshSettledHistory(int generation) async {
    final stored = storedSessionId;
    if (stored == null) return;
    try {
      final fresh = await _session._history(stored);
      if (!_current(generation) || snapshot.hasActiveTurn) return;
      _historyKnown = true;
      _history = fresh;
      // An old/empty sliding page must not erase the received final response.
      _retireCompletedProjection(fresh);
      if (_unmaterializedSubmissionVisible(fresh)) {
        _display.clear();
        _priorDisplay.clear();
      }
      _notify();
    } catch (_) {
      /* keep the received final response */
    }
  }

  bool _unmaterializedSubmissionVisible(List<Map<String, dynamic>> fresh) {
    // Compatibility for a correlated lifecycle that supplied no streamed
    // presentation at all while initial history was pending. Deduplicate its
    // empty optimistic submission only; there is no reply/tool/reasoning here
    // to retire. Never use text matching for active-turn settlement or to
    // discard any materialized presentation when its durable floor is unknown.
    if (phase != NormalGatewayTurnPhase.completed ||
        _floor != null ||
        _wireTurnId == null ||
        _timeline.runs.isNotEmpty ||
        _tools.isNotEmpty ||
        _subagents.isNotEmpty ||
        _display.isEmpty) {
      return false;
    }
    final optimistic = [..._priorDisplay, ..._display];
    if (optimistic.any(
      (row) =>
          row['role'] != 'user' &&
          ((row['content']?.toString().isNotEmpty ?? false) ||
              (row['_gateway_reasoning']?.toString().isNotEmpty ?? false)),
    )) {
      return false;
    }
    final users = optimistic.where((row) => row['role'] == 'user').toList();
    final canonicalUsers = fresh.where((row) => row['role'] == 'user').toList();
    if (users.isEmpty || canonicalUsers.length < users.length) return false;
    final tail = canonicalUsers
        .skip(canonicalUsers.length - users.length)
        .toList();
    for (var i = 0; i < users.length; i++) {
      if (users[i]['content'] != tail[i]['content']) return false;
    }
    final lastUser = fresh.lastIndexWhere((row) => row['role'] == 'user');
    return fresh
        .skip(lastUser + 1)
        .any(
          (row) =>
              const {'assistant', 'agent'}.contains(row['role']) &&
              (row['content']?.toString().isNotEmpty ?? false),
        );
  }

  void _close() {
    _generation++;
    _retryTimer?.cancel();
    _baselineTimer?.cancel();
    final baseline = _baselineRead;
    if (baseline != null && !baseline.isCompleted) baseline.complete(null);
    _listeners.clear();
    _pendingInput.clear();
  }
}

bool _interactive(String type) => const {
  'approval.request',
  'clarify.request',
  'clarify.remaining',
  'sudo.request',
  'secret.request',
  'sudo.expire',
  'secret.expire',
  'request.cancel',
}.contains(type);

int? _numericFloor(List<Map<String, dynamic>> rows) {
  var floor = 0;
  for (final row in rows) {
    final id = row['id'];
    final value = id is int ? id : int.tryParse(id?.toString() ?? '');
    if (value == null || value < 0) return null;
    if (value > floor) floor = value;
  }
  return floor;
}

bool _terminalRow(Map<String, dynamic> row, int floor) {
  final id = int.tryParse(row['id']?.toString() ?? '');
  final role = row['role'];
  return id != null &&
      id > floor &&
      (role == 'assistant' || role == 'agent') &&
      (row['tool_calls'] == null ||
          row['tool_calls'] is List && (row['tool_calls'] as List).isEmpty) &&
      row['tool_call_id'] == null &&
      row['_gateway_interim'] != true &&
      row['interim'] != true &&
      row['is_interim'] != true &&
      row['finish_reason'] != 'tool_calls' &&
      (row['content']?.toString().trim().isNotEmpty ?? false);
}

String? _failure(Map<String, dynamic> state) {
  final status = state['status']?.toString().toLowerCase();
  final error = state['error']?.toString().trim() ?? '';
  if (error.isNotEmpty) return error;
  if (const {
    'error',
    'failed',
    'interrupted',
    'cancelled',
    'canceled',
  }.contains(status)) {
    return state['message']?.toString() ?? 'Gateway turn $status';
  }
  return null;
}
