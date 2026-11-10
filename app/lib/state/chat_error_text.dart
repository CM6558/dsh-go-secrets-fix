import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import 'engine_error_text.dart';

/// 「[action]：原因」, or just [action] when the reason means nothing to a
/// person. The raw error only goes to the log.
String chatErrorText(Object error, {required String action}) {
  debugPrint('$action: $error');
  final reason = switch (error) {
    DshRemoteException(:final code) => switch (code) {
      'session/agent-busy' => appL10n.stateChatAgentBusy,
      'session/writer-held' => appL10n.stateChatWriterHeld,
      'session/model-unavailable' || 'session/provider-models-unavailable' => appL10n.stateChatModelUnavailable,
      'session/attachment-invalid' => appL10n.stateChatAttachmentInvalid,
      'session/fork-unavailable' => appL10n.stateChatForkUnavailable,
      'FRAME_TOO_LARGE' => appL10n.stateChatImagesTooLarge,
      _ => engineErrorReason(error),
    },
    // Uploads and exports go over HTTP: any other status means no engine.
    DshHttpException() => engineErrorReason(error) ?? appL10n.commonEngineUnreachable,
    _ => engineErrorReason(error),
  };
  return reason == null ? action : appL10n.stateActionReason(action, reason);
}
