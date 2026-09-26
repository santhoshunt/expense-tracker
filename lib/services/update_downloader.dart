import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

/// Why a download stopped. [message] is shown to the user as is.
class UpdateDownloadException implements Exception {
  final String message;
  const UpdateDownloadException(this.message);
  @override
  String toString() => message;
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

  final http.Client Function() _clientFactory;
  final Future<Directory> Function() _dir;

  UpdateDownloader({
    http.Client Function()? clientFactory,
    Future<Directory> Function()? dir,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _dir = dir ?? defaultDir;

  /// `cacheDir/updates` on Android: app-private, cleared by the system
  /// under storage pressure.
  static Future<Directory> defaultDir() async =>
      Directory('${(await getTemporaryDirectory()).path}/updates');

  /// Removes every downloaded update. Runs at startup and after every
  /// attempt, so no APK outlives the install it was fetched for.
  Future<void> cleanup() async {
    try {
      final dir = await _dir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // Best effort: a stale file is deleted on the next launch.
    }
  }

  /// Downloads [option] and returns the file. Throws
  /// [UpdateDownloadException] (the file removed) on any problem or when
  /// [cancel] fires.
  Future<File> download(
    ReleaseOption option, {
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  }) async {
    await cleanup();
    final dir = await _dir();
    await dir.create(recursive: true);
    final file = File('${dir.path}/${option.tag}.apk');
    final client = _clientFactory();
    cancel?._onCancel = client.close;
    IOSink? sink;
    try {
      if (cancel?.cancelled ?? false) {
        throw const UpdateDownloadException('Download cancelled.');
      }
      final response = await _follow(client, Uri.parse(option.downloadUrl));
      final total = option.sizeBytes;
      final declared = response.contentLength;
      if (declared != null && declared != total) {
        throw const UpdateDownloadException(
          "The download's size doesn't match the release.",
        );
      }
      sink = file.openWrite();
      var received = 0;
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
      if (cancel?.cancelled ?? false) {
        throw const UpdateDownloadException('Download cancelled.');
      }
      if (received != total) {
        throw const UpdateDownloadException(
          'The download stopped early. Try again.',
        );
      }
      await sink.flush();
      await sink.close();
      sink = null;
      return file;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {
        // The stream already failed; the file goes next.
      }
      // This attempt's file only: another attempt may own the folder now.
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Swept by the next cleanup.
      }
      if (cancel?.cancelled ?? false) {
        throw const UpdateDownloadException('Download cancelled.');
      }
      if (e is UpdateDownloadException) rethrow;
      if (e is TimeoutException) {
        throw const UpdateDownloadException('The download stalled. Try again.');
      }
      throw UpdateDownloadException('Download failed: $e');
    } finally {
      cancel?._onCancel = null;
      client.close();
    }
  }

  /// GETs [url], following up to [maxRedirects] redirects by hand so each
  /// hop can be checked before anything is fetched from it.
  Future<http.StreamedResponse> _follow(http.Client client, Uri url) async {
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
      if (response.statusCode != 200) {
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
