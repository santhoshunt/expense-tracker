import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('backupStatusLine', () {
    final now = DateTime(2026, 10, 14, 9, 30);

    test('counts calendar days', () {
      expect(
        backupStatusLine(DateTime(2026, 10, 14, 1, 5), null, now),
        'Last backup today',
      );
      expect(
        backupStatusLine(DateTime(2026, 10, 13, 23, 50), null, now),
        'Last backup yesterday',
      );
      expect(
        backupStatusLine(DateTime(2026, 10, 12, 18), null, now),
        'Last backup 2 days ago',
      );
      expect(
        backupStatusLine(DateTime(2026, 9, 14, 18), null, now),
        'Last backup 30 days ago',
      );
    });

    test('a recorded failure wins', () {
      expect(
        backupStatusLine(DateTime(2026, 10, 14, 1), 'quota exceeded', now),
        'Last backup failed',
      );
      expect(
        backupStatusLine(null, 'quota exceeded', now),
        'Last backup failed',
      );
    });

    test('access to grant again reads as Reconnect, not a failure', () {
      expect(
        backupStatusLine(
          DateTime(2026, 10, 12, 8),
          kDriveReconnectMessage,
          now,
        ),
        'Reconnect Google Drive',
      );
      expect(
        backupStatusLine(null, kDriveReconnectMessage, now),
        'Reconnect Google Drive',
      );
    });

    test('nothing backed up and nothing failed: no line', () {
      expect(backupStatusLine(null, null, now), isNull);
    });
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    final finance = FinanceProvider();
    await finance.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('the Backup row shows a recorded failure', (tester) async {
    SharedPreferences.setMockInitialValues({
      'drive_last_backup_at': DateTime(2026, 10, 1, 8).toIso8601String(),
      'drive_last_error': 'quota exceeded',
    });
    await pumpSettings(tester);
    expect(find.text('Last backup failed'), findsOneWidget);
    expect(find.text('Google Drive, export, import, delete'), findsNothing);
  });

  testWidgets('the Backup row asks to reconnect when access was lost', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'drive_last_backup_at': DateTime(2026, 10, 1, 8).toIso8601String(),
      'drive_last_error': kDriveReconnectMessage,
    });
    await pumpSettings(tester);
    expect(find.text('Reconnect Google Drive'), findsOneWidget);
    expect(find.text('Last backup failed'), findsNothing);
  });

  testWidgets('never backed up: the row says what the page holds', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpSettings(tester);
    expect(find.text('Google Drive, export, import, delete'), findsOneWidget);
  });

  testWidgets('at 320dp with 2x text the root rows drop their icons and '
      'chevrons, so the words get the width', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({});
    await pumpSettings(tester);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.palette_outlined), findsNothing);
    final cardLeft = tester.getTopLeft(find.byType(ListTile).first).dx;
    // The title starts at the row's own 16dp padding, not past an icon.
    expect(tester.getTopLeft(find.text('Appearance')).dx, cardLeft + 16);
  });

  testWidgets('at normal text the root rows keep their icons', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpSettings(tester);
    expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsWidgets);
  });

  testWidgets('Category order is the row and the page title', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await pumpSettings(tester);
    expect(find.text('Categories and rules'), findsNothing);
    await tester.tap(find.text('Category order'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.widgetWithText(AppBar, 'Category order'), findsOneWidget);
    // The heading no longer repeats the title.
    expect(find.text('Category order'), findsOneWidget);
    expect(find.text('In the add and edit sheets'), findsOneWidget);
  });
}
