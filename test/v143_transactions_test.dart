import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';

/// v1.43.0 on the Transactions side: the review sheet's ways in, a row
/// edited from it, Paid to with its recent payees, the Added toast, the
/// Accounts dues and wallet headers, Clear all and the Set category
/// search. Invented names, senders and amounts only.
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

  Tx pendingRow(String id, double amount, {String note = 'Demo Kiosk'}) => Tx(
    id: id,
    type: TxType.expense,
    categoryId: 'food',
    amount: amount,
    note: note,
    smsBody: 'Rs $amount debited from a/c XX9999. -Sample Bank',
    source: TxSource.sms,
    sender: 'VM-SAMPLE',
    date: DateTime(2026, 10, 12, 11),
    pending: true,
  );

  Future<FinanceProvider> withPending(List<Tx> rows) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions(rows);
    return p;
  }

  Widget home(FinanceProvider p) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
      Provider<DriveBackupService>(create: (_) => DriveBackupService()),
    ],
    child: const MaterialApp(home: HomeScreen()),
  );

  Widget page(FinanceProvider p, Widget body) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: MaterialApp(home: Scaffold(body: body)),
  );

  group('review sheet entry points', () {
    testWidgets('the review launch action opens the sheet over Transactions', (
      tester,
    ) async {
      final p = await withPending([pendingRow('r1', 120)]);
      await tester.pumpWidget(home(p));
      await settle(tester);
      expect(find.text('Imported from SMS'), findsNothing);

      LaunchActions.instance.pending.value = LaunchAction.openReview;
      await settle(tester);
      await settle(tester);
      expect(find.text('Imported from SMS'), findsOneWidget);
      expect(find.text('1 to review'), findsOneWidget);
      expect(LaunchActions.instance.pending.value, isNull);
      // Under the sheet, Home is on Transactions.
      expect(find.text('Transactions', skipOffstage: false), findsWidgets);
      expect(find.byType(TransactionsScreen), findsOneWidget);
    });

    testWidgets('AppNav.openReview closes pushed routes and opens the sheet', (
      tester,
    ) async {
      final p = await withPending([pendingRow('r1', 120)]);
      await tester.pumpWidget(home(p));
      await settle(tester);
      final context = tester.element(find.byType(HomeScreen));
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('pushed'))),
      );
      await settle(tester);
      expect(find.text('pushed'), findsOneWidget);

      AppNav.instance.openReview(tester.element(find.text('pushed')));
      await settle(tester);
      expect(find.text('pushed'), findsNothing);
      expect(find.text('Imported from SMS'), findsOneWidget);
    });

    testWidgets('saving the last row from its edit sheet confirms it, closes '
        'both sheets and leaves Undo on Home', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await withPending([pendingRow('r1', 120)]);
      await tester.pumpWidget(home(p));
      await settle(tester);
      await tester.tap(find.text('Transactions').last);
      await settle(tester);
      await tester.tap(find.byTooltip('Review imports'));
      await settle(tester);

      await tester.tap(find.text('Demo Kiosk'));
      await settle(tester);
      final save = find.widgetWithText(FilledButton, 'Save and confirm');
      expect(save, findsOneWidget);
      // An SMS row keeps its Sender field and has no Paid to.
      expect(
        find.widgetWithText(TextFormField, 'Sender (optional)'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextFormField, 'Paid to'), findsNothing);
      await tester.tap(save);
      await settle(tester);
      await settle(tester);

      expect(p.pendingTransactions, isEmpty);
      expect(find.text('Edit transaction'), findsNothing);
      expect(find.text('Imported from SMS'), findsNothing);
      expect(find.text('Saved and confirmed'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(p.pendingTransactions, hasLength(1));
      // Undo does not reopen the sheet; the badge is back.
      expect(find.text('Imported from SMS'), findsNothing);
      expect(
        find.descendant(
          of: find.byTooltip('Review imports'),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Confirm all asks, confirms, and offers Undo', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await withPending([
        pendingRow('r1', 120),
        pendingRow('r2', 80, note: 'Sample Cafe'),
      ]);
      await tester.pumpWidget(home(p));
      await settle(tester);
      await tester.tap(find.text('Transactions').last);
      await settle(tester);
      await tester.tap(find.byTooltip('Review imports'));
      await settle(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Confirm all'));
      await settle(tester);
      expect(find.text('Confirm all 2 transactions?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm all').last);
      await settle(tester);
      await settle(tester);
      expect(p.pendingTransactions, isEmpty);
      expect(find.text('Imported from SMS'), findsNothing);
      expect(find.text('Confirmed 2 imports'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(p.pendingTransactions, hasLength(2));
    });
  });

  group('add sheet', () {
    Widget opener(FinanceProvider p, {bool income = false}) => page(
      p,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => showAddTransactionSheet(context, income: income),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('Paid to offers recent payees; a tap fills it; Transfer '
        'hides it; Income asks Received from', (tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 60,
        payee: 'Sample Mess',
        note: '',
        date: DateTime(2026, 10, 1),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 30,
        payee: 'Demo Bakery',
        note: '',
        date: DateTime(2026, 10, 2),
      );
      await tester.pumpWidget(opener(p));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final payee = find.widgetWithText(TextFormField, 'Paid to');
      expect(payee, findsOneWidget);
      Finder chip(String name) => find.widgetWithText(ActionChip, name);
      expect(chip('Sample Mess'), findsOneWidget);
      expect(chip('Demo Bakery'), findsOneWidget);
      // Typing narrows the chips.
      await tester.enterText(payee, 'mess');
      await tester.pumpAndSettle();
      expect(chip('Demo Bakery'), findsNothing);
      await tester.tap(chip('Sample Mess'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(payee).controller!.text,
        'Sample Mess',
      );
      // An exact match leaves its own chip out.
      expect(chip('Sample Mess'), findsNothing);

      await tester.tap(find.text('Transfer'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'Paid to'), findsNothing);
      await tester.tap(find.text('Income'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(TextFormField, 'Received from'),
        findsOneWidget,
      );
      // No income payees yet: no chips.
      expect(chip('Sample Mess'), findsNothing);
    });

    testWidgets('an add says Added with Undo, which deletes the row', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = FinanceProvider();
      await p.load();
      await tester.pumpWidget(opener(p));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'),
        '250',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
      expect(p.transactions, hasLength(1));
      final label = p.transactions.single.category.label;
      expect(find.text('Added $label · ${fmtMoney(250)}'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.transactions, isEmpty);
    });
  });

  group('accounts', () {
    testWidgets('a lone wallet header shows no total; two wallets do', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = FinanceProvider();
      await p.load();
      final a = await p.addAccount(
        name: 'Demo Pay main',
        type: AccountType.wallet,
        service: 'Demo Pay',
      );
      await p.setManualBalance(a, 300);
      final b = await p.addAccount(
        name: 'Sample Wallet login',
        type: AccountType.wallet,
        service: 'Sample Wallet',
      );
      await p.setManualBalance(b, 450);
      await tester.pumpWidget(page(p, AccountsScreen(onViewAccount: (_) {})));
      await tester.pumpAndSettle();
      Finder headerTotal(String service) => find.descendant(
        of: find
            .ancestor(of: find.text(service), matching: find.byType(Row))
            .first,
        matching: find.byWidgetPredicate(
          (w) => w is Text && (w.data ?? '').startsWith('₹'),
        ),
      );
      expect(headerTotal('Demo Pay'), findsNothing);
      expect(headerTotal('Sample Wallet'), findsNothing);

      final c = await p.addAccount(
        name: 'Demo Pay spare',
        type: AccountType.wallet,
        service: 'Demo Pay',
      );
      await p.setManualBalance(c, 200);
      await tester.pumpAndSettle();
      expect(find.text(fmtMoney(500)), findsOneWidget);
    });

    testWidgets('an overpaid card reads Nothing due', (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = FinanceProvider();
      await p.load();
      final card = await p.addAccount(
        name: 'Demo Card',
        type: AccountType.creditCard,
        creditLimit: 50000,
      );
      await p.setManualBalance(card, 0);
      await tester.pumpWidget(page(p, AccountsScreen(onViewAccount: (_) {})));
      await tester.pumpAndSettle();
      expect(find.text('Nothing due'), findsOneWidget);
      expect(find.text(' due'), findsNothing);
    });
  });

  group('transactions controls', () {
    Future<FinanceProvider> ledger() async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'Demo Kiosk',
        date: DateTime(2026, 7, 3, 9),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 80,
        note: 'Sample Cab',
        date: DateTime(2026, 7, 4, 9),
      );
      return p;
    }

    testWidgets('Clear all shows with two filters and clears filters only', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await ledger();
      await tester.pumpWidget(page(p, const TransactionsScreen()));
      await tester.pumpAndSettle();
      // One filter: no Clear all, the chip's own close does it.
      await tester.pumpWidget(
        page(
          p,
          TransactionsScreen(
            request: TxFilterRequest(month: DateTime(2026, 7)),
            filterToken: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Clear all'), findsNothing);
      await tester.pumpWidget(
        page(
          p,
          TransactionsScreen(
            request: TxFilterRequest(
              month: DateTime(2026, 7),
              categoryId: 'food',
              query: 'demo',
            ),
            filterToken: 2,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Filters · 2'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      expect(find.text('Clear all'), findsNothing);
      expect(find.text('Filters'), findsOneWidget);
      // The search stays: only the matching row shows.
      expect(find.text('Demo Kiosk'), findsOneWidget);
      expect(find.text('Sample Cab'), findsNothing);
    });

    testWidgets('Set category searches its chips', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await ledger();
      await tester.pumpWidget(page(p, const TransactionsScreen()));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Demo Kiosk'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Set category'));
      await tester.pumpAndSettle();
      expect(find.text('Set category'), findsWidgets);
      final search = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, 'trans');
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.byType(ActionChip),
        ),
        findsWidgets,
      );
      expect(find.widgetWithText(ActionChip, 'Food & Dining'), findsNothing);
      await tester.enterText(search, 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('No matches.'), findsOneWidget);
    });
  });
}
