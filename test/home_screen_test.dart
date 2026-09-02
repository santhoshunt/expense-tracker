import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/animated_fold.dart';
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

  /// Bounded pumps for flows that show the Settings screen: its Drive
  /// section keeps an INDETERMINATE progress bar up while the sign-in state
  /// loads (which never resolves under tests), so pumpAndSettle would time
  /// out. Two pumps advance past route/sheet/dialog transitions instead.
  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  testWidgets('data actions moved to Settings; export sheet lists formats', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));

    // The ⋮ menu is gone; a direct settings button replaced it.
    expect(find.byTooltip('More options'), findsNothing);
    expect(find.byTooltip('Settings'), findsOneWidget);

    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);
    // The settings list mounts lazily — scroll the Data section into view.
    await tester.scrollUntilVisible(
      find.text('Export…'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('Export…'), findsOneWidget);
    expect(find.text('Import…'), findsOneWidget);
    expect(find.text('Delete all data'), findsOneWidget);

    await tester.tap(find.text('Export…'));
    await pumpThrough(tester);
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

    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);
    await tester.scrollUntilVisible(
      find.text('Delete all data'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('Delete all data'));
    await pumpThrough(tester);

    expect(find.text('Delete all data?'), findsOneWidget);
    await tester.tap(find.text('Delete everything'));
    // Dialog closes, the busy barrier shows while the wipe persists, then
    // pops — three bounded pumps carry it through.
    await pumpThrough(tester);
    await pumpThrough(tester);

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

    await tester.tap(find.byTooltip('Settings'));
    await pumpThrough(tester);
    await tester.scrollUntilVisible(
      find.text('Import…'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('Import…'));
    await pumpThrough(tester);
    await tester.tap(find.text('Backup (JSON)'));
    await pumpThrough(tester);
    await pumpThrough(tester);

    expect(find.text('Import backup'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);
    expect(find.text('Replace'), findsOneWidget);

    // Cancel closes without touching the file picker.
    await tester.tap(find.text('Cancel'));
    await pumpThrough(tester);
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

  testWidgets('top merchants row deep-links to a merchant search', (
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
      note: 'Zomato order',
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

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Top merchants'),
      200,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();

    // The merchants row shows the title-cased label, unique on screen.
    final row = find
        .ancestor(
          of: find.text('Zomato Order'),
          matching: find.byWidgetPredicate(
            (w) => w is InkWell && w.onTap != null,
          ),
        )
        .first;
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    // Transactions tab: search pre-filled with the identity, list filtered.
    expect(find.text('Zomato order'), findsOneWidget);
    expect(find.text('cab'), findsNothing);
  });

  testWidgets('upcoming card collapses to its header and re-expands', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final id = await p.addAccount(
      name: 'HDFC Card',
      type: AccountType.creditCard,
    );
    await p.setManualBalance(id, 5000); // outstanding → bill row appears
    await p.setCardCycle(id, dueDay: DateTime.now().day);
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    expect(find.text('HDFC Card bill'), findsOneWidget);

    // The header count is static in both states — animating it (an
    // AnimatedOpacity fade) rendered the glyphs in halves on Impeller.
    final header = find
        .ancestor(of: find.text('Upcoming'), matching: find.byType(Row))
        .first;
    final count = find.descendant(of: header, matching: find.text('1'));
    expect(count, findsOneWidget);
    // (The tab switcher above fades whole pages; only the header row itself
    // must be free of opacity animation.)
    expect(
      find.descendant(of: header, matching: find.byType(AnimatedOpacity)),
      findsNothing,
    );

    // AnimatedFold keeps the folded child mounted at zero height, so assert
    // on the fold's rendered height, not text absence.
    final fold = find.byType(AnimatedFold).first;
    expect(tester.getSize(fold).height, greaterThan(50));

    await tester.tap(find.text('Upcoming'));
    await tester.pumpAndSettle();
    expect(tester.getSize(fold).height, lessThan(1));
    expect(count, findsOneWidget);

    await tester.tap(find.text('Upcoming'));
    await tester.pumpAndSettle();
    expect(tester.getSize(fold).height, greaterThan(50));
    expect(find.text('HDFC Card bill'), findsOneWidget);
    expect(count, findsOneWidget);
  });

  testWidgets('review cards collapse; Reject all discards with Undo', (
    tester,
  ) async {
    Tx pendingTx(String id, double amount, {bool spam = false}) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: amount,
      note: 'row $id',
      date: DateTime(2026, 7, 1),
      pending: true,
      suspectedSpam: spam,
    );
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        pendingTx('p1', 100).toJson(),
        pendingTx('p2', 200).toJson(),
        pendingTx('s1', 300, spam: true).toJson(),
      ]),
    });
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));
    await tester.tap(find.text('Transactions').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('Imported from SMS · 2'), findsOneWidget);
    expect(find.textContaining('Suspected spam · 1'), findsOneWidget);

    Finder foldOf(String headerSub) => find
        .descendant(
          of: find
              .ancestor(
                of: find.textContaining(headerSub),
                matching: find.byType(Card),
              )
              .first,
          matching: find.byType(AnimatedFold),
        )
        .first;

    // Both cards fold to their headers and re-expand.
    final pendingFold = foldOf('Imported from SMS');
    expect(tester.getSize(pendingFold).height, greaterThan(50));
    await tester.tap(find.textContaining('Imported from SMS'));
    await tester.pumpAndSettle();
    expect(tester.getSize(pendingFold).height, lessThan(1));

    final spamFold = foldOf('Suspected spam');
    await tester.tap(find.textContaining('Suspected spam'));
    await tester.pumpAndSettle();
    expect(tester.getSize(spamFold).height, lessThan(1));

    await tester.tap(find.textContaining('Imported from SMS'));
    await tester.pumpAndSettle();
    expect(tester.getSize(pendingFold).height, greaterThan(50));

    // Reject all: dialog → queue emptied (spam untouched) → Undo restores.
    await tester.tap(find.text('Reject all'));
    await tester.pumpAndSettle();
    expect(find.text('Reject all 2 imports?'), findsOneWidget);
    await tester.tap(find.text('Reject all').last);
    await tester.pumpAndSettle();

    expect(p.pendingTransactions.where((t) => !t.suspectedSpam), isEmpty);
    expect(p.pendingTransactions.where((t) => t.suspectedSpam), hasLength(1));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.pendingTransactions.where((t) => !t.suspectedSpam), hasLength(2));
  });

  testWidgets('month select-all and bulk delete with Undo', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'lunch',
      date: DateTime(2026, 7, 1),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 200,
      note: 'cab',
      date: DateTime(2026, 7, 2),
    );
    await tester.pumpWidget(app(p));
    await tester.tap(find.text('Transactions').last);
    await tester.pumpAndSettle();

    // The month-header button toggles the whole month in and out.
    await tester.tap(find.byTooltip('Select month'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete'), findsOneWidget);
    await tester.tap(find.byTooltip('Select month'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Delete'), findsNothing);

    await tester.tap(find.byTooltip('Select month'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 transactions?'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(p.transactions, isEmpty);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.transactions, hasLength(2));
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
    // The settings button is platform-independent and stays visible.
    expect(find.byTooltip('Settings'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('search matches amount, category label and account name', (
    tester,
  ) async {
    Tx row(String id, String note, String cat, double amount, {String? acct}) =>
        Tx(
          id: id,
          type: TxType.expense,
          categoryId: cat,
          amount: amount,
          note: note,
          date: DateTime(2026, 7, 1),
          acctKey: acct,
        );
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        row('c', 'coffee', 'food', 120, acct: 'HDFC:1234').toJson(),
        row('t', 'cab', 'transport', 340).toJson(),
      ]),
    });
    final p = FinanceProvider();
    await p.load();
    final owner = p.accountForKey('HDFC:1234');
    if (owner != null) {
      await p.renameAccount(owner.id, 'Salary Account');
    } else {
      final id = await p.addAccount(
        name: 'Salary Account',
        type: AccountType.bank,
      );
      expect(await p.addAccountKey(id, 'HDFC:1234'), isTrue);
    }
    await tester.pumpWidget(app(p));
    await tester.tap(find.text('Transactions').last);
    await tester.pumpAndSettle();
    expect(find.text('coffee'), findsOneWidget);
    expect(find.text('cab'), findsOneWidget);

    Future<void> search(String q) async {
      await tester.enterText(find.byType(TextField).first, q);
      await tester.pump(const Duration(milliseconds: 300)); // debounce
      await tester.pumpAndSettle();
    }

    await search('340');
    expect(find.text('cab'), findsOneWidget);
    expect(find.text('coffee'), findsNothing);

    await search('transport');
    expect(find.text('cab'), findsOneWidget);
    expect(find.text('coffee'), findsNothing);

    await search('salary');
    expect(find.text('coffee'), findsOneWidget);
    expect(find.text('cab'), findsNothing);
  });

  testWidgets('date range filter keeps whole days and shows a chip', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    Future<void> add(String note, DateTime date) => p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 10,
      note: note,
      date: date,
    );
    await add('early', DateTime(2026, 7, 1, 12));
    await add('mid', DateTime(2026, 7, 7, 9));
    await add('edge', DateTime(2026, 7, 10, 23, 30));
    await add('late', DateTime(2026, 7, 11, 0, 10));

    Widget screen(TxFilterRequest? req, int token) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: p),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TransactionsScreen(request: req, filterToken: token),
        ),
      ),
    );
    await tester.pumpWidget(screen(null, 0));
    await tester.pumpAndSettle();
    expect(find.text('early'), findsOneWidget);
    expect(find.text('late'), findsOneWidget);

    final range = DateTimeRange(
      start: DateTime(2026, 7, 5),
      end: DateTime(2026, 7, 10),
    );
    await tester.pumpWidget(screen(TxFilterRequest(range: range), 1));
    await tester.pumpAndSettle();

    expect(find.text('mid'), findsOneWidget);
    expect(find.text('edge'), findsOneWidget, reason: 'end day inclusive');
    expect(find.text('early'), findsNothing);
    expect(find.text('late'), findsNothing);
    expect(find.text('5 – 10 Jul 2026'), findsOneWidget);

    // Dismissing the chip clears the range.
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, '5 – 10 Jul 2026'),
        matching: find.byTooltip('Delete'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('early'), findsOneWidget);
    expect(find.text('late'), findsOneWidget);
  });

  testWidgets('long-pressing a category row opens a prefilled budget', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 800,
      note: 'groceries',
      date: DateTime.now(),
    );
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    // Only the category rows carry a long-press (the donut legend above
    // them shows the same label without one). The list is lazy, so scroll
    // until the row itself is built.
    final row = find
        .ancestor(
          of: find.text('Food & Dining'),
          matching: find.byWidgetPredicate(
            (w) => w is InkWell && w.onLongPress != null,
          ),
        )
        .first;
    // The single category owns 100% of the month — that share label exists
    // only on the row, so scrolling to it mounts the row.
    await tester.scrollUntilVisible(
      find.text('100%'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.longPress(row);
    await tester.pumpAndSettle();

    expect(find.text('New budget'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Food & Dining'), findsOneWidget);
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(1), '5000');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    final b = p.budgets.single;
    expect(b.name, 'Food & Dining');
    expect(b.mode, BudgetMode.include);
    expect(b.categoryIds, {'food'});
    expect(b.limit, 5000);
    // The row now shows the cap beside the spend.
    expect(find.textContaining(' of ₹'), findsOneWidget);

    // A second long-press edits that budget instead of creating another.
    await tester.longPress(row);
    await tester.pumpAndSettle();
    expect(find.text('Edit budget'), findsOneWidget);
  });

  testWidgets('Year view swaps the month sections for the year', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 800,
      note: 'groceries',
      date: DateTime.now(),
    );
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();
    final year = DateTime.now().year;
    final list = find.byType(Scrollable).first;
    final monthLabel = find.text(
      fmtMonth(DateTime(year, DateTime.now().month)),
    );
    expect(monthLabel, findsOneWidget);
    expect(find.byTooltip('Export year report (PDF)'), findsNothing);

    // The scope switch sits near the top, so it is built and tappable
    // without scrolling.
    await tester.tap(find.text('Year'));
    await tester.pumpAndSettle();
    expect(
      find.text('$year'),
      findsOneWidget,
      reason: 'selector shows the year',
    );
    expect(monthLabel, findsNothing);
    expect(find.byTooltip('Export year report (PDF)'), findsOneWidget);

    // The dashboard list is lazy: scroll the chart section into view.
    await tester.scrollUntilVisible(
      find.text('Months of $year'),
      300,
      scrollable: list,
    );
    expect(find.text('Months of $year'), findsOneWidget);
    expect(find.text('Last 6 months'), findsNothing);
    expect(find.text('Spending heatmap'), findsNothing);

    // Back to Month: the month-only sections return.
    await tester.scrollUntilVisible(find.text('Month'), -300, scrollable: list);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Month'));
    await tester.pumpAndSettle();
    // Rows above the viewport count as offstage for finders even when built,
    // so bring the selector back on screen before asserting on it.
    await tester.scrollUntilVisible(monthLabel, -300, scrollable: list);
    expect(monthLabel, findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Spending heatmap'),
      300,
      scrollable: list,
    );
    expect(find.text('Spending heatmap'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Last 6 months'),
      300,
      scrollable: list,
    );
    expect(find.text('Last 6 months'), findsOneWidget);
  });

  testWidgets('long-pressing a Top merchant renames it everywhere', (
    tester,
  ) async {
    final now = DateTime.now();
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        Tx(
          id: 'fd1',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 5000,
          note: '',
          smsBody:
              'Rs.5000.00 debited from a/c XX1234 to FD NO 12345 on 01-07-26.',
          date: DateTime(now.year, now.month, 1, 10),
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
        ).toJson(),
      ]),
    });
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    final row = find
        .ancestor(
          of: find.text('Fd No 12345'),
          matching: find.byWidgetPredicate(
            (w) => w is InkWell && w.onLongPress != null,
          ),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Fd No 12345'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.longPress(row);
    await tester.pumpAndSettle();

    expect(find.text('Rename merchant'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Fd No 12345'),
      'HDFC FD',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(p.merchantAlias('fd no 12345'), 'HDFC FD');
    expect(find.text('HDFC FD'), findsOneWidget);
    expect(find.text('Fd No 12345'), findsNothing);
  });

  testWidgets('Top merchants explains itself when nothing is identifiable', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    // Spending this month, but only to a phone number: no merchant identity.
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 300,
      note: '9215676766',
      date: DateTime.now(),
    );
    await tester.pumpWidget(app(p));
    await tester.pumpAndSettle();

    // Scroll until the hint itself is on screen (the header alone can be
    // visible while the card below it is still off-stage).
    final list = find.byType(Scrollable).first;
    final hint = find.textContaining('No identifiable merchants in');
    await tester.scrollUntilVisible(hint, 300, scrollable: list);
    expect(hint, findsOneWidget);
    expect(find.text('Top merchants'), findsOneWidget);
  });
}
