import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The refusing store below extends the plugin's in-memory store, which only
// the platform interface exports. shared_preferences brings it in.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/backup_crypto.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/widgets/backup_passphrase_dialogs.dart';

import 'drive_backup_service_test.dart'
    show FakeDrive, FakeDriveAuth, fakeBackupFile;

/// The in-memory store, refusing every write of the backup key.
class _RefusingStore extends InMemorySharedPreferencesStore {
  _RefusingStore(super.data) : super.withData();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key == 'flutter.backup_passphrase') return false;
    return super.setValue(valueType, key, value);
  }
}

/// v2.3.5: the passphrase switch on Backup and data, and its two dialogs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const basePrefs = <String, Object>{
    'drive_connected_email': 'owner@example.test',
    'drive_install_id': 'cafe0042',
  };

  setUp(() {
    SharedPreferences.setMockInitialValues(basePrefs);
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    BackupPassphrase.iterations = 1000;
  });
  tearDown(() => BackupPassphrase.iterations = kBackupKdfIterations);

  final thisYear = DateTime.now().year;

  /// Bounded pumps: dialogs animate, and the Drive section's minute clock
  /// never lets pumpAndSettle finish.
  Future<void> pumpThrough(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Lets worker isolates run in real time, a pump after each slice, until
  /// [until] finds something.
  Future<void> waitFor(WidgetTester tester, Finder until) async {
    for (var i = 0; i < 100 && until.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await pumpThrough(tester);
  }

  final row = find.byKey(const ValueKey('backup-passphrase'));
  final first = find.byKey(const ValueKey('passphrase-first'));
  final second = find.byKey(const ValueKey('passphrase-second'));

  bool switchValue(WidgetTester tester) => tester
      .widget<Switch>(find.descendant(of: row, matching: find.byType(Switch)))
      .value;

  Future<FinanceProvider> pumpBackupPage(
    WidgetTester tester, {
    FakeDrive? drive,
  }) async {
    final fake = drive ?? FakeDrive();
    final finance = FinanceProvider();
    await finance.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(
            create: (_) => DriveBackupService(
              auth: FakeDriveAuth(silent: ['tok-1']),
              httpClient: () => fake.client,
            ),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpThrough(tester);
    await tester.scrollUntilVisible(
      find.text('Backup and data'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('Backup and data'));
    await pumpThrough(tester);
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    return finance;
  }

  FilledButton button(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(FilledButton)),
  );

  TextField field(WidgetTester tester, Finder f) => tester.widget<TextField>(
    find.descendant(of: f, matching: find.byType(TextField)),
  );

  testWidgets('the switch row starts off, and Cancel on the set dialog '
      'leaves it off', (tester) async {
    await pumpBackupPage(tester);
    expect(
      find.descendant(of: row, matching: find.text('Protect with a passphrase')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.text('Needed to restore. Cannot be recovered.'),
      ),
      findsOneWidget,
    );
    expect(switchValue(tester), isFalse);

    await tester.tap(row);
    await pumpThrough(tester);
    expect(find.text('Set a backup passphrase'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await pumpThrough(tester);
    expect(find.text('Set a backup passphrase'), findsNothing);
    expect(switchValue(tester), isFalse);
    expect(await BackupPassphrase.isOn(), isFalse);
  });

  testWidgets('Set stays disabled until both fields match, and Set turns '
      'protection on', (tester) async {
    await pumpBackupPage(tester);
    await tester.tap(row);
    await pumpThrough(tester);
    expect(find.text('Passphrase'), findsOneWidget);
    expect(find.text('Repeat it'), findsOneWidget);
    expect(
      find.text('If you forget it, backups made with it cannot be opened.'),
      findsOneWidget,
    );
    expect(button(tester, 'Set').onPressed, isNull, reason: 'both empty');

    await tester.enterText(first, 'tidal harbour 52');
    await tester.pump();
    expect(button(tester, 'Set').onPressed, isNull, reason: 'one empty');
    await tester.enterText(second, 'tidal harbour 53');
    await tester.pump();
    expect(button(tester, 'Set').onPressed, isNull, reason: 'different');
    await tester.enterText(second, 'tidal harbour 52');
    await tester.pump();
    expect(button(tester, 'Set').onPressed, isNotNull);
    expect(field(tester, first).obscureText, isTrue);

    await tester.tap(find.text('Set'));
    // The key is derived on a worker isolate, which needs real time.
    for (var i = 0; i < 100 && !await BackupPassphrase.isOn(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    await pumpThrough(tester);
    expect(await BackupPassphrase.isOn(), isTrue);
    expect(switchValue(tester), isTrue);
    expect(find.text('Set a backup passphrase'), findsNothing);
  });

  testWidgets('the set dialog takes printable English characters only, no '
      'space at either end, 8 or more, and says so once typed', (
    tester,
  ) async {
    await pumpBackupPage(tester);
    await tester.tap(row);
    await pumpThrough(tester);
    const errors = [
      'Use English letters, digits and symbols only',
      'Remove the space at the start or end',
      'Use at least 8 characters',
    ];
    for (final e in errors) {
      expect(find.text(e), findsNothing, reason: 'nothing typed yet');
    }
    for (final (typed, error) in [
      ('caf\u{00E9} terrace 9', errors[0]),
      ('north\u{200B}gate 4417', errors[0]),
      (' lantern row 31', errors[1]),
      ('lantern row 31 ', errors[1]),
      ('kite 31', errors[2]),
    ]) {
      await tester.enterText(first, typed);
      await tester.enterText(second, typed);
      await tester.pump();
      expect(find.text(error), findsOneWidget, reason: typed);
      expect(button(tester, 'Set').onPressed, isNull, reason: typed);
    }
    await tester.enterText(first, 'kite 3108');
    await tester.enterText(second, 'kite 3108');
    await tester.pump();
    for (final e in errors) {
      expect(find.text(e), findsNothing);
    }
    expect(button(tester, 'Set').onPressed, isNotNull);
  });

  testWidgets('one eye button shows and hides both fields of the set '
      'dialog', (tester) async {
    await pumpBackupPage(tester);
    await tester.tap(row);
    await pumpThrough(tester);
    expect(find.byTooltip('Show passphrase'), findsOneWidget);
    await tester.tap(find.byTooltip('Show passphrase'));
    await tester.pump();
    expect(field(tester, first).obscureText, isFalse);
    expect(field(tester, second).obscureText, isFalse);
    await tester.tap(find.byTooltip('Hide passphrase'));
    await tester.pump();
    expect(field(tester, first).obscureText, isTrue);
    expect(field(tester, second).obscureText, isTrue);
  });

  testWidgets('a key that cannot be saved says so and leaves the switch '
      'off', (tester) async {
    SharedPreferencesStorePlatform.instance = _RefusingStore({
      for (final MapEntry(:key, :value) in basePrefs.entries)
        'flutter.$key': value,
    });
    await (await SharedPreferences.getInstance()).reload();
    await pumpBackupPage(tester);
    await tester.tap(row);
    await pumpThrough(tester);
    await tester.enterText(first, 'tidal harbour 52');
    await tester.enterText(second, 'tidal harbour 52');
    await tester.pump();
    await tester.tap(find.text('Set'));
    final toast = find.text('Could not change backup protection.');
    await waitFor(tester, toast);
    expect(toast, findsOneWidget);
    expect(switchValue(tester), isFalse);
    expect(await BackupPassphrase.isOn(), isFalse);
  });

  testWidgets('turning it off needs no dialog and removes the key', (
    tester,
  ) async {
    await tester.runAsync(() => BackupPassphrase.turnOn('copper finch 08'));
    await pumpBackupPage(tester);
    expect(switchValue(tester), isTrue);
    await tester.tap(row);
    await pumpThrough(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(switchValue(tester), isFalse);
    expect(await BackupPassphrase.isOn(), isFalse);
  });

  group('Drive restore of a protected backup', () {
    const typed = 'copper finch 08';

    /// A backup sealed with [typed] on another phone, made on 23 Nov this
    /// year and uploaded on 25 Nov, as the only file in Drive. The prefs
    /// are reset afterwards, so this phone holds no key and its own ledger
    /// holds one other row.
    Future<FakeDrive> protectedDrive(
      WidgetTester tester, {
      int version = 1,
    }) async {
      final source = FinanceProvider();
      await source.load();
      for (final (i, note) in ['Juniper Deli', 'Orchid Books'].indexed) {
        await source.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 212.0 + i,
          note: note,
          date: DateTime(2026, 11, 2 + i),
        );
      }
      final bytes = await tester.runAsync(() async {
        await BackupPassphrase.turnOn(typed);
        final sealed = await BackupPassphrase.sealIfOn(
          source.exportData(),
          now: DateTime(thisYear, 11, 23, 10),
        );
        return encodeBackupGz({...sealed, 'version': version});
      });
      SharedPreferences.setMockInitialValues(basePrefs);
      final mine = FinanceProvider();
      await mine.load();
      await mine.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 64,
        note: 'Larch Hardware',
        date: DateTime(2026, 11, 20),
      );
      final drive = FakeDrive(
        files: [
          fakeBackupFile(
            'p0',
            DateTime.utc(thisYear, 11, 25, 4),
            install: 'beef0007',
            name: 'Demo Tablet',
            count: 2,
          ),
        ],
      );
      drive.media['p0'] = bytes!;
      return drive;
    }

    /// Import, From Google Drive, Merge or [replace], until [until] shows.
    Future<void> restore(
      WidgetTester tester,
      Finder until, {
      bool replace = false,
    }) async {
      await tester.scrollUntilVisible(
        find.text('Import…'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump();
      await tester.tap(find.text('Import…'));
      await pumpThrough(tester);
      await tester.tap(find.text('From Google Drive'));
      await tester.pump();
      if (replace) {
        await tester.tap(find.text('Replace'));
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('editor-save')));
      await waitFor(tester, until);
    }

    final asking = find.text('Enter the backup passphrase');

    Future<void> tryPassphrase(
      WidgetTester tester,
      String text,
      Finder until,
    ) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await waitFor(tester, until);
    }

    testWidgets('it asks with the date the backup was made, not uploaded; '
        'the right passphrase restores and this phone adopts it', (
      tester,
    ) async {
      final drive = await protectedDrive(tester);
      await pumpBackupPage(tester, drive: drive);
      expect(switchValue(tester), isFalse);
      await restore(tester, asking);
      expect(asking, findsOneWidget);
      expect(
        find.text('This backup was made on 23 Nov and is protected.'),
        findsOneWidget,
      );

      final wrong = find.text('That passphrase does not open this backup.');
      await tryPassphrase(tester, 'copper finch 80', wrong);
      expect(wrong, findsOneWidget);
      expect(asking, findsOneWidget);

      final done = find.textContaining('from the cloud backup');
      await tryPassphrase(tester, typed, done);
      expect(asking, findsNothing);
      expect(
        find.textContaining(
          'Backups from this phone are now protected with the same '
          'passphrase.',
        ),
        findsOneWidget,
      );
      expect(await BackupPassphrase.isOn(), isTrue);
      expect(switchValue(tester), isTrue, reason: 'without reopening');
      expect(
        [
          for (final r in drive.requests)
            if (r.url.queryParameters['alt'] == 'media')
              r.url.pathSegments.last,
        ],
        ['p0'],
        reason: 'fetched once',
      );
    });

    testWidgets('a cancelled passphrase dialog under Replace keeps the '
        'ledger and adopts nothing', (tester) async {
      final drive = await protectedDrive(tester);
      final finance = await pumpBackupPage(tester, drive: drive);
      final before = [for (final t in finance.transactions) t.id];
      expect(finance.transactions.single.note, 'Larch Hardware');
      await restore(tester, asking, replace: true);
      expect(asking, findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await pumpThrough(tester);
      expect(asking, findsNothing);
      expect([for (final t in finance.transactions) t.id], before);
      expect(await BackupPassphrase.isOn(), isFalse);
      expect(switchValue(tester), isFalse);
    });

    testWidgets('a backup a later version made says so and is not '
        'restored', (tester) async {
      final drive = await protectedDrive(tester, version: 2);
      final finance = await pumpBackupPage(tester, drive: drive);
      final toast = find.text(
        'This backup was made by a newer version of the app. Update the app '
        'to restore it.',
      );
      await restore(tester, toast, replace: true);
      expect(toast, findsOneWidget);
      expect(asking, findsNothing);
      expect(finance.transactions.single.note, 'Larch Hardware');
    });
  });

  group('restore dialog', () {
    /// A button that opens the dialog; [result] holds what it returned.
    Future<List<String?>> pumpOpener(
      WidgetTester tester, {
      DateTime? madeAt,
      Future<String> Function(String)? open,
    }) async {
      final result = <String?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async => result.add(
                    await showRestorePassphraseDialog<String>(
                      context,
                      madeAt: madeAt,
                      open:
                          open ??
                          (p) async => p == 'saffron gate 61'
                              ? 'opened'
                              : throw const WrongPassphraseException(),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    }

    Future<void> submit(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
    }

    testWidgets('a wrong entry keeps it open with the error, and a retry '
        'opens', (tester) async {
      final result = await pumpOpener(
        tester,
        madeAt: DateTime(thisYear, 11, 23, 10),
      );
      expect(find.text('Enter the backup passphrase'), findsOneWidget);
      expect(
        find.text('This backup was made on 23 Nov and is protected.'),
        findsOneWidget,
      );
      expect(button(tester, 'Restore').onPressed, isNull);

      await submit(tester, 'saffron gate 16');
      expect(find.text('Enter the backup passphrase'), findsOneWidget);
      expect(
        find.text('That passphrase does not open this backup.'),
        findsOneWidget,
      );
      expect(result, isEmpty);

      await tester.enterText(find.byType(TextField), 'saffron gate 61');
      await tester.pump();
      expect(
        find.text('That passphrase does not open this backup.'),
        findsNothing,
      );
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(find.text('Enter the backup passphrase'), findsNothing);
      expect(result, ['opened']);
    });

    testWidgets('a backup from an earlier year shows the year', (
      tester,
    ) async {
      await pumpOpener(tester, madeAt: DateTime(thisYear - 2, 11, 23, 10));
      expect(
        find.text(
          'This backup was made on 23 Nov ${thisYear - 2} and is protected.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('with no date it says only that the backup is protected, '
        'and Cancel returns nothing', (tester) async {
      final result = await pumpOpener(tester);
      expect(find.text('This backup is protected.'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, [null]);
    });

    testWidgets('any other failure shows that the backup cannot be read, a '
        'newer form says so, and the dialog stays open', (tester) async {
      var calls = 0;
      await pumpOpener(
        tester,
        open: (_) async => calls++ == 0
            ? throw const FormatException('broken')
            : throw const NewerBackupFormatException(),
      );
      await submit(tester, 'saffron gate 16');
      expect(find.text('This backup cannot be read.'), findsOneWidget);
      await submit(tester, 'saffron gate 17');
      expect(
        find.text(
          'This backup was made by a newer version of the app. Update the '
          'app to restore it.',
        ),
        findsOneWidget,
      );
      expect(find.text('Enter the backup passphrase'), findsOneWidget);
    });

    testWidgets('its own eye button shows the passphrase', (tester) async {
      await pumpOpener(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
      await tester.tap(find.byTooltip('Show passphrase'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
      expect(find.byTooltip('Hide passphrase'), findsOneWidget);
    });
  });

  group('360 wide at 1.3 times text', () {
    void small(WidgetTester tester) {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }

    testWidgets('the switch row and the set dialog with an error fit', (
      tester,
    ) async {
      small(tester);
      await pumpBackupPage(tester);
      expect(row, findsOneWidget);
      await tester.tap(row);
      await pumpThrough(tester);
      await tester.enterText(first, 'caf\u{00E9} terrace 9');
      await tester.pump();
      expect(
        find.text('Use English letters, digits and symbols only'),
        findsOneWidget,
      );
      expect(find.text('Set a backup passphrase'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the restore dialog with its error fits', (tester) async {
      small(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RestorePassphraseDialog<String>(
              madeAt: DateTime(thisYear - 1, 11, 23, 10),
              open: (_) async => throw const WrongPassphraseException(),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'saffron gate 16');
      await tester.pump();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(
        find.text('That passphrase does not open this backup.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
