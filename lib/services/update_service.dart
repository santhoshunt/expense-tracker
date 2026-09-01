import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Outcome of a manual "Check for updates".
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

class UpToDate extends UpdateCheckResult {
  final String currentVersion;
  const UpToDate(this.currentVersion);
}

class UpdateAvailable extends UpdateCheckResult {
  /// The release tag, e.g. `v1.2.0`.
  final String latestTag;

  /// The release page — where the APK asset lives.
  final String htmlUrl;
  const UpdateAvailable({required this.latestTag, required this.htmlUrl});
}

class CheckFailed extends UpdateCheckResult {
  final String message;
  const CheckFailed(this.message);
}

/// Manual update check against the app's GitHub releases. No automatic
/// invocation, no stored state — Settings → About calls [check] on demand.
class UpdateService {
  static const releasesLatestUrl =
      'https://api.github.com/repos/santhoshunt/expense-tracker/releases/latest';

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
            Uri.parse(releasesLatestUrl),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return CheckFailed('GitHub returned HTTP ${response.statusCode}');
      }
      final data = jsonDecode(response.body);
      final tag = data is Map ? data['tag_name'] : null;
      final url = data is Map ? data['html_url'] : null;
      if (tag is! String || tag.isEmpty || url is! String || url.isEmpty) {
        return CheckFailed('Unexpected response from GitHub');
      }
      return compareVersions(current, tag) < 0
          ? UpdateAvailable(latestTag: tag, htmlUrl: url)
          : UpToDate(current);
    } catch (e) {
      return CheckFailed('Could not reach GitHub: $e');
    } finally {
      client.close();
    }
  }
}
