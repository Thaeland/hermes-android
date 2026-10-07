import 'package:shared_preferences/shared_preferences.dart';

/// Per-session composer drafts so leaving a chat never loses typed text.
///
/// Persisted in [SharedPreferences] (device-local) so a process restart does
/// not lose them either. Empty text clears the entry: an abandoned draft must
/// not resurrect after the message was sent or deleted.
abstract final class ComposerDraftStore {
  static const _prefix = 'composer_draft:';

  static Future<String?> read(String sessionId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final value = prefs.getString('$_prefix$sessionId');
      return (value == null || value.trim().isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String sessionId, String text) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (text.trim().isEmpty) {
        await prefs.remove('$_prefix$sessionId');
      } else {
        await prefs.setString('$_prefix$sessionId', text);
      }
    } catch (_) {
      // Best-effort: a failed save must never break the screen.
    }
  }
}
