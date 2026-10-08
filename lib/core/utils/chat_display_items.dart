import '../models/gateway_activity.dart';
import '../models/gateway_insight.dart';
import 'message_content.dart';

/// The durable row shape the gateway uses for a mid-turn steer: role=user,
/// `display_kind: "steer"`, content wrapped in the model-facing
/// `[OUT-OF-BAND USER MESSAGE …]` marker, plus (on the dashboard REST
/// projection) `display_content` with the user's own words.
final RegExp _steerMarkerPattern = RegExp(
  r'^\[OUT-OF-BAND USER MESSAGE[^\]]*\]\n?([\s\S]*?)\n?\[/OUT-OF-BAND USER MESSAGE\]\s*$',
);

/// The user's own text of a persisted steer row, or null when [msg] is not a
/// steer row. Prefers the server-projected `display_content`; falls back to
/// stripping the model-facing marker wrapper off `content`.
String? steerDisplayText(Map<String, dynamic> msg) {
  if (msg['display_kind'] != 'steer') return null;
  final display = msg['display_content']?.toString().trim();
  if (display != null && display.isNotEmpty) return display;
  final match = _steerMarkerPattern.firstMatch(
    messageContentToText(msg['content']).trim(),
  );
  final stripped = match?.group(1)?.trim();
  return (stripped == null || stripped.isEmpty) ? null : stripped;
}

/// Assistant reasoning rendered as its own collapsible item in the chat list.
class ChatReasoningItem {
  final String text;
  final bool initiallyExpanded;

  const ChatReasoningItem(this.text, this.initiallyExpanded);
}

/// Project a raw Hermes message list into the heterogeneous list the chat
/// screen renders.
///
/// The result mixes four item kinds, in the order the conversation produced
/// them:
///
/// - `Map<String, dynamic>` — a user or assistant bubble, carrying
///   `_display_content` (tool-result blocks stripped) and, for assistant
///   replies, `_retry_prompt` with the user prompt that caused it;
/// - `List<GatewayToolActivity>` — consecutive tool results collapsed into one
///   activity card;
/// - [ChatReasoningItem] — assistant reasoning, emitted before its bubble;
/// - `GatewaySubagentActivity` list and [GatewayNotice] — appended last.
///
/// Tool results are matched positionally against [toolActivities]: stored tool
/// messages consume activities in order, and any activity left over (streamed
/// but not yet persisted by the server) is appended as a trailing card. The
/// caller's [toolActivities] list is never mutated.
List<dynamic> buildChatDisplayItems({
  required List<Map<String, dynamic>> messages,
  List<GatewayToolActivity> toolActivities = const [],
  List<GatewaySubagentActivity> subagentActivities = const [],
  List<GatewayNotice> notices = const [],
  bool verbose = false,
}) {
  final toolQueue = List<GatewayToolActivity>.from(toolActivities);
  final displayItems = <dynamic>[];
  final currentGroup = <GatewayToolActivity>[];
  String? lastUserPrompt;

  void flushToolGroup() {
    if (currentGroup.isEmpty) return;
    displayItems.add(currentGroup.toList());
    currentGroup.clear();
  }

  for (final msg in messages) {
    final rawRole = (msg['role'] as String?) ?? 'assistant';
    final role = rawRole == 'agent' ? 'assistant' : rawRole;
    if (isToolResultMessage(msg)) {
      if (toolQueue.isNotEmpty) currentGroup.add(toolQueue.removeAt(0));
      continue;
    }
    if (role != 'user' && role != 'assistant') continue;

    final steerText = role == 'user' ? steerDisplayText(msg) : null;
    final content = steerText ??
        stripToolResultText(messageContentToText(msg['content']));
    final reasoning = msg['_gateway_reasoning']?.toString() ?? '';
    final hasReasoning = role == 'assistant' && reasoning.trim().isNotEmpty;
    if (content.isEmpty && !hasReasoning) continue;

    flushToolGroup();

    if (hasReasoning) {
      displayItems.add(
        ChatReasoningItem(
          reasoning,
          verbose || msg['_gateway_reasoning_verbose'] == true,
        ),
      );
    }
    if (content.isNotEmpty) {
      if (role == 'user' && steerText == null) lastUserPrompt = content;
      displayItems.add({
        ...msg,
        'role': role,
        '_display_content': content,
        if (steerText != null) '_is_steer': true,
        if (role == 'assistant' && lastUserPrompt != null)
          '_retry_prompt': lastUserPrompt,
      });
    }
  }
  flushToolGroup();

  // Tools from gateway events that arrived during streaming but were never
  // matched to a stored message — show them as a trailing card.
  if (toolQueue.isNotEmpty) displayItems.add(toolQueue.toList());
  if (subagentActivities.isNotEmpty) {
    displayItems.add(List<GatewaySubagentActivity>.from(subagentActivities));
  }
  displayItems.addAll(notices);

  return displayItems;
}
