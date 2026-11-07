import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

/// Why a download stopped. [message] is shown to the user as is.
class UpdateDownloadException implements Exception {
  final String message;

  /// The partial file stays on disk, and the next download of the same
  /// release resumes from it.
  final bool resumable;
  const UpdateDownloadException(this.message, {this.resumable = false});
  @override
  String toString() => message;
}

/// A server refused a Range request (HTTP 416): the bytes on disk are past
/// the file, so the next attempt starts from 0.
class _RangeRefused implements Exception {
  const _RangeRefused();
}

/// Lets the sheet's Cancel stop a running download at once: it closes the
/// download's connection rather than waiting for the next chunk.
class DownloadCancel {
  bool _cancelled = false;
  void Function()? _onCancel;
  bool get cancelled => _cancelled;
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
  }
}

/// Downloads a [ReleaseOption]'s APK into the app's private cache, where
/// only this app can write, for [UpdateInstaller] to verify and install.
///
/// The URL was checked by [UpdateService.parseReleases]; here every
/// redirect hop must stay on HTTPS and on GitHub's own hosts, and the file
/// must be exactly the size the release reported. The installer's signer
/// check is the final word either way.
class UpdateDownloader {
  /// GitHub serves release assets from these; nothing else is followed.
  static const allowedHosts = {
    'github.com',
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };
  static const maxRedirects = 5;

  /// Retries after a dropped connection, each from the bytes on disk.
  static const maxResumes = 3;

  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _dir;

  /// The wait before each retry; tests set it to zero.
  final Duration _retryPause;

  UpdateDownloader({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? dir,
    this._retryPause = const Duration(seconds: 2),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _dir = dir ?? defaultDir;

  /// `cacheDir/updates` on Android: app-private, cleared by the system
  /// under storage pressure.
  static Future<Directory> defaultDir() async =>
      Directory('${(await getTemporaryDirectory()).path}/updates');

  /// Removes every downloaded update. Runs at startup and after every
  /// attempt, so no APK outlives the install it was fetched for. A download
  /// keeps only its own partial file, to resume from.
  Future<void> cleanup() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort: a stale file is deleted on the next launch.
    }
  }

  /// Downloads [option] and returns the file. A dropped connection is
  /// resumed from the bytes on disk up to [maxResumes] times, re-following
  /// GitHub's redirect each time, since its signed link expires. Throws
  /// [UpdateDownloadException] on any problem or when [cancel] fires; every
  /// message is short and names no URL. The file is removed unless the
  /// exception is [UpdateDownloadException.resumable].
  Future<File> download(
    ReleaseOption option, {
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  }) async {
    final dir = await _dir();
    final name = '${option.tag}.apk';
    // Keeps only this release's partial file, to resume from.
    try {
      if (await dir.exists()) {
        await for (final entry in dir.list()) {
          final keep =
              entry is File &&
              entry.uri.pathSegments.last == name &&
              await entry.length() > 0 &&
              await entry.length() < option.sizeBytes;
          if (!keep) await entry.delete(recursive: true);
        }
      }
    } catch (_) {
      // Best effort: a stale file is deleted on the next launch.
    }
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name');
    final client = _clientFactory();
    cancel?._onCancel = client.close;
    try {
      final total = option.sizeBytes;
      Object? last;
      for (var attempt = 0; attempt <= maxResumes; attempt++) {
        if (attempt > 0) await Future<void>.delayed(_retryPause);
        if (cancel?.cancelled ?? false) {
          throw const UpdateDownloadException('Download cancelled.');
        }
        final from = await file.exists() ? await file.length() : 0;
        try {
          await _attempt(client, option, file, from, onProgress, cancel);
          last = null;
        } on UpdateDownloadException {
          rethrow;
        } on _RangeRefused {
          if (await file.exists()) await file.delete();
          last = null;
          continue;
        } catch (e) {
          if (cancel?.cancelled ?? false) {
            throw const UpdateDownloadException('Download cancelled.');
          }
          if (!_isDrop(e)) {
            throw const UpdateDownloadException(
              'The download failed. Try again.',
            );
          }
          last = e;
        }
        if (cancel?.cancelled ?? false) {
          throw const UpdateDownloadException('Download cancelled.');
        }
        if (await file.exists() && await file.length() == total) return file;
      }
      throw UpdateDownloadException(
        last is TimeoutException
            ? 'The download stalled. Try again.'
            : last != null
            ? 'The connection dropped. Try again.'
            : 'The download stopped early. Try again.',
        resumable: true,
      );
    } catch (e) {
      final keep =
          e is UpdateDownloadException &&
          e.resumable &&
          !(cancel?.cancelled ?? false);
      // This attempt's file only: another attempt may own the folder now.
      if (!keep) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          // Swept by the next cleanup.
        }
      }
      if (cancel?.cancelled ?? false) {
        throw const UpdateDownloadException('Download cancelled.');
      }
      if (e is UpdateDownloadException) rethrow;
      if (e is TimeoutException) {
        throw const UpdateDownloadException('The download stalled. Try again.');
      }
      throw const UpdateDownloadException('The download failed. Try again.');
    } finally {
      cancel?._onCancel = null;
      client.close();
    }
  }

  /// One GET of [option] into [file], resuming at [from] when the server
  /// answers the Range with 206, else writing the file again from 0. It
  /// returns when the body ends, however long; the caller reads the file's
  /// length.
  Future<void> _attempt(
    http.Client client,
    ReleaseOption option,
    File file,
    int from,
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  ) async {
    final response = await _follow(
      client,
      Uri.parse(option.downloadUrl),
      from: from,
    );
    final total = option.sizeBytes;
    final resumed = response.statusCode == 206;
    final start = resumed ? from : 0;
    final range = response.headers['content-range'];
    final declared = response.contentLength;
    if ((resumed && range != null && !range.startsWith('bytes $from-')) ||
        (declared != null && declared != total - start)) {
      throw const UpdateDownloadException(
        "The download's size doesn't match the release.",
      );
    }
    final sink = file.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    try {
      var received = start;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        if (cancel?.cancelled ?? false) {
          throw const UpdateDownloadException('Download cancelled.');
        }
        received += chunk.length;
        if (received > total) {
          throw const UpdateDownloadException(
            'The download is larger than the release says.',
          );
        }
        sink.add(chunk);
        onProgress?.call(received, total);
      }
    } finally {
      try {
        await sink.flush();
      } catch (_) {
        // The stream already failed; what was written stays.
      }
      try {
        await sink.close();
      } catch (_) {
        // As above.
      }
    }
  }

  /// A connection that dropped or stalled, worth resuming.
  static bool _isDrop(Object e) =>
      e is http.ClientException ||
      e is SocketException ||
      e is HttpException ||
      e is TimeoutException;

  /// GETs [url], following up to [maxRedirects] redirects by hand so each
  /// hop can be checked before anything is fetched from it. When resuming
  /// ([from] above 0) each hop carries the Range header, since GitHub's
  /// redirect ignores it and its file storage honours it.
  Future<http.StreamedResponse> _follow(
    http.Client client,
    Uri url, {
    int from = 0,
  }) async {
    var uri = url;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (uri.scheme != 'https' ||
          !allowedHosts.contains(uri.host) ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty) {
        throw UpdateDownloadException(
          'Refused to download from ${uri.scheme}://${uri.host}.',
        );
      }
      final request = http.Request('GET', uri)..followRedirects = false;
      if (from > 0) request.headers['range'] = 'bytes=$from-';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.isRedirect ||
          const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.drain<void>();
        if (location == null) {
          throw const UpdateDownloadException('GitHub sent a bad redirect.');
        }
        uri = uri.resolve(location);
        continue;
      }
      if (from > 0 && response.statusCode == 416) {
        await response.stream.drain<void>();
        throw const _RangeRefused();
      }
      if (response.statusCode != 200 &&
          !(from > 0 && response.statusCode == 206)) {
        await response.stream.drain<void>();
        throw UpdateDownloadException(
          'GitHub returned HTTP ${response.statusCode}.',
        );
      }
      return response;
    }
    throw const UpdateDownloadException('Too many redirects.');
  }
}
