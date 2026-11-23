import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/backup_crypto.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

import 'drive_backup_service_test.dart'
    show FakeDrive, FakeDriveAuth, fakeBackupFile;

/// v2.3.5: the optional passphrase on the JSON backup and the Drive copy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const passphrase = 'violet ladder 1187';

  void resetPrefs() {
    SharedPreferences.setMockInitialValues({
      'drive_connected_email': 'owner@example.test',
      'drive_install_id': 'cafe0042',
    });
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  }

  Future<FinanceProvider> ledger({int rows = 2}) async {
    final p = FinanceProvider();
    await p.load();
    for (var i = 0; i < rows; i++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 315.5 + i,
        note: 'Quill Bakery $i',
        date: DateTime(2026, 10, 3 + i, 9),
      );
    }
    return p;
  }

  /// A second ledger to restore into. It loads what the stored preferences
  /// hold, and the tests restore with Replace, which clears it first.
  Future<FinanceProvider> emptyLedger() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<Map<String, String>> storedKeyAndSalt() async {
    final prefs = await SharedPreferences.getInstance();
    final stored =
        jsonDecode(prefs.getString('backup_passphrase')!)
            as Map<String, dynamic>;
    return {
      'key': stored['key'] as String,
      'salt': stored['salt'] as String,
    };
  }

  /// [envelope] as a later release might write it.
  Map<String, dynamic> newer(Map<String, dynamic> envelope) => {
    ...envelope,
    'version': 2,
  };

  /// [envelope] with one byte of the base64 field [field] flipped.
  Map<String, dynamic> flipped(Map<String, dynamic> envelope, String field) {
    final bytes = base64Decode(envelope[field] as String);
    bytes[bytes.length ~/ 2] ^= 0x01;
    return {...envelope, field: base64Encode(bytes)};
  }

  /// The media an upload sent: googleapis writes it base64 in the
  /// multipart body.
  Uint8List uploadedBytes(http.Request r) {
    const marker = 'Content-Transfer-Encoding: base64\r\n\r\n';
    final body = r.body;
    final start = body.indexOf(marker) + marker.length;
    final end = body.indexOf('\r\n--', start);
    return base64Decode(body.substring(start, end).trim());
  }

  Iterable<http.Request> uploads(FakeDrive d) =>
      d.requests.where((r) => r.url.path.endsWith('/upload/drive/v3/files'));

  List<String> mediaGets(FakeDrive d) => [
    for (final r in d.requests)
      if (r.url.queryParameters['alt'] == 'media') r.url.pathSegments.last,
  ];

  group('envelope', () {
    setUp(() {
      resetPrefs();
      BackupPassphrase.iterations = 1000;
    });
    tearDown(() => BackupPassphrase.iterations = kBackupKdfIterations);

    test('a sealed backup opens back to the same map', () async {
      final data = (await ledger()).exportData();
      await BackupPassphrase.turnOn(passphrase);
      final envelope = await BackupPassphrase.sealIfOn(data);
      expect(isSealedBackup(envelope), isTrue);
      final opened = await BackupPassphrase.open(envelope);
      expect(jsonEncode(opened), jsonEncode(data));
    });

    test('the envelope states every field, and two backups of the same data '
        'differ in nonce and bytes but share the salt', () async {
      final data = (await ledger()).exportData();
      await BackupPassphrase.turnOn(passphrase);
      final a = await BackupPassphrase.sealIfOn(data);
      final b = await BackupPassphrase.sealIfOn(data);
      expect(a.keys.toSet(), {
        'format',
        'version',
        'kdf',
        'iterations',
        'salt',
        'cipher',
        'nonce',
        'made',
        'data',
      });
      expect(a['format'], 'expense_tracker_protected');
      expect(a['version'], 1);
      expect(a['kdf'], 'pbkdf2-hmac-sha256');
      expect(a['iterations'], 1000);
      expect(a['cipher'], 'aes-256-gcm');
      expect(base64Decode(a['salt'] as String), hasLength(16));
      expect(base64Decode(a['nonce'] as String), hasLength(12));
      expect(DateTime.tryParse(a['made'] as String), isNotNull);
      expect(a.containsKey('app'), isFalse, reason: 'older apps reject it');
      expect(a['nonce'], isNot(b['nonce']));
      expect(a['data'], isNot(b['data']));
      expect(a['salt'], b['salt']);
    });

    test('setting a passphrase again picks a new salt', () async {
      await BackupPassphrase.turnOn(passphrase);
      final first = (await storedKeyAndSalt())['salt'];
      await BackupPassphrase.turnOn(passphrase);
      expect((await storedKeyAndSalt())['salt'], isNot(first));
    });

    test('without the stored key a passphrase is needed; a wrong one gives '
        'its own exception and the right one opens', () async {
      final data = (await ledger()).exportData();
      await BackupPassphrase.turnOn(passphrase);
      final envelope = await BackupPassphrase.sealIfOn(data);
      await BackupPassphrase.turnOff();

      late PassphraseNeededException locked;
      try {
        await BackupPassphrase.open(envelope);
        fail('opened without a key');
      } on PassphraseNeededException catch (e) {
        locked = e;
      }
      expect(locked, isNot(isA<FormatException>()));
      expect(locked.madeAt, isNotNull);
      await expectLater(
        locked.open('violet ladder 1188'),
        throwsA(isA<WrongPassphraseException>()),
      );
      final opened = await locked.open(passphrase);
      expect(opened.data['transactions'], hasLength(2));
    });

    test('the key is one preference, all or nothing', () async {
      await BackupPassphrase.turnOn(passphrase);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((k) => k.startsWith('backup_passphrase')),
        ['backup_passphrase'],
      );
      final stored =
          jsonDecode(prefs.getString('backup_passphrase')!)
              as Map<String, dynamic>;
      expect(stored.keys.toSet(), {'key', 'salt', 'iterations', 'kdf'});
      expect(stored['iterations'], 1000);
      expect(stored['kdf'], 'pbkdf2-hmac-sha256');
      // A damaged value reads as off rather than half on.
      await prefs.setString('backup_passphrase', '{"key": "abc"}');
      expect(await BackupPassphrase.isOn(), isFalse);
    });

    test('a later version, derivation, cipher or a count over the cap is a '
        'newer format, not a damaged file', () async {
      final data = (await ledger()).exportData();
      await BackupPassphrase.turnOn(passphrase);
      final envelope = await BackupPassphrase.sealIfOn(data);
      for (final changed in [
        newer(envelope),
        {...envelope, 'kdf': 'argon2id'},
        {...envelope, 'cipher': 'xchacha20-poly1305'},
        {...envelope, 'iterations': 2000001},
      ]) {
        await expectLater(
          BackupPassphrase.open(changed),
          throwsA(
            isA<NewerBackupFormatException>().having(
              (e) => e.message,
              'message',
              'This backup was made by a newer version of the app. Update '
                  'the app to restore it.',
            ),
          ),
          reason: '$changed',
        );
      }
      expect(
        const NewerBackupFormatException(),
        isNot(isA<FormatException>()),
      );
      // The cap itself still opens as this version's form.
      expect(
        () => parseEnvelope({...envelope, 'iterations': 2000000}),
        returnsNormally,
      );
      // Malformed fields stay a FormatException.
      for (final broken in [
        {...envelope, 'salt': 'not base64 !!'},
        {...envelope, 'nonce': base64Encode(List.filled(8, 1))},
        {...envelope, 'iterations': '1000'},
        {...envelope}..remove('made'),
      ]) {
        expect(() => parseEnvelope(broken), throwsFormatException);
      }
    });

    test('adopting a typed passphrase keeps its key when this phone has '
        'none, and changes nothing when it has its own', () async {
      final data = (await ledger()).exportData();
      await BackupPassphrase.turnOn(passphrase);
      final envelope = await BackupPassphrase.sealIfOn(data);
      final first = await storedKeyAndSalt();

      // Protection on with another key: nothing changes.
      await BackupPassphrase.turnOn('marble canyon 77');
      final own = await storedKeyAndSalt();
      final unlocked = await (await _locked(envelope)).open(passphrase);
      expect(await unlocked.adopt(), isFalse);
      expect(await storedKeyAndSalt(), own);

      // Protection off: the key just derived is kept, with the envelope's
      // salt, and opens the envelope without asking.
      await BackupPassphrase.turnOff();
      expect(await unlocked.adopt(), isTrue);
      expect(await BackupPassphrase.isOn(), isTrue);
      expect(await storedKeyAndSalt(), first);
      expect(
        (await BackupPassphrase.open(envelope))['transactions'],
        hasLength(2),
      );
    });

    for (final field in ['data', 'nonce', 'salt']) {
      test('one flipped byte in the $field fails the check', () async {
        final data = (await ledger()).exportData();
        await BackupPassphrase.turnOn(passphrase);
        final envelope = await BackupPassphrase.sealIfOn(data);
        await BackupPassphrase.turnOff();
        final changed = flipped(envelope, field);
        await expectLater(
          () async => (await _locked(changed)).open(passphrase),
          throwsA(isA<WrongPassphraseException>()),
        );
      });
    }

    test('a changed header field fails the check too', () async {
      final data = (await ledger()).exportData();
      await BackupPassphrase.turnOn(passphrase);
      final envelope = await BackupPassphrase.sealIfOn(data);
      await BackupPassphrase.turnOff();
      final changed = {...envelope, 'made': '2026-01-01T00:00:00.000Z'};
      await expectLater(
        () async => (await _locked(changed)).open(passphrase),
        throwsA(isA<WrongPassphraseException>()),
      );
    });

    test('a changed file this phone holds the key for reads as damaged, not '
        'as a passphrase question', () async {
      final data = (await ledger()).exportData();
      await BackupPassphrase.turnOn(passphrase);
      final envelope = await BackupPassphrase.sealIfOn(data);
      await expectLater(
        BackupPassphrase.open(flipped(envelope, 'data')),
        throwsA(isA<FormatException>()),
      );
    });

    test('an envelope with an absurd iteration count is refused as a newer '
        'form before any derivation', () {
      expect(
        () => parseEnvelope({
          'format': 'expense_tracker_protected',
          'version': 1,
          'kdf': 'pbkdf2-hmac-sha256',
          'iterations': 900000000,
          'salt': base64Encode(List.filled(16, 7)),
          'cipher': 'aes-256-gcm',
          'nonce': base64Encode(List.filled(12, 3)),
          'made': '2026-11-23T08:00:00.000Z',
          'data': base64Encode(List.filled(40, 1)),
        }),
        throwsA(isA<NewerBackupFormatException>()),
      );
    });
  });

  group('JSON backup file', () {
    setUp(() {
      resetPrefs();
      BackupPassphrase.iterations = 1000;
    });
    tearDown(() => BackupPassphrase.iterations = kBackupKdfIterations);

    test('a plain backup as v2.3.4 wrote it still imports, with protection '
        'off or on', () async {
      final source = await ledger(rows: 3);
      final settings = SettingsProvider();
      final data = source.exportData()
        ..['settings'] = settings.toBackupMap();
      // Exactly as v2.3.4's exportJson encoded it.
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
      );
      for (final on in [false, true]) {
        if (on) await BackupPassphrase.turnOn(passphrase);
        final read = await BackupService.decodeJsonBackup(bytes);
        final target = await emptyLedger();
        final added = await BackupService.importBackup(
          target,
          read,
          replace: true,
        );
        expect(added, 3, reason: 'protection on: $on');
      }
    });

    test('with protection on the exported file is an envelope that opens on '
        'this phone and imports', () async {
      final source = await ledger();
      await BackupPassphrase.turnOn(passphrase);
      final bytes = await BackupService.jsonBackupBytes(
        source,
        settings: SettingsProvider(),
      );
      final text = utf8.decode(bytes);
      expect(isSealedBackup(jsonDecode(text)), isTrue);
      expect(text, isNot(contains('Quill Bakery')));
      final read = await BackupService.decodeJsonBackup(bytes);
      final added = await BackupService.importBackup(
        await emptyLedger(),
        read,
        replace: true,
      );
      expect(added, 2);
    });

    test('a file made by a later version says so instead of reading as '
        'damaged', () async {
      await BackupPassphrase.turnOn(passphrase);
      final envelope = await BackupPassphrase.sealIfOn(
        (await ledger()).exportData(),
      );
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(newer(envelope))),
      );
      await expectLater(
        BackupService.decodeJsonBackup(bytes),
        throwsA(
          isA<NewerBackupFormatException>().having(
            (e) => '$e',
            'text',
            'This backup was made by a newer version of the app. Update the '
                'app to restore it.',
          ),
        ),
      );
    });

    test('the stored key and salt are in no backup and not in the settings '
        'block', () async {
      final source = await ledger();
      await BackupPassphrase.turnOn(passphrase);
      final stored = await storedKeyAndSalt();
      final settings = SettingsProvider();
      final settingsJson = jsonEncode(settings.toBackupMap());
      expect(settingsJson, isNot(contains('backup_passphrase')));
      for (final v in stored.values) {
        expect(settingsJson, isNot(contains(v)));
      }

      final bytes = await BackupService.jsonBackupBytes(
        source,
        settings: settings,
      );
      // The envelope states its salt by design; the key is never there.
      expect(utf8.decode(bytes), isNot(contains(stored['key'])));
      final payload = jsonEncode(await BackupService.decodeJsonBackup(bytes));
      expect(payload, isNot(contains(stored['key'])));
      expect(payload, isNot(contains(stored['salt'])));
      expect(payload, isNot(contains('backup_passphrase')));
      expect(payload, isNot(contains(passphrase)));

      // And a plain backup made with protection off holds none of it.
      await BackupPassphrase.turnOff();
      final plain = utf8.decode(
        await BackupService.jsonBackupBytes(source, settings: settings),
      );
      for (final v in [...stored.values, passphrase]) {
        expect(plain, isNot(contains(v)));
      }
    });
  });

  group('Google Drive', () {
    setUp(() {
      resetPrefs();
      BackupPassphrase.iterations = 1000;
    });
    tearDown(() => BackupPassphrase.iterations = kBackupKdfIterations);

    DriveBackupService service(FakeDrive drive) => DriveBackupService(
      auth: FakeDriveAuth(silent: ['tok-1']),
      httpClient: () => drive.client,
    );

    /// Uploads a backup of [source] and makes its bytes downloadable.
    Future<Uint8List> upload(
      DriveBackupService svc,
      FakeDrive drive,
      FinanceProvider source,
    ) async {
      await svc.uploadNow(source);
      final bytes = uploadedBytes(uploads(drive).last);
      drive.media['up${drive.uploaded.length}'] = bytes;
      return bytes;
    }

    test('with the switch on an upload is protected and opens on the same '
        'install without asking', () async {
      await BackupPassphrase.turnOn(passphrase);
      final drive = FakeDrive();
      final svc = service(drive);
      final bytes = await upload(svc, drive, await ledger());
      expect(isSealedBackup(decodeBackupGz(bytes)), isTrue);
      final props = drive.uploaded.single['appProperties'] as Map;
      expect(props.containsKey('protected'), isFalse);
      expect(props['count'], '2');

      final groups = await svc.listBackups();
      final backup = await svc.download(groups.single);
      expect(backup.data['transactions'], hasLength(2));
    });

    test('with no stored key a download says a passphrase is needed, and '
        'the right one opens it without downloading again', () async {
      await BackupPassphrase.turnOn(passphrase);
      final drive = FakeDrive();
      final svc = service(drive);
      await upload(svc, drive, await ledger());
      // A new phone: the same folder, no key.
      await BackupPassphrase.turnOff();

      final groups = await svc.listBackups();
      late PassphraseNeededException locked;
      try {
        await svc.download(groups.single);
        fail('opened without a key');
      } on PassphraseNeededException catch (e) {
        locked = e;
      }
      expect(mediaGets(drive), ['up1']);
      expect(locked.madeAt, isNotNull);
      expect(locked.name, startsWith('expense_tracker_backup_'));
      await expectLater(
        locked.open('violet ladder'),
        throwsA(isA<WrongPassphraseException>()),
      );
      final unlocked = await locked.open(passphrase);
      expect(unlocked.data['transactions'], hasLength(2));
      expect(mediaGets(drive), ['up1'], reason: 'not fetched again');
    });

    test('a phone that adopts the passphrase on restore uploads protected '
        'backups the first phone opens without asking', () async {
      await BackupPassphrase.turnOn(passphrase);
      final prefs = await SharedPreferences.getInstance();
      final firstPhoneKey = prefs.getString('backup_passphrase')!;
      final drive = FakeDrive();
      final svc = service(drive);
      await upload(svc, drive, await ledger());

      // The second phone: no key, restores with the typed passphrase.
      await BackupPassphrase.turnOff();
      late PassphraseNeededException locked;
      try {
        await svc.download((await svc.listBackups()).single);
      } on PassphraseNeededException catch (e) {
        locked = e;
      }
      final unlocked = await locked.open(passphrase);
      expect(await unlocked.adopt(), isTrue);
      final bytes = await upload(svc, drive, await ledger(rows: 1));
      expect(isSealedBackup(decodeBackupGz(bytes)), isTrue);

      // Back on the first phone: its own key opens the new upload.
      await prefs.setString('backup_passphrase', firstPhoneKey);
      final newest = await svc.download((await svc.listBackups()).single);
      // The second phone's ledger: the first one's 2 rows plus 1.
      expect(newest.data['transactions'], hasLength(3));
      expect(mediaGets(drive), ['up1', 'up2']);
    });

    test('a newest file made by a later version does not fall back to an '
        'older one and says why', () async {
      final older = encodeBackupGz((await ledger(rows: 1)).exportData());
      await BackupPassphrase.turnOn(passphrase);
      final newest = encodeBackupGz(
        newer(await BackupPassphrase.sealIfOn((await ledger()).exportData())),
      );
      final drive = FakeDrive(
        files: [
          fakeBackupFile('n0', DateTime.utc(2026, 11, 22, 12)),
          fakeBackupFile('n1', DateTime.utc(2026, 11, 21, 12)),
        ],
      );
      drive.media['n0'] = newest;
      drive.media['n1'] = older;
      final svc = service(drive);
      await expectLater(
        svc.download((await svc.listBackups()).single),
        throwsA(
          isA<NewerBackupFormatException>().having(
            (e) => e.message,
            'message',
            contains('Update the app to restore it.'),
          ),
        ),
      );
      expect(mediaGets(drive), ['n0'], reason: 'no older file tried');
    });

    test('a protected newest file the key does not open does not fall back '
        'to an older one', () async {
      final older = encodeBackupGz((await ledger(rows: 1)).exportData());
      await BackupPassphrase.turnOn(passphrase);
      final newest = encodeBackupGz(
        await BackupPassphrase.sealIfOn((await ledger()).exportData()),
      );
      await BackupPassphrase.turnOff();
      final drive = FakeDrive(
        files: [
          fakeBackupFile(
            'p0',
            DateTime.utc(2026, 11, 22, 12),
            install: 'beef0007',
            name: 'Demo Tablet',
            count: 2,
          ),
          fakeBackupFile(
            'p1',
            DateTime.utc(2026, 11, 21, 12),
            install: 'beef0007',
            name: 'Demo Tablet',
            count: 1,
          ),
        ],
      );
      drive.media['p0'] = newest;
      drive.media['p1'] = older;
      final groups = await service(drive).listBackups();
      await expectLater(
        service(drive).download(groups.single),
        throwsA(isA<PassphraseNeededException>()),
      );
      expect(mediaGets(drive), ['p0'], reason: 'no older file tried');
    });

    test('a truly corrupt newest file still falls back, and so does a '
        'protected one the stored key matches but cannot open', () async {
      final older = encodeBackupGz((await ledger(rows: 1)).exportData());
      await BackupPassphrase.turnOn(passphrase);
      final sealed = await BackupPassphrase.sealIfOn(
        (await ledger()).exportData(),
      );
      final damaged = encodeBackupGz(flipped(sealed, 'data'));
      for (final (label, newest) in [
        ('garbage', Uint8List.fromList([9, 8, 7, 6, 5])),
        ('damaged', damaged),
      ]) {
        final drive = FakeDrive(
          files: [
            fakeBackupFile('c0', DateTime.utc(2026, 11, 22, 12)),
            fakeBackupFile('c1', DateTime.utc(2026, 11, 21, 12)),
          ],
        );
        drive.media['c0'] = newest;
        drive.media['c1'] = older;
        final svc = service(drive);
        final backup = await svc.download((await svc.listBackups()).single);
        expect(backup.data['transactions'], hasLength(1), reason: label);
        expect(mediaGets(drive), ['c0', 'c1'], reason: label);
      }
    });

    test('turning the switch off removes the stored key and makes the next '
        'backup plain', () async {
      await BackupPassphrase.turnOn(passphrase);
      expect(await BackupPassphrase.isOn(), isTrue);
      await BackupPassphrase.turnOff();
      expect(await BackupPassphrase.isOn(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getKeys().where((k) => k.startsWith('backup_passphrase')),
        isEmpty,
      );
      final drive = FakeDrive();
      final bytes = await upload(service(drive), drive, await ledger());
      final decoded = decodeBackupGz(bytes);
      expect(isSealedBackup(decoded), isFalse);
      expect(decoded['transactions'], hasLength(2));
      final props = drive.uploaded.single['appProperties'] as Map;
      expect(props.containsKey('protected'), isFalse);
    });
  });

  group('production count', () {
    setUp(resetPrefs);

    test('a new passphrase uses 200,000 iterations', () {
      expect(kBackupKdfIterations, 200000);
      expect(BackupPassphrase.iterations, kBackupKdfIterations);
    });
  });
}

/// The [PassphraseNeededException] that opening [envelope] without a stored
/// key throws.
Future<PassphraseNeededException> _locked(Map<String, dynamic> envelope) async {
  try {
    await BackupPassphrase.open(envelope);
  } on PassphraseNeededException catch (e) {
    return e;
  }
  throw StateError('opened without a key');
}
