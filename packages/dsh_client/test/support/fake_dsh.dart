import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Minimal in-process imitation of `dsh web` 0.2.0-rc.2's carrier: launch
/// token login, cookie check, Host/Origin fence, `POST /api/<endpoint>`
/// envelopes and the `/api/remote.mux` WebSocket with `$events`.
class FakeDsh {
  FakeDsh._(this._server);

  static const token = 'launch-token';
  static const cookieName = 'dsh-auth-test';
  static const cookieValue = 'v1.payload.sig';

  static Future<FakeDsh> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeDsh._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  int get port => _server.port;
  Uri get baseUri => Uri.parse('http://127.0.0.1:$port');

  /// Every HTTP request's method, path, and headers of interest.
  final List<Map<String, Object?>> requests = [];

  /// Decoded RPC envelopes in arrival order.
  final List<Map<String, Object?>> rpcCalls = [];

  /// Business handlers: endpoint -> args -> result (`{ok, value|error}`).
  final Map<String, Map<String, Object?> Function(Map<String, Object?> args)> handlers = {};

  /// Called for each logical stream the client opens (not `$events`).
  void Function(FakeMuxSocket socket, String streamId, String endpoint, Map<String, Object?> payload)? onOpen;

  /// Pending waterfalls redelivered to every new `$events` stream.
  final List<Map<String, Object?>> pendingWaterfalls = [];
  final List<FakeMuxSocket> sockets = [];
  int _generation = 0;
  bool rejectWebSocket = false;

  String? acceptedAuthority;
  String indexHtml = '';
  bool gzipIndex = false;
  Future<void> Function()? beforeIndex;

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.ws.close();
    }
    await _server.close(force: true);
  }

  bool _cookieOk(HttpRequest request) {
    final raw = request.headers.value(HttpHeaders.cookieHeader) ?? '';
    return raw.split(';').map((s) => s.trim()).contains('$cookieName=$cookieValue') &&
        request.headers.value('host') == (acceptedAuthority ?? '127.0.0.1:$port');
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add({
      'method': request.method,
      'path': request.uri.path,
      'rawPath': request.requestedUri.path,
      'host': request.headers.value('host'),
      'origin': request.headers.value('origin'),
      'cookie': request.headers.value(HttpHeaders.cookieHeader),
    });
    final response = request.response;
    final origin = request.headers.value('origin');
    if (origin != null && origin != 'http://${request.headers.value('host')}') {
      response.statusCode = 403;
      await response.close();
      return;
    }
    if (request.uri.path == '/' && request.method == 'GET') {
      final tokens = request.uri.queryParametersAll['token'] ?? const [];
      if (tokens.length == 1 && tokens.single == token) {
        acceptedAuthority = request.headers.value('host');
        response.statusCode = 303;
        response.headers
          ..set('location', './')
          ..add(
            'set-cookie',
            '$cookieName=$cookieValue; Max-Age=2592000; Path=/; '
                'Expires=Sat, 21 Nov 2099 19:10:16 GMT; HttpOnly; SameSite=Strict',
          );
        await response.close();
        return;
      }
      final html = indexHtml;
      final compressed = gzipIndex;
      if (beforeIndex != null) await beforeIndex!();
      response.statusCode = _cookieOk(request) && tokens.isEmpty ? 200 : 401;
      if (response.statusCode == 200) {
        if (compressed) {
          response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          response.add(gzip.encode(utf8.encode(html)));
        } else {
          response.write(html);
        }
      }
      await response.close();
      return;
    }
    if (request.uri.path == '/api/remote.mux') {
      if (rejectWebSocket || !_cookieOk(request)) {
        response.statusCode = 401;
        await response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      final socket = FakeMuxSocket(this, ws, ++_generation);
      sockets.add(socket);
      return;
    }
    if (!request.uri.path.startsWith('/api/')) {
      response.statusCode = 404;
      await response.close();
      return;
    }
    if (!_cookieOk(request)) {
      response.statusCode = 401;
      response.write('unauthorized');
      await response.close();
      return;
    }
    if (request.headers.contentType?.mimeType != 'application/json') {
      response.statusCode = 415;
      await response.close();
      return;
    }
    final envelope = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
    rpcCalls.add(envelope);
    final endpoint = request.requestedUri.path.substring('/api/'.length);
    final Map<String, Object?> result;
    if (envelope['method'] != endpoint) {
      result = {
        'ok': false,
        'error': {'code': 'gateway/bad-request', 'message': 'method mismatch', 'details': {}},
      };
    } else {
      final handler = handlers[endpoint];
      if (handler == null) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      final args = ((envelope['payload'] as Map)['args'] as Map).cast<String, Object?>();
      result = handler(args);
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'type': 'server-response', 'rpcId': envelope['rpcId'], 'result': result}));
    await response.close();
  }
}

class FakeMuxSocket {
  FakeMuxSocket(this.host, this.ws, this.generation) {
    ws.listen(_onMessage);
  }

  final FakeDsh host;
  final WebSocket ws;
  final int generation;
  String? eventsStreamId;
  final List<Map<String, Object?>> received = [];
  String get clientId => 'client-$generation';

  void send(Map<String, Object?> frame) => ws.add(jsonEncode(frame));
  void item(String streamId, Object? value) => send({'type': 'item', 'streamId': streamId, 'value': value});
  void event(Map<String, Object?> value) => item(eventsStreamId!, value);

  void _onMessage(Object? data) {
    final frame = (jsonDecode(data! as String) as Map).cast<String, Object?>();
    received.add(frame);
    if (frame['type'] != 'open') return;
    final streamId = frame['streamId']! as String;
    final endpoint = frame['endpoint']! as String;
    if (endpoint == r'$events') {
      eventsStreamId = streamId;
      event({
        'type': 'ready',
        'clientId': clientId,
        'host': {'home': '/home/user'},
      });
      for (final waterfall in host.pendingWaterfalls) {
        event(waterfall);
      }
      return;
    }
    host.onOpen?.call(this, streamId, endpoint, (frame['payload']! as Map).cast<String, Object?>());
  }
}
