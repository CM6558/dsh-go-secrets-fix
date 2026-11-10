import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../l10n/l10n.dart';

/// The link to the engine broke, or never came up.
bool engineUnreachable(Object error) =>
    error is DshTransportException ||
    error is DshCarrierLostException ||
    error is DshClosedException ||
    error is TimeoutException;

/// The reasons every page words the same way: the link, the sign-in, a
/// conversation that is gone, an engine too old. Null for anything else;
/// each page then says it its own way, or says nothing.
String? engineErrorReason(Object error) => switch (error) {
  _ when engineUnreachable(error) => appL10n.commonEngineUnreachable,
  DshCarrierRefusedException() || DshHttpException(statusCode: 401 || 403) => appL10n.stateEngineAuthFailed,
  DshRemoteException(code: 'session/not-found') => appL10n.stateChatMissing,
  DshRemoteException(:final code) when code.startsWith('gateway/') && code != 'gateway/internal' =>
    appL10n.stateEngineUnsupported,
  _ => null,
};
