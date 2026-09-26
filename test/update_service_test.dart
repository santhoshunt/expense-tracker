import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:expense_tracker/services/update_service.dart';

/// A release as GitHub's /releases endpoint returns it, well formed unless
/// a test overrides a field.
Map<String, Object?> release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object?>>? assets,
  String body = 'Notes',
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'published_at': '2026-09-26T10:00:00Z',
  'body': body,
  'assets':
      assets ??
      [
        {
          'name': 'app-release.apk',
          'size': 68000000,
          'browser_download_url': UpdateService.assetUrlFor(tag),
        },
      ],
};

void main() {
  group('compareVersions', () {
    test('orders dotted numerics, ignoring v prefix and +build', () {
      expect(UpdateService.compareVersions('1.0.0', 'v1.1.0'), lessThan(0));
      expect(UpdateService.compareVersions('v2.0.0', '1.9.9'), greaterThan(0));
      expect(UpdateService.compareVersions('1.0.0+1', '1.0.0'), 0);
      expect(UpdateService.compareVersions('1.0', '1.0.0'), 0);
      expect(UpdateService.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
    });

    test('malformed input compares equal — never announces an update', () {
      expect(UpdateService.compareVersions('garbage', '1.0.0'), 0);
      expect(UpdateService.compareVersions('1.0.0', ''), 0);
      expect(UpdateService.compareVersions('1.x.0', '1.0.0'), 0);
    });
  });

  group('parseReleases', () {
    List<String> tags(List<Object?> json, [String current = '1.20.0']) => [
      for (final r in UpdateService.parseReleases(json, current)) r.tag,
    ];

    test('keeps newer releases, newest first, with their details', () {
      final out = UpdateService.parseReleases([
        release('v1.20.1'),
        release('v1.21.0', body: '  Fixes  '),
        release('v1.20.0'),
      ], '1.20.0');
      expect([for (final r in out) r.tag], ['v1.21.0', 'v1.20.1']);
      final top = out.first;
      expect(top.sizeBytes, 68000000);
      expect(top.notes, 'Fixes');
      expect(
        top.downloadUrl,
        'https://github.com/santhoshunt/expense-tracker/releases/download/'
        'v1.21.0/app-release.apk',
      );
      expect(top.publishedAt, isNotNull);
      expect(
        top.pageUrl,
        'https://github.com/santhoshunt/expense-tracker/releases/tag/v1.21.0',
      );
    });

    test('drops drafts, prereleases, and older or same versions', () {
      expect(
        tags([
          release('v1.21.0', draft: true),
          release('v1.21.0', prerelease: true),
          release('v1.20.0'),
          release('v1.19.0'),
        ]),
        isEmpty,
      );
    });

    test('drops a tag that is not vX.Y.Z', () {
      expect(
        tags([release('1.21.0'), release('v1.21.0-rc1'), release('v2')]),
        isEmpty,
      );
    });

    test('drops tags that could reach a path or pass for digits', () {
      for (final tag in [
        'v1.0.0/../x',
        'v1.21.0\n',
        'v١.0.0',
        'v1.2.3.4.5',
        'v1.21.0 ',
      ]) {
        expect(tags([release(tag)]), isEmpty, reason: tag);
      }
      expect(tags([release('v1.2.3.4')], '1.0.0'), ['v1.2.3.4']);
    });
    test('drops a release without exactly one app-release.apk', () {
      final apk = {
        'name': 'app-release.apk',
        'size': 100,
        'browser_download_url': UpdateService.assetUrlFor('v1.21.0'),
      };
      expect(tags([release('v1.21.0', assets: [])]), isEmpty);
      expect(
        tags([
          release(
            'v1.21.0',
            assets: [
              {...apk, 'name': 'app-debug.apk'},
            ],
          ),
        ]),
        isEmpty,
      );
      expect(
        tags([
          release('v1.21.0', assets: [apk, apk]),
        ]),
        isEmpty,
      );
    });

    test('drops an asset served from anywhere but its own release URL', () {
      for (final url in [
        'https://github.com/someone-else/expense-tracker/releases/download/'
            'v1.21.0/app-release.apk',
        'https://evil.example/app-release.apk',
        'http://github.com/santhoshunt/expense-tracker/releases/download/'
            'v1.21.0/app-release.apk',
        UpdateService.assetUrlFor('v1.20.9'),
      ]) {
        expect(
          tags([
            release(
              'v1.21.0',
              assets: [
                {
                  'name': 'app-release.apk',
                  'size': 100,
                  'browser_download_url': url,
                },
              ],
            ),
          ]),
          isEmpty,
          reason: url,
        );
      }
    });

    test('drops a size of zero, a missing size, or one over the cap', () {
      for (final size in [0, -1, null, UpdateService.maxAssetBytes + 1]) {
        expect(
          tags([
            release(
              'v1.21.0',
              assets: [
                {
                  'name': 'app-release.apk',
                  'size': size,
                  'browser_download_url': UpdateService.assetUrlFor('v1.21.0'),
                },
              ],
            ),
          ]),
          isEmpty,
          reason: '$size',
        );
      }
    });

    test('anything that is not a list of maps gives nothing', () {
      expect(UpdateService.parseReleases({'tag_name': 'v9.0.0'}, '1.0.0'), []);
      expect(UpdateService.parseReleases(['x', 3, null], '1.0.0'), []);
      expect(UpdateService.parseReleases(null, '1.0.0'), []);
    });
  });

  group('check', () {
    UpdateService service(MockClient client, {String current = '1.20.0'}) =>
        UpdateService(
          clientFactory: () => client,
          currentVersion: () async => current,
        );

    test('asks the releases list and returns the newer ones', () async {
      Uri? asked;
      final client = MockClient((request) async {
        asked = request.url;
        return http.Response(
          jsonEncode([release('v1.21.0'), release('v1.20.1')]),
          200,
        );
      });
      final result = await service(client).check();
      expect(
        asked.toString(),
        'https://api.github.com/repos/santhoshunt/expense-tracker/releases'
        '?per_page=30',
      );
      expect(result, isA<UpdateAvailable>());
      final update = result as UpdateAvailable;
      expect(update.latestTag, 'v1.21.0');
      expect(update.updates.newer, hasLength(2));
      expect(update.updates.currentVersion, '1.20.0');
      expect(update.htmlUrl, endsWith('/releases/tag/v1.21.0'));
    });

    test('nothing newer → UpToDate with the current version', () async {
      final client = MockClient(
        (request) async => http.Response(jsonEncode([release('v1.20.0')]), 200),
      );
      final result = await service(client).check();
      expect(result, isA<UpToDate>());
      expect((result as UpToDate).currentVersion, '1.20.0');
    });

    test('non-200 → CheckFailed naming the status', () async {
      final client = MockClient(
        (request) async => http.Response('rate limited', 403),
      );
      final result = await service(client).check();
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).message, contains('403'));
    });

    test('malformed JSON or a non-list → CheckFailed', () async {
      for (final body in [
        'not json',
        jsonEncode({'tag_name': 'v9.0.0'}),
      ]) {
        final client = MockClient((request) async => http.Response(body, 200));
        expect(await service(client).check(), isA<CheckFailed>());
      }
    });

    test('network error → CheckFailed', () async {
      final client = MockClient(
        (request) async => throw http.ClientException('no network'),
      );
      expect(await service(client).check(), isA<CheckFailed>());
    });
  });

  group('shouldCheckForUpdate', () {
    final now = DateTime(2026, 9, 26, 12);
    test('off never checks', () {
      expect(
        shouldCheckForUpdate(enabled: false, lastCheck: null, now: now),
        isFalse,
      );
    });
    test('never checked, or a day or more ago, checks', () {
      expect(
        shouldCheckForUpdate(enabled: true, lastCheck: null, now: now),
        isTrue,
      );
      expect(
        shouldCheckForUpdate(
          enabled: true,
          lastCheck: now.subtract(const Duration(hours: 24)),
          now: now,
        ),
        isTrue,
      );
    });
    test('within the day waits', () {
      expect(
        shouldCheckForUpdate(
          enabled: true,
          lastCheck: now.subtract(const Duration(hours: 23)),
          now: now,
        ),
        isFalse,
      );
    });
  });
}
