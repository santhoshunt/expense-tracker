import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:expense_tracker/services/update_service.dart';

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

  group('check', () {
    UpdateService service(MockClient client, {String current = '1.0.0'}) =>
        UpdateService(
          clientFactory: () => client,
          currentVersion: () async => current,
        );

    MockClient github({required String tag, String url = 'https://x/rel'}) =>
        MockClient(
          (request) async => http.Response(
            jsonEncode({'tag_name': tag, 'html_url': url}),
            200,
          ),
        );

    test('newer release → UpdateAvailable with tag and page url', () async {
      final result = await service(github(tag: 'v1.1.0')).check();
      expect(result, isA<UpdateAvailable>());
      final update = result as UpdateAvailable;
      expect(update.latestTag, 'v1.1.0');
      expect(update.htmlUrl, 'https://x/rel');
    });

    test('same release → UpToDate with the current version', () async {
      final result = await service(github(tag: 'v1.0.0')).check();
      expect(result, isA<UpToDate>());
      expect((result as UpToDate).currentVersion, '1.0.0');
    });

    test('local build newer than the release → UpToDate', () async {
      final result = await service(
        github(tag: 'v1.0.0'),
        current: '1.1.0',
      ).check();
      expect(result, isA<UpToDate>());
    });

    test('non-200 → CheckFailed naming the status', () async {
      final client = MockClient(
        (request) async => http.Response('rate limited', 403),
      );
      final result = await service(client).check();
      expect(result, isA<CheckFailed>());
      expect((result as CheckFailed).message, contains('403'));
    });

    test('malformed JSON → CheckFailed', () async {
      final client = MockClient(
        (request) async => http.Response('not json', 200),
      );
      expect(await service(client).check(), isA<CheckFailed>());
    });

    test('missing tag_name → CheckFailed', () async {
      final client = MockClient(
        (request) async => http.Response(jsonEncode({'foo': 'bar'}), 200),
      );
      expect(await service(client).check(), isA<CheckFailed>());
    });

    test('network error → CheckFailed', () async {
      final client = MockClient(
        (request) async => throw http.ClientException('no network'),
      );
      expect(await service(client).check(), isA<CheckFailed>());
    });
  });
}
