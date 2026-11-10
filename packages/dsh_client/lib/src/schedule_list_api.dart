/// One conversation's automation tasks (`schedule/list`): what the official
/// session header's clock reads (`dsh-client-ui-schedule`,
/// `createSessionScheduleSource`), apart from the Host-wide catalog.
///
/// Verified against DSH 0.2.1-rc.2 (`@deepseek-ai/dsh-schedule` remote
/// typings): `schedule/list({request: {sessionId}})` answers that session's
/// *active* records only, as stored — without the catalog's `sessionId`,
/// `status` or `lastDelivery`. Reading never activates the session.
library;

import 'features_api.dart';
import 'json.dart';
import 'session_api.dart';

extension SessionSchedulesApi on DshClient {
  /// `schedule/list`: [sessionId]'s active tasks in the Host's order, each
  /// bound to [sessionId] (the record itself doesn't carry it).
  Future<List<ScheduleTask>> sessionSchedules(String sessionId) async => [
    for (final entry in asListOrEmpty(
      await rpc.call('schedule/list', {
        'request': {'sessionId': sessionId},
      }),
    ))
      if (asMap(entry) case final record?)
        ?ScheduleTask.fromJson({...record, 'sessionId': sessionId, 'status': 'active'}),
  ];
}
