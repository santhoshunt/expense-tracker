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
import 'package:expense_tracker/screens/transactions_screen.dart';

/// Wallet screens: the add dialog, the Accounts Wallets section and the
/// edit sheet's "Count as spending" switch.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<void> pump(
    WidgetTester tester,
    FinanceProvider p,
    Widget home, {
    Size size = const Size(400, 900),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: home),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
  }

  for (final (width, scale) in [(320.0, 1.3), (480.0, 1.3), (320.0, 2.0)]) {
    testWidgets('the add dialog swaps in wallet fields at ${width}dp, '
        'text x$scale', (tester) async {
      final p = await loaded();
      await pump(
        tester,
        p,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddAccountDialog(context),
            child: const Text('open'),
          ),
        ),
        size: Size(width, 800),
        textScale: scale,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Service'), findsNothing);

      await tester.tap(find.text('Wallet'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.widgetWithText(TextField, 'Service'), findsOneWidget);
      expect(find.text('Link a number (optional)'), findsNothing);
      expect(find.widgetWithText(TextField, 'Value per point'), findsNothing);

      await tester.tap(find.text('Points'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Value per point'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.enterText(
        find.widgetWithText(TextField, 'Service'),
        'Swiggy',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Login label (e.g. me, mom)'),
        'me',
      );
      // Points need a value per point before Create enables.
      final create = find.widgetWithText(FilledButton, 'Create');
      await tester.pump();
      expect(tester.widget<FilledButton>(create).onPressed, isNull);
      await tester.enterText(
        find.widgetWithText(TextField, 'Value per point'),
        '0.25',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Points now (optional)'),
        '500',
      );
      await tester.pump();
      expect(find.text('= ₹125.00'), findsOneWidget);
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.tap(create);
      await tester.pumpAndSettle();

      final a = p.accounts.single;
      expect(a.isWallet, isTrue);
      expect(a.displayName, 'Swiggy · me');
      expect(a.pointValue, 0.25);
      expect(p.accountBalance(a), 125);
    });
  }

  testWidgets('the Wallets section groups by service with its total', (
    tester,
  ) async {
    final p = await loaded();
    for (final (service, name, balance) in [
      ('Amazon Pay', 'me', 840.0),
      ('Amazon Pay', 'mom', 500.0),
      ('Zomato', 'me', 120.0),
    ]) {
      final id = await p.addAccount(
        name: name,
        type: AccountType.wallet,
        service: service,
      );
      await p.setManualBalance(id, balance);
    }
    final points = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Swiggy',
      holdsPoints: true,
      pointValue: 0.25,
    );
    await p.setManualBalance(points, 125);
    // Tall enough that every card is built without scrolling.
    await pump(
      tester,
      p,
      AccountsScreen(onViewAccount: (_) {}),
      size: const Size(400, 2400),
    );

    expect(find.text('WALLETS'), findsOneWidget);
    expect(find.text('Amazon Pay'), findsOneWidget);
    expect(find.text('₹1,340.00'), findsOneWidget);
    expect(find.text('Zomato'), findsOneWidget);
    expect(find.text('Swiggy'), findsOneWidget);
    expect(find.text('500 points · ₹0.25 each'), findsOneWidget);
    // Alphabetical by service, each wallet under its own service.
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('Amazon Pay'), lessThan(top('mom')));
    expect(top('mom'), lessThan(top('Swiggy')));
    expect(top('Swiggy'), lessThan(top('Zomato')));
    // Net balance leaves every wallet out.
    expect(p.netWorth, 0);
  });

  testWidgets('an uncounted wallet row says so in the list', (tester) async {
    final p = await loaded();
    final wallet = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Amazon Pay',
    );
    final id = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'groceries',
      date: DateTime(2026, 9, 12, 10),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 80,
      note: 'tea',
      date: DateTime(2026, 9, 13, 10),
    );
    await p.assignAccount(id, wallet);
    await pump(tester, p, const TransactionsScreen());
    expect(find.text('Not counted'), findsOneWidget);
    // The month header counts the tea only: never ₹330 with the wallet row.
    expect(find.textContaining('330'), findsNothing);
  });

  testWidgets('the edit sheet offers Count as spending on a wallet only', (
    tester,
  ) async {
    final p = await loaded();
    final wallet = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Amazon Pay',
    );
    final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
    final id = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'groceries',
      date: DateTime(2026, 9, 12, 10),
    );
    final other = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 60,
      note: 'tea',
      date: DateTime(2026, 9, 13, 10),
    );
    await p.assignAccount(id, wallet);
    await p.assignAccount(other, bank);
    var editing = id;
    await pump(
      tester,
      p,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showAddTransactionSheet(
            context,
            existing: p.transactions.firstWhere((t) => t.id == editing),
          ),
          child: const Text('open'),
        ),
      ),
      size: const Size(400, 1000),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The sheet has other switches (Subscription): this one's tile.
    final toggle = find.descendant(
      of: find.widgetWithText(ListTile, 'Count as spending'),
      matching: find.byType(Switch),
    );
    expect(find.text('Count as spending'), findsOneWidget);
    expect(tester.widget<Switch>(toggle).value, isFalse);
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(p.transactions.firstWhere((t) => t.id == id).walletCounted, isTrue);
    expect(p.expenseInMonth(DateTime(2026, 9)), 310);

    // A bank row has no such switch.
    editing = other;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget, reason: 'sheet open');
    expect(find.text('Count as spending'), findsNothing);
  });

  testWidgets('a wallet credit counts as income, a wallet transfer never', (
    tester,
  ) async {
    final p = await loaded();
    final wallet = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Amazon Pay',
    );
    final cashback = await p.addTransaction(
      type: TxType.income,
      categoryId: 'other_income',
      amount: 50,
      note: 'cashback',
      date: DateTime(2026, 9, 12, 10),
    );
    final moved = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transfer_out',
      amount: 100,
      note: 'moved',
      date: DateTime(2026, 9, 13, 10),
    );
    await p.assignAccount(cashback, wallet);
    await p.assignAccount(moved, wallet);
    var editing = cashback;
    await pump(
      tester,
      p,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showAddTransactionSheet(
            context,
            existing: p.transactions.firstWhere((t) => t.id == editing),
          ),
          child: const Text('open'),
        ),
      ),
      size: const Size(400, 1000),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Count as income'), findsOneWidget);
    expect(find.text('Count as spending'), findsNothing);
    Navigator.of(tester.element(find.text('Save changes'))).pop();
    await tester.pumpAndSettle();

    editing = moved;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget, reason: 'sheet open');
    expect(find.textContaining('Count as'), findsNothing);
  });

  testWidgets('a split bill keeps its people on a points wallet', (
    tester,
  ) async {
    final p = await loaded();
    final wallet = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Swiggy',
      holdsPoints: true,
      pointValue: 0.25,
    );
    final id = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 1000,
      note: 'dinner',
      date: DateTime(2026, 9, 12, 10),
      myShare: 700,
      people: const [SplitShare(name: 'Priya', amount: 300)],
    );
    await p.assignAccount(id, wallet);
    await pump(
      tester,
      p,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showAddTransactionSheet(
            context,
            existing: p.transactions.firstWhere((t) => t.id == id),
          ),
          child: const Text('open'),
        ),
      ),
      size: const Size(400, 1200),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // A split is entered in ₹, not points.
    expect(find.widgetWithText(TextFormField, 'Amount'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Note (optional)'),
      'team dinner',
    );
    final save = find.widgetWithText(FilledButton, 'Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    final row = p.transactions.single;
    expect(row.note, 'team dinner');
    expect(row.amount, 1000);
    expect(row.people.single.name, 'Priya');
    expect(row.myShare, 700);
  });
}
