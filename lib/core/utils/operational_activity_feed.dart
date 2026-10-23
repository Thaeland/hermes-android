/// Combines observed turn outcomes with honest server activity hints.
library;

import '../l10n/l10n.dart';
import '../models/session.dart';
import '../services/operational_activity_store.dart';
import '../theme/hermes_theme.dart';
import 'activity_feed.dart';

ActivityFeed buildOperationalActivityFeed({
  required ActivityFeed journalFeed,
  required Iterable<OperationalActivityRecord> records,
  required Iterable<Session> sessions,
  required DateTime now,
  required AppLocalizations l10n,
  int groupLimit = kActivityGroupLimit,
}) {
  if (groupLimit <= 0) throw ArgumentError.value(groupLimit, 'groupLimit');
  final buckets = <ActivityGroupKind, List<ActivityItem>>{
    for (final kind in ActivityGroupKind.values) kind: [],
  };
  final knownSessions = <String>{};
  final knownTurns = <String>{};
  for (final group in journalFeed.groups) {
    buckets[group.kind]!.addAll(group.items);
    for (final item in group.items) {
      knownSessions.add(item.sessionId);
      knownTurns.add(item.clientTurnId);
      if (item.turnId != null) knownTurns.add(item.turnId!);
    }
  }
  final sessionRows = sessions.toList(growable: false);
  final byId = <String, Session>{
    for (final session in sessionRows) session.id: session,
    for (final session in sessionRows)
      if (session.lineageRootId != null) session.lineageRootId!: session,
  };
  final floor = now.subtract(kActivityCompletedWindow).millisecondsSinceEpoch;
  for (final record in records) {
    if (knownTurns.contains(record.turnId)) continue;
    // Unresolved work must remain discoverable, even after a long outage.
    final unresolved = const {
      OperationalActivityState.submitted,
      OperationalActivityState.running,
      OperationalActivityState.needsInput,
      OperationalActivityState.reconciling,
    }.contains(record.state);
    if (!unresolved && record.updatedAtEpochMs < floor) continue;
    final session = byId[record.storedSessionId] ?? byId[record.localSessionId];
    final sessionId =
        session?.id ?? record.storedSessionId ?? record.localSessionId;
    knownSessions.addAll([
      sessionId,
      record.localSessionId,
      if (record.storedSessionId != null) record.storedSessionId!,
    ]);
    knownTurns.add(record.turnId);
    var (kind, status, label) = switch (record.state) {
      OperationalActivityState.submitted => (
        ActivityGroupKind.running,
        HermesStatus.running,
        l10n.submitted_waiting_for_hermes,
      ),
      OperationalActivityState.running => (
        ActivityGroupKind.running,
        HermesStatus.running,
        l10n.status_running,
      ),
      OperationalActivityState.needsInput => (
        ActivityGroupKind.needsYou,
        HermesStatus.blocked,
        l10n.waiting_for_your_input,
      ),
      OperationalActivityState.reconciling => (
        ActivityGroupKind.unconfirmed,
        HermesStatus.idle,
        l10n.activity_reconnecting,
      ),
      OperationalActivityState.unknown => (
        ActivityGroupKind.unconfirmed,
        HermesStatus.idle,
        l10n.activity_outcome_unknown,
      ),
      OperationalActivityState.completed => (
        ActivityGroupKind.completed,
        HermesStatus.completed,
        l10n.status_completed,
      ),
      OperationalActivityState.failed => (
        ActivityGroupKind.failed,
        HermesStatus.failed,
        l10n.the_turn_failed,
      ),
    };
    // An old local running receipt is not proof the server is still running.
    if ((record.state == OperationalActivityState.running ||
            record.state == OperationalActivityState.submitted) &&
        now.millisecondsSinceEpoch - record.updatedAtEpochMs >
            kActivityRunningStaleAfter.inMilliseconds) {
      kind = ActivityGroupKind.unconfirmed;
      status = HermesStatus.idle;
      label = l10n.activity_outcome_unknown;
    }
    buckets[kind]!.add(
      ActivityItem(
        sessionId: sessionId,
        clientTurnId: record.turnId,
        turnId: record.turnId,
        title: session?.title,
        label: label,
        status: status,
        statusLabel: kind == ActivityGroupKind.unconfirmed
            ? l10n.activity_status_unconfirmed
            : null,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(record.updatedAtEpochMs),
      ),
    );
  }
  for (final session in sessionRows) {
    if (session.isLocalDraft ||
        session.messageCount <= 0 ||
        knownSessions.contains(session.id) ||
        knownSessions.contains(session.lineageRootId)) {
      continue;
    }
    final seconds = session.lastActive > 0
        ? session.lastActive
        : session.startedAt;
    if (!seconds.isFinite || seconds <= 0) continue;
    final at = (seconds * 1000).round();
    if (at < floor) continue;
    knownSessions.add(session.id);
    buckets[ActivityGroupKind.recentlyUpdated]!.add(
      ActivityItem(
        sessionId: session.id,
        clientTurnId: 'session-update:${session.id}',
        title: session.title,
        label: l10n.activity_chat_updated_detail,
        status: HermesStatus.idle,
        statusLabel: l10n.activity_updated,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
      ),
    );
  }
  final groups = <ActivityGroup>[];
  for (final kind in ActivityGroupKind.values) {
    final items = buckets[kind]!;
    if (items.isEmpty) continue;
    items.sort((a, b) {
      final time = b.updatedAt.compareTo(a.updatedAt);
      return time != 0 ? time : a.clientTurnId.compareTo(b.clientTurnId);
    });
    groups.add(
      ActivityGroup(
        kind: kind,
        items: List.unmodifiable(items.take(groupLimit)),
        totalCount: items.length,
      ),
    );
  }
  return ActivityFeed(
    groups: List.unmodifiable(groups),
    blockedCount: buckets[ActivityGroupKind.needsYou]!.length,
    runningCount: buckets[ActivityGroupKind.running]!.length,
  );
}
