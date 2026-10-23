import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/session.dart';
import 'package:hermes_android/core/services/operational_activity_store.dart';
import 'package:hermes_android/core/utils/activity_feed.dart';
import 'package:hermes_android/core/utils/operational_activity_feed.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

import 'support/l10n_test_utils.dart';

void main() {
  final now = DateTime.utc(2026, 10, 23, 10);
  late AppLocalizations l10n;
  setUpAll(() async => l10n = await loadTestL10n());
  const empty = ActivityFeed(groups: [], blockedCount: 0, runningCount: 0);
  Session session(
    String id, {
    int messages = 2,
    int daysAgo = 0,
    String? root,
  }) => Session(
    id: id,
    title: 'Chat $id',
    model: '',
    source: 'cli',
    messageCount: messages,
    isActive: true,
    preview: '',
    startedAt:
        now.subtract(const Duration(days: 90)).millisecondsSinceEpoch / 1000,
    lastActive:
        now.subtract(Duration(days: daysAgo)).millisecondsSinceEpoch / 1000,
    lineageRootId: root,
  );
  OperationalActivityRecord record(
    String turn,
    OperationalActivityState state, {
    int daysAgo = 0,
  }) => OperationalActivityRecord(
    scope: 'scope',
    localSessionId: 'local',
    storedSessionId: 'stored',
    turnId: turn,
    state: state,
    updatedAtEpochMs: now
        .subtract(Duration(days: daysAgo))
        .millisecondsSinceEpoch,
  );
  ActivityFeed feed({
    List<OperationalActivityRecord> records = const [],
    List<Session> sessions = const [],
    int limit = 20,
  }) => buildOperationalActivityFeed(
    journalFeed: empty,
    records: records,
    sessions: sessions,
    now: now,
    l10n: l10n,
    groupLimit: limit,
  );

  test(
    'stock turns populate Activity without a v2 journal and preserve each turn',
    () {
      final result = feed(
        records: [
          record('done-1', OperationalActivityState.completed),
          record('done-2', OperationalActivityState.completed),
          record('blocked', OperationalActivityState.needsInput),
          record('live', OperationalActivityState.running),
          record('bad', OperationalActivityState.failed),
        ],
        sessions: [session('stored')],
      );
      expect(result.groups.map((g) => g.kind), [
        ActivityGroupKind.needsYou,
        ActivityGroupKind.running,
        ActivityGroupKind.failed,
        ActivityGroupKind.completed,
      ]);
      expect(result.groups.expand((g) => g.items).length, 5);
      expect(
        result.groups
            .expand((g) => g.items)
            .every((i) => i.sessionId == 'stored' && i.title == 'Chat stored'),
        isTrue,
      );
      expect(result.blockedCount, 1);
      expect(result.runningCount, 1);
    },
  );

  test(
    'existing server chats immediately show metadata, never invented completion/liveness',
    () {
      final result = feed(
        sessions: [
          session('from-cli'),
          session('empty', messages: 0),
          session('old', daysAgo: 8),
        ],
      );
      expect(result.groups.single.kind, ActivityGroupKind.recentlyUpdated);
      final item = result.groups.single.items.single;
      expect(item.sessionId, 'from-cli');
      expect(item.statusLabel, 'Updated');
      expect(result.runningCount, 0);
      expect(result.blockedCount, 0);
    },
  );

  test(
    'recovering, unknown and stale running receipts are never failed or completed',
    () {
      final result = feed(
        records: [
          record('recover', OperationalActivityState.reconciling),
          record('unknown', OperationalActivityState.unknown),
          record('stale', OperationalActivityState.running, daysAgo: 2),
        ],
      );
      expect(result.groups.single.kind, ActivityGroupKind.unconfirmed);
      expect(result.groups.single.items.length, 3);
      expect(result.runningCount, 0);
    },
  );

  test(
    'finished turns expire, unresolved attention is retained, and overflow is exact',
    () {
      final result = feed(
        records: [
          record('expired', OperationalActivityState.completed, daysAgo: 8),
          record('blocked-1', OperationalActivityState.needsInput, daysAgo: 30),
          record('blocked-2', OperationalActivityState.needsInput),
        ],
        limit: 1,
      );
      expect(result.groups.single.totalCount, 2);
      expect(result.groups.single.overflow, 1);
      expect(result.blockedCount, 2);
    },
  );

  test(
    'compression aliases resolve the visible chat and do not duplicate server fallback',
    () {
      final result = feed(
        records: [record('turn', OperationalActivityState.completed)],
        sessions: [session('tip', root: 'stored')],
      );
      expect(result.groups.single.kind, ActivityGroupKind.completed);
      expect(result.groups.single.items.single.sessionId, 'tip');
    },
  );

  test(
    'duplicate receipt identity produces one row; caps apply after merging',
    () {
      final row = record('turn', OperationalActivityState.completed);
      final result = feed(
        records: [row, row],
        sessions: [session('stored'), session('other')],
        limit: 1,
      );
      expect(result.groups.fold<int>(0, (n, g) => n + g.totalCount), 2);
      expect(result.groups.first.items.single.clientTurnId, 'turn');
    },
  );
}
