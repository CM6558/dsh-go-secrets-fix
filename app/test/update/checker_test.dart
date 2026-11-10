import 'package:dsh_app/update/checker.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _mirrors = [
  UpdateMirror.github,
  UpdateMirror(id: 'm1', label: 'mirror-one.example', prefix: 'https://mirror-one.example/'),
  UpdateMirror(id: 'm2', label: 'mirror-two.example', prefix: 'https://mirror-two.example/'),
];

const _api = 'https://api.github.com/repos/ccch1mneyyy/dsh-go/releases/latest';
const _manifest = 'https://github.com/ccch1mneyyy/dsh-go/releases/latest/download/update.json';
const _m1 = 'https://mirror-one.example/$_manifest';
const _m2 = 'https://mirror-two.example/$_manifest';
const _feed = 'https://update.example.com/dsh/update.json';

void main() {
  group('source order', () {
    const sources = UpdateSources(mirrors: _mirrors);

    test('metadata: API, then update.json through GitHub and each mirror', () {
      expect(sources.metadataEndpoints().map((e) => e.url.toString()), [_api, _manifest, _m1, _m2]);
      expect(sources.metadataEndpoints().map((e) => e.id), ['api', 'manifest:github', 'manifest:m1', 'manifest:m2']);
    });

    test('a self-hosted feed goes first', () {
      final withFeed = UpdateSources(feed: Uri.parse(_feed), mirrors: _mirrors);
      expect(withFeed.metadataEndpoints().first.url.toString(), _feed);
      expect(withFeed.metadataEndpoints(), hasLength(5));
    });

    test('whatever answered last time is tried first, the rest keep their order', () {
      expect(sources.metadataEndpoints(preferred: 'manifest:m2').map((e) => e.id), [
        'manifest:m2',
        'api',
        'manifest:github',
        'manifest:m1',
      ]);
      expect(sources.metadataEndpoints(preferred: 'gone').map((e) => e.id).first, 'api');
    });

    test('downloads: each GitHub URL through every mirror, preferred mirror first, others as they are', () {
      final asset = Uri.parse('https://github.com/ccch1mneyyy/dsh-go/releases/download/v1.2.0/a.apk');
      final cdn = Uri.parse('https://cdn.example.com/a.apk');
      final urls = sources.downloadUrls([cdn, asset, asset], preferredMirror: 'm1');
      expect(urls.map((u) => u.url.toString()), [
        'https://cdn.example.com/a.apk',
        'https://mirror-one.example/$asset',
        '$asset',
        'https://mirror-two.example/$asset',
      ]);
      expect(urls.map((u) => u.mirrorId), [null, 'm1', 'github', 'm2']);
      expect(urls[1].label, 'mirror-one.example');
    });
  });

  group('checker', () {
    test('API rate limited → GitHub update.json unreachable → first mirror answers', () async {
      final http = FakeHttp({
        _api: (_, _) =>
            textResponse('{"message":"API rate limit exceeded"}', status: 403, headers: {'x-ratelimit-remaining': '0'}),
        _m1: (_, _) => textResponse(fixture('update.json')),
        _m2: (_, _) => throw StateError('must not get this far'),
      });
      final result = await UpdateChecker(
        http: http,
        sources: const UpdateSources(mirrors: _mirrors),
      ).check();
      expect(http.urls, [_api, _manifest, _m1]);
      expect(result, isA<CheckFound>());
      final found = result as CheckFound;
      expect(found.release.version.toString(), '1.2.0+7');
      expect(found.endpoint.id, 'manifest:m1');
      expect(found.endpoint.mirrorId, 'm1');
    });

    test('API answers: GitHub headers are sent, nothing else is asked', () async {
      final http = FakeHttp({_api: (_, _) => textResponse(fixture('github_release.json'))});
      final result = await UpdateChecker(
        http: http,
        sources: const UpdateSources(mirrors: _mirrors),
      ).check();
      expect(result, isA<CheckFound>());
      expect(http.urls, [_api]);
      expect(http.requests.single.$2['accept'], 'application/vnd.github+json');
    });

    test('starts with the preferred endpoint', () async {
      final http = FakeHttp({_m2: (_, _) => textResponse(fixture('update.json'))});
      final result = await UpdateChecker(
        http: http,
        sources: const UpdateSources(mirrors: _mirrors),
      ).check(preferred: 'manifest:m2');
      expect(http.urls, [_m2]);
      expect((result as CheckFound).endpoint.id, 'manifest:m2');
    });

    test('a mirror answering 200 with an HTML page is skipped', () async {
      final http = FakeHttp({
        _api: (_, _) => textResponse('', status: 502),
        _manifest: (_, _) => textResponse('<html>blocked</html>'),
        _m1: (_, _) => textResponse(fixture('update.json')),
      });
      final result = await UpdateChecker(
        http: http,
        sources: const UpdateSources(mirrors: _mirrors),
      ).check();
      expect((result as CheckFound).endpoint.id, 'manifest:m1');
    });

    test('no release yet / private repository: 404 everywhere', () async {
      final notFound = textResponse('{"message":"Not Found"}', status: 404);
      final http = FakeHttp({_api: (_, _) => notFound, _manifest: (_, _) => notFound});
      final result = await UpdateChecker(http: http, sources: const UpdateSources()).check();
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).failure, CheckFailure.noRelease);
      expect(result.attempts.map((a) => a.$1), ['api', 'manifest:github']);
    });

    test('rate limiting is reported over network errors', () async {
      final http = FakeHttp({_api: (_, _) => textResponse('', status: 429)});
      final result = await UpdateChecker(
        http: http,
        sources: const UpdateSources(mirrors: _mirrors),
      ).check();
      expect((result as CheckFailed).failure, CheckFailure.rateLimited);
      expect(http.urls, [_api, _manifest, _m1, _m2]);
    });

    test('offline: every endpoint unreachable', () async {
      final http = FakeHttp();
      final result = await UpdateChecker(
        http: http,
        sources: const UpdateSources(mirrors: _mirrors),
      ).check();
      expect((result as CheckFailed).failure, CheckFailure.network);
      expect(http.urls, hasLength(4));
    });

    test('a 403 without the rate-limit header is not called rate limiting', () async {
      final http = FakeHttp({_api: (_, _) => textResponse('{"message":"Forbidden"}', status: 403)});
      final result = await UpdateChecker(http: http, sources: const UpdateSources()).check();
      expect((result as CheckFailed).failure, CheckFailure.badResponse);
    });
  });
}
