enum BackgroundReportKind { task, process }

/// Display-only server annotation. Neither prose nor a quoted notification
/// header is evidence that a message is an internal report.
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
    if (kind == null || body is! String) return null;

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
}
