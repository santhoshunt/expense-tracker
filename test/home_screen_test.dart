import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/widgets/category_donut_chart.dart';

Widget app(FinanceProvider provider) => MultiProvider(
  providers: [
    ChangeNotifierProvider.value(value: provider),
    ChangeNotifierProvider(create: (_) => SettingsProvider()),
    // Never signs in under tests (platform channel absent → the scheduled
    // check's catch-all records the failure and moves on).
    Provider<DriveBackupService>(create: (_) => DriveBackupService()),
  ],
  child: const MaterialApp(home: HomeScreen()),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('backup menu groups export and import into submenus', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();

    expect(find.text('Export'), findsOneWidget);
    expect(find.text('Import'), findsOneWidget);
    expect(find.text('Delete all data'), findsOneWidget);

    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Backup (JSON)'), findsOneWidget);
    expect(find.text('Transactions (CSV)'), findsOneWidget);
    expect(find.text('Report (PDF)'), findsOneWidget);
  });

  testWidgets('delete all asks for confirmation and clears data', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'lunch',
      date: DateTime(2026, 7, 1),
    );
    await tester.pumpWidget(app(p));

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete all data'));
    await tester.pumpAndSettle();

    expect(find.text('Delete all data?'), findsOneWidget);
    await tester.tap(find.text('Delete everything'));
    await tester.pumpAndSettle();

    expect(p.transactions, isEmpty);
  });

  testWidgets('editing an entry offers a delete button', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'Lunch',
      date: DateTime(2026, 7, 1),
    );
    await tester.pumpWidget(app(p));

    // Open the Transactions tab and tap the entry to edit it.
    await tester.tap(find.text('Transactions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lunch'));
    await tester.pumpAndSettle();

    expect(find.text('Delete transaction'), findsOneWidget);
    await tester.ensureVisible(find.text('Delete transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete transaction'));
    await tester.pumpAndSettle();

    // Deletes act immediately — no confirmation dialog — and offer Undo.
    expect(p.transactions, isEmpty);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.transactions.single.note, 'Lunch');
  });

  testWidgets('import action asks for merge or replace', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup (JSON)'));
    await tester.pumpAndSettle();

    expect(find.text('Import backup'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);

    // Cancel closes without touching the file picker.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Merge'), findsNothing);
  });

  testWidgets('dashboard budget row deep-links to budget-filtered list', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    final month = DateTime(now.year, now.month, 1);
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'lunch',
      date: month,
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 200,
      note: 'cab',
      date: month,
    );
    await p.addBudget(
      name: 'Eating out',
      limit: 2000,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Eating out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();

    // The row now opens the detail sheet; the deep-link moved onto its
    // "View transactions" button.
    expect(find.text('Where it went'), findsOneWidget);
    await tester.ensureVisible(find.text('View transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View transactions'));
    await tester.pumpAndSettle();

    // Landed on Transactions with only the budget's rows.
    expect(find.text('lunch'), findsOneWidget);
    expect(find.text('cab'), findsNothing);
  });

  testWidgets('deleting the deep-linked budget un-filters the list cleanly', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    final month = DateTime(now.year, now.month, 1);
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'lunch',
      date: month,
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 200,
      note: 'cab',
      date: month,
    );
    await p.addBudget(
      name: 'Eating out',
      limit: 2000,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Eating out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Eating out'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('View transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View transactions'));
    await tester.pumpAndSettle();
    expect(find.text('cab'), findsNothing);

    // Delete the budget out from under the active filter: the stale id must
    // be pruned (not silently no-op with the badge still lit) and its chip
    // must disappear.
    await p.deleteBudget(p.budgets.single.id);
    await tester.pumpAndSettle();

    expect(find.text('lunch'), findsOneWidget);
    expect(find.text('cab'), findsOneWidget);
    expect(find.textContaining('Budget ·'), findsNothing);
  });

  testWidgets('dashboard category spending row deep-links to that category', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    final month = DateTime(now.year, now.month, 1);
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'lunch',
      date: month,
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 200,
      note: 'cab',
      date: month,
    );
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    // The dashboard list inflates lazily — scroll until the donut chart
    // (which sits right above the spending card) is built, then a bit more.
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byType(CategoryDonutChart),
      200,
      scrollable: scrollable,
    );
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pumpAndSettle();

    // "Food & Dining" also appears in the donut legend and recent tiles;
    // the spending row is the first tappable InkWell holding that text.
    final foodRow = find
        .ancestor(
          of: find.text('Food & Dining'),
          matching: find.byWidgetPredicate(
            (w) => w is InkWell && w.onTap != null,
          ),
        )
        .first;
    await tester.ensureVisible(foodRow);
    await tester.pumpAndSettle();
    await tester.tap(foodRow);
    await tester.pumpAndSettle();

    expect(find.text('lunch'), findsOneWidget);
    expect(find.text('cab'), findsNothing);
  });

  testWidgets('filter sheet search narrows chips; selections stay visible', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 100,
      note: 'lunch',
      date: DateTime(2026, 7, 1),
    );
    await tester.pumpWidget(app(p));

    await tester.tap(find.text('Transactions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Filters'));
    await tester.pumpAndSettle();

    // Select Transport, then search for something it doesn't match.
    await tester.ensureVisible(find.widgetWithText(FilterChip, 'Transport'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'Transport'));
    await tester.pump();

    final sheetSearch = find
        .descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(TextField),
        )
        .first;
    await tester.enterText(sheetSearch, 'foo');
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilterChip, 'Food & Dining'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Health'), findsNothing);
    // The active selection can't disappear behind the query.
    expect(find.widgetWithText(FilterChip, 'Transport'), findsOneWidget);
  });

  testWidgets('SMS import button is absent on non-Android platforms', (
    tester,
  ) async {
    // Widget tests run with debugDefaultTargetPlatformOverride unset →
    // TargetPlatform.android by default; simulate iOS.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));

    expect(find.byIcon(Icons.sms_outlined), findsNothing);
    // Backup menu is platform-independent and stays visible.
    expect(find.byTooltip('More options'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });
}
