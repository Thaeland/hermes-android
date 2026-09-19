// AI-assisted filing — the correction-aware Projects filing contract.
//
// Talks to the gateway's `filing.*` RPC family (tui_gateway/methods_filing.py):
//   filing.status  — is the contract installed, is the correction hook live
//   filing.suggest — deterministic suggestions (contract rule / cwd match)
//   filing.apply   — accept: record the rule + mirror into projects.db
//   filing.reject  — reject: record an exclusion (+ retroactive unfile)
//   filing.rules   — the policy lists with the recent audit trail
//
// The organizer itself lives on the server; this screen only reviews and
// corrects it. Every accept/reject is a standing contract entry with the
// quoted source, visible under "Contract".

import 'package:flutter/material.dart';

import '../services/connection_manager.dart';
import '../services/desktop_gateway_client.dart';
import '../services/filing_gateway_client.dart';
import '../theme/hermes_theme.dart';
import '../widgets/hermes_components.dart';

class FilingScreen extends StatefulWidget {
  final SavedConnection connection;
  const FilingScreen({required this.connection, super.key});

  @override
  State<FilingScreen> createState() => _FilingScreenState();
}

/// Suggestions that share one (cwd, project) pair. `filing.apply` is a
/// path→project rule, so a whole group collapses to a single apply: one
/// tap files every session in the folder class, not one card's worth.
class FilingGroup {
  final String cwd;
  final String projectId;
  final String projectName;
  final String reason;
  final double confidence;
  final List<FilingSuggestion> sessions;

  const FilingGroup({
    required this.cwd,
    required this.projectId,
    required this.projectName,
    required this.reason,
    required this.confidence,
    required this.sessions,
  });

  bool get isUserRule => reason == 'contract_rule';
}

/// Groups suggestions by (cwd, project), highest-confidence reason first
/// inside each group, groups ordered by size (biggest win first).
List<FilingGroup> groupFilingSuggestions(List<FilingSuggestion> suggestions) {
  final byKey = <String, FilingGroup>{};
  for (final s in suggestions) {
    final key = '${s.cwd}\u0000${s.projectId}';
    final existing = byKey[key];
    if (existing == null) {
      byKey[key] = FilingGroup(
        cwd: s.cwd,
        projectId: s.projectId,
        projectName: s.projectName,
        reason: s.reason,
        confidence: s.confidence,
        sessions: [s],
      );
    } else {
      // A user rule outranks a cwd match as the group's displayed reason.
      final betterReason = s.isUserRule && !existing.isUserRule;
      byKey[key] = FilingGroup(
        cwd: existing.cwd,
        projectId: existing.projectId,
        projectName: existing.projectName,
        reason: betterReason ? s.reason : existing.reason,
        confidence: s.confidence > existing.confidence
            ? s.confidence
            : existing.confidence,
        sessions: [...existing.sessions, s],
      );
    }
  }
  final groups = byKey.values.toList()
    ..sort((a, b) => b.sessions.length.compareTo(a.sessions.length));
  return groups;
}

class _FilingScreenState extends State<FilingScreen> {
  DesktopGatewayClient? _gateway;
  FilingStatus? _status;
  List<FilingSuggestion> _suggestions = const [];
  FilingPolicy? _policy;
  bool _loading = true;
  String? _error;
  bool _unsupported = false;
  final Set<String> _busyCwds = {};

  @override
  void initState() {
    super.initState();
    _open();
  }

  void _open() {
    try {
      _gateway = DesktopGatewayClient.fromConnection(widget.connection);
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
      return;
    }
    _load();
  }

  @override
  void dispose() {
    _gateway?.close();
    super.dispose();
  }

  Future<void> _load() async {
    final client = _gateway?.filing;
    if (client == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await client.status();
      if (!mounted) return;
      setState(() => _status = status);
      if (!status.available) {
        setState(() {
          _loading = false;
          _unsupported = true;
        });
        return;
      }
      final results = await Future.wait([client.suggest(), client.policy()]);
      if (!mounted) return;
      setState(() {
        _suggestions = results[0] as List<FilingSuggestion>;
        _policy = results[1] as FilingPolicy;
        _loading = false;
        _unsupported = false;
      });
    } on FilingUnsupportedException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unsupported = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Bulk accept: one tap files the whole folder class. `filing.apply`
  /// records a path→project rule, so applying it once covers every session
  /// sharing this cwd — current and future — instead of one call per chat.
  Future<void> _acceptGroup(FilingGroup group) async {
    final client = _gateway?.filing;
    if (client == null || _busyCwds.contains(group.cwd)) return;
    setState(() => _busyCwds.add(group.cwd));
    try {
      final note =
          await client.apply(path: group.cwd, project: group.projectName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${group.sessions.length} chats — $note')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not apply: $e')));
    } finally {
      if (mounted) setState(() => _busyCwds.remove(group.cwd));
    }
  }

  /// Bulk reject: one exclusion covers the whole folder class — the
  /// contract is path-keyed, and the retroactive unfile runs server-side.
  Future<void> _rejectGroup(FilingGroup group) async {
    final client = _gateway?.filing;
    if (client == null || _busyCwds.contains(group.cwd)) return;
    setState(() => _busyCwds.add(group.cwd));
    try {
      final note =
          await client.reject(path: group.cwd, project: group.projectName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${group.sessions.length} chats — $note')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not record: $e')));
    } finally {
      if (mounted) setState(() => _busyCwds.remove(group.cwd));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: const Text('AI-assisted filing'),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(tokens),
    );
  }

  Widget _buildBody(HermesTokens tokens) {
    if (_loading) {
      return const Center(child: LoadingSkeleton(rows: 4));
    }
    if (_error != null) {
      return ErrorState(
        title: 'Filing check failed',
        message: _error!,
        onRetry: _load,
      );
    }
    if (_unsupported || _status?.available != true) {
      return const ErrorState.unsupported(
        title: 'Filing not available on this server',
        message:
            'This Hermes gateway has no correction-aware filing contract '
            'installed. Set up the filing contract library and the '
            'project-filing gateway hook to enable AI-assisted filing.',
      );
    }
    final status = _status!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: HermesSpacing.xl),
        children: [
          _statusBanner(tokens, status),
          const SectionHeader(title: 'Suggestions'),
          if (_suggestions.isEmpty)
            const EmptyState(
              icon: Icons.auto_fix_high_outlined,
              title: 'Nothing to file',
              message:
                  'Every recent session already matches a Project by its '
                  'working directory or a standing rule.',
            )
          else
            for (final group in groupFilingSuggestions(_suggestions))
              _groupCard(tokens, group),
          const SectionHeader(title: 'Contract'),
          _policySection(tokens),
        ],
      ),
    );
  }

  Widget _statusBanner(HermesTokens tokens, FilingStatus status) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HermesSpacing.lg, HermesSpacing.lg, HermesSpacing.lg, 0),
      child: HermesCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              status.hookInstalled
                  ? Icons.verified_outlined
                  : Icons.info_outline_rounded,
              color: status.hookInstalled ? tokens.accent : tokens.muted,
            ),
            const SizedBox(width: HermesSpacing.md),
            Expanded(
              child: Text(
                status.hookInstalled
                    ? 'Filing contract live — ${status.rules} rules, '
                        '${status.exclusions} exclusions. Corrections you '
                        'make here and in chat ("never file X under Y") '
                        'teach the organizer.'
                    : 'Filing contract installed, but the correction hook '
                        'is not active — natural-language corrections '
                        'won\u2019t be recorded until it is.',
                style: tokens.typography.body.copyWith(color: tokens.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupCard(HermesTokens tokens, FilingGroup group) {
    final busy = _busyCwds.contains(group.cwd);
    final single = group.sessions.length == 1;
    final title = single
        ? (group.sessions.first.title.isEmpty
            ? group.sessions.first.sessionId
            : group.sessions.first.title)
        : '${group.sessions.length} chats in this folder';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HermesSpacing.lg, HermesSpacing.sm, HermesSpacing.lg, 0),
      child: HermesCard(
        key: Key('filing-group-${group.cwd}'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.typography.section
                  .copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: HermesSpacing.xs),
            Text(
              group.cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  tokens.typography.label.copyWith(color: tokens.muted),
            ),
            const SizedBox(height: HermesSpacing.sm),
            Text(
              group.isUserRule
                  ? 'Your standing rule \u2192 ${group.projectName}'
                  : 'Working directory matches ${group.projectName} '
                      '(${(group.confidence * 100).round()}%)',
              style: tokens.typography.body.copyWith(color: tokens.accent),
            ),
            const SizedBox(height: HermesSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  TextButton(
                    onPressed: () => _rejectGroup(group),
                    child: const Text('Never here'),
                  ),
                  const SizedBox(width: HermesSpacing.sm),
                  FilledButton.tonal(
                    onPressed: () => _acceptGroup(group),
                    child: Text(single ? 'File it' : 'File all ${group.sessions.length}'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _policySection(HermesTokens tokens) {
    final policy = _policy;
    if (policy == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HermesSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (policy.rules.isEmpty && policy.exclusions.isEmpty)
            const EmptyState(
              icon: Icons.rule_outlined,
              title: 'No standing rules yet',
              message:
                  'Accepting a suggestion or saying "never file X under Y" '
                  'in chat creates one.',
            ),
          for (final rule in policy.rules)
            _policyRow(
              tokens,
              icon: Icons.drive_file_move_outline,
              text: '${rule['path']} \u2192 ${rule['project']}',
            ),
          for (final ex in policy.exclusions)
            _policyRow(
              tokens,
              icon: Icons.block_outlined,
              text: 'never file ${ex['path']}'
                  '${ex['project'] != null ? ' under ${ex['project']}' : ''}',
            ),
          if (policy.audit.isNotEmpty) ...[
            const SizedBox(height: HermesSpacing.md),
            Text('Recent audit',
                style:
                    tokens.typography.label.copyWith(color: tokens.muted)),
            const SizedBox(height: HermesSpacing.xs),
            for (final entry in policy.audit.reversed)
              _policyRow(
                tokens,
                icon: Icons.history,
                text: '${entry['action']} ${entry['path'] ?? ''}'
                    '${entry['quote'] != null ? '  \u201c${entry['quote']}\u201d' : ''}',
              ),
          ],
        ],
      ),
    );
  }

  Widget _policyRow(HermesTokens tokens,
      {required IconData icon, required String text}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HermesSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tokens.muted),
          const SizedBox(width: HermesSpacing.sm),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style:
                  tokens.typography.label.copyWith(color: tokens.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
