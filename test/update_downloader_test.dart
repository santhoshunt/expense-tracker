import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:expense_tracker/services/update_downloader.dart';
import 'package:expense_tracker/services/update_service.dart';

void main() {
  late Directory root;
  late Directory updates;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('updates_test');
    updates = Directory('${root.path}/updates');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  const tag = 'v1.21.0';
  final storage = Uri.parse(
    'https://release-assets.githubusercontent.com/github-production-release-'
    'asset/1/abc?sig=x',
  );

  ReleaseOption option({int size = 6}) => ReleaseOption(
    tag: tag,
    publishedAt: null,
    sizeBytes: size,
    notes: '',
    downloadUrl: UpdateService.assetUrlFor(tag),
  );

  http.StreamedResponse bytes(List<int> body, {int status = 200}) =>
      http.StreamedResponse(Stream.value(body), status);

  http.StreamedResponse redirect(String location) => http.StreamedResponse(
    const Stream.empty(),
    302,
    headers: {'location': location},
  );

  UpdateDownloader downloader(
    Future<http.StreamedResponse> Function(http.BaseRequest r) handler,
  ) => UpdateDownloader(
    clientFactory: () => MockClient.streaming((r, _) => handler(r)),
    dir: () async => updates,
    retryPause: Duration.zero,
  );

  Future<List<File>> files() async => await updates.exists()
      ? updates.listSync().whereType<File>().toList()
      : <File>[];

  Stream<List<int>> dropAfter(List<int> head, Uri url) async* {
    yield head;
    throw http.ClientException('Connection closed while receiving data', url);
  }

  test(
    'follows GitHub to its file storage and saves the exact bytes',
    () async {
      final seen = <Uri>[];
      var progress = 0;
      final file = await downloader((r) async {
        seen.add(r.url);
        expect(r.followRedirects, isFalse, reason: 'each hop is checked');
        return r.url.host == 'github.com'
            ? redirect(storage.toString())
            : bytes([1, 2, 3, 4, 5, 6]);
      }).download(option(), onProgress: (received, _) => progress = received);
      expect(seen.map((u) => u.host), [
        'github.com',
        'release-assets.githubusercontent.com',
      ]);
      expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(file.path, endsWith('$tag.apk'));
      expect(progress, 6);
    },
  );

  Future<void> expectRefused(
    UpdateDownloader d, {
    required String message,
    int size = 6,
  }) async {
    await expectLater(
      d.download(option(size: size)),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.message,
          'message',
          contains(message),
        ),
      ),
    );
    expect(await files(), isEmpty, reason: 'nothing left behind');
  }

  test('refuses a redirect off HTTPS or off GitHub', () async {
    for (final to in [
      'http://release-assets.githubusercontent.com/x',
      'https://evil.example/app.apk',
    ]) {
      await expectRefused(
        downloader(
          (r) async => r.url.host == 'github.com' ? redirect(to) : bytes([1]),
        ),
        message: 'Refused to download',
      );
    }
  });

  test(
    'refuses a hop with a port, user info or a protocol-relative host',
    () async {
      for (final to in [
        'https://release-assets.githubusercontent.com:8443/x',
        'https://github.com@evil.example/x',
        '//evil.example/x',
      ]) {
        await expectRefused(
          downloader(
            (r) async => r.url.host == 'github.com' && r.url.path.contains('/v')
                ? redirect(to)
                : bytes([1, 2, 3, 4, 5, 6]),
          ),
          message: 'Refused to download',
        );
      }
    },
  );

  test('a declared length that differs from the release is refused', () async {
    await expectRefused(
      downloader(
        (r) async => http.StreamedResponse(
          Stream.value([1, 2, 3, 4, 5, 6]),
          200,
          contentLength: 7,
        ),
      ),
      message: "size doesn't match",
    );
  });

  test(
    'cancel mid-stream stops at the next chunk and removes the file',
    () async {
      final chunks = StreamController<List<int>>();
      final cancel = DownloadCancel();
      final pending = downloader(
        (r) async => http.StreamedResponse(chunks.stream, 200),
      ).download(option(), cancel: cancel);
      chunks.add([1, 2]);
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      chunks.add([3, 4]);
      await expectLater(
        pending,
        throwsA(
          isA<UpdateDownloadException>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      // Not awaited: its done future waits for a listener that may be gone.
      unawaited(chunks.close());
      expect(await files(), isEmpty);
    },
  );
  test('gives up after five redirects', () async {
    await expectRefused(
      downloader((r) async => redirect(UpdateService.assetUrlFor(tag))),
      message: 'Too many redirects',
    );
  });

  test('rejects a body shorter or longer than the release says', () async {
    // A short body is retried like a drop, and its partial file is kept
    // for the next download to resume from.
    await expectLater(
      downloader((r) async => bytes([1, 2, 3])).download(option()),
      throwsA(
        isA<UpdateDownloadException>()
            .having((e) => e.message, 'message', contains('stopped early'))
            .having((e) => e.resumable, 'resumable', isTrue),
      ),
    );
    final kept = await files();
    expect(kept.map((f) => f.uri.pathSegments.last), ['$tag.apk']);
    expect(await kept.single.length(), 3);
    await updates.delete(recursive: true);
    await expectRefused(
      downloader((r) async => bytes([1, 2, 3, 4, 5, 6, 7])),
      message: 'larger than the release',
    );
  });

  test('a GitHub error status is reported', () async {
    await expectRefused(
      downloader((r) async => bytes([], status: 404)),
      message: 'HTTP 404',
    );
  });

  test('cancel stops the download and removes the file', () async {
    final cancel = DownloadCancel()..cancel();
    await expectLater(
      downloader(
        (r) async => bytes([1, 2, 3, 4, 5, 6]),
      ).download(option(), cancel: cancel),
      throwsA(isA<UpdateDownloadException>()),
    );
    expect(await files(), isEmpty);
  });

  test(
    'a dropped connection resumes where it stopped and follows GitHub again',
    () async {
      var github = 0;
      var stored = 0;
      var progress = 0;
      final file = await downloader((r) async {
        if (r.url.host == 'github.com') {
          github++;
          return redirect(storage.toString());
        }
        stored++;
        if (stored == 1) {
          return http.StreamedResponse(dropAfter([1, 2, 3], r.url), 200);
        }
        expect(r.headers['range'], 'bytes=3-');
        return http.StreamedResponse(
          Stream.value([4, 5, 6]),
          206,
          contentLength: 3,
          headers: {'content-range': 'bytes 3-5/6'},
        );
      }).download(option(), onProgress: (received, _) => progress = received);
      expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(github, 2, reason: 'the signed link is fetched again');
      expect(progress, 6);
    },
  );

  test('after three resumes it says the connection dropped, with no link or '
      'error text', () async {
    var stored = 0;
    Future<http.StreamedResponse> handler(http.BaseRequest r) async {
      if (r.url.host == 'github.com') return redirect(storage.toString());
      stored++;
      return http.StreamedResponse(dropAfter([1], r.url), 200);
    }

    await expectLater(
      downloader(handler).download(option()),
      throwsA(
        isA<UpdateDownloadException>()
            .having(
              (e) => e.message,
              'message',
              allOf(
                equals('The connection dropped. Try again.'),
                isNot(contains('http')),
                isNot(contains('uri=')),
                isNot(contains('ClientException')),
              ),
            )
            .having((e) => e.resumable, 'resumable', isTrue),
      ),
    );
    expect(stored, 4);
    // Each 200 restarts the file, so the kept partial holds one byte.
    final kept = await files();
    expect(kept.map((f) => f.uri.pathSegments.last), ['$tag.apk']);
    expect(await kept.single.length(), 1);
  });

  test('a second download resumes from the kept file', () async {
    // What the exhausted drops above leave behind.
    await updates.create(recursive: true);
    await File('${updates.path}/$tag.apk').writeAsBytes([1]);
    final file = await downloader((r) async {
      if (r.url.host == 'github.com') return redirect(storage.toString());
      expect(r.headers['range'], 'bytes=1-');
      return http.StreamedResponse(
        Stream.value([2, 3, 4, 5, 6]),
        206,
        contentLength: 5,
        headers: {'content-range': 'bytes 1-5/6'},
      );
    }).download(option());
    expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });

  test('a 200 to a Range request starts the file again', () async {
    var stored = 0;
    final file = await downloader((r) async {
      if (r.url.host == 'github.com') return redirect(storage.toString());
      stored++;
      return stored == 1
          ? http.StreamedResponse(dropAfter([1, 2, 3], r.url), 200)
          : bytes([1, 2, 3, 4, 5, 6]);
    }).download(option());
    expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });

  test('a 416 to a Range request starts again from 0', () async {
    await updates.create(recursive: true);
    await File('${updates.path}/$tag.apk').writeAsBytes([9, 9, 9]);
    var stored = 0;
    final file = await downloader((r) async {
      if (r.url.host == 'github.com') return redirect(storage.toString());
      stored++;
      if (stored == 1) {
        expect(r.headers['range'], 'bytes=3-');
        return bytes([], status: 416);
      }
      expect(r.headers.containsKey('range'), isFalse);
      return bytes([1, 2, 3, 4, 5, 6]);
    }).download(option());
    expect(await file.readAsBytes(), [1, 2, 3, 4, 5, 6]);
  });

  test('an unexpected error says the download failed, briefly', () async {
    await expectRefused(
      downloader((r) async => throw StateError('secret detail')),
      message: 'The download failed. Try again.',
    );
    await expectLater(
      downloader(
        (r) async => throw StateError('secret detail'),
      ).download(option()),
      throwsA(
        isA<UpdateDownloadException>().having(
          (e) => e.message,
          'message',
          isNot(contains('secret')),
        ),
      ),
    );
  });

  test('cleanup removes every downloaded update', () async {
    await updates.create(recursive: true);
    await File('${updates.path}/v1.0.0.apk').writeAsBytes([1]);
    await downloader((r) async => bytes([])).cleanup();
    expect(await updates.exists(), isFalse);
  });
}
