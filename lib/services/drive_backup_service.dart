import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/finance_provider.dart';

/// Gzips the backup map. Top-level so [compute] can ship it to a worker
/// isolate — a full ledger is ~4 MB of JSON, ~10x smaller gzipped.
Uint8List encodeBackupGz(Map<String, dynamic> data) =>
    Uint8List.fromList(gzip.encode(utf8.encode(jsonEncode(data))));

/// Inverse of [encodeBackupGz]. Throws [FormatException] on anything that
/// isn't a gzipped JSON object.
Map<String, dynamic> decodeBackupGz(Uint8List bytes) {
  final List<int> raw;
  try {
    raw = gzip.decode(bytes);
  } catch (_) {
    throw const FormatException('Not a gzip backup file');
  }
  final decoded = jsonDecode(utf8.decode(raw));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Not an Expense Tracker backup file');
  }
  return decoded;
}

/// A downloaded cloud backup: the parsed payload plus when it was uploaded,
/// so the confirm UI can say which backup is about to be imported.
class CloudBackup {
  final Map<String, dynamic> data;
  final DateTime createdAt;
  final String name;

  const CloudBackup({
    required this.data,
    required this.createdAt,
    required this.name,
  });
}

/// Shown when Drive access has to be granted again (revoked, or a 6.x
/// connection Android didn't carry over). Settings offers Reconnect for it.
const kDriveReconnectMessage =
    'Reconnect Google Drive in Settings to keep backing up.';

/// Why Drive access could not be had. [message] is shown as is.
class DriveAuthException implements Exception {
  final String message;
  const DriveAuthException(this.message);
  @override
  String toString() => message;
}

/// Drive access tokens, behind a seam so tests can fake Google.
abstract class DriveAuth {
  /// A token for [scopes] without any UI, or null when the user has to
  /// grant access first. [email] pins the account; without it Google Play
  /// services picks one.
  Future<String?> silentToken(List<String> scopes, {String? email});

  /// Asks the user (account picker, then consent; with [email], that
  /// account's consent only). Throws [DriveAuthException] when cancelled
  /// or refused. Only from a tap.
  Future<String> interactiveToken(List<String> scopes, {String? email});

  /// Drops a token Google rejected, so the next request gets a fresh one.
  Future<void> forget(String accessToken);

  Future<void> signOut();
}

/// [DriveAuth] over google_sign_in 7's authorization client. Authorization
/// only, no sign-in: that needs just the Android OAuth client (package +
/// signing SHA-1), not the Web client ID a Credential Manager sign-in does.
class GoogleDriveAuth implements DriveAuth {
  Future<void>? _init;

  Future<void> _ready() =>
      _init ??= GoogleSignIn.instance.initialize().catchError((Object e) {
        _init = null; // retry next time rather than cache the failure
        throw e;
      });

  static const _cancelled = DriveAuthException(
    'Google Drive access was cancelled.',
  );
  static const _notSetUp = DriveAuthException(
    "Google Drive access isn't set up for this build of the app.",
  );

  /// Android's authorize path reports most failures as unknownError with
  /// the Play services status code in the text ("SDK reported an
  /// exception: 16: ..."): 16 is CANCELED, 10 DEVELOPER_ERROR (the OAuth
  /// client's package or signing SHA-1 doesn't match this build).
  @visibleForTesting
  static DriveAuthException mapped(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.canceled:
      case GoogleSignInExceptionCode.interrupted:
        return _cancelled;
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return _notSetUp;
      default:
        final status = RegExp(
          r'exception: (\d+)',
        ).firstMatch(e.description ?? '')?.group(1);
        if (status == '16') return _cancelled;
        if (status == '10') return _notSetUp;
        debugPrint('Google Drive authorization failed: ${e.description}');
        return const DriveAuthException(
          "Google Drive access didn't go through. Try again.",
        );
    }
  }

  /// Through the platform interface rather than
  /// `GoogleSignIn.instance.authorizationClient`, whose requests never name
  /// an account: without one, Play services picks the app's default
  /// account, which only a (never used) Credential Manager sign-in sets.
  Future<String?> _authorize(
    List<String> scopes, {
    required String? email,
    required bool prompt,
  }) async {
    await _ready();
    try {
      final data = await GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            ClientAuthorizationTokensForScopesParameters(
              request: AuthorizationRequestDetails(
                scopes: scopes,
                userId: null,
                email: email,
                promptIfUnauthorized: prompt,
              ),
            ),
          );
      return data?.accessToken;
    } on GoogleSignInException catch (e) {
      throw mapped(e);
    }
  }

  @override
  Future<String?> silentToken(List<String> scopes, {String? email}) =>
      _authorize(scopes, email: email, prompt: false);

  @override
  Future<String> interactiveToken(List<String> scopes, {String? email}) async {
    final token = await _authorize(scopes, email: email, prompt: true);
    if (token == null) throw _cancelled;
    return token;
  }

  @override
  Future<void> forget(String accessToken) async {
    try {
      await _ready();
      await GoogleSignIn.instance.authorizationClient.clearAuthorizationToken(
        accessToken: accessToken,
      );
    } catch (_) {
      // Best effort: an unusable token simply fails again.
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _ready();
      await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Nothing signed in, or no plugin (tests).
    }
  }
}

/// Google Drive backup: daily/weekly/monthly auto-upload of the JSON backup
/// (gzipped) into a visible "Expense Tracker Backups" folder in My Drive,
/// plus restore of the newest one.
///
/// Prerequisites (one-time, Google Cloud Console):
///  1. A project with the Drive API enabled and an OAuth consent screen
///     listing the user's account.
///  2. An Android OAuth client for applicationId
///     `com.fabletest.expense_tracker` registered with the signing SHA-1
///     (release keystore, plus the debug keystore for `flutter run`).
///     No google-services.json and no Web client ID: the app asks only for
///     Drive access, never a Google sign-in. A missing or mismatched client
///     shows as "isn't set up for this build".
///
/// Scope is `drive.file`: the app can only see files it created — enough to
/// manage its folder and backups, and that access survives reinstalls
/// (identity is the OAuth client, not the install).
///
/// google_sign_in 7 keeps no signed-in user, so "connected" is the email
/// stored at connect time. A connection made by 6.x (before 1.21) is
/// adopted silently on first use when Android still holds the grant.
class DriveBackupService {
  static const _freqKey = 'drive_backup_frequency';
  static const _lastKey = 'drive_last_backup_at';
  static const _folderIdKey = 'drive_backup_folder_id';
  static const _lastErrorKey = 'drive_last_error';
  static const _emailKey = 'drive_connected_email';

  static const folderName = 'Expense Tracker Backups';
  static const _filePrefix = 'expense_tracker_backup_';

  /// How many backups stay in Drive; older ones are pruned after each upload.
  static const keepBackups = 7;

  static const _scopes = [drive.DriveApi.driveFileScope];

  final DriveAuth _auth;
  final http.Client Function() _httpClient;

  DriveBackupService({DriveAuth? auth, http.Client Function()? httpClient})
    : _auth = auth ?? GoogleDriveAuth(),
      _httpClient = httpClient ?? http.Client.new;

  /// The token of the last Drive request, for [disconnect] to drop.
  String? _lastToken;

  // --- Connection -------------------------------------------------------------

  /// The connected Google account's email, or null when Drive backup is
  /// off. Never shows UI. A 6.x-era connection (a last backup or a folder,
  /// but no stored email) is adopted here when Android still has its
  /// grant; when it doesn't, the reconnect message lands in [lastError].
  Future<String?> connectedEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_emailKey);
    if (stored != null) return stored;
    if (prefs.getString(_lastKey) == null &&
        prefs.getString(_folderIdKey) == null) {
      return null; // never connected
    }
    try {
      final token = await _auth.silentToken(_scopes);
      if (token == null) {
        await prefs.setString(_lastErrorKey, kDriveReconnectMessage);
        return null;
      }
      final email = await _emailFor(token);
      await prefs.setString(_emailKey, email);
      return email;
    } on DriveAuthException catch (e) {
      await prefs.setString(_lastErrorKey, e.message);
      return null;
    } on AccessDeniedException {
      await prefs.setString(_lastErrorKey, kDriveReconnectMessage);
      return null;
    } catch (e) {
      // Offline, most likely: the grant may be fine, so no reconnect
      // prompt; the next launch tries again.
      debugPrint('Drive connection check failed: $e');
      return null;
    }
  }

  /// Asks for Drive access (account picker, consent) and remembers the
  /// account. Only call from an explicit user tap. Throws
  /// [DriveAuthException] when it doesn't happen.
  Future<String> connect() async {
    try {
      final token = await _auth.interactiveToken(_scopes);
      final email = await _emailFor(token);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_emailKey, email);
      await prefs.remove(_lastErrorKey);
      return email;
    } on DriveAuthException {
      rethrow;
    } catch (e) {
      debugPrint('Drive connect failed: $e');
      throw const DriveAuthException(
        "Couldn't connect Google Drive. Check the connection and try again.",
      );
    }
  }

  Future<void> disconnect() async {
    final token = _lastToken;
    _lastToken = null;
    if (token != null) await _auth.forget(token);
    await _auth.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_emailKey);
    await prefs.remove(_folderIdKey);
    // Account-scoped state must not survive a disconnect: a stale error
    // banner would contradict "Off until connected", and a stale last-backup
    // timestamp both shows "Last backup: 2h ago" for a new account that has
    // never been backed up AND makes isDue skip that account's first cycle.
    await prefs.remove(_lastKey);
    await prefs.remove(_lastErrorKey);
  }

  /// The account behind [token], from Drive's own about.get (allowed under
  /// `drive.file`), so no Google sign-in is needed to name it.
  Future<String> _emailFor(String token) async {
    final about = await _withDrive(
      (api) => api.about.get($fields: 'user(emailAddress)'),
      firstToken: token,
    );
    final email = about.user?.emailAddress;
    if (email == null || email.isEmpty) {
      throw const DriveAuthException(
        "Couldn't read which Google account was connected.",
      );
    }
    return email;
  }

  /// A fresh token for each operation (they last an hour; nothing here
  /// tracks expiry), for the stored account. Null from the silent path
  /// means access has to be granted again: a tap ([interactive]) asks for
  /// it there and then; a scheduled run records the reconnect message.
  Future<String> _token({bool interactive = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final email = prefs.getString(_emailKey);
    var token = await _auth.silentToken(_scopes, email: email);
    if (token == null && interactive) {
      token = await _auth.interactiveToken(_scopes, email: email);
    }
    if (token == null) throw const DriveAuthException(kDriveReconnectMessage);
    _lastToken = token;
    return token;
  }

  Future<T> _run<T>(
    String token,
    Future<T> Function(drive.DriveApi api) op,
  ) async {
    final base = _httpClient();
    final client = authenticatedClient(
      base,
      AccessCredentials(
        AccessToken(
          'Bearer',
          token,
          DateTime.now().toUtc().add(const Duration(minutes: 55)),
        ),
        null,
        _scopes,
      ),
    );
    try {
      return await op(drive.DriveApi(client));
    } finally {
      client.close();
      base.close();
    }
  }

  /// Runs [op] against Drive. A token Google rejects is dropped and the
  /// operation retried once with a fresh one. Google answers a bad token
  /// with 401 plus `WWW-Authenticate`, which googleapis_auth turns into
  /// [AccessDeniedException] before googleapis sees it; a bare 401 arrives
  /// as [drive.DetailedApiRequestError].
  Future<T> _withDrive<T>(
    Future<T> Function(drive.DriveApi api) op, {
    String? firstToken,
    bool interactive = false,
  }) async {
    final token = firstToken ?? await _token(interactive: interactive);
    _lastToken = token;
    try {
      return await _run(token, op);
    } on Exception catch (e) {
      final rejected =
          e is AccessDeniedException ||
          (e is drive.DetailedApiRequestError && e.status == 401);
      if (!rejected) rethrow;
      await _auth.forget(token);
      return _run(await _token(interactive: interactive), op);
    }
  }

  // --- Preferences ------------------------------------------------------------

  Future<String> getFrequency() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_freqKey) ?? 'daily';
  }

  Future<void> setFrequency(String freq) async {
    assert(freq == 'daily' || freq == 'weekly' || freq == 'monthly');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_freqKey, freq);
  }

  Future<DateTime?> lastBackupAt() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lastKey);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// Why the most recent backup attempt failed, or null when it succeeded.
  /// Scheduled runs swallow errors to protect startup, so Settings surfaces
  /// this — otherwise expired auth or quota errors go unnoticed forever.
  Future<String?> lastError() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastErrorKey);
  }

  // --- Folder -----------------------------------------------------------------

  /// Find-or-create the visible backups folder in My Drive. The id is cached
  /// in prefs; a vanished folder (user deleted it) is transparently
  /// re-created.
  Future<String> _folderId(drive.DriveApi api) async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_folderIdKey);
    if (cached != null) {
      try {
        final f =
            await api.files.get(cached, $fields: 'id, trashed') as drive.File;
        if (f.trashed != true) return cached;
      } catch (_) {
        // 404 → fall through to lookup/create.
      }
    }
    final existing = await api.files.list(
      q:
          "name = '$folderName' and "
          "mimeType = 'application/vnd.google-apps.folder' and trashed = false",
      $fields: 'files(id)',
      pageSize: 1,
    );
    String? id = existing.files?.firstOrNull?.id;
    id ??= (await api.files.create(
      drive.File()
        ..name = folderName
        ..mimeType = 'application/vnd.google-apps.folder',
    )).id;
    if (id == null) throw Exception('Could not create the Drive folder');
    await prefs.setString(_folderIdKey, id);
    return id;
  }

  // --- Backup -----------------------------------------------------------------

  @visibleForTesting
  static String backupFileName(DateTime now) =>
      '$_filePrefix${now.toIso8601String().split('.').first.replaceAll(':', '-')}'
      '.json.gz';

  /// A second uploadNow while one is in flight joins it instead of running a
  /// duplicate (a startup-scheduled upload racing a manual "Back up now"
  /// used to double-upload — two identically-named files, racing prefs
  /// writes and racing prunes).
  Future<String>? _inFlightUpload;

  /// Uploads a fresh backup and prunes old ones down to [keepBackups].
  /// Returns the uploaded file name.
  /// [interactive] (a tap) may ask for Drive access again when it was
  /// lost; the scheduled run never does.
  Future<String> uploadNow(
    FinanceProvider finance, {
    Map<String, dynamic>? settings,
    bool interactive = false,
  }) {
    return _inFlightUpload ??= () async {
      try {
        return await _uploadNow(
          finance,
          settings: settings,
          interactive: interactive,
        );
      } catch (e) {
        // Persist the failure so Settings shows it even when the caller
        // only toasts — a failed manual "Back up now" used to leave no
        // trace once the snackbar expired.
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_lastErrorKey, '$e');
        } catch (_) {
          // Recording the failure failed too — the rethrow still surfaces.
        }
        rethrow;
      } finally {
        _inFlightUpload = null;
      }
    }();
  }

  Future<String> _uploadNow(
    FinanceProvider finance, {
    Map<String, dynamic>? settings,
    required bool interactive,
  }) async {
    // Snapshot the ledger BEFORE any network await: sign-in and folder
    // lookups take seconds, and a "Delete all data" landing in that window
    // used to upload the emptied ledger as the newest backup.
    final payload = finance.exportData();
    // Preference block (monthly cap, alert flags, theme…) — SettingsProvider
    // state the finance snapshot can't see. Callers pass it when they have
    // the provider; a replace-mode restore applies it back.
    if (settings != null) payload['settings'] = settings;

    final bytes = await compute(
      encodeBackupGz,
      payload,
      debugLabel: 'encodeBackupGz',
    );
    final now = DateTime.now();
    final name = backupFileName(now);

    return _withDrive(interactive: interactive, (api) async {
      final folderId = await _folderId(api);
      // A fresh Media per attempt: its stream is single-subscription, so it
      // must never be reused across retries (the 401 retry included).
      await api.files.create(
        drive.File()
          ..name = name
          ..mimeType = 'application/gzip'
          ..parents = [folderId],
        uploadMedia: drive.Media(
          Stream.fromIterable([bytes]),
          bytes.length,
          contentType: 'application/gzip',
        ),
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_lastKey, now.toIso8601String());
      await prefs.remove(_lastErrorKey);
      await _prune(api, folderId);
      return name;
    });
  }

  /// Retention: newest [keepBackups] stay, older ones go. Best-effort — a
  /// prune hiccup must not fail the successful upload.
  Future<void> _prune(drive.DriveApi api, String folderId) async {
    try {
      // Paged: a folder that ever exceeds one page (e.g. after repeated
      // prune failures) must still be pruned in full, not just its first
      // 100 entries.
      final all = <drive.File>[];
      String? pageToken;
      do {
        final listed = await api.files.list(
          q:
              "'$folderId' in parents and name contains '$_filePrefix' "
              'and trashed = false',
          orderBy: 'createdTime desc',
          $fields: 'nextPageToken, files(id, name, createdTime)',
          pageSize: 100,
          pageToken: pageToken,
        );
        all.addAll(listed.files ?? const <drive.File>[]);
        pageToken = listed.nextPageToken;
      } while (pageToken != null);
      for (final f in all.skip(keepBackups)) {
        final id = f.id;
        if (id != null) await api.files.delete(id);
      }
    } catch (e) {
      debugPrint('Drive prune failed (upload succeeded): $e');
    }
  }

  /// Downloads the newest cloud backup, parsed and ready for
  /// `FinanceProvider.importData`. Throws when none exists.
  ///
  /// Falls back through the next-newest files when the newest one is
  /// corrupt (e.g. an upload aborted mid-create) — one bad file must not
  /// make every older good backup unreachable.
  Future<CloudBackup> downloadLatest({bool interactive = false}) =>
      _withDrive(_downloadLatest, interactive: interactive);

  Future<CloudBackup> _downloadLatest(drive.DriveApi api) async {
    final folderId = await _folderId(api);
    final listed = await api.files.list(
      q:
          "'$folderId' in parents and name contains '$_filePrefix' "
          'and trashed = false',
      orderBy: 'createdTime desc',
      $fields: 'files(id, name, createdTime)',
      pageSize: 5,
    );
    final candidates = listed.files ?? const <drive.File>[];
    if (candidates.isEmpty) {
      throw FormatException(
        'No cloud backup found in "$folderName" for this Google account.',
      );
    }
    Object? lastError;
    for (final f in candidates) {
      final id = f.id;
      if (id == null) continue;
      try {
        final media =
            await api.files.get(
                  id,
                  downloadOptions: drive.DownloadOptions.fullMedia,
                )
                as drive.Media;
        final builder = BytesBuilder(copy: false);
        await for (final chunk in media.stream) {
          builder.add(chunk);
        }
        final data = await compute(
          decodeBackupGz,
          builder.takeBytes(),
          debugLabel: 'decodeBackupGz',
        );
        return CloudBackup(
          data: data,
          createdAt: f.createdTime ?? DateTime.now(),
          name: f.name ?? '',
        );
      } on FormatException catch (e) {
        // Corrupt file — try the next-newest.
        debugPrint('Skipping corrupt cloud backup ${f.name}: $e');
        lastError = e;
      }
    }
    if (lastError is FormatException) throw lastError;
    throw const FormatException('Every cloud backup failed to decode.');
  }

  // --- Scheduled check — call on app start ------------------------------------

  /// Uploads silently when the cadence says one is due. Never blocks or
  /// crashes startup; failures land in [lastError] for Settings to show.
  Future<void> checkAndRunScheduled(
    FinanceProvider finance, {
    Map<String, dynamic>? settings,
  }) async {
    try {
      final email = await connectedEmail();
      if (email == null) return; // Drive backup not connected — opt-in.
      // Never let an empty ledger become the newest backup: a scheduled run
      // racing "Delete all data" (or firing on a freshly wiped device)
      // would push the real backups toward the retention cliff.
      if (!finance.hasTransactions) return;
      final last = await lastBackupAt();
      final freq = await getFrequency();
      if (!isDue(last, freq, DateTime.now())) return;
      await uploadNow(finance, settings: settings);
    } catch (e) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_lastErrorKey, '$e');
      } catch (_) {
        // Even recording the failure failed — nothing more to do silently.
      }
    }
  }

  @visibleForTesting
  static bool isDue(DateTime? last, String freq, DateTime now) {
    if (last == null) return true;
    // Clock moved backwards (manual change, TZ shenanigans): a "future" last
    // backup would otherwise stall the schedule indefinitely.
    if (last.isAfter(now)) return true;
    final diff = now.difference(last);
    return switch (freq) {
      'daily' => diff.inHours >= 23,
      'weekly' => diff.inDays >= 6,
      'monthly' => diff.inDays >= 28,
      _ => diff.inHours >= 23,
    };
  }

  // --- Display helpers ----------------------------------------------------------

  static String freqLabel(String freq) => switch (freq) {
    'daily' => 'Daily',
    'weekly' => 'Weekly',
    'monthly' => 'Monthly',
    _ => 'Daily',
  };

  static String formatLastBackup(DateTime? dt) {
    if (dt == null) return 'Never';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 2) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
