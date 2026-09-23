import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';

/// The "i" tips on the Settings screen open their explanation bubble.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Bounded pumps: the Drive section keeps an indeterminate progress bar up
  /// while the sign-in state loads (never resolves under tests), so
  /// pumpAndSettle would time out.
  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

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
    await pumpThrough(tester);
  }

  /// Opens a group page from the Settings root by its row title.
  Future<void> openGroup(WidgetTester tester, String title) async {
    await tester.tap(find.text(title));
    await pumpThrough(tester);
  }

  Future<void> openTip(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('About $label'));
    await pumpThrough(tester);
  }

  testWidgets('Cloud backup tip explains what the backup holds', (
    tester,
  ) async {
    await pumpSettings(tester);
    await openGroup(tester, 'Backup and data');
    await openTip(tester, 'Cloud backup');
    expect(
      find.textContaining('The newest 7 backups are kept'),
      findsOneWidget,
    );

    await tester.tap(find.text('Got it'));
    await pumpThrough(tester);
    expect(find.textContaining('The newest 7 backups are kept'), findsNothing);
  });

  testWidgets('App lock tip opens without toggling the lock', (tester) async {
    await pumpSettings(tester);
    await openGroup(tester, 'Privacy');
    await openTip(tester, 'App lock');
    expect(find.textContaining('returns after 2 minutes away'), findsOneWidget);
    // The pushed group page, not SettingsScreen: the root route is offstage
    // under it, and finders skip offstage widgets.
    final settings = tester
        .element(find.byType(SettingsGroupPage))
        .read<SettingsProvider>();
    expect(settings.appLock, isFalse);
  });
}
