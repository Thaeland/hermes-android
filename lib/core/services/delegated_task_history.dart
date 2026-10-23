import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/gateway_insight.dart';
import 'connection_manager.dart';
import 'desktop_gateway_client.dart';

enum TaskHistoryProblem {
  invalidReference,
  authRequired,
  authRejected,
  incompatible,
  identityUnproven,
  missingReference,
  missingRowIdentity,
  notReady,
  refreshFailed,
}

class TaskHistoryUnavailable implements Exception {
  const TaskHistoryUnavailable(this.reason);
  final TaskHistoryProblem reason;
  @override
  String toString() => 'TaskHistoryUnavailable(${reason.name})';
}

class TaskHistoryReadFailure implements Exception {
  const TaskHistoryReadFailure(this.reason);
  final TaskHistoryProblem reason;
}

abstract interface class TaskHistorySource {
  Future<List<Map<String, dynamic>>> fetch(String childId, int offset);
  void close();
}

/// Dashboard raw history only: no socket, runtime session or API-server fallback.
class DashboardTaskHistory implements TaskHistorySource {
  DashboardTaskHistory({
    required this.dashboard,
    this.profile,
    this.authAvailable = true,
  });
  final DashboardClient dashboard;
  final String? profile;
  final bool authAvailable;

  factory DashboardTaskHistory.fromConnection(
    SavedConnection connection, {
    http.Client? httpClient,
  }) {
    final base = Uri.parse(
      DesktopGatewayClient.normalizedGatewayBaseUrl(connection),
    );
    final local = const {'localhost', '127.0.0.1', '::1'}.contains(base.host);
    return DashboardTaskHistory(
      dashboard: DashboardClient(
        host: base.host,
        port: base.port,
        useHttps: base.scheme == 'https',
        pathPrefix: base.path == '/' ? '' : base.path,
        proxied: connection.dashboardProxied,
        username: connection.dashboardUsername,
        password: connection.dashboardPassword,
        httpClient: _TaskHistoryHttpClient(httpClient ?? http.Client()),
      ),
      profile: connection.gatewayProfile,
      authAvailable:
          connection.dashboardProxied ||
          local ||
          (connection.dashboardUsername?.isNotEmpty == true &&
              connection.dashboardPassword?.isNotEmpty == true),
    );
  }

  @override
  Future<List<Map<String, dynamic>>> fetch(String childId, int offset) async {
    if (GatewaySubagentActivity.opaqueId(childId) == null || offset < 0) {
      throw const TaskHistoryUnavailable(TaskHistoryProblem.invalidReference);
    }
    if (!authAvailable) {
      throw const TaskHistoryUnavailable(TaskHistoryProblem.authRequired);
    }
    final Map<String, dynamic> data;
    try {
      // Both stock endpoints resolve prefixes. Prove the exact durable row
      // exists before asking for any transcript.
      await _exactDetail(childId);
      data = await dashboard.apiGet(
        'sessions/${Uri.encodeComponent(childId)}/messages',
        queryParameters: {
          if (profile != null && profile!.isNotEmpty) 'profile': profile!,
          'limit': '50',
          'offset': '$offset',
          'order': 'latest',
          'inline_images': 'false',
          'include_compacted': 'true',
        },
      );
      await _proveCompressionLineage(childId, data['session_id']);
    } on DashboardHttpException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        throw const TaskHistoryUnavailable(TaskHistoryProblem.authRejected);
      }
      if (error.statusCode == 404) {
        throw const TaskHistoryReadFailure(TaskHistoryProblem.notReady);
      }
      rethrow;
    }
    final messages = data['messages'];
    final pagination = data['pagination'];
    if (GatewaySubagentActivity.opaqueId(data['session_id']) == null ||
        messages is! List ||
        messages.length > 50 ||
        messages.any((row) => row is! Map<String, dynamic>) ||
        pagination is! Map ||
        pagination['limit'] != 50 ||
        pagination['offset'] != offset ||
        pagination['order'] != 'latest' ||
        pagination['returned'] != messages.length ||
        (profile?.isNotEmpty == true && data['profile'] != profile)) {
      throw const TaskHistoryUnavailable(TaskHistoryProblem.incompatible);
    }
    return messages.cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> _exactDetail(String id) async {
    final detail = await dashboard.apiGet(
      'sessions/${Uri.encodeComponent(id)}',
      queryParameters: {if (profile?.isNotEmpty == true) 'profile': profile!},
    );
    if (detail['id'] != id ||
        (profile?.isNotEmpty == true && detail['profile'] != profile)) {
      throw const TaskHistoryUnavailable(TaskHistoryProblem.identityUnproven);
    }
    return detail;
  }

  Future<void> _proveCompressionLineage(
    String original,
    Object? canonical,
  ) async {
    if (canonical == original) return;
    var current = GatewaySubagentActivity.opaqueId(canonical);
    final seen = <String>{};
    // No latest-descendant heuristic or invented lineage fields. Stock detail
    // returns parent_session_id, end_reason, source and model_config.
    for (var hop = 0; hop < 32 && current != null; hop++) {
      if (!seen.add(current)) break;
      final child = await _exactDetail(current);
      final parentId = GatewaySubagentActivity.opaqueId(
        child['parent_session_id'],
      );
      if (parentId == null ||
          !child.containsKey('model_config') ||
          !child.containsKey('source') ||
          child['source'] == 'tool') {
        break;
      }
      final config = decodeTaskJson(child['model_config']);
      if (config != null && config is! Map) break;
      if (config is Map &&
          const [
            '_delegate_from',
            '_branched_from',
            '_reset_from',
          ].any((key) => config[key] != null)) {
        break;
      }
      final parent = await _exactDetail(parentId);
      if (parent['end_reason'] != 'compression') break;
      if (parentId == original) return;
      current = parentId;
    }
    throw const TaskHistoryUnavailable(TaskHistoryProblem.identityUnproven);
  }

  @override
  void close() => dashboard.close();
}

/// An auth request can finish after the viewer closes. Reject the follow-up
/// GET before it reaches the delegate, even with clients whose close is a no-op.
class _TaskHistoryHttpClient extends http.BaseClient {
  _TaskHistoryHttpClient(this._delegate);
  final http.Client _delegate;
  bool _closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) {
      throw StateError('Task history viewer is closed');
    }
    final response = await _delegate.send(request);
    if (request.url.path.endsWith('/auth/password-login') &&
        (response.statusCode == 401 || response.statusCode == 403)) {
      await response.stream.drain<void>();
      throw const TaskHistoryUnavailable(TaskHistoryProblem.authRejected);
    }
    return response;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _delegate.close();
  }
}

Object? decodeTaskJson(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return value;
  }
}

String _pretty(Object? value) =>
    value is String ? value : const JsonEncoder.withIndent('  ').convert(value);

/// Read only explicitly exposed textual fields; encrypted/opaque reasoning is
/// deliberately not stringified. Sidecars can be JSON strings or native lists.
List<String> _reasoningText(Object? raw) {
  final value = decodeTaskJson(raw);
  if (value is String) return value.trim().isEmpty ? [] : [value];
  if (value is List) return value.expand(_reasoningText).toList();
  if (value is Map) {
    if (const {
      'reasoning.encrypted',
      'redacted_thinking',
    }.contains(value['type'])) {
      return [];
    }
    for (final key in ['text', 'thinking', 'summary', 'content']) {
      if (value[key] != null) return _reasoningText(value[key]);
    }
  }
  return [];
}

// Server-projected text is already decoded: JSON-looking prose stays prose.
List<String> _projectedText(Object? raw) => [
  if (raw is String) raw,
  if (raw is List) ...raw.whereType<String>(),
].where((text) => text.trim().isNotEmpty).toList();

String _prose(Object? raw) {
  // Prose that happens to be JSON is still prose, not an encoded sidecar.
  final value = raw;
  if (value is String) return value;
  if (value is List) {
    return value
        .map((part) {
          if (part is String) return part;
          if (part is Map &&
              const {
                'text',
                'output_text',
                'input_text',
              }.contains(part['type'])) {
            return part['text'] as String? ?? '';
          }
          return '';
        })
        .where((text) => text.isNotEmpty)
        .join('\n');
  }
  // A literal JSON result is still actual result content.
  return raw is String ? raw : '';
}

class TaskToolCall {
  const TaskToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
  final String? id;
  final String name;
  final String? arguments;
}

List<TaskToolCall> _calls(Object? raw) {
  final list = decodeTaskJson(raw);
  if (list is! List) return [];
  return [
    for (final call in list.whereType<Map>())
      if (call['function'] is Map)
        TaskToolCall(
          id: call['id'] is String ? call['id'] as String : null,
          name: (call['function'] as Map)['name'] as String? ?? 'tool',
          arguments: (call['function'] as Map)['arguments'] == null
              ? null
              : _pretty((call['function'] as Map)['arguments']),
        ),
  ];
}

class TaskTranscriptRow {
  const TaskTranscriptRow({
    required this.id,
    required this.role,
    required this.text,
    required this.reasoning,
    required this.reasoningKeys,
    required this.calls,
    this.toolId,
    this.toolName,
  });
  final int id;
  final String role;
  final String text;
  final List<String> reasoning;
  final List<String> reasoningKeys;
  final List<TaskToolCall> calls;
  final String? toolId;
  final String? toolName;
}

int? taskRowId(Map<String, dynamic> row) {
  final id = row['id'];
  if (id is int) return id;
  if (id is String) return int.tryParse(id);
  return null;
}

List<TaskTranscriptRow> parseTaskTranscript(List<Map<String, dynamic>> rows) {
  final ordered = rows.where((row) => taskRowId(row) != null).toList()
    ..sort((a, b) => taskRowId(a)!.compareTo(taskRowId(b)!));
  final names = <String, String>{};
  for (final row in ordered) {
    for (final call in _calls(row['tool_calls'])) {
      if (call.id != null) names[call.id!] = call.name;
    }
  }
  final transcript = <TaskTranscriptRow>[];
  for (final row in ordered) {
    if (row['display_kind'] == 'hidden' ||
        !const {
          'user',
          'assistant',
          'agent',
          'tool',
          'system',
        }.contains(row['role'])) {
      continue;
    }
    final reasoning = <MapEntry<String, String>>[
      for (final field
          in row.containsKey('display_reasoning')
              ? ['display_reasoning']
              : [
                  'reasoning',
                  'reasoning_content',
                  'reasoning_details',
                  'codex_reasoning_items',
                ])
        for (final (index, text)
            in (field == 'display_reasoning'
                    ? _projectedText(row[field])
                    : _reasoningText(row[field]))
                .indexed)
          MapEntry('$field:$index', text),
    ];
    transcript.add(
      TaskTranscriptRow(
        id: taskRowId(row)!,
        role: row['role'] == 'agent' ? 'assistant' : row['role'] as String,
        text: row['role'] == 'tool'
            ? (row['content'] == null ? '' : _pretty(row['content']))
            : [
                ..._projectedText(row['display_commentary']),
                _prose(
                  row.containsKey('display_content')
                      ? row['display_content']
                      : row['content'],
                ),
              ].where((text) => text.isNotEmpty).join('\n\n'),
        reasoning: reasoning.map((entry) => entry.value).toList(),
        reasoningKeys: reasoning.map((entry) => entry.key).toList(),
        calls: _calls(row['tool_calls']),
        toolId: row['tool_call_id'] is String
            ? row['tool_call_id'] as String
            : null,
        toolName:
            names[row['tool_call_id']] ??
            (row['name'] is String ? row['name'] as String : null) ??
            (row['tool_name'] is String ? row['tool_name'] as String : null) ??
            'tool',
      ),
    );
  }
  return transcript;
}

/// Recover only delegate_task's known top-level result/results schema. Never
/// recurse into arbitrary tool output or accept a generic session_id as a child.
List<GatewaySubagentActivity> recoverDelegatedTasks(
  List<Map<String, dynamic>> rows,
) {
  final delegates = <String, Map>{};
  for (final row in rows) {
    final calls = decodeTaskJson(row['tool_calls']);
    if (calls is! List) continue;
    for (final call in calls.whereType<Map>()) {
      final function = call['function'];
      if (function is Map &&
          function['name'] == 'delegate_task' &&
          call['id'] is String) {
        final args = decodeTaskJson(function['arguments']);
        delegates[call['id'] as String] = args is Map ? args : {};
      }
    }
  }
  final recovered = <GatewaySubagentActivity>[];
  for (final row in rows) {
    if (row['role'] != 'tool') continue;
    final callId = row['tool_call_id'];
    if (callId is! String ||
        (!delegates.containsKey(callId) &&
            row['name'] != 'delegate_task' &&
            row['tool_name'] != 'delegate_task')) {
      continue;
    }
    final result = decodeTaskJson(row['content']);
    final args = delegates[callId];
    if (_isControlAcknowledgement(args) || _isControlAcknowledgement(result)) {
      continue;
    }
    final entries = _delegationEntries(result);
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry is! Map || _isControlAcknowledgement(entry)) continue;
      final taskArgs = args?['tasks'];
      final arg = taskArgs is List && i < taskArgs.length && taskArgs[i] is Map
          ? taskArgs[i] as Map
          : args;
      recovered.add(
        GatewaySubagentActivity.fromGatewayEvent(
          const {
                'completed',
                'failed',
                'error',
                'interrupted',
                'cancelled',
              }.contains(entry['status'])
              ? 'subagent.complete'
              : 'subagent.start',
          {
            ...Map<String, dynamic>.from(entry),
            'subagent_id':
                GatewaySubagentActivity.opaqueId(entry['subagent_id']) ??
                'stored-tool:$callId:$i',
            'goal': entry['goal'] ?? arg?['goal'],
            'task_index': i,
          },
        )!,
      );
    }
  }
  return recovered;
}

bool _isControlAcknowledgement(Object? value) =>
    value is Map &&
    ((value['action'] != null && value['action'] != 'spawn') ||
        const {'queued', 'interrupt_requested'}.contains(value['status']) ||
        value.containsKey('subagents'));

List<dynamic> _delegationEntries(Object? result) {
  if (result is! Map) return [];
  if (result['results'] is List) return result['results'] as List;
  // Actual background dispatch carries runtime ids/goals, not durable child
  // refs. Preserve each task; opening it explains the missing-reference limit.
  if (result['status'] == 'dispatched' && result['goals'] is List) {
    final goals = result['goals'] as List;
    final ids = result['subagent_ids'];
    return [
      for (var i = 0; i < goals.length; i++)
        {
          ...result,
          'goal': goals[i],
          if (ids is List && i < ids.length) 'subagent_id': ids[i],
        },
    ];
  }
  return [result];
}
