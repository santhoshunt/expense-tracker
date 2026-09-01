import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
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

/// Google Drive backup: daily/weekly/monthly auto-upload of the JSON backup
/// (gzipped) into a visible "Expense Tracker Backups" folder in My Drive,
/// plus restore of the newest one. Mirrors the Orbit app's service, with
/// restore added.
///
/// Prerequisites (one-time, Google Cloud Console):
///  1. A project with the Drive API enabled and an OAuth consent screen in
///     Testing mode listing the user's account.
///  2. An Android OAuth client for applicationId
///     `com.fabletest.expense_tracker` registered with the signing SHA-1
///     (release keystore, plus the debug keystore for `flutter run`).
///     No google-services.json is needed. A missing/mismatched client makes
///     signIn() return null with no further error.
///
/// Scope is `drive.file`: the app can only see files it created — enough to
/// manage its folder and backups, and that access survives reinstalls
/// (identity is the OAuth client, not the install).
class DriveBackupService {
  static const _freqKey = 'drive_backup_frequency';
  static const _lastKey = 'drive_last_backup_at';
  static const _folderIdKey = 'drive_backup_folder_id';
  static const _lastErrorKey = 'drive_last_error';

  static const folderName = 'Expense Tracker Backups';
  static const _filePrefix = 'expense_tracker_backup_';

  /// How many backups stay in Drive; older ones are pruned after each upload.
  static const keepBackups = 7;

  static const _scopes = [drive.DriveApi.driveFileScope];

  final GoogleSignIn _googleSignIn;

  DriveBackupService({GoogleSignIn? googleSignIn})
    : _googleSignIn = googleSignIn ?? GoogleSignIn(scopes: _scopes);

  // --- Auth -----------------------------------------------------------------

  /// Cached account, else a silent sign-in — never shows UI.
  Future<GoogleSignInAccount?> get currentUser async =>
      _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();

  /// Interactive sign-in; only call from an explicit user tap.
  Future<GoogleSignInAccount?> signIn() => _googleSignIn.signIn();

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_folderIdKey);
    // Account-scoped state must not survive a disconnect: a stale error
    // banner would contradict "Off until connected", and a stale last-backup
    // timestamp both shows "Last backup: 2h ago" for a new account that has
    // never been backed up AND makes isDue skip that account's first cycle.
    await prefs.remove(_lastKey);
    await prefs.remove(_lastErrorKey);
  }

  Future<drive.DriveApi> _api() async {
    final account = await currentUser;
    if (account == null) {
      throw Exception('Not signed in to Google');
    }
    final client = await _googleSignIn.authenticatedClient();
    if (client == null) {
      throw Exception('Could not get an authenticated Google client');
    }
    return drive.DriveApi(client);
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
  Future<String> uploadNow(
    FinanceProvider finance, {
    Map<String, dynamic>? settings,
  }) {
    return _inFlightUpload ??= () async {
      try {
        return await _uploadNow(finance, settings: settings);
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
  }) async {
    // Snapshot the ledger BEFORE any network await: sign-in and folder
    // lookups take seconds, and a "Delete all data" landing in that window
    // used to upload the emptied ledger as the newest backup.
    final payload = finance.exportData();
    // Preference block (monthly cap, alert flags, theme…) — SettingsProvider
    // state the finance snapshot can't see. Callers pass it when they have
    // the provider; a replace-mode restore applies it back.
    if (settings != null) payload['settings'] = settings;

    final api = await _api();
    final folderId = await _folderId(api);

    final bytes = await compute(
      encodeBackupGz,
      payload,
      debugLabel: 'encodeBackupGz',
    );
    final now = DateTime.now();
    final name = backupFileName(now);

    // A fresh Media per attempt: its stream is single-subscription, so it
    // must never be reused across retries (Orbit's update→create fallback
    // bug).
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

    // Retention: newest [keepBackups] stay, older ones go. Best-effort — a
    // prune hiccup must not fail the successful upload.
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
    return name;
  }

  /// Downloads the newest cloud backup, parsed and ready for
  /// `FinanceProvider.importData`. Throws when none exists.
  ///
  /// Falls back through the next-newest files when the newest one is
  /// corrupt (e.g. an upload aborted mid-create) — one bad file must not
  /// make every older good backup unreachable.
  Future<CloudBackup> downloadLatest() async {
    final api = await _api();
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
      final account = await currentUser;
      if (account == null) return; // Drive backup not connected — opt-in.
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
