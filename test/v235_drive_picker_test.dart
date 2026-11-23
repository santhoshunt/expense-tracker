import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/utils/format.dart';

import 'drive_backup_service_test.dart'
    show FakeDrive, FakeDriveAuth, fakeBackupFile;

/// v2.3.5: a restore from Google Drive lists one row per phone, and the
/// Drive backup settings name this phone's backups.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The picker dates a backup from this year without its year, so the
  // phones' fixtures sit in this year and the earlier backups in 2025.
  final thisYear = DateTime.now().year;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'drive_connected_email': 'me@example.com',
      'drive_install_id': 'mine0001',
    });
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// Bounded pumps: the sheets animate, and the Drive section's minute
  /// clock never lets pumpAndSettle finish.
  Future<void> pumpThrough(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpSettings(WidgetTester tester, FakeDrive drive) async {
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
              httpClient: () => drive.client,
            ),
          ),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpThrough(tester);
    // Below the fold on a small screen with large text.
    await tester.scrollUntilVisible(
      find.text('Backup and data'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('Backup and data'));
    await pumpThrough(tester);
  }

  /// Import, From Google Drive, with the sheet's Merge.
  Future<void> importFromDrive(WidgetTester tester) async {
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
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await pumpThrough(tester);
  }

  /// Ids of the files the restore downloaded. The fake holds no content
  /// for them, so the restore stops there with its failure toast and the
  /// test needs no background isolate to decode a file.
  List<String> downloaded(FakeDrive drive) => [
    for (final http.Request r in drive.requests)
      if (r.url.queryParameters['alt'] == 'media') r.url.pathSegments.last,
  ];

  List<Map<String, Object?>> threePhones({String other = 'Demo Phone Two'}) => [
    fakeBackupFile(
      'm0',
      DateTime.utc(thisYear, 11, 21, 12),
      install: 'mine0001',
      name: 'Demo Phone One',
      count: 310,
    ),
    fakeBackupFile(
      'm1',
      DateTime.utc(thisYear, 11, 20, 12),
      install: 'mine0001',
      name: 'Demo Phone One',
      count: 300,
    ),
    fakeBackupFile(
      'o0',
      DateTime.utc(thisYear, 11, 23, 12),
      install: 'other002',
      name: other,
      count: 1204,
    ),
    fakeBackupFile('e0', DateTime.utc(2025, 10, 12, 12)),
  ];

  testWidgets('the picker lists this phone first, then the others by their '
      "newest backup, and a tap restores that phone's newest", (tester) async {
    final drive = FakeDrive(files: threePhones());
    await pumpSettings(tester, drive);
    await importFromDrive(tester);

    expect(find.text('Choose a backup'), findsOneWidget);
    final rows = [
      ('This phone', joinFacts(['21 Nov', '310 transactions'])),
      // Grouped the Indian way, as amounts are.
      ('Demo Phone Two', joinFacts(['23 Nov', '1,204 transactions'])),
      // Another year's date names its year.
      ('Earlier backups', joinFacts(['12 Oct 2025'])),
    ];
    var above = double.negativeInfinity;
    for (final (title, line) in rows) {
      expect(find.text(title), findsOneWidget);
      expect(find.text(line), findsOneWidget, reason: title);
      final y = tester.getTopLeft(find.text(title)).dy;
      expect(y, greaterThan(above), reason: title);
      above = y;
    }
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNWidgets(3),
    );
    expect(downloaded(drive), isEmpty, reason: 'nothing before a choice');

    await tester.tap(find.text('Demo Phone Two'));
    await pumpThrough(tester);
    expect(downloaded(drive), ['o0']);
    expect(find.text('Choose a backup'), findsNothing);
  });

  testWidgets('one phone in the folder skips the picker', (tester) async {
    final drive = FakeDrive(
      files: [
        fakeBackupFile(
          'o0',
          DateTime.utc(2026, 11, 23, 12),
          install: 'other002',
          name: 'Demo Phone Two',
          count: 40,
        ),
        fakeBackupFile(
          'o1',
          DateTime.utc(2026, 11, 22, 12),
          install: 'other002',
          name: 'Demo Phone Two',
          count: 38,
        ),
      ],
    );
    await pumpSettings(tester, drive);
    await importFromDrive(tester);
    expect(find.text('Choose a backup'), findsNothing);
    expect(downloaded(drive), ['o0']);
  });

  testWidgets('a restore through the screen clears the waiting message, and '
      'the Cloud backup banner goes at once', (tester) async {
    // Another phone's ledger, built and encoded before this test's
    // preferences are set, so its rows are only in the file.
    final other = FinanceProvider();
    await other.load();
    await other.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 75,
      note: 'demo cafe',
      date: DateTime(2026, 9, 3),
    );
    final bytes = encodeBackupGz(other.exportData());
    SharedPreferences.setMockInitialValues({
      'drive_connected_email': 'me@example.com',
      'drive_install_id': 'mine0001',
      'drive_last_error': kDriveOtherPhoneMessage,
    });
    final drive = FakeDrive(
      files: [
        fakeBackupFile(
          'o0',
          DateTime.utc(2026, 11, 23, 12),
          install: 'other002',
          name: 'Demo Phone Two',
          count: 1,
        ),
      ],
    );
    drive.media['o0'] = bytes;
    await pumpSettings(tester, drive);
    expect(find.text(kDriveOtherPhoneMessage), findsOneWidget);

    await importFromDrive(tester);
    // The download decodes on a background isolate, which runs only on
    // real time: let it, then pump, until the restore is marked.
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < 100; i++) {
      if (prefs.getBool('drive_restored_here') == true) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await pumpThrough(tester);

    expect(downloaded(drive), ['o0']);
    expect(prefs.getString('drive_last_error'), isNull);
    expect(find.text(kDriveOtherPhoneMessage), findsNothing);
    expect(find.textContaining('Imported 1 new transactions'), findsOneWidget);
  });

  testWidgets('the picker fits a 360 wide screen at 1.3 times text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final drive = FakeDrive(
      files: threePhones(other: 'Demo Phone Two in the spare bedroom'),
    );
    await pumpSettings(tester, drive);
    await importFromDrive(tester);
    expect(find.text('Choose a backup'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Backup name shows the name, renames it, and the waiting '
      'message reads as it is', (tester) async {
    SharedPreferences.setMockInitialValues({
      'drive_connected_email': 'me@example.com',
      'drive_install_id': 'mine0001',
      'drive_backup_name': 'Demo Phone One',
      'drive_last_error': kDriveOtherPhoneMessage,
    });
    final drive = FakeDrive();
    await pumpSettings(tester, drive);
    expect(find.text(kDriveOtherPhoneMessage), findsOneWidget);
    expect(find.textContaining('The last Drive backup failed'), findsNothing);

    final row = find.byKey(const ValueKey('drive-backup-name'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(
      find.descendant(of: row, matching: find.text('Demo Phone One')),
      findsOneWidget,
    );
    await tester.tap(row);
    await pumpThrough(tester);
    await tester.enterText(find.byType(TextField), 'Demo Phone Three');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await pumpThrough(tester);
    expect(
      find.descendant(of: row, matching: find.text('Demo Phone Three')),
      findsOneWidget,
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('drive_backup_name'), 'Demo Phone Three');
  });

  testWidgets('a name too long for Drive cannot be saved', (tester) async {
    await pumpSettings(tester, FakeDrive());
    final row = find.byKey(const ValueKey('drive-backup-name'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(row);
    await pumpThrough(tester);
    await tester.enterText(find.byType(TextField), 'Demo phone ' * 12);
    await tester.pump();
    expect(find.text('Use a shorter name'), findsOneWidget);
  });

  testWidgets('the Drive backup settings fit a 360 wide screen at 1.3 times '
      'text', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({
      'drive_connected_email': 'me@example.com',
      'drive_install_id': 'mine0001',
      'drive_last_error': kDriveOtherPhoneMessage,
    });
    await pumpSettings(tester, FakeDrive());
    expect(find.text(kDriveOtherPhoneMessage), findsOneWidget);
    final row = find.byKey(const ValueKey('drive-backup-name'));
    await tester.scrollUntilVisible(
      row,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(row, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
