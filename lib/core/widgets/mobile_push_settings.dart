import 'dart:async';
import 'package:flutter/material.dart';
import '../services/connection_manager.dart';
import '../services/mobile_push_service.dart';

/// Optional transport settings, deliberately separate from local notifications.
class MobilePushSettings extends StatefulWidget {
  const MobilePushSettings({
    required this.connection,
    required this.connectionManager,
    this.service,
    super.key,
  });
  final SavedConnection connection;
  final ConnectionManager connectionManager;
  final MobilePushService? service;
  @override
  State<MobilePushSettings> createState() => _MobilePushSettingsState();
}

class _MobilePushSettingsState extends State<MobilePushSettings> {
  late final MobilePushService service =
      widget.service ?? MobilePushService.shared;
  final sessions = TextEditingController();
  List<String> distributors = [];
  String? distributor;
  bool consent = false;
  bool busy = false;
  String? message;
  @override
  void initState() {
    super.initState();
    service.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await service.initialize(widget.connectionManager);
      if (!mounted) return;
      final list = await service.distributors();
      if (!mounted) return;
      setState(() {
        distributors = list;
        if (list.length == 1) distributor = list.single;
        if (service.connectionId == widget.connection.id) {
          sessions.text = service.sessionIds.join('\n');
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Unable to read Android push availability.');
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              service.error ??
              'Push setup failed. Check session IDs, permission and server authorization.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    service.removeListener(_changed);
    sessions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!service.supported) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Android UnifiedPush (optional)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Status: ${service.status}'),
            const Text(
              'No Google push SDK. Install and configure a UnifiedPush distributor yourself. The optional mobile-push server plugin must authorize your dashboard login and selected sessions. Delivery is best-effort; reopen Hermes to reconcile.',
            ),
            const SizedBox(height: 8),
            if (service.enabled) ...[
              Text(
                service.connectionId == widget.connection.id
                    ? 'Bound only to ${widget.connection.label}; ${service.sessionIds.length} selected session(s).'
                    : 'Bound to another saved connection. Disable it before selecting this connection.',
              ),
              const Text(
                'Changing sessions/distributor requires disabling and explicitly opting in again.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy ? null : () => _run(service.retry),
                    child: const Text('Reconcile / retry'),
                  ),
                  // Revocation stays available while a registration request is in flight.
                  TextButton(
                    onPressed: () => _run(service.disable),
                    child: const Text('Disable and revoke'),
                  ),
                ],
              ),
              if (service.events.isNotEmpty)
                Text(
                  '${service.events.length} authorized event(s) reconciled. Notification taps open their session; no actions are approved automatically.',
                ),
            ] else ...[
              if (distributors.isEmpty)
                const Text(
                  'No installed distributor detected. Install one, then refresh availability.',
                ),
              DropdownButtonFormField<String>(
                initialValue: distributor,
                decoration: const InputDecoration(
                  labelText: 'Installed distributor',
                ),
                isExpanded: true,
                items: distributors
                    .map(
                      (d) => DropdownMenuItem(
                        value: d,
                        child: Text(d, overflow: TextOverflow.ellipsis),
                      ),
                    )
                    .toList(),
                onChanged: busy ? null : (d) => setState(() => distributor = d),
              ),
              TextField(
                controller: sessions,
                enabled: !busy,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Durable session IDs (one per line)',
                  helperText:
                      'Copy IDs from the server session browser. Only these IDs; never all chats.',
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: consent,
                onChanged: busy
                    ? null
                    : (value) => setState(() => consent = value == true),
                title: Text(
                  'Allow private push hints for ${widget.connection.label} and only the session IDs above',
                ),
                subtitle: const Text(
                  'Shares this installation’s endpoint and encryption keys with that server. Notifications contain no chat text. Android permission is requested only after you enable.',
                ),
              ),
              FilledButton(
                onPressed: busy || !consent || distributor == null
                    ? null
                    : () => _run(
                        () => service.enable(
                          widget.connection,
                          distributor!,
                          // CRLF is one separator, never part of an ID. Preserve
                          // empty entries; the service rejects them before effects.
                          sessions.text.split(RegExp(r'\r\n|\n|,')),
                        ),
                      ),
                child: const Text('Enable for selected sessions'),
              ),
              TextButton(
                onPressed: busy ? null : () => _run(_load),
                child: const Text('Refresh availability / retry revocation'),
              ),
            ],
            if (busy) const LinearProgressIndicator(),
            if (service.pendingRevocations > 0)
              const Text(
                'Server revocation pending. Local delivery is off; retry while the original saved login is available.',
              ),
            if (message ?? service.error case final String text)
              Text(
                text,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}
