// In-process imitation of a ds-harness-remote Server (REST + Control
// gateway, modelled on upstream apps/server) and a Host plugin (Noise
// responder + harness.remote.* bridge, modelled on upstream
// packages/plugin/src/server-connection.ts and harness-remote-bridge.ts).
// Upstream: https://github.com/liguobao/ds-harness-remote (MIT).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_remote/src/carrier/tunnel_carrier.dart' show harnessRemoteAllowlist;
import 'package:dsh_remote/src/crypto/noise_ik.dart';
import 'package:dsh_remote/src/protocol/control.dart';
import 'package:dsh_remote/src/protocol/messages.dart';
import 'package:dsh_remote/src/util/bytes.dart';

class FakeDevice {
  FakeDevice(this.descriptor);
  Map<String, Object?> descriptor;
  bool revoked = false;
  String get id => descriptor['deviceId']! as String;
  String get role => descriptor['role']! as String;
}

class FakeToken {
  FakeToken(this.kind, this.deviceId, this.expires);
  final String kind;
  final String deviceId;
  DateTime expires;
  bool used = false;
}

class FakePeer {
  FakePeer(this.ws, this.id, this.role, this.capabilities);
  final WebSocket ws;
  final String id;
  final String role;
  final List<String> capabilities;
}

class FakeLink {
  FakeLink(this.id, this.host, this.client);
  final String id;
  final String host;
  final String client;
  String stage = 'pending';
  final Map<String, int> counters = {};
}

class FakeRemoteServer {
  FakeRemoteServer._(this._server);

  static const account = 'e2e@example.test';
  static const password = 'fake-password-123';

  static Future<FakeRemoteServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeRemoteServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  final Map<String, FakeDevice> devices = {};
  final Map<String, FakeToken> _tokens = {};
  final Set<String> _webTokens = {};
  final Map<String, Map<String, Object?>> _qr = {};
  final Map<String, FakePeer> peers = {};
  final Map<String, FakeLink> links = {};
  final List<String> requests = [];

  /// One-shot response gates for real HTTP cancellation tests.
  Future<void> Function()? beforeAccountLookupResponse;
  Future<void> Function()? beforeRegistrationResponse;
  Duration accessTtl = const Duration(hours: 1);
  int refreshCount = 0;
  int controlConnects = 0;

  /// When set, hello is answered with this error code and the socket closed.
  String? rejectHelloWith;

  Future<void> close() async {
    for (final peer in [...peers.values]) {
      await peer.ws.close();
    }
    await _server.close(force: true);
  }

  String _secret() => toBase64Url(randomBytes(32));

  Map<String, Object?> _issue(String deviceId, {DateTime? refreshExpires}) {
    final access = _secret();
    final refresh = _secret();
    final accessExpires = DateTime.now().add(accessTtl);
    final refreshExpiresAt = refreshExpires ?? DateTime.now().add(const Duration(days: 30));
    _tokens[access] = FakeToken('access', deviceId, accessExpires);
    _tokens[refresh] = FakeToken('refresh', deviceId, refreshExpiresAt);
    return {
      'accessToken': access,
      'accessTokenExpiresAt': accessExpires.millisecondsSinceEpoch,
      'refreshToken': refresh,
      'refreshTokenExpiresAt': refreshExpiresAt.millisecondsSinceEpoch,
    };
  }

  /// Expires access tokens (of [deviceId] only, when given).
  void expireAccessTokens({String? deviceId}) {
    for (final token in _tokens.values) {
      if (token.kind == 'access' && (deviceId == null || token.deviceId == deviceId)) {
        token.expires = DateTime.now().subtract(const Duration(seconds: 1));
      }
    }
  }

  FakeDevice? _authenticate(String? header) {
    if (header == null || !header.startsWith('Bearer ')) return null;
    final token = _tokens[header.substring(7)];
    if (token == null || token.kind != 'access' || token.expires.isBefore(DateTime.now())) {
      return null;
    }
    final device = devices[token.deviceId];
    return device == null || device.revoked ? null : device;
  }

  /// Simulates the user approving a QR sign-in in the browser.
  void approveQr(String qrId) {
    final token = _secret();
    _webTokens.add(token);
    _qr[qrId]!['token'] = token;
  }

  /// Account web token as a password login would mint (for fixture Hosts).
  String mintWebToken() {
    final token = _secret();
    _webTokens.add(token);
    return token;
  }

  Map<String, Object?> _descriptor(FakeDevice d) => {
    ...d.descriptor,
    'membershipId': 'account:fake',
    'online': peers.containsKey(d.id),
    'lastSeenAt': 1786000000000,
  };

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    final response = request.response;
    final beforeResponse = switch (path) {
      '/api/v1/auth/me' => beforeAccountLookupResponse,
      '/api/v1/devices/register' => beforeRegistrationResponse,
      _ => null,
    };
    if (path == '/api/v1/auth/me') beforeAccountLookupResponse = null;
    if (path == '/api/v1/devices/register') beforeRegistrationResponse = null;
    Future<void> json(int status, Object? body) async {
      if (beforeResponse != null) await beforeResponse();
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      await response.close();
    }

    Future<void> error(int status, String code) => json(status, {
      'error': {'code': code, 'message': code, 'requestId': 'r', 'retryable': status >= 500},
    });

    Future<Map<String, Object?>> body() async =>
        (jsonDecode(await utf8.decodeStream(request)) as Map).cast<String, Object?>();

    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (path == '/ws/v1/connect') {
      final ws = await WebSocketTransformer.upgrade(request);
      _accept(ws);
      return;
    }
    if (request.method == 'GET' && path == '/health') return json(200, {'status': 'ok'});
    if (request.method == 'GET' && path == '/api/v1/auth/oauth/providers') {
      return json(200, {
        'items': [
          {
            'id': 'github',
            'displayName': 'GitHub',
            'startUrl': '/api/v1/auth/oauth/github/start',
            'qrStartUrl': '/api/v1/auth/oauth/qr/start?provider=github',
          },
        ],
      });
    }
    if (request.method == 'POST' && path == '/api/v1/auth/oauth/qr/start') {
      final qrId = 'qr-${_secret()}';
      _qr[qrId] = {'expires': DateTime.now().add(const Duration(minutes: 2))};
      return json(200, {'qrId': qrId, 'scanUrl': '$url/app/qr/$qrId', 'expiresIn': 120, 'provider': 'github'});
    }
    if (request.method == 'GET' && path.startsWith('/api/v1/auth/oauth/qr/')) {
      final session = _qr[Uri.decodeComponent(path.substring('/api/v1/auth/oauth/qr/'.length))];
      if (session == null) return error(404, 'NOT_FOUND');
      final token = session.remove('token');
      if (token != null) {
        session['claimed'] = true;
        return json(200, {'status': 'complete', 'token': token});
      }
      return json(200, {'status': session['claimed'] == true ? 'expired' : 'pending'});
    }
    if (request.method == 'POST' && path == '/api/v1/auth/login') {
      final b = await body();
      if (b['email'] != account || b['password'] != password) return error(401, 'AUTH_INVALID');
      return json(200, {'token': mintWebToken(), 'expiresAt': 1786000000000, 'account': account, 'isAdmin': false});
    }
    if (request.method == 'GET' && path == '/api/v1/auth/me') {
      if (auth == null || !_webTokens.contains(auth.substring(7))) {
        return error(401, 'ACCOUNT_AUTH_REQUIRED');
      }
      return json(200, {'account': account, 'isAdmin': false});
    }
    if (request.method == 'POST' && path == '/api/v1/devices/register') {
      if (auth == null || !_webTokens.contains(auth.substring(7))) {
        return error(401, 'ACCOUNT_AUTH_REQUIRED');
      }
      final device = ((await body())['device']! as Map).cast<String, Object?>();
      final old = devices[device['deviceId']];
      if (old != null && old.revoked) return error(403, 'DEVICE_REVOKED');
      if (old != null && old.descriptor['identityKey'] != device['identityKey']) {
        return error(409, 'PEER_IDENTITY_MISMATCH');
      }
      devices[device['deviceId']! as String] = FakeDevice(device);
      _tokens.removeWhere((_, t) => t.deviceId == device['deviceId']);
      return json(200, _issue(device['deviceId']! as String));
    }
    if (request.method == 'POST' && path == '/api/v1/auth/refresh') {
      final b = await body();
      final token = _tokens[b['refreshToken']];
      if (token == null || token.kind != 'refresh' || token.deviceId != b['deviceId']) {
        return error(401, 'AUTH_INVALID');
      }
      if (token.used) {
        _tokens.removeWhere((_, t) => t.deviceId == token.deviceId);
        return error(401, 'AUTH_INVALID');
      }
      token.used = true;
      refreshCount++;
      return json(200, _issue(token.deviceId, refreshExpires: token.expires));
    }
    final source = _authenticate(auth);
    if (source == null) return error(401, 'AUTH_INVALID');
    if (request.method == 'DELETE' && path == '/api/v1/devices/self') {
      source.revoked = true;
      return json(200, {'status': 'revoked'});
    }
    if (request.method == 'GET' && path == '/api/v1/devices') {
      if (source.role != 'client') return error(403, 'MEMBERSHIP_REQUIRED');
      return json(200, {
        'items': devices.values.where((d) => d.role == 'host' && !d.revoked).map((d) {
          final result = _descriptor(d)..remove('identityKey');
          if (separatePresence) result.remove('online');
          return result;
        }).toList(),
        'nextCursor': null,
      });
    }
    final presenceMatch = RegExp(r'^/api/v1/devices/([^/]+)/presence$').firstMatch(path);
    if (request.method == 'GET' && presenceMatch != null) {
      presenceRequests++;
      final target = devices[presenceMatch.group(1)];
      if (target == null) return error(404, 'DEVICE_NOT_FOUND');
      if (target.role == source.role) return error(403, 'MEMBERSHIP_REQUIRED');
      if (presenceError != null) return error(503, presenceError!);
      final d = _descriptor(target);
      return json(200, {'deviceId': d['deviceId'], 'online': d['online'], 'lastSeenAt': d['lastSeenAt']});
    }
    final match = RegExp(r'^/api/v1/devices/([^/]+)$').firstMatch(path);
    if (request.method == 'GET' && match != null) {
      final target = devices[match.group(1)];
      if (target == null) return error(404, 'DEVICE_NOT_FOUND');
      if (target.role == source.role) return error(403, 'MEMBERSHIP_REQUIRED');
      final result = _descriptor(target);
      if (separatePresence) result.remove('online');
      return json(200, result);
    }
    return error(404, 'METHOD_NOT_FOUND');
  }

  // --- Control gateway (relay only) ----------------------------------------

  bool separatePresence = false;
  String? presenceError;
  int presenceRequests = 0;

  final List<String> protocolErrors = [];

  void _send(FakePeer peer, String type, Map<String, Object?> payload) {
    if (peer.ws.closeCode != null) return;
    try {
      peer.ws.add(encodeControlFrame(ControlFrame(type, payload)));
    } on StateError {
      // socket already closing
    }
  }

  void _dropLink(FakeLink link, String code) {
    links.remove(link.id);
    for (final id in [link.host, link.client]) {
      final peer = peers[id];
      if (peer != null) {
        _send(peer, 'error', {'code': code, 'message': code, 'connectionId': link.id, 'retryable': true});
      }
    }
  }

  void disconnectPeer(String id, String code) {
    final peer = peers.remove(id);
    for (final link in [...links.values]) {
      if (link.host == id || link.client == id) _dropLink(link, code);
    }
    if (peer != null) unawaited(peer.ws.close(code == 'CONNECTION_REPLACED' ? 4003 : 4001, code));
  }

  void _accept(WebSocket ws) {
    controlConnects++;
    FakePeer? peer;
    ws.listen(
      (raw) {
        try {
          final frame = decodeControlFrame(raw as String);
          if (peer == null) {
            if (frame.type != 'hello') throw const ProtocolError('AUTH_REQUIRED');
            final p = frame.payload;
            if (rejectHelloWith != null) {
              ws.add(
                encodeControlFrame(ControlFrame('error', {'code': rejectHelloWith!, 'message': rejectHelloWith!})),
              );
              unawaited(ws.close(4001, rejectHelloWith));
              return;
            }
            final device = _authenticate('Bearer ${p['accessToken']}');
            if (device == null || device.id != p['deviceId'] || device.role != p['role']) {
              ws.add(encodeControlFrame(ControlFrame('error', {'code': 'AUTH_INVALID', 'message': 'AUTH_INVALID'})));
              unawaited(ws.close(4001, 'AUTH_INVALID'));
              return;
            }
            disconnectPeer(device.id, 'CONNECTION_REPLACED');
            final caps = (p['capabilities']! as List).cast<String>();
            final created = peer = FakePeer(ws, device.id, device.role, caps);
            peers[device.id] = created;
            _send(created, 'hello.ack', {
              'protocol': 1,
              'serverVersion': 'fake/0.1.0',
              'connectionSessionId': uuidV7(),
              'heartbeatIntervalMs': 25000,
              'maxControlFrameBytes': maxControlFrameBytes,
              'maxRelayFrameBytes': maxRelayFrameBytes,
              'capabilities': caps.contains('transport.relay') ? ['transport.relay'] : <String>[],
              'webrtcEnabled': false,
            });
            return;
          }
          _route(peer!, frame);
        } on ProtocolError catch (error) {
          protocolErrors.add(error.code);
          final connectionId = asString(asMap(asMap(tryDecodeJson(raw as String))?['payload'])?['connectionId']);
          if (peer != null && connectionId != null) {
            // Connection-scoped failure: tell the peer, keep its socket.
            _send(peer!, 'error', {'code': error.code, 'message': error.code, 'connectionId': connectionId});
          } else if (peer != null) {
            _send(peer!, 'error', {'code': error.code, 'message': error.message});
            disconnectPeer(peer!.id, error.code);
          } else {
            unawaited(ws.close(4001, error.code));
          }
        }
      },
      onDone: () {
        final current = peer;
        if (current != null && peers[current.id] == current) {
          disconnectPeer(current.id, 'CONNECTION_FAILED');
        }
      },
    );
  }

  void _route(FakePeer peer, ControlFrame frame) {
    final p = frame.payload;
    switch (frame.type) {
      case 'ping':
        _send(peer, 'pong', {'nonce': p['nonce']});
        return;
      case 'pong':
        return;
      case 'connect.request':
        final host = peers[p['hostDeviceId']];
        if (host == null || host.role != 'host') {
          _send(peer, 'error', {'code': 'HOST_OFFLINE', 'message': 'Host is offline.', 'retryable': true});
          return;
        }
        for (final old in [...links.values]) {
          if (old.client == peer.id) _dropLink(old, 'CONNECTION_REPLACED');
        }
        final link = FakeLink(uuidV7(), host.id, peer.id);
        links[link.id] = link;
        _send(host, 'connect.incoming', {
          'connectionId': link.id,
          'clientDeviceId': peer.id,
          'clientIdentityKey': devices[peer.id]!.descriptor['identityKey'],
          'authorization': 'account',
          'preferredTransports': ['relay'],
        });
        return;
    }
    final link = links[p['connectionId']];
    if (link == null || (peer.id != link.host && peer.id != link.client)) {
      throw const ProtocolError('CONNECTION_NOT_FOUND', 'CONNECTION_NOT_FOUND');
    }
    final other = peers[peer.id == link.host ? link.client : link.host];
    if (other == null) throw const ProtocolError('CONNECTION_FAILED', 'CONNECTION_FAILED');
    switch (frame.type) {
      case 'connect.accepted' || 'connect.rejected':
        if (peer.id != link.host) throw const ProtocolError('INVALID_MESSAGE');
        if (frame.type == 'connect.rejected') links.remove(link.id);
        link.stage = 'accepted';
      case 'secure.handshake':
        final step = p['step'];
        if (step == 1 && peer.id == link.client && link.stage == 'accepted') {
          link.stage = 'handshake';
        } else if (step == 2 && peer.id == link.host && link.stage == 'handshake') {
          link.stage = 'ready';
        } else {
          throw const ProtocolError('INVALID_MESSAGE');
        }
      case 'relay':
        final counter = p['counter']! as int;
        if (link.stage != 'ready' || counter <= (link.counters[peer.id] ?? -1)) {
          throw const ProtocolError('INVALID_MESSAGE');
        }
        link.counters[peer.id] = counter;
      default:
        return;
    }
    if (other.ws.closeCode == null) other.ws.add(encodeControlFrame(frame));
  }
}

/// Handle on one logical stream the fake Host opened.
class FakeHostStream {
  FakeHostStream(this._connection, this.streamId, this.endpoint, this.payload);

  final FakeHostConnection _connection;
  final String streamId;
  final String endpoint;
  final Map<String, Object?> payload;
  bool closed = false;

  Map<String, Object?> get args => (payload['args']! as Map).cast<String, Object?>();

  void push(Object? value) {
    if (closed) return;
    _connection.event('harness.remote.frame', {'streamId': streamId, 'hasValue': true, 'value': value});
  }

  /// Exact #161 Host wire shape, using the production chunk size.
  void pushTransferred(
    Object? value, {
    Map<String, Object?> Function(Map<String, Object?>)? changeDescriptor,
    Map<String, Object?> Function(Map<String, Object?>)? changeFrame,
  }) {
    final id = uuidV7();
    final frame = {'streamId': streamId, 'hasValue': true, 'value': value};
    final bytes = utf8.encode(jsonEncode(changeFrame?.call(frame) ?? frame));
    _connection.transfers[id] = {'out': bytes};
    final descriptor = <String, Object?>{
      'kind': 'chunked',
      'transferId': id,
      'totalBytes': bytes.length,
      'totalChunks': (bytes.length + 512 * 1024 - 1) ~/ (512 * 1024),
    };
    _connection.event('harness.remote.frame', {
      'streamId': streamId,
      'hasValue': true,
      'transfer': changeDescriptor?.call(descriptor) ?? descriptor,
    });
  }

  void complete() => _close('completed');

  void fail(String code, String message) =>
      _close('failed', {'code': code, 'message': message, 'details': <String, Object?>{}});

  void _close(String reason, [Map<String, Object?>? failure]) {
    if (closed) return;
    closed = true;
    _connection.streams.remove(streamId);
    _connection.event('harness.remote.stream.closed', {'streamId': streamId, 'reason': reason, 'failure': ?failure});
  }
}

class FakeHostConnection {
  FakeHostConnection(this.host, this.connectionId, this.clientId, this.noise);

  final FakeRemoteHost host;
  final String connectionId;
  final String clientId;
  final NoiseIkSession noise;
  final SecureMessageCodec incoming = SecureMessageCodec();
  final SecureMessageCodec outgoing = SecureMessageCodec();
  final Map<String, FakeHostStream> streams = {};
  final Map<String, Map<String, Object?>> transfers = {};
  bool ready = false;
  int eventsGeneration = 0;

  void send(RemoteMessage message) {
    for (final fragment in outgoing.encode(message.encode())) {
      final counter = noise.sendingCounter;
      host._sendControl('relay', {
        'connectionId': connectionId,
        'targetDeviceId': clientId,
        'counter': counter,
        'ciphertext': toBase64Url(noise.encrypt(fragment)),
      });
    }
  }

  void event(String name, Object? data) => send(RemoteMessage('event', {'event': name, 'data': data}));
}

/// Fake Host plugin: registers, keeps a Control socket, answers clients.
class FakeRemoteHost {
  FakeRemoteHost._(this.server, this.deviceId, this.keys);

  static Future<FakeRemoteHost> start(
    FakeRemoteServer server, {
    String name = 'Fake Workstation',
    X25519KeyPair? keys,
    String? deviceId,
  }) async {
    final identity = keys ?? X25519KeyPair.generate();
    final host = FakeRemoteHost._(server, deviceId ?? uuidV7(), identity);
    final client = HttpClient();
    try {
      final request = await client.postUrl(server.url.resolve('/api/v1/devices/register'));
      request.headers
        ..contentType = ContentType.json
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${server.mintWebToken()}');
      request.write(
        jsonEncode({
          'v': 1,
          'device': {
            'deviceId': host.deviceId,
            'name': name,
            'role': 'host',
            'platform': 'linux',
            'identityKey': identity.publicKeyBase64Url,
            'clientVersion': '0.5.17',
            'harnessVersion': '0.2.1-rc.2',
          },
        }),
      );
      final response = await request.close();
      host._tokens = (jsonDecode(await utf8.decodeStream(response)) as Map).cast<String, Object?>();
    } finally {
      client.close();
    }
    await host.goOnline();
    return host;
  }

  final FakeRemoteServer server;
  final String deviceId;
  X25519KeyPair keys;
  late Map<String, Object?> _tokens;
  WebSocket? _ws;
  final Map<String, FakeHostConnection> connections = {};

  /// `harness.transport.describe` capabilities.
  List<String> capabilities = ['transport.relay', 'harness.remote.v3', 'harness.remote.transfer.v1'];

  /// Unary handlers by endpoint; default: `gateway/not-found`.
  final Map<String, Map<String, Object?> Function(Map<String, Object?> args)> handlers = {};

  /// Called for each non-`$events` stream a client opens.
  void Function(FakeHostStream stream)? onOpen;

  /// Waterfalls replayed to every new `$events` stream.
  final List<Map<String, Object?>> pendingWaterfalls = [];

  /// Every unary call: endpoint and args.
  final List<(String, Map<String, Object?>)> calls = [];

  /// Every tunnel RPC method in order.
  final List<String> rpcMethods = [];
  final List<Map<String, Object?>> openedStreamParams = [];
  Future<Map<String, Object?>> Function(Map<String, Object?>)? transferRead;

  /// Responses above this many bytes answer RESPONSE_TOO_LARGE on the
  /// direct path (forces the transfer path).
  int? directResponseLimit;

  /// Simulates a Host whose plugin predates `harness.transport.describe`.
  bool describeUnsupported = false;
  bool stallDescribe = false;

  final Map<String, FakeHostStream> eventStreams = {};
  int _clientIds = 0;

  Future<void> goOnline() async {
    final ws = _ws = await WebSocket.connect('${server.url.toString().replaceFirst('http', 'ws')}/ws/v1/connect');
    final acked = Completer<void>();
    ws.listen((raw) {
      final frame = decodeControlFrame(raw as String);
      if (frame.type == 'hello.ack') {
        acked.complete();
        return;
      }
      unawaited(_onControl(frame));
    });
    _sendControl('hello', {
      'role': 'host',
      'deviceId': deviceId,
      'accessToken': _tokens['accessToken'],
      'protocols': [1],
      'capabilities': ['transport.relay'],
      'clientVersion': '0.5.17',
      'harnessVersion': '0.2.1-rc.2',
    });
    await acked.future;
  }

  Future<void> goOffline() async {
    await _ws?.close();
    _ws = null;
    connections.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// Drops every client connection (the Server reports CONNECTION_FAILED).
  void dropClients() {
    for (final link in [...server.links.values]) {
      if (link.host == deviceId) server._dropLink(link, 'CONNECTION_FAILED');
    }
    connections.clear();
  }

  void _sendControl(String type, Map<String, Object?> payload) =>
      _ws?.add(encodeControlFrame(ControlFrame(type, payload)));

  Future<void> _onControl(ControlFrame frame) async {
    final p = frame.payload;
    switch (frame.type) {
      case 'ping':
        _sendControl('pong', {'nonce': p['nonce']});
      case 'connect.incoming':
        final clientId = p['clientDeviceId']! as String;
        final client = HttpClient();
        try {
          final request = await client.getUrl(server.url.resolve('/api/v1/devices/$clientId'));
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${_tokens['accessToken']}');
          final response = await request.close();
          final descriptor = (jsonDecode(await utf8.decodeStream(response)) as Map).cast<String, Object?>();
          if (descriptor['identityKey'] != p['clientIdentityKey'] || descriptor['role'] != 'client') {
            _sendControl('connect.rejected', {'connectionId': p['connectionId']});
            return;
          }
        } finally {
          client.close();
        }
        final connectionId = p['connectionId']! as String;
        connections[connectionId] = FakeHostConnection(
          this,
          connectionId,
          clientId,
          NoiseIkSession(
            role: NoiseRole.responder,
            localPrivateKey: keys.privateKeyBase64Url,
            localPublicKey: keys.publicKeyBase64Url,
            remotePublicKey: p['clientIdentityKey']! as String,
            prologue: createNoisePrologue(connectionId, deviceId, clientId),
          ),
        );
        _sendControl('connect.accepted', {'connectionId': connectionId});
      case 'secure.handshake':
        final connection = connections[p['connectionId']];
        if (connection == null) return;
        connection.noise.readHandshake(fromBase64Url(p['data']! as String));
        final reply = connection.noise.writeHandshake();
        connection.ready = true;
        _sendControl('secure.handshake', {
          'connectionId': connection.connectionId,
          'targetDeviceId': connection.clientId,
          'step': 2,
          'data': toBase64Url(reply),
        });
      case 'relay':
        final connection = connections[p['connectionId']];
        if (connection == null) return;
        if (p['counter'] != connection.noise.receivingCounter) {
          throw StateError('relay counter mismatch');
        }
        final plain = connection.incoming.decode(connection.noise.decrypt(fromBase64Url(p['ciphertext']! as String)));
        if (plain == null) return;
        await _onMessage(connection, RemoteMessage.decode(plain));
      case 'error':
        final id = p['connectionId'];
        if (id != null) connections.remove(id);
    }
  }

  Future<void> _onMessage(FakeHostConnection connection, RemoteMessage message) async {
    if (message.type != 'rpc.request') return;
    final payload = (message.payload! as Map).cast<String, Object?>();
    final method = payload['method']! as String;
    final params = (payload['params'] as Map?)?.cast<String, Object?>() ?? const {};
    rpcMethods.add(method);
    void respond(Object? result) =>
        connection.send(RemoteMessage('rpc.response', {'requestId': message.id, 'result': result}));
    void reject(String code, String text) => connection.send(
      RemoteMessage('rpc.error', {'requestId': message.id, 'code': code, 'message': text, 'retryable': false}),
    );
    switch (method) {
      case 'harness.transport.describe':
        if (stallDescribe) return;
        if (describeUnsupported) return reject('METHOD_NOT_FOUND', 'Unknown method.');
        respond({'capabilities': capabilities});
      case 'harness.remote.call':
        final endpoint = params['endpoint']! as String;
        if (!harnessRemoteAllowlist.contains(endpoint)) {
          return reject('METHOD_NOT_ALLOWED', 'Not allowed.');
        }
        final result = _dispatch(connection, endpoint, params['payload']);
        final limit = directResponseLimit;
        if (limit != null && utf8.encode(jsonEncode(result)).length > limit) {
          return reject('RESPONSE_TOO_LARGE', 'Too large for a direct response.');
        }
        respond(result);
      case 'harness.remote.stream.open':
        openedStreamParams.add(params);
        if (params.containsKey('transferFrames') && !capabilities.contains('harness.remote.stream.transfer.v1')) {
          return reject('INVALID_MESSAGE', 'Old Host rejects unknown stream fields.');
        }
        final streamId = params['streamId']! as String;
        final endpoint = params['endpoint']! as String;
        if (!harnessRemoteAllowlist.contains(endpoint)) {
          return reject('METHOD_NOT_ALLOWED', 'Not allowed.');
        }
        if (connection.streams.length >= 16) return reject('RATE_LIMITED', 'Too many streams.');
        final stream = FakeHostStream(
          connection,
          streamId,
          endpoint,
          (params['payload']! as Map).cast<String, Object?>(),
        );
        connection.streams[streamId] = stream;
        respond({'opened': true, 'streamId': streamId});
        if (endpoint == r'$events') {
          eventStreams[connection.connectionId] = stream;
          stream.push({
            'type': 'ready',
            'clientId': 'remote-client-${++_clientIds}',
            'host': {'home': '/home/host'},
          });
          pendingWaterfalls.forEach(stream.push);
        } else {
          onOpen?.call(stream);
        }
      case 'harness.remote.stream.close':
        connection.streams[params['streamId']]?._close('cancelled');
        respond({'closed': true, 'streamId': params['streamId']});
      case 'harness.remote.transfer.open':
        connection.transfers[params['transferId']! as String] = {
          'totalBytes': params['totalBytes'],
          'totalChunks': params['totalChunks'],
          'chunks': <List<int>>[],
        };
        respond({'opened': true, 'transferId': params['transferId']});
      case 'harness.remote.transfer.chunk':
        final transfer = connection.transfers[params['transferId']]!;
        final chunks = transfer['chunks']! as List<List<int>>;
        if (params['index'] != chunks.length) return reject('INVALID_MESSAGE', 'Out of order.');
        chunks.add(base64Decode(params['data']! as String));
        respond({'accepted': true, 'transferId': params['transferId'], 'index': params['index']});
      case 'harness.remote.transfer.commit':
        final transfer = connection.transfers.remove(params['transferId'])!;
        final bytes = (transfer['chunks']! as List<List<int>>).expand((c) => c).toList();
        final request = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
        final result = _dispatch(connection, request['endpoint']! as String, request['payload']);
        final encoded = utf8.encode(jsonEncode(result));
        if (encoded.length <= 2 * 1024 * 1024) {
          respond({'kind': 'inline', 'response': result});
        } else {
          final total = (encoded.length + 512 * 1024 - 1) ~/ (512 * 1024);
          connection.transfers[params['transferId']! as String] = {'out': encoded};
          respond({
            'kind': 'chunked',
            'transferId': params['transferId'],
            'totalBytes': encoded.length,
            'totalChunks': total,
          });
        }
      case 'harness.remote.transfer.read':
        final out = connection.transfers[params['transferId']]!['out']! as List<int>;
        final index = params['index']! as int;
        final start = index * 512 * 1024;
        final end = start + 512 * 1024 < out.length ? start + 512 * 1024 : out.length;
        final result = <String, Object?>{
          'transferId': params['transferId'],
          'index': index,
          'data': base64Encode(out.sublist(start, end)),
        };
        respond(transferRead == null ? result : await transferRead!(result));
      case 'harness.remote.transfer.close':
        connection.transfers.remove(params['transferId']);
        respond({'closed': true, 'transferId': params['transferId']});
      default:
        reject('METHOD_NOT_FOUND', 'Unknown method $method.');
    }
  }

  Map<String, Object?> _dispatch(FakeHostConnection connection, String endpoint, Object? payload) {
    final args = ((payload! as Map)['args']! as Map).cast<String, Object?>();
    calls.add((endpoint, args));
    final handler = handlers[endpoint];
    if (handler == null) {
      return {
        'ok': false,
        'error': {'code': 'gateway/not-found', 'message': 'No handler for $endpoint', 'details': <String, Object?>{}},
      };
    }
    return handler(args);
  }

  /// Pushes a `$events` item to every connected client.
  void emitHostEvent(Map<String, Object?> value) {
    for (final stream in eventStreams.values) {
      stream.push(value);
    }
  }

  Future<void> close() async => goOffline();
}

/// Minimal session/follow snapshot as DSH 0.2 sends it.
Map<String, Object?> followSnapshot(
  String sessionId, {
  int cursor = -1,
  List<Map<String, Object?>> records = const [],
}) => {
  'type': 'snapshot',
  'header': {'version': 4, 'id': sessionId, 'createdAt': 1786000000000, 'cwd': '/home/host/ws', 'isSeeded': false},
  'cursor': cursor,
  'records': records,
  'hasMore': false,
  'projections': {'asOfSeq': cursor, 'values': <String, Object?>{}},
  'assistantStream': {'revision': 0},
};

Map<String, Object?> logRecord(int seq, String type, Map<String, Object?> data) => {
  'type': 'event',
  'event': {'type': type, 'seq': seq, 'time': 1786000000000 + seq, 'data': data},
};

Uint8List utf8Bytes(String text) => Uint8List.fromList(utf8.encode(text));
