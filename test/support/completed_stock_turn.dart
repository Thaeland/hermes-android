import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/ws_client.dart';

/// These older fixtures model the entire completed transport operation, not a
/// bare RPC ack. Make their terminal evidence explicit for the stock owner.
TestRemotePromptSubmit? completedStockTurn(TestRemotePromptSubmit? submit) {
  if (submit == null) return null;
  return ({
    required sessionId,
    required text,
    required onEvent,
    required onSent,
  }) async {
    await submit(
      sessionId: sessionId,
      text: text,
      onEvent: onEvent,
      onSent: onSent,
    );
    onEvent(StreamEvent(type: 'turn.end', data: const {'status': 'completed'}));
  };
}
