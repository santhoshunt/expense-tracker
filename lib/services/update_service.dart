import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// One release the app may update to. Every field was checked by
/// [UpdateService.parseReleases]; [downloadUrl] is always this repo's own
/// release asset URL for [tag].
@immutable
class ReleaseOption {
  final String tag;
  final DateTime? publishedAt;
  final int sizeBytes;

  /// The release body, as GitHub wrote it (plain text / markdown).
  final String notes;
  final String downloadUrl;

  const ReleaseOption({
    required this.tag,
    required this.publishedAt,
    required this.sizeBytes,
    required this.notes,
    required this.downloadUrl,
  });

  /// The release's page on GitHub, for the browser fallback.
  String get pageUrl => '${UpdateService.releasesPageUrl}/tag/$tag';
}

/// The releases newer than [currentVersion], newest first. Never empty when
/// it is published through [availableUpdate].
@immutable
class UpdateList {
  final String currentVersion;
  final List<ReleaseOption> newer;
  const UpdateList(this.currentVersion, this.newer);
}

/// Outcome of a "Check for updates".
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

class UpToDate extends UpdateCheckResult {
  final String currentVersion;
  const UpToDate(this.currentVersion);
}

class UpdateAvailable extends UpdateCheckResult {
  final UpdateList updates;
  const UpdateAvailable(this.updates);

  /// The newest release's tag, e.g. `v1.2.0`.
  String get latestTag => updates.newer.first.tag;

  /// The newest release's page — where the APK asset lives.
  String get htmlUrl => updates.newer.first.pageUrl;
}

class CheckFailed extends UpdateCheckResult {
  final String message;
  const CheckFailed(this.message);
}

/// What the last successful check found, for the Overview banner: null
/// until a check finds something newer.
final ValueNotifier<UpdateList?> availableUpdate = ValueNotifier(null);

/// Whether the launch check is due: switched on, and a day or more since
/// the last one (or never run).
bool shouldCheckForUpdate({
  required bool enabled,
  required DateTime? lastCheck,
  required DateTime now,
}) {
  if (!enabled) return false;
  if (lastCheck == null) return true;
  return now.difference(lastCheck) >= const Duration(hours: 24);
}

/// Update check against the app's GitHub releases. Settings → About calls
/// it on demand; HomeScreen runs it once a day when that is switched on.
class UpdateService {
  static const repo = 'santhoshunt/expense-tracker';

  static const releasesListUrl =
      'https://api.github.com/repos/$repo/releases?per_page=30';

  /// The human-facing list of every release, for the browser.
  static const releasesPageUrl = 'https://github.com/$repo/releases';

  /// The only asset the app will download.
  static const assetName = 'app-release.apk';

  /// Larger than any real build (about 65 MB), small enough that a bogus
  /// size cannot fill the phone.
  static const maxAssetBytes = 200 * 1024 * 1024;

  /// The one download URL a release may carry for [tag].
  static String assetUrlFor(String tag) =>
      'https://github.com/$repo/releases/download/$tag/$assetName';

  static final _tagPattern = RegExp(r'^v\d+(\.\d+){1,3}$');

  /// Injectable so tests can supply a MockClient.
  final http.Client Function() _clientFactory;

  /// Injectable so tests don't need the platform channel.
  final Future<String> Function() _currentVersion;

  UpdateService({
    http.Client Function()? clientFactory,
    Future<String> Function()? currentVersion,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _currentVersion =
           currentVersion ??
           (() async => (await PackageInfo.fromPlatform()).version);

  /// Compares two dotted version strings (a leading `v` and any `+build`
  /// suffix are ignored): negative when [a] < [b], 0 when equal or either
  /// side is unreadable (an unparseable tag must not announce an update).
  static int compareVersions(String a, String b) {
    List<int>? parse(String s) {
      var v = s.trim();
      if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
      v = v.split('+').first;
      if (v.isEmpty) return null;
      final parts = v.split('.').map(int.tryParse).toList();
      if (parts.any((p) => p == null || p < 0)) return null;
      return parts.cast<int>();
    }

    final pa = parse(a);
    final pb = parse(b);
    if (pa == null || pb == null) return 0;
    for (var i = 0; i < pa.length || i < pb.length; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// The releases in a GitHub `/releases` response that the app may offer,
  /// newest first. The response is data from the network, so anything that
  /// does not look exactly like this repo's own release is dropped: drafts
  /// and prereleases, tags that are not newer or not `vX.Y.Z`, and any
  /// release without exactly one `app-release.apk` at its own URL with a
  /// sane size.
  static List<ReleaseOption> parseReleases(Object? json, String current) {
    if (json is! List) return const [];
    final out = <ReleaseOption>[];
    for (final r in json) {
      if (r is! Map) continue;
      if (r['draft'] != false || r['prerelease'] != false) continue;
      final tag = r['tag_name'];
      if (tag is! String || !_tagPattern.hasMatch(tag)) continue;
      if (compareVersions(current, tag) >= 0) continue;
      final assets = r['assets'];
      if (assets is! List) continue;
      final apks = [
        for (final a in assets)
          if (a is Map && a['name'] == assetName) a,
      ];
      if (apks.length != 1) continue;
      final apk = apks.single;
      if (apk['browser_download_url'] != assetUrlFor(tag)) continue;
      final size = apk['size'];
      if (size is! int || size <= 0 || size > maxAssetBytes) continue;
      final body = r['body'];
      final published = r['published_at'];
      out.add(
        ReleaseOption(
          tag: tag,
          publishedAt: published is String
              ? DateTime.tryParse(published)?.toLocal()
              : null,
          sizeBytes: size,
          notes: body is String ? body.trim() : '',
          downloadUrl: assetUrlFor(tag),
        ),
      );
    }
    out.sort((a, b) => compareVersions(b.tag, a.tag));
    return out;
  }

  /// The releases newer than this build, or why they could not be listed.
  Future<UpdateCheckResult> check() async {
    final String current;
    try {
      current = await _currentVersion();
    } catch (e) {
      return CheckFailed('Could not read the app version: $e');
    }
    final client = _clientFactory();
    try {
      final response = await client
          .get(
            Uri.parse(releasesListUrl),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return CheckFailed('GitHub returned HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body);
      if (data is! List) {
        return const CheckFailed('Unexpected response from GitHub');
      }
      final newer = parseReleases(data, current);
      return newer.isEmpty
          ? UpToDate(current)
          : UpdateAvailable(UpdateList(current, newer));
    } catch (e) {
      return CheckFailed('Could not reach GitHub: $e');
    } finally {
      client.close();
    }
  }
}
