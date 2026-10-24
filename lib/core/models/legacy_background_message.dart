/// Compatibility for backend-authored user-role rows from older gateways.
///
/// These are presentation hints, never proof of authorship. Match complete known
/// producer formats, not generic [System:]/[IMPORTANT:] prefixes: the backend can
/// merge a notice with a real user turn and deliberately remove its display kind.
/// Arbitrary plugin/webhook text requires server display metadata instead.
abstract final class LegacyBackgroundMessage {
  static bool isTask(String body) {
    final text = body.replaceAll('\r\n', '\n');
    return _fixedTasks.contains(text) ||
        _taskFrames.any((pattern) => _matchesWhole(pattern, text));
  }

  static bool isProcess(String body) {
    final text = body.replaceAll('\r\n', '\n');
    return _processFrames.any((pattern) => _matchesWhole(pattern, text));
  }

  // RegExp's $ also accepts the position before a final newline. Check the match
  // end explicitly so no human suffix (or extra line) can slip past a frame.
  static bool _matchesWhole(RegExp pattern, String text) {
    final match = pattern.matchAsPrefix(text);
    return match != null && match.end == text.length;
  }

  // agent/conversation_loop.py and agent/context_compressor.py. Equality is
  // intentional: these ordinary-looking sentences must not swallow human prose.
  static const _fixedTasks = {
    '[System: The previous response was cut off by a network error mid-stream — '
        'a transport interruption, NOT a change in your capabilities. Your tools '
        'are still fully available; call them as normal and ignore any earlier '
        'claim that you lack tool access. Continue the task from where you left '
        'off. Do not restart or repeat prior text.]',
    '[System: The previous response was cut off by a network error mid-stream. '
        'Continue exactly where you left off. Do not restart or repeat prior '
        'text. Finish the answer directly.]',
    '[System: Your previous response was truncated by the output length limit. '
        'Continue exactly where you left off. Do not restart or repeat prior '
        'text. Finish the answer directly.]',
    '[System: Your previous response contained only internal reasoning and never '
        'produced a visible answer or tool call. Do not keep thinking. Produce '
        'your final answer as plain text now (or make the tool call you were '
        'planning).]',
    '[System: Continue now. Execute the required tool calls and only send your '
        'final answer after completing the task.]',
    '[System: Your previous message ended the turn with a fragment that is not '
        'a usable answer. If the task is unfinished, continue it and then give '
        'the complete answer. If that fragment WAS your complete answer, send '
        'it again exactly as before.]',
    'Your previous turn indicated a tool call but none was included. Do not '
        'narrate a plan or restate intent — issue the actual tool call now to '
        'continue the task.',
    'You just executed tool calls but returned an empty response. Please process '
        'the tool results above and continue with the task.',
    'Continue from the compressed conversation context above. This marker '
        'exists because no human user turn was available.',
    'Continue from the compressed conversation context above. This marker '
        'exists because the compacted transcript contained no preserved user turn.',
    "You've reached the maximum number of tool-calling iterations allowed. "
        'Please provide a final response summarizing what you\'ve found and '
        'accomplished so far, without calling any more tools.',
    '(imported conversation begins with an assistant reply)',
    '[System: The user has cleared the personality overlay. From this point '
        'forward, respond in your normal default style.]',
    // hermes_cli/cli_commands_mixin.py: /browser connect and disconnect notices.
    '[System note: The user invoked /browser connect and connected your browser '
        'tools to a Chromium-family dev/debug browser via Chrome DevTools '
        'Protocol. Your browser_navigate, browser_snapshot, browser_click, and '
        'other browser tools now control that CDP browser. The command itself '
        'is a signal that using browser tools for their current browser-related '
        'request is expected; do not wait for separate permission just because '
        'CDP is connected. This is typically a Hermes-managed isolated debug '
        "profile, not the user's main everyday browser. It is still user-visible "
        'and may contain pages, logged-in sessions, or cookies in that debug '
        'profile, so avoid destructive actions, closing tabs, or navigating away '
        "unless the user's task calls for it.]",
    '[System note: The user has disconnected the browser tools from their live '
        'Chromium-family browser. Browser tools are back to default mode '
        '(headless local browser or cloud provider).]',
  };

  static final _taskFrames = <RegExp>[
    // tui_gateway/server.py: _append_model_switch_marker. The final sentence and
    // whole-body boundary distinguish a standalone pivot from a merged user turn.
    RegExp(
      r'\[System: The active model for this chat has changed to [^\r\n\[\]]+\. '
      r'From this point forward, use this runtime metadata when answering '
      r'questions about what model/provider is active\.\]',
    ),
    RegExp(
      r"\[System: The user has changed the assistant's personality\. From this "
      r'point forward, adopt the following persona and respond accordingly: '
      r'[\s\S]+\]',
    ),
    RegExp(
      r'\[System: Your previous tool call \([^\r\n]+\) was too large and the '
      r'stream timed out before it could be delivered\. Do NOT retry the same '
      r'tool call with the same large content\. Instead, break the content into '
      r'multiple smaller tool calls \(e\.g\. use multiple patch calls or write '
      r"smaller files\)\. Each tool call's arguments must be under ~8K tokens to "
      r'avoid stream timeouts\. The cut was a transport interruption, not a '
      r'capability change — your tools remain fully available\.\]',
    ),
    // Standalone automatic restart, not the different "A new message has
    // arrived" note wrapped around a newly submitted human request.
    RegExp(
      r'\[System note: Your previous turn was interrupted mid-run — the app or '
      r'its backend process stopped before the turn could finish\. Some of the '
      r'work may already be complete; check the current state before redoing '
      r'anything, then finish the task\. The interrupted request was:\]\n\n'
      r'[\s\S]+',
    ),
    RegExp(
      r'\[IMPORTANT: MCP servers have been reloaded\. [^\r\n]*'
      r'(?:[0-9]+ MCP tool\(s\) now available|No MCP tools available)\. '
      r'The tool list for this conversation has been updated accordingly\.\]',
    ),
    // Mirror provenance is otherwise lost in gateway/mirror.py. There must be a
    // complete delivery header and payload, not a mention of one in user prose.
    RegExp(r'\[(?:Cron|Webhook) delivery: [^\r\n]+\]\n[\s\S]+'),
    // tools/process_registry_notifications.py. Require the actual producer's
    // introduction and evidence fields, never just an ASYNC DELEGATION header.
    RegExp(
      r'\[ASYNC DELEGATION COMPLETE — [^\r\n\]]+\]\n'
      r'A background subagent you dispatched earlier has finished\. You may '
      r'have moved on since dispatching it; the full task source is below so '
      r'you can act on the result or re-dispatch if things have changed\.'
      r'\n[\s\S]*Original goal: [\s\S]*\nRole: [^\n]+\n[\s\S]*'
      r'Status: [^\n]+\n--- RESULT ---\n[\s\S]+',
    ),
    RegExp(
      r'\[ASYNC DELEGATION BATCH COMPLETE — [^\r\n\]]+\]\n'
      r'A background fan-out unit you dispatched earlier — [^\n]+ — has '
      r'finished; its consolidated results are below\. Any other units from '
      r'the same delegate_task call report separately as they finish\. You '
      r'may have moved on since dispatching — act on these or re-dispatch '
      r'if things have changed\. If you are still waiting on siblings, end '
      r'your turn after acting on this one\.\n[\s\S]*'
      r'Role: [^\n]+   Total duration: [^\n]+s\n[\s\S]*'
      r'(?:--- [✓✗⚠] TASK [0-9]+/[0-9]+[^\n]* ---|--- ERROR ---)\n[\s\S]+',
    ),
    RegExp(
      r'\[ASYNC DELEGATION TASK FAILED — [^\r\n\]]+, task [0-9]+/[0-9]+\]\n'
      r'One subagent in a background fan-out you dispatched has failed while '
      r"its siblings are still running\. The batch's consolidated results "
      r'will still arrive when the last sibling finishes; this is an early '
      r'warning so you can re-dispatch or investigate now instead of then\.'
      r'\n(?:Task: [^\n]+\n)?Status: [^\n]+   Duration: [^\n]+s'
      r'(?:\nError: [^\n]+)?(?:\nLive transcript: [^\n]+)?',
    ),
    // Autonomous goal/heartbeat/loop prompts have source-defined closing prose.
    // Initial /goal, /heartbeat and /loop commands remain human messages.
    RegExp(
      r'\[Heartbeat — recurring instruction, fires every [^\r\n\]]+\]\n'
      r'[\s\S]+\n\nIf there is nothing meaningful to do or report for this '
      r'instruction right now, reply briefly that nothing has changed and '
      r'stop — do not invent work\.',
    ),
    RegExp(
      r'\[Continuing toward your standing goal\]\nGoal: [\s\S]+\n\n'
      r'Continue working toward this goal\. Take the next concrete step\. '
      r'If you believe the goal is complete, state so explicitly and stop\. '
      r'If you are blocked and need input from the user, say so clearly and stop\.',
    ),
    RegExp(
      r'\[Continuing toward your standing goal\]\nGoal: [\s\S]+\n\n'
      r'Completion contract:\n[\s\S]+\n\nContinue working toward the outcome '
      r'above\. Take the next concrete step\. Stay within the stated '
      r'boundaries and do not violate the constraints\. Before claiming the '
      r'goal is done, satisfy the Verification criterion and show the concrete '
      r'evidence \(command output, file contents, test result\)\. If you hit '
      r'the stated stop condition or are otherwise blocked and need user '
      r'input, say so clearly and stop\.',
    ),
    RegExp(
      r'\[Continuing toward your standing goal\]\nGoal: [\s\S]+\n\n'
      r'Additional criteria the user added mid-loop:\n[\s\S]+\n\n'
      r'Continue working toward the goal AND all additional criteria\. Take '
      r'the next concrete step\. If you believe the goal and every additional '
      r'criterion are complete, state so explicitly and stop\. If you are '
      r'blocked and need input from the user, say so clearly and stop\.',
    ),
    RegExp(
      r'\[Continuing toward your standing goal — a quality gate failed\]\n'
      r'Goal: [\s\S]+\n\nThe quality gate command below must pass before this '
      r'goal can be declared done, and it just failed \(attempt [0-9]+/[0-9]+\):\n'
      r'  \$ [^\n]+\nExit code: -?[0-9]+\nOutput \(tail\):\n```\n[\s\S]*\n```\n\n'
      r'Fix the underlying problem so this gate passes, then re-run it to '
      r'confirm\. Do not declare the goal complete while any gate fails\. '
      r'If the gate itself is wrong or cannot pass, say so clearly and stop\.',
    ),
    RegExp(
      r'\[/loop wakeup #[0-9]+[^\r\n\]]*\]\nRecurring task: [\s\S]+\n\n'
      r'This is an automatic wakeup from the /loop the user set\. Perform the '
      r'task now against the CURRENT state \(re-check files, processes, or '
      r'services fresh — do not assume anything from earlier iterations still '
      r'holds\)\. Report concisely what you found or did this iteration\.\n'
      r'If the task is now complete, no longer applicable, or the thing you '
      r'were watching has finished, say so and end your reply with '
      r'LOOP_COMPLETE on its own line — that stops the loop\.',
    ),
    RegExp(
      r'\[/loop wakeup #[0-9]+[^\r\n\]]*\]\nRecurring task: [\s\S]+\n\n'
      r'Stop condition: [\s\S]+\n\nThis is an automatic wakeup from the /loop '
      r'the user set\. Perform the task now against the CURRENT state '
      r'\(re-check files, processes, or services fresh — do not assume anything '
      r'from earlier iterations still holds\)\. Report concisely what you found '
      r"or did this iteration, and show concrete evidence of the stop condition's "
      r'status\.\nIf the stop condition is met, or the task is no longer '
      r'applicable, say so and end your reply with LOOP_COMPLETE on its own '
      r'line — that stops the loop\.',
    ),
    RegExp(
      r'Your previous final response was rejected by the output contract '
      r'validator\. Validation errors:\n- [\s\S]+\n\nReply with ONLY the corrected '
      r'JSON object matching the OUTPUT CONTRACT schema from your task context\. '
      r'No prose, no explanations\.',
    ),
    RegExp(
      r'\[System note: the language server reported problems in files you '
      r'edited this turn, after those tool results had returned\. Fix them if '
      r'they are real, then give your final answer\.\]\n\n[\s\S]+',
    ),
    RegExp(
      r'\[System: the previous turn ended UNFINISHED — the API call failed '
      r'after all retries and the turn was interrupted \(recovery attempt '
      r'[0-9]+/[0-9]+\)\. Error: [^\n]+\.\n\nTask `[^\n]+` is still `running`\. '
      r'This is the SAME session, with your full context — nothing you already '
      r'read, wrote, or computed is lost\. Do NOT start over\.\n\n'
      r'Do this immediately:\n1\. If the interrupted turn was mid tool-call, '
      r're-check the on-disk state of whatever it was writing before continuing '
      r'\(the action may not have executed\)\.\n2\. Continue the task from where '
      r'it stopped and finish any remaining deliverable\.\n3\. End with a '
      r'terminal `kanban_complete\(summary=\.\.\., artifacts=\[\.\.\.\]\)` if the '
      r'work is done, or `kanban_block\(reason=\.\.\.\)` if you are blocked\.\]',
    ),
  ];

  static final _processFrames = <RegExp>[
    RegExp(
      r'\[IMPORTANT: Watch patterns disabled for process [^\r\n ]+ — [^\n]+ '
      r"Falling back to notify_on_complete semantics; you'll get exactly one "
      r'notification when the process exits\.\]',
    ),
    RegExp(
      r'\[IMPORTANT: Watch-pattern overflow: >[0-9]+ notifications in '
      r'[0-9]+s across all processes\. Suppressing further watch_match events '
      r'for [0-9]+s\.\]',
    ),
    RegExp(
      r'\[IMPORTANT: Watch-pattern notifications resumed\. [0-9]+ match '
      r'event\(s\) were suppressed during the flood\.\]',
    ),
    RegExp(
      r'\[IMPORTANT: Background process [^\r\n ]+ '
      r'(?:completed normally|exited|terminated by [^\n]+|'
      r'marked lost because the process backend disappeared|failed to start) '
      r'\(exit code (?:-?[0-9]+|\?)(?:, SIGTERM)?\)\.\n'
      r'(?:Started by subagent [^\n]+\n|'
      r'Handed off to you by a subagent before it finished\. Purpose: [^\n]+\n)?'
      r'Command: [\s\S]+\nOutput:\n[\s\S]*\]',
    ),
    RegExp(
      r'\[IMPORTANT: Background process [^\r\n ]+ matched watch pattern '
      r'"[^\n]+"\.\n(?:Started by subagent [^\n]+\n)?'
      r'Command: [\s\S]+\nMatched output:\n[\s\S]*\]',
    ),
    RegExp(
      r'\[Background process [^\r\n ]+ heartbeat #[0-9]+ — still running after '
      r'[^\r\n]+ \(next in [0-9]+s when there is new output; you will also be '
      r'told when it exits\)\.\n(?:Started by subagent [^\n]+\n)?'
      r'Command: [\s\S]+\nOutput since last heartbeat:\n[\s\S]*\]',
    ),
  ];
}
