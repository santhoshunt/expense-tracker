import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The counting store below extends the plugin's in-memory store, which only
// the platform interface exports. shared_preferences brings it in.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

/// Counts exportData calls so tests can pin WHEN the snapshot is taken.
class _ProbeProvider extends FinanceProvider {
  int exportCalls = 0;

  @override
  Map<String, dynamic> exportData() {
    exportCalls++;
    return super.exportData();
  }
}

/// A ledger whose load warnings the test sets, whatever loaded.
class _WarnedProvider extends FinanceProvider {
  _WarnedProvider(this.warnings);

  final List<String> warnings;

  @override
  List<String> get loadWarnings => warnings;
}

/// The in-memory store, counting writes of the recorded Drive error.
class _CountingStore extends InMemorySharedPreferencesStore {
  _CountingStore(super.data) : super.withData();

  int errorWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.drive_last_error') errorWrites++;
    return super.setValue(valueType, key, value);
  }
}

/// Google, faked: [silent] is handed out in order (the last one repeats),
/// [interactive] answers a connect, or [interactiveError] refuses it.
class FakeDriveAuth implements DriveAuth {
  List<String?> silent;
  String interactive;
  DriveAuthException? interactiveError;
  int silentCalls = 0;
  int interactiveCalls = 0;
  int signOuts = 0;
  final forgotten = <String>[];
  final silentEmails = <String?>[];
  final interactiveEmails = <String?>[];

  FakeDriveAuth({
    this.silent = const [null],
    this.interactive = 'tok-interactive',
    this.interactiveError,
  });

  @override
  Future<String?> silentToken(List<String> scopes, {String? email}) async {
    silentCalls++;
    silentEmails.add(email);
    if (silent.length > 1) {
      final next = silent.first;
      silent = silent.sublist(1);
      return next;
    }
    return silent.single;
  }

  @override
  Future<String> interactiveToken(List<String> scopes, {String? email}) async {
    interactiveCalls++;
    interactiveEmails.add(email);
    final error = interactiveError;
    if (error != null) throw error;
    return interactive;
  }

  @override
  Future<void> forget(String accessToken) async => forgotten.add(accessToken);

  @override
  Future<void> signOut() async => signOuts++;
}

/// A backup file as Drive lists it, made at [at] by [install] (none for a
/// backup from before install ids), with [count] transactions.
Map<String, Object?> fakeBackupFile(
  String id,
  DateTime at, {
  String? install,
  String? name,
  int? count,
}) => {
  'id': id,
  'name': 'expense_tracker_backup_$id.json.gz',
  'createdTime': at.toUtc().toIso8601String(),
  if (install != null)
    'appProperties': {
      'install': install,
      'name': ?name,
      if (count != null) 'count': '$count',
    },
};

/// Drive v3, faked: about, folder lookup, and a folder of backup [files]
/// that uploads add to, listings return newest first, deletes remove from
/// and downloads read from [media]. The first [uploads401] uploads answer
/// 401, as for an expired token.
class FakeDrive {
  final String email;
  int uploads401;

  /// When set, about.get fails as if offline.
  bool offline;
  final requests = <http.Request>[];

  /// The backups in the folder, as [fakeBackupFile] builds them.
  final List<Map<String, Object?>> files;

  /// Each file's content by id, for a restore to download.
  final media = <String, List<int>>{};

  /// Ids of the files deleted, in order.
  final deleted = <String>[];

  /// The metadata of each upload, as the app sent it.
  final uploaded = <Map<String, dynamic>>[];

  /// Run once while the next listing or upload is in flight, to land
  /// something in the middle of it. The listing answers with the folder as
  /// it was when asked.
  Future<void> Function()? duringNextList;
  Future<void> Function()? duringNextUpload;

  FakeDrive({
    this.email = 'me@example.com',
    this.uploads401 = 0,
    this.offline = false,
    List<Map<String, Object?>>? files,
  }) : files = files ?? [];

  /// Uploads are newer than any file a test seeds, a minute apart.
  static final _uploadsFrom = DateTime.utc(2026, 11, 23, 12);

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/drive/v3/about')) {
      if (offline) throw const SocketException('offline');
      return _json({
        'user': {'emailAddress': email},
      });
    }
    if (path.endsWith('/upload/drive/v3/files')) {
      if (uploads401 > 0) {
        uploads401--;
        // As Google answers a bad token: the header makes googleapis_auth
        // throw AccessDeniedException before googleapis parses the body.
        return http.Response(
          jsonEncode({
            'error': {'code': 401, 'message': 'Invalid Credentials'},
          }),
          401,
          headers: {
            'content-type': 'application/json',
            'www-authenticate':
                'Bearer realm="https://accounts.google.com/", '
                'error="invalid_token"',
          },
        );
      }
      final hook = duringNextUpload;
      duringNextUpload = null;
      await hook?.call();
      // The multipart body's first JSON line is the file's metadata.
      final meta =
          jsonDecode(
                const LineSplitter()
                    .convert(request.body)
                    .firstWhere((l) => l.startsWith('{')),
              )
              as Map<String, dynamic>;
      uploaded.add(meta);
      final id = 'up${uploaded.length}';
      files.add({
        'id': id,
        'name': meta['name'],
        'createdTime': _uploadsFrom
            .add(Duration(minutes: uploaded.length))
            .toIso8601String(),
        'appProperties': meta['appProperties'],
      });
      return _json({'id': id, 'name': meta['name']});
    }
    if (path.endsWith('/drive/v3/files') && request.method == 'GET') {
      final q = request.url.queryParameters['q'] ?? '';
      if (q.contains('google-apps.folder')) {
        return _json({
          'files': [
            {'id': 'folder1'},
          ],
        });
      }
      // ISO times in UTC sort as text.
      final newestFirst = [...files]
        ..sort(
          (a, b) => (b['createdTime'] as String).compareTo(
            a['createdTime'] as String,
          ),
        );
      final hook = duringNextList;
      duringNextList = null;
      await hook?.call();
      return _json({'files': newestFirst});
    }
    if (path.contains('/drive/v3/files/')) {
      final id = request.url.pathSegments.last;
      if (request.method == 'DELETE') {
        deleted.add(id);
        files.removeWhere((f) => f['id'] == id);
        return http.Response('', 204);
      }
      if (request.url.queryParameters['alt'] == 'media') {
        final bytes = media[id];
        if (bytes == null) return _json({'error': 'not found'}, 404);
        return http.Response.bytes(
          bytes,
          200,
          headers: {'content-type': 'application/gzip'},
        );
      }
      return _json({'id': id, 'trashed': false});
    }
    return _json({'id': 'folder1'});
  });

  List<String?> get authHeaders => [
    for (final r in requests) r.headers['authorization'],
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isDue', () {
    final now = DateTime(2026, 8, 10, 9);

    test('never backed up → due', () {
      expect(DriveBackupService.isDue(null, 'daily', now), isTrue);
    });

    test('clock moved backwards (future last) → due', () {
      expect(
        DriveBackupService.isDue(
          now.add(const Duration(days: 2)),
          'daily',
          now,
        ),
        isTrue,
      );
    });

    test('daily: due after 23h, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(hours: 23)),
          'daily',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(hours: 22)),
          'daily',
          now,
        ),
        isFalse,
      );
    });

    test('weekly: due after 6 days, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 6)),
          'weekly',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 5)),
          'weekly',
          now,
        ),
        isFalse,
      );
    });

    test('monthly: due after 28 days, not before', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 28)),
          'monthly',
          now,
        ),
        isTrue,
      );
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 27)),
          'monthly',
          now,
        ),
        isFalse,
      );
    });

    test('unknown frequency falls back to daily', () {
      expect(
        DriveBackupService.isDue(
          now.subtract(const Duration(days: 1)),
          'bogus',
          now,
        ),
        isTrue,
      );
    });
  });

  group('gzip payload round-trip', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    test('a full exportData survives encode → decode intact', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 123.45,
        note: 'gym · lunch',
        date: DateTime(2026, 8, 1, 12, 30),
      );
      await p.addRule('chai corner', 'food');
      final data = p.exportData();

      final bytes = encodeBackupGz(data);
      final decoded = decodeBackupGz(bytes);

      expect(decoded['app'], 'expense_tracker');
      expect(decoded['version'], data['version']);
      expect(
        (decoded['transactions'] as List).length,
        (data['transactions'] as List).length,
      );
      // And the round-tripped payload is importable.
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
      final p2 = FinanceProvider();
      await p2.load();
      final added = await p2.importData(decoded, replace: true);
      expect(added, 1);
      expect(p2.transactions.single.note, 'gym · lunch');
      expect(p2.rules.any((r) => r.pattern == 'chai corner'), isTrue);
    });

    test('garbage bytes are rejected with FormatException', () {
      expect(
        () => decodeBackupGz(Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsFormatException,
      );
    });
  });

  group('Drive access (google_sign_in 7)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    DriveBackupService service(FakeDriveAuth auth, FakeDrive drive) =>
        DriveBackupService(auth: auth, httpClient: () => drive.client);

    Future<FinanceProvider> withRows() async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'lunch',
        date: DateTime(2026, 9, 1),
      );
      return p;
    }

    test('connect names the account from Drive and remembers it', () async {
      final auth = FakeDriveAuth();
      final drive = FakeDrive();
      final svc = service(auth, drive);
      expect(await svc.connectedEmail(), isNull, reason: 'never connected');
      expect(auth.silentCalls, 0, reason: 'nothing asked of Google');

      expect(await svc.connect(), 'me@example.com');
      expect(await svc.connectedEmail(), 'me@example.com');
      expect(await svc.lastError(), isNull);
      expect(drive.authHeaders.single, 'Bearer tok-interactive');
    });

    test('a cancelled connect stores nothing', () async {
      final auth = FakeDriveAuth(
        interactiveError: const DriveAuthException('cancelled'),
      );
      final svc = service(auth, FakeDrive());
      await expectLater(svc.connect(), throwsA(isA<DriveAuthException>()));
      expect(await svc.connectedEmail(), isNull);
    });

    test('a 6.x connection is adopted silently when Android still has the '
        'grant', () async {
      SharedPreferences.setMockInitialValues({
        'drive_last_backup_at': '2026-09-25T08:00:00.000',
      });
      final auth = FakeDriveAuth(silent: ['tok-old']);
      final svc = service(auth, FakeDrive());
      expect(await svc.connectedEmail(), 'me@example.com');
      expect(auth.interactiveCalls, 0, reason: 'never shows UI');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('drive_connected_email'), 'me@example.com');
    });

    test(
      'a 6.x connection without the grant asks to reconnect, silently',
      () async {
        SharedPreferences.setMockInitialValues({
          'drive_last_backup_at': '2026-09-25T08:00:00.000',
        });
        final auth = FakeDriveAuth();
        final svc = service(auth, FakeDrive());
        expect(await svc.connectedEmail(), isNull);
        expect(await svc.lastError(), kDriveReconnectMessage);
        expect(auth.interactiveCalls, 0);
      },
    );

    test('a scheduled backup without a token records the reconnect message '
        'and shows no UI', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final auth = FakeDriveAuth();
      final drive = FakeDrive();
      await service(auth, drive).checkAndRunScheduled(await withRows());
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('drive_last_error'), kDriveReconnectMessage);
      expect(auth.interactiveCalls, 0);
      expect(drive.requests, isEmpty);
    });

    Iterable<http.Request> uploads(FakeDrive d) =>
        d.requests.where((r) => r.url.path.endsWith('/upload/drive/v3/files'));

    test('a scheduled backup is skipped while a collection failed to load, '
        'says so once, and a clean launch uploads and clears it', () async {
      final store = _CountingStore({
        'flutter.drive_connected_email': 'me@example.com',
        'flutter.saved_filters_v1': '{broken',
      });
      SharedPreferencesStorePlatform.instance = store;
      await (await SharedPreferences.getInstance()).reload();
      final broken = await withRows();
      expect(broken.loadWarnings, ['saved filters']);
      final drive = FakeDrive();
      final svc = service(FakeDriveAuth(silent: ['tok-1']), drive);
      await svc.checkAndRunScheduled(broken);
      expect(uploads(drive), isEmpty);
      expect(await svc.lastBackupAt(), isNull);
      expect(await svc.lastError(), kDriveBackupsPausedMessage);
      expect(store.errorWrites, 1);

      // The next launch, still broken: the message is not written again.
      await svc.checkAndRunScheduled(broken);
      expect(uploads(drive), isEmpty);
      expect(store.errorWrites, 1);

      // A clean launch backs up and clears the message.
      final loaded = _WarnedProvider(const []);
      await loaded.load();
      final healthy = FakeDrive();
      final clean = service(FakeDriveAuth(silent: ['tok-1']), healthy);
      await clean.checkAndRunScheduled(loaded);
      expect(uploads(healthy), hasLength(1));
      expect(await clean.lastError(), isNull);
      expect(await clean.lastBackupAt(), isNotNull);
    });

    test('a late start-up step that threw does not pause backups', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final p = _WarnedProvider(const ['setup']);
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'lunch',
        date: DateTime(2026, 9, 1),
      );
      final drive = FakeDrive();
      final svc = service(FakeDriveAuth(silent: ['tok-1']), drive);
      await svc.checkAndRunScheduled(p);
      expect(uploads(drive), hasLength(1));
      expect(await svc.lastError(), isNull);
    });

    test('an upload goes to the backups folder as multipart', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final auth = FakeDriveAuth(silent: ['tok-1']);
      final drive = FakeDrive();
      final name = await service(auth, drive).uploadNow(await withRows());
      expect(name, startsWith('expense_tracker_backup_'));
      final upload = drive.requests.singleWhere(
        (r) => r.url.path.endsWith('/upload/drive/v3/files'),
      );
      expect(upload.method, 'POST');
      expect(upload.url.queryParameters['uploadType'], 'multipart');
      expect(upload.body, contains('"parents":["folder1"]'));
      expect(upload.headers['authorization'], 'Bearer tok-1');
    });

    test('a rejected token is dropped and the upload retried once', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final auth = FakeDriveAuth(silent: ['tok-stale', 'tok-fresh']);
      final drive = FakeDrive(uploads401: 1);
      final svc = service(auth, drive);
      await svc.uploadNow(await withRows());
      expect(auth.forgotten, ['tok-stale']);
      expect(drive.authHeaders.last, 'Bearer tok-fresh');
      expect(await svc.lastBackupAt(), isNotNull);
    });

    test('a second rejection fails the upload and is recorded', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final auth = FakeDriveAuth(silent: ['tok-1', 'tok-2']);
      final svc = service(auth, FakeDrive(uploads401: 2));
      await expectLater(svc.uploadNow(await withRows()), throwsA(anything));
      expect(await svc.lastError(), isNotNull);
    });

    test('every silent request names the connected account', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final auth = FakeDriveAuth(silent: ['tok-1']);
      await service(auth, FakeDrive()).uploadNow(await withRows());
      expect(auth.silentEmails, everyElement('me@example.com'));
    });

    test('a tap asks for access again when it was lost, for the same '
        'account', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final auth = FakeDriveAuth(interactive: 'tok-again');
      final drive = FakeDrive();
      await service(auth, drive).uploadNow(await withRows(), interactive: true);
      expect(auth.interactiveEmails, ['me@example.com']);
      expect(drive.authHeaders.last, 'Bearer tok-again');
    });

    test('offline during the 6.x check is not a reason to reconnect', () async {
      SharedPreferences.setMockInitialValues({
        'drive_last_backup_at': '2026-09-25T08:00:00.000',
      });
      final svc = service(
        FakeDriveAuth(silent: ['tok-old']),
        FakeDrive(offline: true),
      );
      expect(await svc.connectedEmail(), isNull);
      expect(await svc.lastError(), isNull);
    });

    test('a 6.x folder with no backup yet also counts as connected', () async {
      SharedPreferences.setMockInitialValues({
        'drive_backup_folder_id': 'folder1',
      });
      final svc = service(FakeDriveAuth(silent: ['tok-old']), FakeDrive());
      expect(await svc.connectedEmail(), 'me@example.com');
    });

    test('disconnect forgets the token and the account-scoped state', () async {
      final auth = FakeDriveAuth(silent: ['tok-1']);
      final svc = service(auth, FakeDrive());
      await svc.connect();
      await svc.uploadNow(await withRows());
      await svc.disconnect();
      expect(auth.forgotten, ['tok-1']);
      expect(auth.signOuts, 1);
      final prefs = await SharedPreferences.getInstance();
      for (final key in [
        'drive_connected_email',
        'drive_backup_folder_id',
        'drive_last_backup_at',
        'drive_last_error',
      ]) {
        expect(prefs.getString(key), isNull, reason: key);
      }
      expect(await svc.connectedEmail(), isNull);
    });
  });

  group('Android authorization errors', () {
    String message(GoogleSignInExceptionCode code, [String? description]) =>
        GoogleDriveAuth.mapped(
          GoogleSignInException(code: code, description: description),
        ).message;

    test('a cancel reads as cancelled, however Android reports it', () {
      expect(
        message(GoogleSignInExceptionCode.canceled),
        contains('cancelled'),
      );
      expect(
        message(
          GoogleSignInExceptionCode.unknownError,
          'SDK reported an exception: 16: Cancelled by user.',
        ),
        contains('cancelled'),
      );
    });

    test('a package or SHA-1 mismatch reads as not set up', () {
      expect(
        message(
          GoogleSignInExceptionCode.unknownError,
          'SDK reported an exception: 10: ',
        ),
        contains("isn't set up"),
      );
      expect(
        message(GoogleSignInExceptionCode.clientConfigurationError),
        contains("isn't set up"),
      );
    });

    test('anything else asks to try again', () {
      expect(
        message(GoogleSignInExceptionCode.unknownError, 'Authorization failed'),
        contains('Try again'),
      );
    });
  });

  group('uploadNow race hardening', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    test('snapshots the ledger before any network call', () async {
      final p = _ProbeProvider();
      await p.load();
      final svc = DriveBackupService(auth: FakeDriveAuth());
      // No token → the Drive step fails AFTER the snapshot. exportCalls == 1
      // proves snapshot-first order.
      final f = svc.uploadNow(p);
      expect(p.exportCalls, 1);
      await expectLater(f, throwsA(anything));
    });

    test('a second uploadNow joins the in-flight one', () async {
      final p = _ProbeProvider();
      await p.load();
      final svc = DriveBackupService(auth: FakeDriveAuth());
      final f1 = svc.uploadNow(p);
      final f2 = svc.uploadNow(p);
      expect(identical(f1, f2), isTrue);
      expect(p.exportCalls, 1); // not double-encoded
      await expectLater(f1, throwsA(anything));
      // After completion the slot is free again — a new call runs fresh.
      final f3 = svc.uploadNow(p);
      expect(identical(f1, f3), isFalse);
      await expectLater(f3, throwsA(anything));
    });

    test('a failed upload records drive_last_error', () async {
      final p = _ProbeProvider();
      await p.load();
      final svc = DriveBackupService(auth: FakeDriveAuth());
      await expectLater(svc.uploadNow(p), throwsA(anything));
      expect(await svc.lastError(), isNotNull);
    });
  });

  group('backups per phone', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
        'drive_install_id': 'mine0001',
      });
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
    });

    DriveBackupService service(FakeDrive drive) => DriveBackupService(
      auth: FakeDriveAuth(silent: ['tok-1']),
      httpClient: () => drive.client,
    );

    Future<FinanceProvider> withRows() async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'lunch',
        date: DateTime(2026, 9, 1),
      );
      return p;
    }

    /// [n] backups a day apart, the newest on 20 Nov 2026.
    List<Map<String, Object?>> seeded(
      String prefix,
      int n, {
      String? install,
    }) => [
      for (var i = 0; i < n; i++)
        fakeBackupFile(
          '$prefix$i',
          DateTime.utc(2026, 11, 20, 12).subtract(Duration(days: i)),
          install: install,
          name: install == null ? null : 'Demo Phone Two',
          count: install == null ? null : 40,
        ),
    ];

    int uploads(FakeDrive d) => d.requests
        .where((r) => r.url.path.endsWith('/upload/drive/v3/files'))
        .length;

    test('an upload carries the install id, the default name and the '
        'count', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
      });
      final drive = FakeDrive();
      final svc = service(drive);
      final rows = await withRows();
      await svc.uploadNow(rows);
      await svc.uploadNow(rows);
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString('drive_install_id');
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
      for (final meta in drive.uploaded) {
        final props = meta['appProperties'] as Map<String, dynamic>;
        expect(props['install'], id, reason: 'made once, then kept');
        expect(
          props['name'],
          matches(RegExp(r'^Phone set up \d+ \w{3} \d{4}$')),
        );
        expect(props['count'], '1');
      }
      expect(
        await svc.backupName(),
        drive.uploaded.first['appProperties']['name'],
      );
    });

    test('a rename applies to the next upload', () async {
      final drive = FakeDrive();
      final svc = service(drive);
      final rows = await withRows();
      await svc.uploadNow(rows);
      await svc.setBackupName('Demo Phone One');
      await svc.uploadNow(rows);
      final names = [
        for (final m in drive.uploaded) m['appProperties']['name'] as String,
      ];
      expect(names.first, startsWith('Phone set up '));
      expect(names.last, 'Demo Phone One');
    });

    test('a rename saved while the first upload runs is kept', () async {
      final drive = FakeDrive();
      final svc = service(drive);
      drive.duringNextUpload = () => svc.setBackupName('Demo Phone Three');
      await svc.uploadNow(await withRows());
      expect(
        drive.uploaded.single['appProperties']['name'],
        startsWith('Phone set up '),
        reason: 'the upload already under way carries the old name',
      );
      expect(await svc.backupName(), 'Demo Phone Three');
    });

    test('a Back up now that lands while the scheduled run lists the folder '
        'is not followed by the waiting message', () async {
      final drive = FakeDrive(files: seeded('o', 2, install: 'other002'));
      final svc = service(drive);
      final rows = await withRows();
      // The scheduled run's listing answers with the folder as it was, after
      // the upload has been recorded.
      drive.duringNextList = () async {
        await svc.uploadNow(rows);
      };
      await svc.checkAndRunScheduled(rows);
      expect(uploads(drive), 1);
      expect(await svc.lastBackupAt(), isNotNull);
      expect(await svc.lastError(), isNull);
    });

    test("pruning keeps this phone's newest 7 and the earlier backups' "
        "newest 7, and never deletes another phone's", () async {
      final drive = FakeDrive(
        files: [
          ...seeded('m', 8, install: 'mine0001'),
          ...seeded('o', 9, install: 'other002'),
          ...seeded('e', 9),
        ],
      );
      await service(drive).uploadNow(await withRows());
      // This phone: 8 plus the upload, the 2 oldest go. Earlier: 9, the 2
      // oldest go, as the whole folder used to be pruned.
      expect(drive.deleted, ['m6', 'm7', 'e7', 'e8']);
      expect(
        drive.files.where((f) => '${f['id']}'.startsWith('o')),
        hasLength(9),
      );
    });

    test('a new install waits beside another phone\'s backups, says so '
        'once, and a manual upload ends the wait', () async {
      final store = _CountingStore({
        'flutter.drive_connected_email': 'me@example.com',
        'flutter.drive_install_id': 'mine0001',
      });
      SharedPreferencesStorePlatform.instance = store;
      await (await SharedPreferences.getInstance()).reload();
      final drive = FakeDrive(files: seeded('o', 3, install: 'other002'));
      final svc = service(drive);
      final rows = await withRows();

      await svc.checkAndRunScheduled(rows);
      expect(uploads(drive), 0);
      expect(await svc.lastError(), kDriveOtherPhoneMessage);
      expect(store.errorWrites, 1);

      await svc.checkAndRunScheduled(rows);
      expect(uploads(drive), 0);
      expect(store.errorWrites, 1, reason: 'written once');

      await svc.uploadNow(rows);
      expect(await svc.lastError(), isNull);
      // Due again: the scheduled run uploads and lists the folder only to
      // prune, not to ask whether to wait.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('drive_last_backup_at', '2026-11-01T08:00:00.000');
      drive.requests.clear();
      await svc.checkAndRunScheduled(rows);
      expect(uploads(drive), 1);
      expect(
        drive.requests.where(
          (r) =>
              r.method == 'GET' &&
              r.url.path.endsWith('/drive/v3/files') &&
              !(r.url.queryParameters['q'] ?? '').contains(
                'google-apps.folder',
              ),
        ),
        hasLength(1),
      );
    });

    test('a restore ends the wait and clears its message', () async {
      final drive = FakeDrive(files: seeded('o', 2, install: 'other002'));
      final source = await withRows();
      drive.media['o0'] = encodeBackupGz(source.exportData());
      final svc = service(drive);
      final rows = await withRows();
      await svc.checkAndRunScheduled(rows);
      expect(await svc.lastError(), kDriveOtherPhoneMessage);

      final groups = await svc.listBackups();
      final backup = await svc.download(groups.single);
      expect((backup.data['transactions'] as List), hasLength(1));
      await svc.markRestored();
      expect(await svc.lastError(), isNull);

      await svc.checkAndRunScheduled(rows);
      expect(uploads(drive), 1);
    });

    test('an install updated from before install ids keeps backing up '
        'beside its own earlier backups', () async {
      SharedPreferences.setMockInitialValues({
        'drive_connected_email': 'me@example.com',
        'drive_last_backup_at': '2026-11-01T08:00:00.000',
      });
      final drive = FakeDrive(files: seeded('e', 7));
      final svc = service(drive);
      await svc.checkAndRunScheduled(await withRows());
      expect(uploads(drive), 1);
      expect(await svc.lastError(), isNull);
    });

    test('an empty folder does not wait', () async {
      final drive = FakeDrive();
      await service(drive).checkAndRunScheduled(await withRows());
      expect(uploads(drive), 1);
    });

    test('the listing puts this phone first, then the others by their '
        'newest backup', () async {
      final drive = FakeDrive(
        files: [
          ...seeded('e', 2),
          fakeBackupFile(
            'o0',
            DateTime.utc(2026, 11, 22, 12),
            install: 'other002',
            name: 'Demo Phone Two',
            count: 1204,
          ),
          fakeBackupFile(
            'm0',
            DateTime.utc(2026, 11, 21, 12),
            install: 'mine0001',
            name: 'Demo Phone One',
            count: 310,
          ),
        ],
      );
      final groups = await service(drive).listBackups();
      expect(
        [for (final g in groups) g.installId],
        ['mine0001', 'other002', null],
      );
      expect(groups.first.mine, isTrue);
      expect(groups[1].name, 'Demo Phone Two');
      expect(groups[1].newestCount, 1204);
      expect(groups[1].newestAt, DateTime.utc(2026, 11, 22, 12).toLocal());
      expect(groups.last.newestCount, isNull);
      expect([for (final f in groups.last.files) f.id], ['e0', 'e1']);
    });

    test('an empty folder still says no backup was found', () async {
      await expectLater(
        service(FakeDrive()).listBackups(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('No cloud backup found'),
          ),
        ),
      );
    });
  });

  group('backup file name', () {
    test('is prefix-matched, iso-sortable, and extension-tagged', () {
      final name = DriveBackupService.backupFileName(
        DateTime(2026, 8, 10, 9, 5, 3),
      );
      expect(name, 'expense_tracker_backup_2026-08-10T09-05-03.json.gz');
      // Lexicographic order == chronological order (retention relies on
      // createdTime, but the names must not mislead a human sorting them).
      final later = DriveBackupService.backupFileName(DateTime(2026, 8, 11, 8));
      expect(name.compareTo(later), lessThan(0));
    });
  });
}
