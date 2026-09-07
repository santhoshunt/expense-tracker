import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Widget cockpit(FinanceProvider p) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: const MaterialApp(home: ClassifiersScreen()),
  );

  testWidgets('Cockpit hosts Budgets and Reminders tabs with add flows', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(cockpit(p));
    await pumpThrough(tester);

    expect(find.text('Cockpit'), findsOneWidget);
    expect(find.text('Budgets'), findsOneWidget);
    expect(find.text('Reminders'), findsOneWidget);

    await tester.tap(find.text('Budgets'));
    await pumpThrough(tester);
    expect(find.text('Monthly cap'), findsOneWidget);
    expect(find.text('No custom budgets yet.'), findsOneWidget);
    expect(find.text('Add budget'), findsOneWidget);
    expect(find.text('New budget'), findsOneWidget, reason: 'FAB follows tab');

    await tester.tap(find.text('Reminders'));
    await pumpThrough(tester);
    expect(find.text('No reminders yet.'), findsOneWidget);
    expect(find.text('Add reminder'), findsOneWidget);
    expect(find.text('New reminder'), findsOneWidget);
  });

  testWidgets('Settings lost the moved sections and points at Cockpit', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);

    expect(find.text('Monthly cap', skipOffstage: false), findsNothing);
    expect(find.text('Custom budgets', skipOffstage: false), findsNothing);
    expect(find.text('Add reminder', skipOffstage: false), findsNothing);
    // The pointer row sits near the bottom, offstage in the cache extent.
    await tester.scrollUntilVisible(
      find.text('Moved — manage them in Cockpit'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('Rules, categories, budgets & reminders'), findsOneWidget);
    expect(find.text('Moved — manage them in Cockpit'), findsOneWidget);
  });
}
