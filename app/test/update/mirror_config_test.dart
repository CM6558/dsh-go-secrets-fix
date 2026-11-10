// Update sources without a beta channel token (dev builds): GitHub and its
// accelerators only, never go.dshtui.com. A public copy of the release files
// can be added at build time (DSH_UPDATE_MIRROR).

import 'dart:convert';

import 'package:dsh_app/update/checker.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _api = 'https://api.github.com/repos/ccch1mneyyy/dsh-go/releases/latest';
const _apk = 'dsh-go-0.9.0-arm64.apk';
const _githubApk = 'https://github.com/ccch1mneyyy/dsh-go/releases/download/v0.9.0/$_apk';
const _mirror = 'https://dl.example.com';
const _mirrorFeed = '$_mirror/update.json';
const _mirrorApk = '$_mirror/download/0.9.0/$_apk';

void main() {
  group('defaults', () {
    final sources = buildUpdateSources();

    test('GitHub only: no channel, no feed, nothing on go.dshtui.com', () {
      expect(sources.channel, isNull);
      expect(sources.feed, isNull);
      expect(sources.mirrors.map((m) => m.id), ['github', 'ghfast', 'gh-proxy']);
      final endpoints = sources.metadataEndpoints();
      expect(endpoints.map((e) => e.id), ['api', 'manifest:github', 'manifest:ghfast', 'manifest:gh-proxy']);
      expect(endpoints.every((e) => e.headers.isEmpty), isTrue);
      final urls = sources.downloadUrls([Uri.parse(_githubApk)]);
      expect(urls.map((u) => u.url.toString()), [
        _githubApk,
        'https://ghfast.top/$_githubApk',
        'https://gh-proxy.com/$_githubApk',
      ]);
      expect(urls.every((u) => u.headers.isEmpty), isTrue);
      expect([for (final e in endpoints) e.url.host], isNot(contains('go.dshtui.com')));
    });

    test('the shipped configuration (no token in tests) is the same', () {
      final shipped = defaultUpdateSources();
      expect(shipped.channel, isNull);
      expect(shipped.feed, isNull);
      expect(shipped.metadataEndpoints().first.id, 'api');
    });
  });

  group('a public mirror, when a build asks for one', () {
    final sources = buildUpdateSources(mirror: '$_mirror/');

    test('its update.json comes first, then GitHub; downloads try it first', () {
      expect(sources.feed.toString(), _mirrorFeed);
      expect(sources.mirrors.map((m) => m.id), ['dshgo', 'github', 'ghfast', 'gh-proxy']);
      final urls = sources.downloadUrls([Uri.parse(_githubApk)]);
      expect(urls.map((u) => u.url.toString()), [
        _mirrorApk,
        _githubApk,
        'https://ghfast.top/$_githubApk',
        'https://gh-proxy.com/$_githubApk',
      ]);
      expect(urls.first.label, 'dl.example.com');
    });

    test('a manifest from the mirror: its URL first, no duplicate', () {
      final urls = sources.downloadUrls([Uri.parse(_mirrorApk), Uri.parse(_githubApk)]);
      expect(urls.map((u) => u.url.toString()), [
        _mirrorApk,
        _githubApk,
        'https://ghfast.top/$_githubApk',
        'https://gh-proxy.com/$_githubApk',
      ]);
    });

    test('whatever worked last still moves to the front', () {
      final urls = sources.downloadUrls([Uri.parse(_githubApk)], preferredMirror: 'github');
      expect(urls.first.url.toString(), _githubApk);
      expect(urls[1].url.toString(), _mirrorApk);
    });

    test('checksums go through the mirror too', () {
      final sums = githubReleaseAsset('v0.9.0', checksumsName);
      expect(sources.downloadUrls([sums]).first.url.toString(), '$_mirror/download/0.9.0/SHA256SUMS');
    });

    test('the mirror answers: its APK URL, nothing else asked', () async {
      final manifest = jsonEncode({
        'schema': 1,
        'version': '0.9.0+10251518',
        'tag': 'v0.9.0',
        'assets': {
          'arm64': {'name': _apk, 'size': 185254217, 'sha256': '1c' * 32, 'url': _mirrorApk},
        },
      });
      final http = FakeHttp({_mirrorFeed: (_, _) => textResponse(manifest)});
      final result = await UpdateChecker(http: http, sources: sources).check();
      expect(http.urls, [_mirrorFeed]);
      final found = result as CheckFound;
      expect(found.endpoint.id, 'feed');
      expect(found.release.apks[ApkFlavor.arm64]!.url.toString(), _mirrorApk);
    });

    test('the mirror is down or answers with an error page: GitHub answers', () async {
      var http = FakeHttp({_api: (_, _) => textResponse(fixture('github_release.json'))});
      var result = await UpdateChecker(http: http, sources: sources).check();
      expect(http.urls, [_mirrorFeed, _api]);
      expect((result as CheckFound).endpoint.id, 'api');

      http = FakeHttp({
        _mirrorFeed: (_, _) => textResponse('<html>502</html>', status: 502),
        _api: (_, _) => textResponse(fixture('github_release.json')),
      });
      result = await UpdateChecker(http: http, sources: sources).check();
      expect((result as CheckFound).endpoint.id, 'api');
    });
  });

  group('the mirror only maps tagged release files', () {
    final mirror = UpdateMirror.selfHosted(_mirror);

    test('tag → version directory', () {
      expect(
        mirror.rewrite(githubReleaseAsset('v1.3.0-beta.1', 'dsh-go-1.3.0-beta.1-x64.apk')).toString(),
        '$_mirror/download/1.3.0-beta.1/dsh-go-1.3.0-beta.1-x64.apk',
      );
    });

    test('nothing else', () {
      expect(mirror.rewrite(githubLatestAsset(updateManifestName)), isNull);
      expect(mirror.rewrite(githubReleaseAsset('0.9.0', _apk)), isNull);
      expect(mirror.rewrite(Uri.parse('https://github.com/someone/else/releases/download/v1.0.0/a.apk')), isNull);
      expect(mirror.rewrite(Uri.parse(_mirrorApk)), isNull);
    });
  });

  group('overrides', () {
    test('another feed', () {
      final sources = buildUpdateSources(feed: 'https://update.example.com/dsh/update.json');
      expect(sources.feed.toString(), 'https://update.example.com/dsh/update.json');
      expect(sources.metadataEndpoints().first.id, 'feed');
      expect(buildUpdateSources(mirror: _mirror, feed: '').feed, isNull);
    });

    test('accelerators replaced', () {
      final sources = buildUpdateSources(accelerators: 'https://a.example/');
      expect(sources.mirrors.map((m) => m.id), ['github', 'custom0']);
    });
  });
}
