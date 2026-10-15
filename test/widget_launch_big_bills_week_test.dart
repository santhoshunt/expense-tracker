import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/weekly_digest.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';

/// v1.41.0: a tap on a Big bills widget opens the Big bills ahead sheet,
/// and one on a This week widget opens the digest on the current week,
/// from any tab.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    LaunchActions.instance.resetForTest();
    appLocked.value = false;
  });

  tearDown(() {
    LaunchActions.instance.resetForTest();
    appLocked.value = true;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// Home, moved to the Transactions tab, so the tap has to bring the
  /// Dashboard back.
  Future<void> pumpHomeOnTransactions(
    WidgetTester tester, {
    Future<void> Function(FinanceProvider)? seed,
  }) async {
    final finance = FinanceProvider();
    await finance.load();
    await seed?.call(finance);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Transactions').last);
    await settle(tester);
  }

  Finder inSheet(String text) =>
      find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

  testWidgets('Big bills opens the Big bills ahead sheet', (tester) async {
    await pumpHomeOnTransactions(tester);
    expect(find.byType(BottomSheet), findsNothing);

    LaunchActions.instance.pending.value = LaunchAction.openBigBills;
    await settle(tester);
    await settle(tester);
    expect(inSheet('Big bills ahead'), findsOneWidget);
    expect(LaunchActions.instance.pending.value, isNull);
  });

  testWidgets('This week opens the digest on the current week', (tester) async {
    final now = DateTime.now();
    final thisWeek = weekStartOf(now);
    final lastWeek = DateTime(thisWeek.year, thisWeek.month, thisWeek.day - 7);
    // Records from three weeks back, so the sheet would keep an earlier
    // week if it were handed one rather than move it to this week.
    await pumpHomeOnTransactions(
      tester,
      seed: (p) => p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: 'test food',
        date: DateTime(now.year, now.month, now.day - 21),
      ),
    );
    expect(find.byType(BottomSheet), findsNothing);

    LaunchActions.instance.pending.value = LaunchAction.openThisWeek;
    await settle(tester);
    await settle(tester);
    expect(
      inSheet(weekRangeLabel(thisWeek, withWeekday: true)),
      findsOneWidget,
    );
    expect(inSheet(weekRangeLabel(lastWeek, withWeekday: true)), findsNothing);
    expect(LaunchActions.instance.pending.value, isNull);
  });
}
