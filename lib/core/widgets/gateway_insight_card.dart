import 'package:flutter/material.dart';

import '../models/gateway_insight.dart';
import 'delegated_task_labels.dart';

import 'package:hermes_android/core/l10n/l10n.dart';

class GatewayReasoningCard extends StatelessWidget {
  final String text;
  final bool initiallyExpanded;

  const GatewayReasoningCard({
    required this.text,
    this.initiallyExpanded = false,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey<String>('gateway-reasoning-${text.hashCode}'),
        initiallyExpanded: initiallyExpanded,
        leading: const Icon(Icons.psychology_outlined),
        title: Text(context.l10n.reasoning),
        subtitle: Text(context.l10n.hermes_reasoning_details),
        children: [
          const Divider(height: 1),
          SelectionArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(alignment: Alignment.centerLeft, child: Text(text)),
            ),
          ),
        ],
      ),
    );
  }
}

class GatewayNoticeCard extends StatelessWidget {
  final GatewayNotice notice;

  const GatewayNoticeCard({required this.notice, super.key});

  @override
  Widget build(BuildContext context) {
    final isBackground = notice.kind == GatewayNoticeKind.background;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isBackground
                  ? Icons.task_alt_outlined
                  : Icons.fact_check_outlined,
              size: 21,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      notice.title,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(notice.text),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GatewaySubagentCard extends StatelessWidget {
  final List<GatewaySubagentActivity> activities;
  final ValueChanged<GatewaySubagentActivity>? onOpenTask;

  const GatewaySubagentCard({
    required this.activities,
    this.onOpenTask,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final complete = activities.every((activity) => activity.isComplete);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        initiallyExpanded: !complete,
        leading: Icon(
          activities.any((task) => task.failed)
              ? Icons.error_outline
              : activities.any((task) => task.interrupted)
              ? Icons.cancel_outlined
              : complete
              ? Icons.hub_outlined
              : Icons.account_tree_outlined,
          color: activities.any((task) => task.failed)
              ? Theme.of(context).colorScheme.error
              : null,
        ),
        title: Text(
          complete
              ? (activities.every((task) => task.succeeded)
                    ? context.l10n.delegated_tasks_completed(activities.length)
                    : context.l10n.task_tasks_finished(activities.length))
              : context.l10n.delegated_tasks_active(
                  activities.where((item) => !item.isComplete).length,
                ),
        ),
        children: [
          for (final activity in activities)
            ListTile(
              key: ValueKey('delegated-task-${activity.id}'),
              onTap: onOpenTask == null ? null : () => onOpenTask!(activity),
              trailing: onOpenTask == null
                  ? null
                  : const Icon(Icons.chevron_right),
              dense: true,
              leading: activity.isComplete
                  ? Icon(
                      activity.failed
                          ? Icons.error_outline
                          : activity.status == 'cancelled'
                          ? Icons.cancel_outlined
                          : activity.interrupted
                          ? Icons.pause_circle_outline
                          : activity.succeeded
                          ? Icons.check_circle_outline
                          : Icons.help_outline,
                      color: activity.failed
                          ? Theme.of(context).colorScheme.error
                          : null,
                      semanticLabel: delegatedTaskStatus(
                        context.l10n,
                        activity,
                      ),
                    )
                  : const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
              title: Text(delegatedTaskGoal(context.l10n, activity)),
              subtitle: Text(
                [
                  delegatedTaskStatus(context.l10n, activity),
                  if (activity.model != null) activity.model!,
                  if (activity.detail != null) activity.detail!,
                ].join(' • '),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
