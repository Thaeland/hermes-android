import 'dart:convert';

import '../utils/media_tags.dart';
import 'session.dart';

enum ChatAssetKind { image, audio, video, document }

/// A file explicitly delivered in an assistant's durable chat history.
///
/// This is a reference, not an inventory entry or evidence that the file still
/// exists. Resolve it through the source connection's remote files client.
class ChatAsset {
  final Session session;
  final MediaTagRef ref;

  /// The message's Unix timestamp, or zero when none was recorded.
  final double timestamp;

  const ChatAsset({
    required this.session,
    required this.ref,
    required this.timestamp,
  });

  /// Lossless tuple encoding: delimiters inside either value cannot collide.
  /// Assets are scoped to one connection/profile by their data source.
  String get id => jsonEncode([session.id, ref.path]);

  ChatAssetKind get kind => switch (ref.extension) {
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'bmp' ||
    'tiff' ||
    'svg' => ChatAssetKind.image,
    'mp3' ||
    'm2a' ||
    'wav' ||
    'ogg' ||
    'opus' ||
    'm4a' ||
    'flac' => ChatAssetKind.audio,
    'mp4' || 'mov' || 'avi' || 'mkv' || 'webm' || '3gp' => ChatAssetKind.video,
    _ => ChatAssetKind.document,
  };
}

/// Extract explicit MEDIA references, never links, uploads, or tool output.
///
/// Uses the server's display projection when supplied rather than inspecting a
/// compaction carrier's model-only text. Compacted *real* rows remain eligible.
/// Duplicate paths within this session retain their newest message timestamp;
/// results are newest first. Neither messages nor paths are normalised/mutated.
List<ChatAsset> chatAssetsFromMessages(
  Session session,
  List<Map<String, dynamic>> messages,
) {
  final assets = <String, ChatAsset>{};
  for (final message in messages) {
    if (message['role'] != 'assistant' && message['role'] != 'agent') continue;
    if (_syntheticDisplayKinds.contains(message['display_kind'])) continue;
    final metadata = message['display_metadata'];
    if (metadata is Map && metadata['model_only'] == true) continue;

    final hasDisplayContent = message.containsKey('display_content');
    final text = _textContent(
      hasDisplayContent ? message['display_content'] : message['content'],
    );
    if (!hasDisplayContent && _isCompactionCarrier(message, text)) continue;

    final rawTimestamp = message['timestamp'];
    final timestamp = rawTimestamp is num
        ? rawTimestamp.toDouble()
        : rawTimestamp is String
        ? double.tryParse(rawTimestamp)
        : null;
    final recordedTimestamp = timestamp != null && timestamp.isFinite
        ? timestamp
        : 0.0;
    for (final ref in extractMediaTagRefs(text)) {
      final asset = ChatAsset(
        session: session,
        ref: ref,
        timestamp: recordedTimestamp,
      );
      final previous = assets[asset.id];
      if (previous == null || asset.timestamp > previous.timestamp) {
        assets[asset.id] = asset;
      }
    }
  }
  return assets.values.toList()..sort((left, right) {
    final byTime = right.timestamp.compareTo(left.timestamp);
    return byTime == 0 ? left.id.compareTo(right.id) : byTime;
  });
}

const _syntheticDisplayKinds = {
  'hidden',
  'compaction',
  'compaction_summary',
  'compression_summary',
  'context_summary',
};

bool _isCompactionCarrier(Map<String, dynamic> message, String text) {
  if (message['_compressed_summary'] == true ||
      message['_compressed_summary'] == 1) {
    return true;
  }
  // Legacy stores can lose the metadata. These are Hermes' reserved carrier
  // prefixes, not a heuristic that rejects ordinary mentions of compaction.
  final start = text.trimLeft();
  return start.startsWith('[CONTEXT COMPACTION — REFERENCE ONLY]') ||
      start.startsWith('[CONTEXT SUMMARY]:') ||
      start.startsWith(
        '[PRIOR CONTEXT — for reference only; not a new message]',
      );
}

String _textContent(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  // Do not stringify arbitrary parts: image URLs, reasoning, tool results and
  // provider sidecars can contain paths without being assistant deliveries.
  return content
      .map((part) {
        if (part is String) return part;
        if (part is Map &&
            const {
              'text',
              'input_text',
              'output_text',
            }.contains(part['type']) &&
            part['text'] is String) {
          return part['text'] as String;
        }
        return '';
      })
      .join('\n');
}
