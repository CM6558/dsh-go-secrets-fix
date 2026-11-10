// `schedule/list`: one conversation's active tasks, read the way the official
// session header's clock reads them.

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

/// A `schedule/list` record as DSH 0.2.1-rc.2 stores it: no `sessionId`,
/// `status` or `lastDelivery`.
const _daily = {
  'id': 'sch-daily',
  'kind': 'daily',
  'title': '日报提醒',
  'prompt': '整理今天的提交，写一段日报。',
  'time': '21:30:00.000',
  'timeZone': 'Asia/Shanghai',
  'scheduledAt': '2026-10-24T13:30:00.000Z',
};

const _every = {
  'id': 'sch-every',
  'kind': 'every',
  'title': '检查夜间构建',
  'prompt': '看一眼构建',
  'everySeconds': 7200,
  'scheduledAt': '2026-10-24T08:00:00.000Z',
};

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
    addTearDown(client.close);
    return client;
  }

  test('asks for one session and binds each record to it', () async {
    host.handlers['schedule/list'] = (args) {
      expect(args, {
        'request': {'sessionId': 'session-1'},
      });
      return ok([_daily, _every]);
    };
    final tasks = await (await connect()).sessionSchedules('session-1');
    expect(tasks.map((t) => t.id), ['sch-daily', 'sch-every']);
    final daily = tasks.first;
    expect(daily.sessionId, 'session-1');
    expect(daily.active, isTrue);
    expect(daily.title, '日报提醒');
    expect(daily.time, '21:30:00.000');
    expect(daily.timeZone, 'Asia/Shanghai');
    expect(daily.scheduledAt, DateTime.utc(2026, 10, 24, 13, 30));
    expect(daily.lastDeliveredAt, isNull);
    expect(tasks.last.everySeconds, 7200);
    expect(tasks.last.recurring, isTrue);
  });

  test('keeps the stored record as the update baseline', () async {
    host.handlers['schedule/list'] = (_) => ok([_daily]);
    final task = (await (await connect()).sessionSchedules('session-1')).single;
    expect(task.record, _daily);
    expect(task.record.containsKey('sessionId'), isFalse);
    expect(task.record.containsKey('status'), isFalse);
  });

  test('skips unusable entries and reads a non-list as empty', () async {
    host.handlers['schedule/list'] = (_) => ok([
      _daily,
      {'kind': 'daily'},
      'nonsense',
    ]);
    final client = await connect();
    expect((await client.sessionSchedules('session-1')).single.id, 'sch-daily');

    host.handlers['schedule/list'] = (_) => ok({'code': 'internal_error', 'message': 'nope'});
    expect(await client.sessionSchedules('session-1'), isEmpty);
  });

  test('a Host failure surfaces as the remote error', () async {
    host.handlers['schedule/list'] = (_) => {
      'ok': false,
      'error': {'code': 'gateway/method-not-found', 'message': 'no schedule'},
    };
    final client = await connect();
    await expectLater(client.sessionSchedules('session-1'), throwsA(isA<DshRemoteException>()));
  });
}
