import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/filing_screen.dart';
import 'package:hermes_android/core/services/filing_gateway_client.dart';

FilingSuggestion _s(
  String sessionId,
  String cwd,
  String projectId, {
  String reason = 'cwd_match',
  double confidence = 0.95,
  String title = 'chat',
}) => FilingSuggestion(
  sessionId: sessionId,
  title: title,
  cwd: cwd,
  projectId: projectId,
  projectName: 'Project $projectId',
  reason: reason,
  confidence: confidence,
);

void main() {
  group('groupFilingSuggestions', () {
    test('empty input yields no groups', () {
      expect(groupFilingSuggestions(const []), isEmpty);
    });

    test('single suggestion becomes a single-session group', () {
      final groups = groupFilingSuggestions([
        _s('s1', '/home/me/work', 'p1'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.sessions, hasLength(1));
      expect(groups.single.cwd, '/home/me/work');
      expect(groups.single.projectName, 'Project p1');
    });

    test('same cwd + project collapses into one bulk group', () {
      // The core invariant: filing.apply is a path→project rule, so N
      // suggestions sharing (cwd, project) are ONE tap, not N.
      final groups = groupFilingSuggestions([
        _s('s1', '/home/me/work', 'p1'),
        _s('s2', '/home/me/work', 'p1'),
        _s('s3', '/home/me/work', 'p1'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.sessions.map((s) => s.sessionId),
          ['s1', 's2', 's3']);
    });

    test('same cwd with different projects stays separate', () {
      final groups = groupFilingSuggestions([
        _s('s1', '/home/me/work', 'p1'),
        _s('s2', '/home/me/work', 'p2'),
      ]);
      expect(groups, hasLength(2));
      expect(groups.map((g) => g.projectId).toSet(), {'p1', 'p2'});
    });

    test('different cwds stay separate', () {
      final groups = groupFilingSuggestions([
        _s('s1', '/home/me/work', 'p1'),
        _s('s2', '/home/me/other', 'p1'),
      ]);
      expect(groups, hasLength(2));
      expect(groups.map((g) => g.cwd).toSet(),
          {'/home/me/work', '/home/me/other'});
    });

    test('a contract_rule outranks cwd_match as the group reason', () {
      final groups = groupFilingSuggestions([
        _s('s1', '/home/me/work', 'p1', reason: 'cwd_match'),
        _s('s2', '/home/me/work', 'p1', reason: 'contract_rule',
            confidence: 1.0),
      ]);
      expect(groups.single.isUserRule, isTrue);
      expect(groups.single.confidence, 1.0);
    });

    test('contract_rule seen first is not downgraded by a later cwd_match',
        () {
      final groups = groupFilingSuggestions([
        _s('s1', '/home/me/work', 'p1', reason: 'contract_rule',
            confidence: 1.0),
        _s('s2', '/home/me/work', 'p1', reason: 'cwd_match'),
      ]);
      expect(groups.single.isUserRule, isTrue);
      expect(groups.single.confidence, 1.0);
    });

    test('groups sort biggest first (biggest filing win per tap)', () {
      final groups = groupFilingSuggestions([
        _s('s1', '/small', 'p1'),
        _s('s2', '/big', 'p2'),
        _s('s3', '/big', 'p2'),
        _s('s4', '/big', 'p2'),
        _s('s5', '/mid', 'p3'),
        _s('s6', '/mid', 'p3'),
      ]);
      expect(groups.map((g) => g.sessions.length), [3, 2, 1]);
      expect(groups.map((g) => g.cwd), ['/big', '/mid', '/small']);
    });
  });
}
