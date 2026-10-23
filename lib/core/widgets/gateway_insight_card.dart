import 'package:flutter/material.dart';

import '../models/gateway_insight.dart';

import 'package:hermes_android/core/l10n/l10n.dart';

class GatewayReasoningCard extends StatefulWidget {
  final String text;
  final bool initiallyExpanded;
  final String? id;
  final bool? pinnedExpansion;
  final ValueChanged<bool>? onPinChanged;

  const GatewayReasoningCard({
    required this.text,
    this.initiallyExpanded = false,
    this.id,
    this.pinnedExpansion,
    this.onPinChanged,
    super.key,
  });

  @override
  State<GatewayReasoningCard> createState() => _GatewayReasoningCardState();
}

class _GatewayReasoningCardState extends State<GatewayReasoningCard> {
  final _controller = ExpansibleController();
  bool? _userExpanded;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _userExpanded = widget.pinnedExpansion;
  }

  @override
  void didUpdateWidget(GatewayReasoningCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pinnedExpansion != oldWidget.pinnedExpansion) {
      _userExpanded = widget.pinnedExpansion;
    }
    if (_userExpanded != null ||
        _controller.isExpanded == widget.initiallyExpanded) {
      return;
    }
    _syncing = true;
    if (widget.initiallyExpanded) {
      _controller.expand();
    } else {
      _controller.collapse();
    }
    _syncing = false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        controller: _controller,
        initiallyExpanded: _userExpanded ?? widget.initiallyExpanded,
        onExpansionChanged: (expanded) {
          if (_syncing) return;
          _userExpanded = expanded;
          widget.onPinChanged?.call(expanded);
        },
        leading: const Icon(Icons.psychology_outlined),
        title: Text(context.l10n.reasoning),
        subtitle: Text(context.l10n.hermes_reasoning_details),
        children: [
          const Divider(height: 1),
          SelectionArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(widget.text),
              ),
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

  const GatewaySubagentCard({required this.activities, super.key});

  @override
  Widget build(BuildContext context) {
    final complete = activities.every((activity) => activity.isComplete);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ExpansionTile(
        initiallyExpanded: !complete,
        leading: Icon(
          complete ? Icons.hub_outlined : Icons.account_tree_outlined,
        ),
        title: Text(
          complete
              ? context.l10n.delegated_tasks_completed(activities.length)
              : context.l10n.delegated_tasks_active(
                  activities.where((item) => !item.isComplete).length,
                ),
        ),
        children: [
          for (final activity in activities)
            ListTile(
              dense: true,
              leading: activity.isComplete
                  ? const Icon(Icons.check_circle_outline, color: Colors.green)
                  : const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
              title: Text(activity.goal),
              subtitle: Text(
                [
                  activity.phase.name,
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
