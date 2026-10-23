import 'gateway_activity.dart';
import 'gateway_insight.dart';

enum ChatTimelineKind { text, reasoning, tool }

/// A presentation reference, never a synthetic conversation/history row.
class ChatTimelineRun {
  const ChatTimelineRun({
    required this.id,
    required this.scope,
    required this.kind,
    this.text = '',
    this.verbose = false,
    this.activity,
  });

  final String id;
  final Object scope;
  final ChatTimelineKind kind;
  final String text;
  final bool verbose;
  final GatewayToolActivity? activity;

  ChatTimelineRun _copy({
    Object? scope,
    String? text,
    bool? verbose,
    GatewayToolActivity? activity,
  }) => ChatTimelineRun(
    id: id,
    scope: scope ?? this.scope,
    kind: kind,
    text: text ?? this.text,
    verbose: verbose ?? this.verbose,
    activity: activity ?? this.activity,
  );
}

/// Pure receipt-ordered reducer for transports that actually expose chronology.
///
/// Scopes are canonical assistant-row identities owned by the caller. Text and
/// reasoning never enter request history through this model. Updates retain the
/// first-appearance position; only adjacent *new* tools form a batch. Histories
/// without receipt chronology should use their durable row ordering instead.
class ChatTimeline {
  const ChatTimeline._(
    this.runs,
    this._nextId,
    this.scopes,
    this._evictedTools,
    this._tombstonesSaturated,
  );
  const ChatTimeline()
    : runs = const [],
      _nextId = 0,
      scopes = const {},
      _evictedTools = const {},
      _tombstonesSaturated = false;

  static const maxRuns = 1024;
  static const maxTextCodeUnits = 1048576;
  // Identity-only tombstones are bounded too. Once saturated, unmatched late
  // terminals cannot safely be distinguished from completed-only first receipts.
  static const maxEvictedTools = 1024;

  final List<ChatTimelineRun> runs;
  final int _nextId;
  final Set<Object> scopes;
  final Set<String> _evictedTools;
  final bool _tombstonesSaturated;

  /// Drop optimistic references on durable hydration, without reusing card IDs.
  ChatTimeline clear() =>
      ChatTimeline._(const [], _nextId, const {}, const {}, false);

  /// Keep only retained presentation anchors. This is a bounded live view, not
  /// a transcript: durable history is always the authority after hydration.
  ChatTimeline retainScopes(Iterable<Object> scopes) {
    final retained = scopes.toSet();
    final (tombstones, saturated) = _rememberEvictions(
      runs.where((run) => !retained.contains(run.scope)),
    );
    return ChatTimeline._(
      List.unmodifiable(runs.where((run) => retained.contains(run.scope))),
      _nextId,
      Set.unmodifiable(this.scopes.intersection(retained)),
      // Dropping a scope anchor is not durable hydration. Its late tool
      // completion still must not become a new run under the current scope.
      tombstones,
      saturated,
    );
  }

  bool excludesTool(GatewayToolActivity activity) =>
      _evictedTools.contains(activity.identity);

  (Set<String>, bool) _rememberEvictions(Iterable<ChatTimelineRun> removed) {
    final tombstones = {..._evictedTools};
    var saturated = _tombstonesSaturated;
    for (final run in removed) {
      if (run.kind != ChatTimelineKind.tool ||
          tombstones.contains(run.activity!.identity)) {
        continue;
      }
      if (tombstones.length < maxEvictedTools) {
        tombstones.add(run.activity!.identity);
      } else {
        saturated = true;
      }
    }
    return (Set.unmodifiable(tombstones), saturated);
  }

  ChatTimeline _with(List<ChatTimelineRun> next, {bool inserted = false}) {
    final ownedScopes = {...scopes, ...next.map((r) => r.scope)};
    final excess = next.length > maxRuns ? next.length - maxRuns : 0;
    final (tombstones, saturated) = _rememberEvictions(next.take(excess));
    if (next.length > maxRuns) {
      next = next.sublist(next.length - maxRuns);
    }
    var budget = maxTextCodeUnits;
    final bounded = <ChatTimelineRun>[];
    for (final run in next.reversed) {
      if (run.kind == ChatTimelineKind.tool) {
        bounded.add(run);
      } else if (budget > 0) {
        final text = run.text.length > budget
            ? run.text.substring(run.text.length - budget)
            : run.text;
        budget -= text.length;
        bounded.add(run._copy(text: text));
      }
    }
    return ChatTimeline._(
      List.unmodifiable(bounded.reversed),
      _nextId + (inserted ? 1 : 0),
      Set.unmodifiable(ownedScopes),
      tombstones,
      saturated,
    );
  }

  Iterable<ChatTimelineRun> forScope(Object scope) =>
      runs.where((run) => run.scope == scope);

  ChatTimeline appendText(Object scope, String token) {
    if (token.isEmpty) return this;
    final next = [...runs];
    if (next.isNotEmpty &&
        next.last.scope == scope &&
        next.last.kind == ChatTimelineKind.text) {
      next[next.length - 1] = next.last._copy(text: next.last.text + token);
      return _with(next);
    }
    next.add(
      ChatTimelineRun(
        id: 'timeline:$_nextId',
        scope: scope,
        kind: ChatTimelineKind.text,
        text: token,
      ),
    );
    return _with(next, inserted: true);
  }

  ChatTimeline reasoning(Object scope, GatewayReasoningUpdate update) {
    final scoped = forScope(
      scope,
    ).where((r) => r.kind == ChatTimelineKind.reasoning);
    final current = scoped.map((r) => r.text).join();
    final snapshot = update.applyTo(current);
    if (update.mode == GatewayReasoningEventMode.replace) {
      // An identical full snapshot confirms the observed sub-run boundaries.
      // A rewrite replaces the scoped content, never appends a duplicate card.
      if (snapshot == current) {
        return _with([
          for (final run in runs)
            if (run.scope == scope && run.kind == ChatTimelineKind.reasoning)
              run._copy(verbose: update.verbose)
            else
              run,
        ]);
      }
      return _replaceReasoning(scope, snapshot, update.verbose);
    }
    if (!snapshot.startsWith(current)) {
      // The reasoning size cap can rewrite the final character to an ellipsis.
      return _replaceReasoning(scope, snapshot, update.verbose);
    }
    final delta = snapshot.substring(current.length);
    if (delta.isEmpty) return this;
    final next = [...runs];
    if (next.isNotEmpty &&
        next.last.scope == scope &&
        next.last.kind == ChatTimelineKind.reasoning) {
      next[next.length - 1] = next.last._copy(
        text: next.last.text + delta,
        verbose: update.verbose,
      );
      return _with(next);
    }
    next.add(
      ChatTimelineRun(
        id: 'timeline:$_nextId',
        scope: scope,
        kind: ChatTimelineKind.reasoning,
        text: delta,
        verbose: update.verbose,
      ),
    );
    return _with(next, inserted: true);
  }

  ChatTimeline _replaceReasoning(Object scope, String text, bool verbose) {
    final index = runs.indexWhere(
      (run) => run.scope == scope && run.kind == ChatTimelineKind.reasoning,
    );
    if (index < 0) {
      return _with([
        ...runs,
        ChatTimelineRun(
          id: 'timeline:$_nextId',
          scope: scope,
          kind: ChatTimelineKind.reasoning,
          text: text,
          verbose: verbose,
        ),
      ], inserted: true);
    }
    return _with([
      for (var i = 0; i < runs.length; i++)
        if (i == index)
          runs[i]._copy(text: text, verbose: verbose)
        else if (runs[i].scope != scope ||
            runs[i].kind != ChatTimelineKind.reasoning)
          runs[i],
    ]);
  }

  ChatTimeline tool(Object scope, GatewayToolActivity update) {
    final index = runs.indexWhere(
      (run) =>
          run.kind == ChatTimelineKind.tool &&
          (run.activity!.identity == update.identity ||
              update.toolId != null && run.activity!.toolId == update.toolId),
    );
    final next = [...runs];
    if (index >= 0) {
      next[index] = next[index]._copy(
        activity: next[index].activity!.merge(update),
      );
      return _with(next);
    }
    if (excludesTool(update) || (_tombstonesSaturated && update.isTerminal)) {
      return this;
    }
    next.add(
      ChatTimelineRun(
        id: update.identity,
        scope: scope,
        kind: ChatTimelineKind.tool,
        activity: update,
      ),
    );
    return _with(next);
  }

  /// Complete/interim text is a snapshot, not another delta. Keep known run
  /// boundaries for unchanged/prefix snapshots. An arbitrary rewrite has no
  /// trustworthy sub-run chronology: replace prose at its original anchor,
  /// rather than appending a second copy or guessing a split in the rewrite.
  ChatTimeline textSnapshot(
    Object scope,
    String text, {
    bool preservePosition = false,
  }) {
    final indices = [
      for (var i = 0; i < runs.length; i++)
        if (runs[i].scope == scope && runs[i].kind == ChatTimelineKind.text) i,
    ];
    final current = indices.map((i) => runs[i].text).join();
    if (text == current) return this;
    if (preservePosition && indices.isNotEmpty && text.startsWith(current)) {
      final next = [...runs];
      final last = indices.last;
      next[last] = next[last]._copy(
        text: next[last].text + text.substring(current.length),
      );
      return _with(next);
    }
    if (text.startsWith(current)) {
      return appendText(scope, text.substring(current.length));
    }
    if (indices.isEmpty) return appendText(scope, text);
    return _with([
      for (var i = 0; i < runs.length; i++)
        if (i == indices.first)
          runs[i]._copy(text: text)
        else if (!indices.contains(i))
          runs[i],
    ]);
  }

  /// A preview completion can consume an empty interim continuation. Append
  /// reasoning transfers ownership only: its receipt runs and IDs stay intact.
  /// An explicit replacement snapshot still replaces the earlier scoped content.
  ChatTimeline reassignScope(
    Object from,
    Object to, {
    bool replaceReasoning = false,
  }) {
    if (from == to) return this;
    var next = this;
    final sourceReasoning = forScope(
      from,
    ).where((r) => r.kind == ChatTimelineKind.reasoning).toList();
    final targetReasoning = forScope(
      to,
    ).where((r) => r.kind == ChatTimelineKind.reasoning).toList();
    if (replaceReasoning &&
        sourceReasoning.isNotEmpty &&
        targetReasoning.isNotEmpty) {
      final merged = GatewayReasoningUpdate(
        text: sourceReasoning.map((r) => r.text).join(),
        mode: GatewayReasoningEventMode.replace,
        verbose: sourceReasoning.last.verbose,
      ).applyTo(targetReasoning.map((r) => r.text).join());
      next = next._replaceReasoning(to, merged, sourceReasoning.last.verbose);
      next = next._with(
        next.runs
            .where(
              (r) => r.scope != from || r.kind != ChatTimelineKind.reasoning,
            )
            .toList(),
      );
    }
    next = ChatTimeline._(
      next.runs,
      next._nextId,
      Set.unmodifiable({...next.scopes.where((scope) => scope != from), to}),
      next._evictedTools,
      next._tombstonesSaturated,
    );
    return next._with([
      for (final run in next.runs)
        if (run.scope == from) run._copy(scope: to) else run,
    ]);
  }
}
