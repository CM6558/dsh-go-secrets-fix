// Portions derived from ds-harness-remote (https://github.com/liguobao/ds-harness-remote), MIT, Copyright (c) 2026 DSH Remote contributors. See THIRD_PARTY_NOTICES.md.
// Relay-only client transport over the Server Control WebSocket.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../protocol/control.dart';
import '../util/bytes.dart';
import 'transport.dart';

/// Opens the Control WebSocket (`wss://<server>/ws/v1/connect`); injectable
/// for tests.
typedef ControlSocketConnector = Future<WebSocket> Function(Uri url, Duration timeout);

Future<WebSocket> _defaultConnector(Uri url, Duration timeout) => WebSocket.connect(url.toString()).timeout(timeout);

/// Diagnostic hook: every Control frame in or out (tokens redacted).
typedef ControlTracer = void Function(String direction, JsonMap frame);

/// Relay transport: `hello` → `hello.ack` → `connect.request` →
/// `connect.accepted`, then Noise handshake and ciphertext in `relay`
/// frames. Answers Server `ping` with `pong`; treats a silent socket
/// (no frame for 3 heartbeats) as dead.
///
/// One Control WebSocket per device: the Server closes an older socket of
/// the same device (`CONNECTION_REPLACED`, close code 4003), and a new
/// `connect.request` replaces the device's previous Host connection.
class RelayTransport implements SecureHandshakeTransport {
  RelayTransport._(this._socket, this._deviceId, this._hostDeviceId, this._tracer);

  /// Connects and waits for `connect.accepted`.
  ///
  /// Throws [RemoteTransportException]: `CONNECTION_FAILED` (socket, timeout),
  /// `AUTH_INVALID` / `TOKEN_EXPIRED` (access token refused — refresh and
  /// retry once), `HOST_OFFLINE`, `MEMBERSHIP_REQUIRED`,
  /// `CAPABILITY_NOT_SUPPORTED`, `CONNECTION_REJECTED` (Host refused),
  /// `INVALID_MESSAGE` (protocol violation).
  static Future<RelayTransport> connect({
    required Uri url,
    required String deviceId,
    required String accessToken,
    required String hostDeviceId,
    String? clientVersion,
    Duration timeout = const Duration(seconds: 10),
    ControlSocketConnector? connector,
    ControlTracer? tracer,
  }) async {
    final WebSocket socket;
    try {
      socket = await (connector ?? _defaultConnector)(url, timeout);
    } on WebSocketException catch (error) {
      final status = error.httpStatusCode;
      throw RemoteTransportException(
        status == 401 || status == 403 ? 'AUTH_INVALID' : 'CONNECTION_FAILED',
        'Control WebSocket failed: ${error.message}${status == null ? '' : ' (HTTP $status)'}',
      );
    } on TimeoutException {
      throw const RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect timed out.');
    } on SocketException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect failed: ${error.message}');
    } on HttpException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'Control WebSocket connect failed: ${error.message}');
    } on HandshakeException catch (error) {
      throw RemoteTransportException('CONNECTION_FAILED', 'TLS handshake failed: ${error.message}');
    }
    final transport = RelayTransport._(socket, deviceId, hostDeviceId, tracer);
    try {
      await transport._open(accessToken, clientVersion).timeout(timeout);
      return transport;
    } on TimeoutException {
      await transport._abort();
      throw const RemoteTransportException('CONNECTION_FAILED', 'Relay control handshake timed out.');
    } on Object {
      await transport._abort();
      rethrow;
    }
  }

  static const List<String> _offered = ['transport.relay'];

  final WebSocket _socket;
  final String _deviceId;
  final String _hostDeviceId;
  final ControlTracer? _tracer;
  ControlFrameLimits _limits = const ControlFrameLimits();
  String? _connectionId;
  Completer<void>? _ready;
  int _heartbeatMs = 25000;
  DateTime _lastReceived = DateTime.now();
  Timer? _watchdog;
  bool _closed = false;
  bool _closedNotified = false;

  TransportDataHandler? _onData;
  TransportHandshakeHandler? _onHandshake;
  TransportClosedHandler? _onClosed;
  final List<void Function()> _backlog = [];
  RemoteTransportClosed? _pendingClose;

  /// Negotiated `hello.ack` heartbeat.
  Duration get heartbeatInterval => Duration(milliseconds: _heartbeatMs);

  @override
  RemoteTransportMode get mode => RemoteTransportMode.relay;

  @override
  RemoteConnectionInfo get info {
    final id = _connectionId;
    if (id == null) throw StateError('relay connection has not been authorized');
    return RemoteConnectionInfo(connectionId: id, localDeviceId: _deviceId, remoteDeviceId: _hostDeviceId);
  }

  Future<void> _open(String accessToken, String? clientVersion) {
    final ready = _ready = Completer<void>();
    _socket.listen(
      _onMessage,
      onError: (Object error) => _fail(RemoteTransportClosed('CONNECTION_FAILED', 'Control socket error: $error')),
      onDone: () => _fail(_closeReason()),
      cancelOnError: true,
    );
    _sendControl('hello', {
      'role': 'client',
      'deviceId': _deviceId,
      'accessToken': accessToken,
      'protocols': [protocolVersion],
      'capabilities': _offered,
      'clientVersion': ?clientVersion,
    });
    return ready.future;
  }

  RemoteTransportClosed _closeReason() {
    final code = _socket.closeCode;
    final reason = _socket.closeReason ?? '';
    final known = RegExp(r'^[A-Z][A-Z0-9_]+$').hasMatch(reason) ? reason : null;
    if (code == 4003) {
      return RemoteTransportClosed(
        'CONNECTION_REPLACED',
        'Another connection of this device replaced the Control channel.',
        retryable: false,
        closeCode: code,
      );
    }
    return RemoteTransportClosed(
      known ?? 'CONNECTION_FAILED',
      'Control channel closed (${code ?? 'no code'} $reason)'.trim(),
      retryable: known == null || _retryableCodes.contains(known),
      closeCode: code,
    );
  }

  static const Set<String> _retryableCodes = {
    'CONNECTION_FAILED',
    'HOST_OFFLINE',
    'RATE_LIMITED',
    'SLOW_CONSUMER',
    'RELAY_UNAVAILABLE',
    'TOKEN_EXPIRED',
    'AUTH_INVALID',
  };

  void _onMessage(Object? raw) {
    if (_closed) return;
    _lastReceived = DateTime.now();
    final ControlFrame frame;
    try {
      if (raw is! String) throw const ProtocolError('Relay control frames must be text JSON.');
      frame = decodeControlFrame(raw, _limits);
    } on ProtocolError catch (error) {
      // A frame this client cannot parse (unknown type, bad field, newer
      // protocol version, oversize) fails the same way on every attempt:
      // stop rather than reconnect forever. Retrying is left to the person.
      // PROTOCOL_MISMATCH tells it apart from a REST reply that was not JSON
      // (a captive portal or proxy), which shares INVALID_MESSAGE.
      final code = error.code == 'INVALID_MESSAGE' ? 'PROTOCOL_MISMATCH' : error.code;
      _fail(RemoteTransportClosed(code, error.message, retryable: false));
      return;
    }
    _trace('in', frame.toJson());
    try {
      _handle(frame);
    } on ProtocolError catch (error) {
      // A well-formed frame out of turn (a race around a reconnect) is worth
      // another attempt; a refused capability or version is not.
      _fail(RemoteTransportClosed(error.code, error.message, retryable: !_incompatibleCodes.contains(error.code)));
    }
  }

  /// [ProtocolError] codes that say the two sides do not speak the same protocol.
  static const Set<String> _incompatibleCodes = {'UNSUPPORTED_VERSION', 'CAPABILITY_NOT_SUPPORTED', 'FRAME_TOO_LARGE'};

  void _handle(ControlFrame frame) {
    final p = frame.payload;
    switch (frame.type) {
      case 'hello.ack':
        if (_ready == null || _ready!.isCompleted) {
          throw const ProtocolError('Unexpected hello.ack.');
        }
        final caps = p['capabilities'];
        final List<String> negotiated;
        try {
          negotiated = acceptNegotiatedCapabilities(_offered, caps is List ? caps.cast<String>() : null);
        } on ProtocolError catch (error) {
          throw ProtocolError(error.message, 'CAPABILITY_NOT_SUPPORTED');
        }
        if (!negotiated.contains('transport.relay')) {
          throw const ProtocolError(
            'Server did not negotiate the required Relay capability.',
            'CAPABILITY_NOT_SUPPORTED',
          );
        }
        _limits = ControlFrameLimits(
          maxControlFrameBytes: asInt(p['maxControlFrameBytes']),
          maxRelayFrameBytes: asInt(p['maxRelayFrameBytes']),
        );
        _heartbeatMs = asInt(p['heartbeatIntervalMs']) ?? _heartbeatMs;
        _sendControl('connect.request', {
          'hostDeviceId': _hostDeviceId,
          'preferredTransports': const ['relay'],
        });
      case 'connect.accepted':
        final ready = _ready;
        if (ready == null || ready.isCompleted || _connectionId != null) {
          throw const ProtocolError('Unexpected connect.accepted.');
        }
        _connectionId = p['connectionId']! as String;
        _startWatchdog();
        ready.complete();
      case 'connect.rejected':
        if (_connectionId != null && p['connectionId'] != _connectionId) return;
        final code = asString(p['code']) ?? 'CONNECTION_REJECTED';
        _fail(
          RemoteTransportClosed(
            code,
            asString(p['message']) ?? 'The Host rejected the connection.',
            // The Server rejects with HOST_OFFLINE while a Host sleeps: keep
            // backing off so it reconnects once the Host is back.
            retryable: _retryableCodes.contains(code),
          ),
        );
      case 'error':
        final connectionId = asString(p['connectionId']);
        if (connectionId != null && _connectionId != null && connectionId != _connectionId) return;
        final code = p['code']! as String;
        _fail(
          RemoteTransportClosed(
            code,
            p['message']! as String,
            retryable: p['retryable'] == true || _retryableCodes.contains(code),
          ),
        );
      case 'relay':
        if (p['connectionId'] != _connectionId || p['targetDeviceId'] != _deviceId) {
          throw const ProtocolError('Received a relay frame for an unknown connection.');
        }
        final Uint8List data;
        try {
          data = fromBase64Url(p['ciphertext']! as String);
        } on FormatException {
          throw const ProtocolError('Relay ciphertext is not base64url.');
        }
        final counter = p['counter']! as int;
        _deliver(() => _onData!(data, counter));
      case 'secure.handshake':
        if (p['connectionId'] != _connectionId || p['targetDeviceId'] != _deviceId) {
          throw const ProtocolError('Received a secure handshake frame for an unknown connection.');
        }
        final Uint8List data;
        try {
          data = fromBase64Url(p['data']! as String);
        } on FormatException {
          throw const ProtocolError('Handshake data is not base64url.');
        }
        final step = p['step']! as int;
        _deliver(() => _onHandshake!(step, data));
      case 'ping':
        _sendControl('pong', {'nonce': p['nonce']});
      default:
        // pong, signaling and Host-only frames are not for a relay client.
        break;
    }
  }

  void _deliver(void Function() action) {
    if (_onData == null) {
      _backlog.add(action);
    } else {
      action();
    }
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    final period = Duration(milliseconds: _heartbeatMs);
    _watchdog = Timer.periodic(period, (_) {
      if (DateTime.now().difference(_lastReceived) > period * 3) {
        _fail(const RemoteTransportClosed('CONNECTION_FAILED', 'The Server Control channel went silent.'));
        unawaited(_socket.close(4000, 'heartbeat timeout'));
      }
    });
  }

  @override
  void listen({
    required TransportDataHandler onData,
    required TransportHandshakeHandler onHandshake,
    required TransportClosedHandler onClosed,
  }) {
    _onData = onData;
    _onHandshake = onHandshake;
    _onClosed = onClosed;
    final backlog = [..._backlog];
    _backlog.clear();
    for (final action in backlog) {
      action();
    }
    final pending = _pendingClose;
    if (pending != null && !_closedNotified) {
      _closedNotified = true;
      onClosed(pending);
    }
  }

  @override
  Future<void> sendHandshake(int step, Uint8List data) async {
    final id = _requireConnection();
    _sendControl('secure.handshake', {
      'connectionId': id,
      'targetDeviceId': _hostDeviceId,
      'step': step,
      'data': toBase64Url(data),
    });
  }

  @override
  Future<void> send(Uint8List ciphertext, {required int counter}) async {
    final id = _requireConnection();
    _sendControl('relay', {
      'connectionId': id,
      'targetDeviceId': _hostDeviceId,
      'counter': counter,
      'ciphertext': toBase64Url(ciphertext),
    });
  }

  String _requireConnection() {
    final id = _connectionId;
    if (_closed || id == null) {
      throw const RemoteTransportException('CONNECTION_FAILED', 'The relay connection is not open.');
    }
    return id;
  }

  void _sendControl(String type, JsonMap payload) {
    if (_closed) {
      throw const RemoteTransportException('CONNECTION_FAILED', 'The relay control socket is closed.');
    }
    final frame = ControlFrame(type, payload);
    final encoded = encodeControlFrame(frame, _limits);
    _trace('out', frame.toJson());
    _socket.add(encoded);
  }

  void _trace(String direction, JsonMap frame) {
    final tracer = _tracer;
    if (tracer == null) return;
    final payload = asMapOrEmpty(frame['payload']);
    tracer(direction, {
      ...frame,
      'payload': {
        ...payload,
        if (payload.containsKey('accessToken')) 'accessToken': '<redacted>',
        if (payload.containsKey('ciphertext')) 'ciphertext': '<${(payload['ciphertext']! as String).length} chars>',
      },
    });
  }

  void _fail(RemoteTransportClosed reason) {
    if (_closed) return;
    _closed = true;
    _watchdog?.cancel();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(
        RemoteTransportException(reason.code, reason.message, retryable: reason.retryable, closeCode: reason.closeCode),
      );
      // Avoid an unhandled error if the caller already gave up waiting.
      ready.future.ignore();
    } else if (_onClosed != null) {
      if (!_closedNotified) {
        _closedNotified = true;
        _onClosed!(reason);
      }
    } else {
      _pendingClose = reason;
    }
    unawaited(_socket.close(1000).catchError((Object _) {}));
  }

  Future<void> _abort() async {
    _closed = true;
    _watchdog?.cancel();
    await _socket.close(1000).catchError((Object _) {});
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _closedNotified = true;
    _watchdog?.cancel();
    await _socket.close(1000, 'client closed').catchError((Object _) {});
  }
}
