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

import '../l10n/l10n.dart';
import '../services/connection_manager.dart';
import '../services/desktop_gateway_client.dart';
import '../services/filing_gateway_client.dart';
import '../services/projects_gateway_client.dart' show GatewayRpcCall;
import '../theme/hermes_theme.dart';
import '../widgets/hermes_components.dart';

class FilingScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Test-only RPC override: when set, the screen talks to this function
  /// instead of opening a Desktop gateway socket. Mirrors the recovery-
  /// socket seam pattern used elsewhere; production callers never pass it.
  final GatewayRpcCall? testRpc;

  const FilingScreen({
    required this.connection,
    this.testRpc,
    super.key,
  });

  @override
  State<FilingScreen> createState() => _FilingScreenState();
}

class _FilingScreenState extends State<FilingScreen> {
  DesktopGatewayClient? _gateway;
  FilingGatewayClient? _testClient;
  FilingStatus? _status;
  List<FilingSuggestion> _suggestions = const [];
  FilingPolicy? _policy;
  bool _loading = true;
  String? _error;
  bool _unsupported = false;
  final Set<String> _busySessions = {};

  @override
  void initState() {
    super.initState();
    _open();
  }

  void _open() {
    if (widget.testRpc != null) {
      _testClient = FilingGatewayClient(widget.testRpc!);
      _load();
      return;
    }
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

  FilingGatewayClient? get _client => _testClient ?? _gateway?.filing;

  Future<void> _load() async {
    final client = _client;
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

  Future<void> _accept(FilingSuggestion s) async {
    final client = _client;
    if (client == null || _busySessions.contains(s.sessionId)) return;
    if (s.cwd.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.suggestion_has_no_folder_path_cannot_apply,
          ),
        ),
      );
      return;
    }
    setState(() => _busySessions.add(s.sessionId));
    try {
      final note = await client.apply(path: s.cwd, project: s.projectName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.could_not_apply('$e'))));
    } finally {
      if (mounted) setState(() => _busySessions.remove(s.sessionId));
    }
  }

  Future<void> _reject(FilingSuggestion s) async {
    final client = _client;
    if (client == null || _busySessions.contains(s.sessionId)) return;
    if (s.cwd.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.suggestion_has_no_folder_path_cannot_record,
          ),
        ),
      );
      return;
    }
    setState(() => _busySessions.add(s.sessionId));
    try {
      final note = await client.reject(path: s.cwd, project: s.projectName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(note)));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.could_not_record('$e'))));
    } finally {
      if (mounted) setState(() => _busySessions.remove(s.sessionId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: Text(context.l10n.ai_assisted_filing),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: context.l10n.refresh,
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
        title: context.l10n.filing_check_failed,
        message: _error!,
        onRetry: _load,
      );
    }
    if (_unsupported || _status?.available != true) {
      return ErrorState.unsupported(
        title: context.l10n.filing_not_available_on_this_server,
        message: context.l10n.filing_not_available_message,
      );
    }
    final status = _status!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: HermesSpacing.xl),
        children: [
          _statusBanner(tokens, status),
          SectionHeader(title: context.l10n.suggestions),
          if (_suggestions.isEmpty)
            EmptyState(
              icon: Icons.auto_fix_high_outlined,
              title: context.l10n.nothing_to_file,
              message: context.l10n.nothing_to_file_message,
            )
          else
            for (final s in _suggestions) _suggestionCard(tokens, s),
          SectionHeader(title: context.l10n.contract),
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
                    ? context.l10n.filing_contract_live(
                        status.exclusions, status.rules)
                    : context.l10n.filing_hook_inactive,
                style: tokens.typography.body.copyWith(color: tokens.onSurface),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionCard(HermesTokens tokens, FilingSuggestion s) {
    final busy = _busySessions.contains(s.sessionId);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HermesSpacing.lg, HermesSpacing.sm, HermesSpacing.lg, 0),
      child: HermesCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              s.title.isEmpty ? s.sessionId : s.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: tokens.typography.section
                  .copyWith(color: tokens.onSurface),
            ),
            const SizedBox(height: HermesSpacing.xs),
            Text(
              s.cwd,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  tokens.typography.label.copyWith(color: tokens.muted),
            ),
            const SizedBox(height: HermesSpacing.sm),
            Text(
              s.isUserRule
                  ? context.l10n.your_standing_rule(s.projectName)
                  : context.l10n.working_directory_matches(
                      (s.confidence * 100).round(), s.projectName),
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
                    onPressed: () => _reject(s),
                    child: Text(context.l10n.never_here),
                  ),
                  const SizedBox(width: HermesSpacing.sm),
                  FilledButton.tonal(
                    onPressed: () => _accept(s),
                    child: Text(context.l10n.file_it),
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
            EmptyState(
              icon: Icons.rule_outlined,
              title: context.l10n.no_standing_rules_yet,
              message: context.l10n.no_standing_rules_message,
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
              text: ex['project'] != null
                  ? context.l10n.never_file_path_under(
                      ex['path'], ex['project'])
                  : context.l10n.never_file_path(ex['path']),
            ),
          if (policy.audit.isNotEmpty) ...[
            const SizedBox(height: HermesSpacing.md),
            Text(context.l10n.recent_audit,
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
