import 'dart:math' as math;

enum BackgroundReportKind { task, process }

typedef _TaskListCandidate = ({
  String status,
  bool hasActiveTask,
  int contentLength,
});

/// Display-only background report. Prefer server annotations; legacy standalone
/// todo snapshots need a narrow format fallback because they have no annotation.
/// Quoted headers and mixed human messages are not classified as reports.
class BackgroundReport {
  const BackgroundReport._({
    required this.kind,
    required this.body,
    required this.summary,
    required this.hasIssues,
  });

  final BackgroundReportKind kind;
  final String body;
  final String? summary;
  final bool hasIssues;

  static BackgroundReport? fromMessage(Map<String, dynamic> message) {
    final kind = switch (message['display_kind']) {
      'async_delegation_complete' => BackgroundReportKind.task,
      'process_complete' => BackgroundReportKind.process,
      _ => null,
    };
    final body = message['content'];
    if (body is! String) return null;
    if (kind == null) {
      // Explicit server kinds (including hidden/steer) always take precedence.
      if (message['role'] != 'user' ||
          (message['display_kind'] != null && message['display_kind'] != '') ||
          !_isPreservedTaskList(body)) {
        return null;
      }
      return BackgroundReport._(
        kind: BackgroundReportKind.task,
        body: body,
        summary: null,
        hasIssues: false,
      );
    }

    final metadata = message['display_metadata'];
    final fields = metadata is Map ? metadata : const {};
    final displayText = fields['display_text'];
    // Bound only the preview, never the original body (including whitespace,
    // literal escapes and tool-looking markup).
    final preview = displayText is String
        ? String.fromCharCodes(displayText.runes.take(240)).trim()
        : '';
    final failed = fields['failed_count'];
    final total = fields['task_count'];
    final completed = fields['completed_count'];
    return BackgroundReport._(
      kind: kind,
      body: body,
      summary: preview.isEmpty ? null : preview,
      hasIssues:
          fields['has_issues'] == true ||
          (failed is int && failed > 0) ||
          (total is int &&
              total > 0 &&
              completed is int &&
              completed >= 0 &&
              completed < total),
    );
  }

  static const _taskListHeader =
      '[Your active task list was preserved across context compression]';
  static const _skillReloadHeader =
      '[Skills pruned during compression — reload before acting on these tasks]';
  static final _taskPrefix = RegExp(
    r'^(?:  )*- \[([ >x~])\] [^\r\n]+?\. (?=\S)',
  );
  static final _skillReloadNotice = RegExp(
    '^${RegExp.escape(_skillReloadHeader)}\n'
    r'The task list above crossed the compression boundary verbatim, but '
    r'the skill instructions that governed it were pruned\. Before '
    r'executing any preserved task that depends on these skills, reload '
    r"them first: skill_view\(name='[^'\r\n]+'\)"
    r"(?:; skill_view\(name='[^'\r\n]+'\))*\. After reloading, re-check that each pending "
    r'task is still justified — findings recorded before the boundary may have invalidated it\.$',
  );

  static bool _isPreservedTaskList(String body) {
    if (!body.startsWith('$_taskListHeader\n') &&
        !body.startsWith('$_taskListHeader\r\n')) {
      return false;
    }
    // Parse a copy only. The complete original body stays available on expansion.
    final lines = body.replaceAll('\r\n', '\n').split('\n');
    final noticeIndex = lines.lastIndexOf(_skillReloadHeader);
    if (noticeIndex >= 3 &&
        lines[noticeIndex - 1].isEmpty &&
        _skillReloadNotice.hasMatch(lines.skip(noticeIndex).join('\n'))) {
      lines.removeRange(noticeIndex - 1, lines.length);
    }
    var candidates = <_TaskListCandidate>{};
    var lastLine = '';
    bool completeItem(_TaskListCandidate candidate) {
      final suffix = ' (${candidate.status})';
      return lastLine.endsWith(suffix) &&
          candidate.contentLength > suffix.length;
    }

    for (var index = 1; index < lines.length; index++) {
      final line = lines[index];
      final completed = candidates.where(completeItem).toList();
      // A checkbox-shaped line may be description text, even after a status-like
      // suffix. Keep both readings until the entire snapshot validates. Lengths
      // saturate just beyond each suffix, bounding the candidate set.
      candidates = {
        for (final candidate in candidates)
          (
            status: candidate.status,
            hasActiveTask: candidate.hasActiveTask,
            contentLength: math.min(
              candidate.contentLength + line.length + 1,
              ' (${candidate.status})'.length + 1,
            ),
          ),
      };
      final prefix = _taskPrefix.firstMatch(line);
      if (prefix != null && (index == 1 || completed.isNotEmpty)) {
        final status = switch (prefix.group(1)) {
          '>' => 'in_progress',
          ' ' => 'pending',
          'x' => 'completed',
          _ => 'cancelled',
        };
        candidates.add((
          status: status,
          hasActiveTask:
              status == 'pending' ||
              status == 'in_progress' ||
              completed.any((candidate) => candidate.hasActiveTask),
          contentLength: math.min(
            line.length - prefix.end,
            ' ($status)'.length + 1,
          ),
        ));
      }
      lastLine = line;
    }
    return candidates.any(
      (candidate) => candidate.hasActiveTask && completeItem(candidate),
    );
  }
}
