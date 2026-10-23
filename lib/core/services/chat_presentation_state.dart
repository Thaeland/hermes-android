import 'dart:async';

import 'composer_draft_store.dart';
import 'tool_activity_group_pins.dart';

typedef ComposerDraftReader =
    Future<String?> Function({
      required String connectionId,
      required String sessionId,
    });

/// Connection-configuration lifetime, owned by the application, not a route.
/// No transcript, credentials, or pending-turn receipt is kept here.
class ChatPresentationRegistry {
  ChatPresentationRegistry(this.connectionId);

  final String connectionId;
  final Map<String, ChatPresentationState> _aliases = {};
  int _intent = 0;
  bool _closed = false;
  bool get isClosed => _closed;

  ChatPresentationState chatFor(String id) {
    if (_closed) throw StateError('Chat presentation registry is closed.');
    return (_aliases[id] ??= ChatPresentationState._(this, id))._root;
  }

  void bind(String local, String stored) {
    final source = chatFor(local);
    final target = _aliases[stored]?._root;
    if (target != null && !identical(source, target)) {
      // Existing leases follow the redirect. The most recent explicit intent
      // wins, not whichever asynchronous migration/read happens to finish last.
      if (source._edit > target._edit) {
        target
          .._text = source._text
          .._edit = source._edit;
      }
      if (source._authority > target._authority) {
        target
          .._writer = source._writer
          .._authority = source._authority
          .._writerClosed = source._writerClosed;
      }
      target._reasoningPins.mergeMissingFrom(source._reasoningPins);
      target._toolPins.mergeMissingFrom(source._toolPins);
      source._redirect = target;
    }
    final state = target ?? source;
    final changed = state._sessionId != stored;
    state._sessionId = stored;
    _aliases[local] = state;
    _aliases[stored] = state;
    if (changed || !identical(source, state)) {
      state._binding++;
      if (state._edit == 0) state._text = null;
      state._pendingWrites++;
      unawaited(
        ComposerDraftStore.bind(
              connectionId: connectionId,
              localSessionId: local,
              storedSessionId: stored,
              isCurrent: () => !_closed,
            )
            .then((_) => state._persist())
            .whenComplete(() => state._pendingWrites--),
      );
    }
  }

  void close() {
    _closed = true; // Fences leases, held reads and queued migrations together.
    _aliases.clear();
  }
}

class ChatPresentationState {
  ChatPresentationState._(this._registry, this._sessionId);

  final ChatPresentationRegistry _registry;
  String _sessionId;
  ChatPresentationState? _redirect;
  ChatPresentationState get _root => _redirect?._root ?? this;
  final ToolActivityGroupPins _reasoningPins = ToolActivityGroupPins();
  final ToolActivityGroupPins _toolPins = ToolActivityGroupPins();
  ToolActivityGroupPins get reasoningPins => _root._reasoningPins;
  ToolActivityGroupPins get toolPins => _root._toolPins;
  String? _text;
  int _edit = 0;
  int _authority = 0;
  int _binding = 0;
  Object? _writer;
  bool _writerClosed = true;
  int _pendingWrites = 0;

  ComposerDraftWriter openWriter() {
    final state = _root;
    // Once a detached writer's checkpoint drains, re-read durable state on
    // the next mount, including writes made by another application embedder.
    if (state._writerClosed && state._pendingWrites == 0) {
      state._text = null;
      state._edit = 0;
    }
    final token = ComposerDraftStore.open(
      connectionId: _registry.connectionId,
      sessionId: state._sessionId,
    );
    state._writer = token;
    state._writerClosed = false;
    state._authority = ++_registry._intent;
    return ComposerDraftWriter._(this, token);
  }

  Future<void> _persist() {
    final state = _root;
    final text = state._text;
    if (text == null || state._edit == 0 || _registry._closed) {
      return Future.value();
    }
    final edit = state._edit;
    final binding = state._binding;
    state._pendingWrites++;
    return (state._writer! as ComposerDraftHandle)
        .save(
          text,
          isCurrent: () =>
              !_registry._closed &&
              identical(state, _root) &&
              edit == state._edit &&
              binding == state._binding,
        )
        .whenComplete(() => state._pendingWrites--);
  }
}

/// Mounting admits a writer; only a subsequent explicit edit can reclaim it.
/// Checkpoints/disposal/restoration never acquire authority from a newer route.
class ComposerDraftWriter {
  ComposerDraftWriter._(this._state, this._token);

  final ChatPresentationState _state;
  final ComposerDraftHandle _token;
  ComposerDraftHandle get draftHandle => _token;
  bool _closed = false;
  ChatPresentationState get _root => _state._root;
  bool get isCurrent =>
      !_closed && !_state._registry._closed && identical(_root._writer, _token);

  Future<String?> read({ComposerDraftReader? reader}) async {
    while (isCurrent) {
      final state = _root;
      if (state._text != null) return state._text;
      final binding = state._binding;
      final edit = state._edit;
      final text = await (reader ?? ComposerDraftStore.read)(
        connectionId: state._registry.connectionId,
        sessionId: state._sessionId,
      );
      if (!isCurrent) return null;
      if (!identical(state, _root) || binding != state._binding) continue;
      if (edit == state._edit) state._text = text ?? '';
      return state._text;
    }
    return null;
  }

  void edit(String text) {
    if (_closed || _state._registry._closed) return;
    final state = _root;
    _token.edited();
    state
      .._writer = _token
      .._writerClosed = false
      .._edit = ++state._registry._intent
      .._authority = state._registry._intent
      .._text = text;
  }

  Future<void> save(String text) {
    if (!isCurrent) return Future.value();
    final state = _root;
    // An untouched route leaving before hydration is not an explicit clear.
    if (state._text == null) return Future.value();
    if (state._text != text) {
      state
        .._edit = ++state._registry._intent
        .._authority = state._registry._intent
        .._text = text;
    }
    return state._persist();
  }

  Future<void> flush() => isCurrent ? _root._persist() : Future.value();

  Future<void> close() {
    final saved = flush();
    if (isCurrent) _root._writerClosed = true;
    _closed = true;
    return saved;
  }
}
