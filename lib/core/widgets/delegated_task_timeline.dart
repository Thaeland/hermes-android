import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../controllers/delegated_task_controller.dart';
import '../services/delegated_task_history.dart';

/// A modal route keeps the parent chat, composer and scroll controller mounted.
Future<void> showDelegatedTaskTimeline(
  BuildContext context,
  DelegatedTaskController controller,
) {
  if (MediaQuery.sizeOf(context).width >= 700) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 840,
          height: MediaQuery.sizeOf(dialogContext).height * .9,
          child: DelegatedTaskTimeline(controller: controller),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * .9,
      child: DelegatedTaskTimeline(controller: controller),
    ),
  );
}

class DelegatedTaskTimeline extends StatefulWidget {
  const DelegatedTaskTimeline({required this.controller, super.key});
  final DelegatedTaskController controller;
  @override
  State<DelegatedTaskTimeline> createState() => _DelegatedTaskTimelineState();
}

class _DelegatedTaskTimelineState extends State<DelegatedTaskTimeline>
    with WidgetsBindingObserver {
  DelegatedTaskController get controller => widget.controller;
  final _scrollController = ScrollController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(_changed);
    controller.setForeground(
      WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    controller.start();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      controller.setForeground(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_changed);
    controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final task = controller.task;
    final transcript = parseTaskTranscript(controller.rows);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
            child: Row(
              children: [
                const Icon(Icons.account_tree_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Task timeline',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh task history',
                  onPressed:
                      controller.loading ||
                          controller.loadingOlder ||
                          task.childSessionId == null
                      ? null
                      : () => unawaited(controller.refresh()),
                  icon: const Icon(Icons.refresh),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  label: const Text('Close'),
                ),
              ],
            ),
          ),

          if (controller.loading || controller.loadingOlder)
            const LinearProgressIndicator(),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              controller: _scrollController,
              key: const PageStorageKey('task-timeline-scroll'),
              padding: const EdgeInsets.all(12),
              children: [
                _identity(context),
                if (task.livePreview != null)
                  Card(
                    child: ExpansionTile(
                      key: PageStorageKey('task-preview-${task.id}'),
                      title: const Text('Live preview from parent events'),
                      subtitle: const Text(
                        'Latest exposed preview only; not a recorded transcript row.',
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SelectableText(
                            '${task.previewKind ?? 'Preview'}\n${task.livePreview}',
                          ),
                        ),
                      ],
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Recorded task history'),
                ),
                if (controller.unavailable != null)
                  _notice(controller.unavailable!),
                if (controller.error != null) _notice(controller.error!),
                if (controller.unavailable != null || controller.error != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: controller.loading
                          ? null
                          : () => unawaited(controller.refresh()),
                      child: const Text('Retry'),
                    ),
                  ),
                if (!controller.hasRead && controller.loading)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Loading task history…'),
                  ),
                if (controller.hasRead && transcript.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No recorded messages yet. The task may not have flushed its history; this does not mean it produced no work.',
                    ),
                  ),
                if (controller.hasOlder)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: controller.loading || controller.loadingOlder
                          ? null
                          : () => unawaited(controller.loadOlder()),
                      child: const Text('Load older'),
                    ),
                  ),
                for (final row in transcript)
                  _TranscriptRow(key: ValueKey('task-row-${row.id}'), row: row),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(String text) =>
      Padding(padding: const EdgeInsets.all(12), child: SelectableText(text));

  // Keep unabridged opaque identities inside the scrollable, not in a fixed
  // header that can overflow a small phone or a large accessibility text size.
  Widget _identity(BuildContext context) {
    final task = controller.task;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              task.displayGoal,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text('Status: ${task.statusLabel}'),
            Text('Task: ${task.id}'),
            if (task.childSessionId != null)
              Text('Stored session: ${task.childSessionId}'),
            if (task.delegationId != null)
              Text('Delegation: ${task.delegationId}'),
            const Text(
              'Read-only · recorded history may appear after the task flushes. Refresh to check again.',
            ),
          ],
        ),
      ),
    );
  }
}

class _TranscriptRow extends StatelessWidget {
  const _TranscriptRow({required this.row, super.key});
  final TaskTranscriptRow row;
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${row.role} · row ${row.id}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            for (var i = 0; i < row.reasoning.length; i++)
              _detail(
                'reasoning:${row.id}:${row.reasoningKeys[i]}',
                'Reasoning',
                row.reasoning[i],
              ),
            if (row.role != 'tool' && row.text.trim().isNotEmpty)
              MarkdownBody(
                data: row.text,
                selectable: true,
                sizedImageBuilder: (config) => Text(config.alt ?? '[image]'),
              ),
            for (var i = 0; i < row.calls.length; i++)
              _detail(
                'call:${row.id}:${row.calls[i].id ?? i}',
                'Tool call · ${row.calls[i].name}',
                'Call ID: ${row.calls[i].id ?? 'not supplied'}\nArguments\n${row.calls[i].arguments}',
              ),
            if (row.role == 'tool')
              _detail(
                'result:${row.id}',
                'Tool result · ${row.toolName}',
                'Call ID: ${row.toolId ?? 'not supplied'}\nResult\n${row.text}',
              ),
          ],
        ),
      ),
    );
  }

  Widget _detail(String identity, String title, String text) => ExpansionTile(
    key: PageStorageKey(identity),
    maintainState: true,
    title: Text(title),
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(text),
        ),
      ),
    ],
  );
}
