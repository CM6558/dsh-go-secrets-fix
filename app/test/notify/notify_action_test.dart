import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));
  final replies = <(ApprovalRequest, ApprovalDecision)>[];
  bool failReply = false;

  @override
  Future<void> respondApproval(ApprovalRequest request, ApprovalDecision decision) async {
    replies.add((request, decision));
    if (failReply) throw StateError('disconnected');
  }
}

class _Local extends LocalConnectionController {
  _Local(this.connection);
  final HostConnection? connection;
  @override
  Future<HostConnection?> build() async => connection;
}

void main() {
  late _Client localClient;
  late _Client remoteClient;
  late FakeAlertSource local;
  late FakeAlertSource remote;
  late FakeNotifyChannel channel;
  late ProviderContainer container;
  const remoteHost = HostRef.ssh('lab');
  const request = ApprovalRequest(eventId: 'approval-1', sessionId: 'r1', toolName: 'bash', callId: 'call-1');

  NotifyAction action({ApprovalDecision decision = ApprovalDecision.allowOnce, HostRef host = remoteHost}) =>
      NotifyAction(
        host: host,
        group: notifyGroup(host, 'r1'),
        key: request.eventId,
        eventId: request.eventId,
        decision: decision,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    localClient = _Client();
    remoteClient = _Client();
    local = FakeAlertSource()..sessions = [session('s1')];
    remote = FakeAlertSource()
      ..sessions = [session('r1')]
      ..approvalCalls['call-1'] = const ToolCallPart(id: 'call-1', name: 'bash', arguments: '{"command":"echo ready"}');
    channel = FakeNotifyChannel();
    final localConnection = HostConnection(client: localClient, label: '本机', isLocal: true);
    final remoteConnection = HostConnection(
      client: remoteClient,
      label: '远程',
      isLocal: false,
      kind: HostKind.ssh,
      hostId: 'lab',
    );
    container = ProviderContainer(
      overrides: [
        notifyChannelProvider.overrideWithValue(channel),
        alertSourceFactoryProvider.overrideWithValue((connection) => connection.isLocal ? local : remote),
        alertTimingProvider.overrideWithValue((announce: Duration.zero, reconcile: const Duration(milliseconds: 30))),
        localConnectionProvider.overrideWith(() => _Local(localConnection)),
        activeConnectionProvider.overrideWithValue(AsyncData(remoteConnection)),
      ],
    );
    container.listen(chatAlertsProvider, (_, _) {});
    container.read(appForegroundProvider.notifier).set(false);
    await settle();
  });

  tearDown(() async {
    container.dispose();
    await channel.actionController.close();
    await channel.tapController.close();
    await localClient.close();
    await remoteClient.close();
  });

  Future<void> announce() async {
    remote.emit(const ApprovalRequestedEvent(request));
    await settle();
  }

  test('event routes to its host client and acknowledges allowOnce', () async {
    await announce();
    expect(channel.shown.single.canApprove, isTrue);
    expect(channel.shown.single.text, '运行：echo ready');
    channel.actionController.add(action());
    await settle();
    expect(localClient.replies, isEmpty);
    expect(remoteClient.replies, [(request, ApprovalDecision.allowOnce)]);
    expect(channel.actionResults.single.$2, NotifyActionResult.handled);
  });

  test('reject decision reaches respondApproval unchanged', () async {
    await announce();
    final result = await container
        .read(chatAlertsProvider.notifier)
        .respondAction(action(decision: ApprovalDecision.reject));
    expect(result, NotifyActionResult.handled);
    expect(remoteClient.replies.single.$2, ApprovalDecision.reject);
  });

  test('disconnected host fails without replying', () async {
    await announce();
    remote.isConnected = false;
    expect(await container.read(chatAlertsProvider.notifier).respondAction(action()), NotifyActionResult.failed);
    expect(remoteClient.replies, isEmpty);
    expect(
      await container.read(chatAlertsProvider.notifier).respondAction(action(host: const HostRef.ssh('gone'))),
      NotifyActionResult.failed,
    );
  });

  test('withdrawn request is gone', () async {
    await announce();
    remote.emit(const HostRequestCancelledEvent('approval-1'));
    expect(await container.read(chatAlertsProvider.notifier).respondAction(action()), NotifyActionResult.gone);
    expect(remoteClient.replies, isEmpty);
  });

  test('missing exact tool call leaves actions disabled', () async {
    remote.approvalCalls.clear();
    await announce();
    expect(channel.shown.single.canApprove, isFalse);
    expect(await container.read(chatAlertsProvider.notifier).respondAction(action()), NotifyActionResult.gone);
    expect(remoteClient.replies, isEmpty);
  });

  test('RPC errors report failure rather than a successful approval', () async {
    await announce();
    remoteClient.failReply = true;
    expect(await container.read(chatAlertsProvider.notifier).respondAction(action()), NotifyActionResult.failed);
  });

  test('approval previews use exact calls, mask secrets and stay within 90 characters', () {
    const key = 'sk-1234567890abcdefghijklmnopqrstuvwxyz';
    final preview = approvalPreview(
      request,
      const ToolCallPart(id: 'call-1', name: 'bash', arguments: '{"command":"echo $key\\nnext line"}'),
    )!;
    expect(preview.text, startsWith('运行：echo sk-12345'));
    expect(preview.text, isNot(contains('next line')));
    expect(preview.fullText, contains('next line'));
    expect(preview.fullText, isNot(contains(key.substring(8))));
    final long = approvalPreview(
      request,
      ToolCallPart(id: 'call-1', name: 'bash', arguments: '{"command":"${'字' * 120}"}'),
    )!;
    expect(long.text.runes.length, lessThanOrEqualTo(90));
    expect(approvalPreview(request, const ToolCallPart(id: 'another', name: 'bash', arguments: '{}')), isNull);
    expect(approvalPreview(request, const ToolCallPart(id: 'call-1', name: 'bash', arguments: 'invalid')), isNull);
    for (final (tool, field, verb) in [
      ('write', 'file_path', '写入'),
      ('edit', 'path', '修改'),
      ('web_fetch', 'url', '打开'),
    ]) {
      final result = approvalPreview(
        ApprovalRequest(eventId: 'e', sessionId: 's', toolName: tool, callId: 'c'),
        ToolCallPart(id: 'c', name: tool, arguments: '{"$field":"target"}'),
      )!;
      expect(result.text, '$verb：target');
    }
  });

  test('native action parser accepts only explicit one-shot decisions', () {
    final payload = {'host': remoteHost.encode(), 'group': 'g', 'key': 'k', 'eventId': 'e', 'decision': 'allowed-once'};
    expect(NotifyAction.fromMap(payload)?.decision, ApprovalDecision.allowOnce);
    expect(NotifyAction.fromMap({...payload, 'decision': 'next'}), isNull);
    expect(NotifyAction.fromMap({...payload, 'eventId': ''}), isNull);
  });
}
