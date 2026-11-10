import 'package:dsh_client/dsh_client.dart';

/// Answers one native phone card only in the generation that presented it.
Future<bool> answerPhoneApproval({
  required DshClient client,
  required MuxGeneration generation,
  required ApprovalRequest request,
  required ApprovalDecision decision,
  required bool Function() current,
}) async {
  if (!identical(client.mux.generation, generation) ||
      !current() ||
      (decision != ApprovalDecision.allowOnce && decision != ApprovalDecision.reject)) {
    return false;
  }
  // The general respondApproval API waits for a ready generation and retries
  // a stale clientId. An already displayed native choice must do neither.
  await client.rpc.call(r'$events/result', {
    'clientId': generation.clientId,
    'eventId': request.eventId,
    'outcome': {'kind': 'result', 'value': decision.wire},
  });
  // An accepted old RPC remains a fact, but cannot clear the pending request
  // of a newer connection. Once sent, the server side action is not revocable.
  if (identical(client.mux.generation, generation) && current()) {
    client.mux.resolvePendingRequest(request.eventId);
  }
  return true;
}
