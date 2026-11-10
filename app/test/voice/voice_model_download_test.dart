import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/voice/voice_model_download.dart';
import 'package:flutter_test/flutter_test.dart';

/// A file server like ModelScope's: ranges (206 + Content-Range), or 200 when
/// [ranges] is off; [stallAfter] stops sending (connection kept open); a path
/// in [hang] answers that status, sends the headers and never ends the body.
class _Server {
  _Server(this.files);

  final Map<String, Uint8List> files;
  bool ranges = true;
  int? stallAfter;
  final hang = <String, int>{};
  final requests = <(String, String?)>[];
  late HttpServer _server;
  final _stalled = <HttpResponse>[];
  final _hung = <Socket>[];

  Uri url(String path) => Uri.parse('http://127.0.0.1:${_server.port}$path');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      requests.add((request.uri.path, range));
      final body = files[request.uri.path];
      final response = request.response;
      if (hang[request.uri.path] case final status?) {
        // The status line and headers go out; the promised body never does.
        response
          ..statusCode = status
          ..contentLength = 1000;
        _hung.add(await response.detachSocket());
        return;
      }
      if (body == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      var start = 0;
      final match = RegExp(r'^bytes=(\d+)-$').firstMatch(range ?? '');
      if (ranges && match != null) {
        start = int.parse(match.group(1)!);
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-${body.length - 1}/${body.length}');
      }
      response.contentLength = body.length - start;
      final stall = stallAfter;
      if (stall != null && start < stall) {
        response.add(body.sublist(start, stall));
        await response.flush();
        _stalled.add(response);
        return;
      }
      response.add(body.sublist(start));
      await response.close();
    });
  }

  Future<void> close() async {
    for (final r in _stalled) {
      unawaited(r.close().catchError((_) {}));
    }
    for (final socket in _hung) {
      socket.destroy();
    }
    await _server.close(force: true);
  }
}

Uint8List _bytes(int n, int seed) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 0xff]);

String _sha(Uint8List b) => sha256.convert(b).toString();

void main() {
  late Directory dir;
  late _Server server;
  final model = _bytes(300 * 1024, 7);
  final vad = _bytes(5000, 3);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('voice-dl');
    server = _Server({'/model.onnx': model, '/vad.onnx': vad});
    await server.start();
  });
  tearDown(() async {
    await server.close();
    await dir.delete(recursive: true);
  });

  VoiceDownloadJob job(String name, Uint8List body, {List<Uri>? urls, String? sha}) => VoiceDownloadJob(
    urls: urls ?? [server.url('/$name')],
    path: '${dir.path}/models/$name',
    bytes: body.length,
    sha256: sha ?? _sha(body),
  );

  test('downloads every file, checks it and gives it its final name', () async {
    final progress = <int>[];
    await downloadVoiceFiles([job('model.onnx', model), job('vad.onnx', vad)], onProgress: progress.add);
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
    expect(File('${dir.path}/models/vad.onnx').readAsBytesSync(), vad);
    expect(File('${dir.path}/models/model.onnx.dsh-go.part').existsSync(), isFalse);
    expect(progress.last, model.length + vad.length);
    expect(progress, orderedEquals([...progress]..sort()));
  });

  test('a partial file resumes with a range and the result is still checked whole', () async {
    final part = File('${dir.path}/models/model.onnx.dsh-go.part')..createSync(recursive: true);
    part.writeAsBytesSync(model.sublist(0, 100000));
    await downloadVoiceFiles([job('model.onnx', model)], onProgress: (_) {});
    expect(server.requests.single, ('/model.onnx', 'bytes=100000-'));
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
  });

  test('a whole .part (killed before its check) is checked and renamed without the network', () async {
    final part = File('${dir.path}/models/model.onnx.dsh-go.part')..createSync(recursive: true);
    part.writeAsBytesSync(model);
    await downloadVoiceFiles([job('model.onnx', model, urls: [Uri.parse('http://127.0.0.1:9/unreachable')])], onProgress: (_) {});
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
    expect(part.existsSync(), isFalse);
  });

  test('a whole .part with wrong content is thrown away; the next run downloads the file again', () async {
    final part = File('${dir.path}/models/model.onnx.dsh-go.part')..createSync(recursive: true);
    part.writeAsBytesSync(Uint8List(model.length));
    await expectLater(
      downloadVoiceFiles([job('model.onnx', model)], onProgress: (_) {}),
      throwsA(isA<VoiceDownloadException>().having((e) => e.kind, 'kind', VoiceDownloadError.integrity)),
    );
    expect(part.existsSync(), isFalse);
    expect(server.requests, isEmpty);
    await downloadVoiceFiles([job('model.onnx', model)], onProgress: (_) {});
    expect(server.requests.single, ('/model.onnx', null));
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
  });

  test('a server without ranges starts the file over', () async {
    server.ranges = false;
    File('${dir.path}/models/model.onnx.dsh-go.part')
      ..createSync(recursive: true)
      ..writeAsBytesSync(model.sublist(0, 4096));
    await downloadVoiceFiles([job('model.onnx', model)], onProgress: (_) {});
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
  });

  test('a file already in place is not fetched again', () async {
    File('${dir.path}/models/vad.onnx')
      ..createSync(recursive: true)
      ..writeAsBytesSync(vad);
    await downloadVoiceFiles([job('vad.onnx', vad)], onProgress: (_) {});
    expect(server.requests, isEmpty);
  });

  test('wrong content is thrown away and reported as integrity', () async {
    await expectLater(
      downloadVoiceFiles([job('model.onnx', model, sha: _sha(vad))], onProgress: (_) {}),
      throwsA(isA<VoiceDownloadException>().having((e) => e.kind, 'kind', VoiceDownloadError.integrity)),
    );
    expect(File('${dir.path}/models/model.onnx').existsSync(), isFalse);
    expect(File('${dir.path}/models/model.onnx.dsh-go.part').existsSync(), isFalse);
  });

  test('the next mirror is tried when one answers 404', () async {
    await downloadVoiceFiles([
      job('model.onnx', model, urls: [server.url('/gone.onnx'), server.url('/model.onnx')]),
    ], onProgress: (_) {});
    expect(server.requests.map((r) => r.$1), ['/gone.onnx', '/model.onnx']);
    expect(File('${dir.path}/models/model.onnx').existsSync(), isTrue);
  });

  test('every mirror failing reports the last reason (http status kept)', () async {
    await expectLater(
      downloadVoiceFiles([job('x.onnx', vad, urls: [server.url('/missing')])], onProgress: (_) {}),
      throwsA(
        isA<VoiceDownloadException>()
            .having((e) => e.kind, 'kind', VoiceDownloadError.http)
            .having((e) => e.status, 'status', 404),
      ),
    );
  });

  test('a stalled line times out and keeps what arrived for the next try', () async {
    server.stallAfter = 50000;
    await expectLater(
      downloadVoiceFiles([job('model.onnx', model)], onProgress: (_) {}, stall: const Duration(milliseconds: 300)),
      throwsA(isA<VoiceDownloadException>().having((e) => e.kind, 'kind', VoiceDownloadError.timeout)),
    );
    expect(File('${dir.path}/models/model.onnx.dsh-go.part').lengthSync(), 50000);
    server.stallAfter = null;
    await downloadVoiceFiles([job('model.onnx', model)], onProgress: (_) {});
    expect(server.requests.last.$2, 'bytes=50000-');
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
  });

  test('an error answer whose body never ends is closed: the next source is tried, or the failure reported', () async {
    server.hang['/busy.onnx'] = HttpStatus.serviceUnavailable;
    const stall = Duration(milliseconds: 300);
    // The only source: reported as its status instead of waiting for a body that never comes.
    await expectLater(
      downloadVoiceFiles([
        job('model.onnx', model, urls: [server.url('/busy.onnx')]),
      ], onProgress: (_) {}, stall: stall).timeout(const Duration(seconds: 5)),
      throwsA(
        isA<VoiceDownloadException>()
            .having((e) => e.kind, 'kind', VoiceDownloadError.http)
            .having((e) => e.status, 'status', 503),
      ),
    );
    // With another source: that one is used.
    await downloadVoiceFiles([
      job('model.onnx', model, urls: [server.url('/busy.onnx'), server.url('/model.onnx')]),
    ], onProgress: (_) {}, stall: stall).timeout(const Duration(seconds: 5));
    expect(server.requests.map((r) => r.$1), ['/busy.onnx', '/busy.onnx', '/model.onnx']);
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
  });

  test('cancel stops at the next chunk and keeps the partial file', () async {
    var cancelled = false;
    await expectLater(
      downloadVoiceFiles(
        [job('model.onnx', model)],
        onProgress: (done) {
          if (done > 0) cancelled = true;
        },
        progressEvery: Duration.zero,
        cancelled: () => cancelled,
      ),
      throwsA(isA<VoiceDownloadException>().having((e) => e.kind, 'kind', VoiceDownloadError.cancelled)),
    );
    expect(File('${dir.path}/models/model.onnx').existsSync(), isFalse);
    // Going on later finishes from what is there.
    await downloadVoiceFiles([job('model.onnx', model)], onProgress: (_) {});
    expect(File('${dir.path}/models/model.onnx').readAsBytesSync(), model);
  });

  test('the isolate task reports progress and completes', () async {
    final task = await VoiceDownloadTask.start([job('model.onnx', model), job('vad.onnx', vad)]);
    final seen = <int>[];
    final sub = task.progress.listen(seen.add);
    await task.done;
    await sub.cancel();
    expect(seen.last, model.length + vad.length);
    expect(File('${dir.path}/models/vad.onnx').readAsBytesSync(), vad);
  });

  test('the isolate task carries the failure kind back', () async {
    final task = await VoiceDownloadTask.start([job('vad.onnx', vad, sha: _sha(model))]);
    await expectLater(
      task.done,
      throwsA(isA<VoiceDownloadException>().having((e) => e.kind, 'kind', VoiceDownloadError.integrity)),
    );
  });
}
