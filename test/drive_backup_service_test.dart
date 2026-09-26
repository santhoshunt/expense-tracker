import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Drive v3, faked: about, folder lookup, file listing and upload. The
/// first [uploads401] uploads answer 401, as for an expired token.
class FakeDrive {
  final String email;
  int uploads401;

  /// When set, about.get fails as if offline.
  bool offline;
  final requests = <http.Request>[];

  FakeDrive({
    this.email = 'me@example.com',
    this.uploads401 = 0,
    this.offline = false,
  });

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
      return _json({'id': 'file1', 'name': 'backup'});
    }
    if (path.endsWith('/drive/v3/files') && request.method == 'GET') {
      final q = request.url.queryParameters['q'] ?? '';
      return _json({
        'files': q.contains('google-apps.folder')
            ? [
                {'id': 'folder1'},
              ]
            : <Object>[],
      });
    }
    if (path.contains('/drive/v3/files/')) {
      return _json({'id': request.url.pathSegments.last, 'trashed': false});
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
