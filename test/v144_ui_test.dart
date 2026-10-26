import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/card_rewards.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

/// v1.44.0 rows and the edit sheet: the guessed and To sort pills, split
/// parts on the tile and in the sheet, the split editor, and the card
/// rewards tick. Invented merchants, cards and amounts only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day - 2, 13);
  String label(String id) => categoryById(id).label;

  Future<void> pump(
    WidgetTester tester,
    FinanceProvider p,
    Widget home, {
    Size size = const Size(800, 1800),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = size.width < 400 ? 1 : 2;
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
    await tester.pumpAndSettle();
  }

  Tx row(
    String id,
    double amount, {
    String category = 'food',
    String payee = 'Corner Mart',
    bool guessed = false,
    bool unseen = false,
    String? splitId,
  }) => Tx(
    id: id,
    type: TxType.expense,
    categoryId: category,
    amount: amount,
    note: '',
    payee: payee,
    date: day,
    categoryGuessed: guessed,
    unseen: unseen,
    splitId: splitId,
  );

  Tx txOf(FinanceProvider p, String id) =>
      p.transactions.firstWhere((t) => t.id == id);

  Widget opener(FinanceProvider p, String id) => Builder(
    builder: (context) => TextButton(
      onPressed: () => showAddTransactionSheet(context, existing: txOf(p, id)),
      child: const Text('open'),
    ),
  );

  Future<void> tapVisible(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  group('tile', () {
    testWidgets('a guessed row and a To sort row show their pills', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row('g', 450, guessed: true),
        row('s', 900, category: kToSortExpenseId, payee: 'Blue Kiosk'),
      ]);
      await pump(
        tester,
        p,
        ListView(
          children: [
            TransactionTile(tx: txOf(p, 'g')),
            TransactionTile(tx: txOf(p, 's')),
          ],
        ),
      );
      expect(find.text('${label('food')} · guessed'), findsOneWidget);
      expect(find.text('To sort'), findsOneWidget);
      // The pill's text keeps the line's own colour; only the border is
      // coloured.
      final context = tester.element(find.text('To sort'));
      expect(
        tester.widget<Text>(find.text('To sort')).style?.color,
        Theme.of(context).colorScheme.onSurfaceVariant,
      );
    });

    testWidgets('an unseen guessed row fits 320dp at text scale 2', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row(
          'g',
          45000,
          guessed: true,
          unseen: true,
          payee: 'Northwind Furniture Gallery',
        ),
      ]);
      await pump(
        tester,
        p,
        TransactionTile(tx: txOf(p, 'g')),
        size: const Size(320, 640),
        textScale: 2,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('split parts say which part they are', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row('a', 3000, splitId: 'split_t'),
        row('b', 2000, category: 'shopping', splitId: 'split_t'),
      ]);
      await pump(
        tester,
        p,
        ListView(
          children: [
            TransactionTile(tx: txOf(p, 'a')),
            TransactionTile(tx: txOf(p, 'b')),
          ],
        ),
      );
      expect(find.text('${label('food')} · 1 of 2'), findsOneWidget);
      expect(find.text('${label('shopping')} · 2 of 2'), findsOneWidget);
    });
  });

  group('edit sheet', () {
    testWidgets('To sort is not offered in the category picker', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([row('s', 900, category: kToSortExpenseId)]);
      await pump(tester, p, opener(p, 's'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('To sort: pick a category'), findsOneWidget);
      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();
      expect(find.text(label('food')), findsWidgets);
      expect(find.text('To sort'), findsNothing);
    });

    testWidgets('Keep confirms a guess, and the banner goes', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([row('g', 450, guessed: true)]);
      await pump(tester, p, opener(p, 'g'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Category guessed from past payments'), findsOneWidget);
      await tapVisible(tester, find.widgetWithText(TextButton, 'Keep'));
      expect(txOf(p, 'g').categoryGuessed, isFalse);
      expect(find.text('Category guessed from past payments'), findsNothing);
    });

    testWidgets('saving a guessed row clears the guess', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([row('g', 450, guessed: true)]);
      await pump(tester, p, opener(p, 'g'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, 'Save changes'),
      );
      expect(txOf(p, 'g').categoryGuessed, isFalse);
      expect(txOf(p, 'g').userCategorized, isTrue);
    });

    testWidgets('a split part locks what the payment shares', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row('a', 3000, splitId: 'split_t'),
        row('b', 2000, category: 'shopping', splitId: 'split_t'),
      ]);
      await pump(tester, p, opener(p, 'b'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Edit split · 2 of 2'), findsOneWidget);
      expect(find.text('Split by category'), findsNothing);
      final amount = tester.widget<TextField>(
        find.descendant(
          of: find.widgetWithText(TextFormField, 'Amount'),
          matching: find.byType(TextField),
        ),
      );
      expect(amount.enabled, isFalse);
      expect(find.text('Change in Edit split'), findsWidgets);
    });

    testWidgets('deleting a split part deletes the payment, with Undo', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row('a', 3000, splitId: 'split_t'),
        row('b', 2000, category: 'shopping', splitId: 'split_t'),
        row('c', 2000, category: 'shopping', splitId: 'split_t'),
      ]);
      await pump(tester, p, opener(p, 'b'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Delete transaction'));
      expect(p.transactions, isEmpty);
      expect(find.text('Deleted payment (3 parts)'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.transactions.map((t) => t.id).toSet(), {'a', 'b', 'c'});
      expect(p.transactions.every((t) => t.splitId == 'split_t'), isTrue);
    });

    testWidgets('a card with rewards shows the tick and its estimate', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      final card = await p.addAccount(
        name: 'Demo Card',
        type: AccountType.creditCard,
      );
      await p.setCardRewards(
        card,
        const CardRewards(
          groups: [
            RewardGroup(categoryIds: {'food'}, rate: 10),
          ],
          baseRate: 1,
        ),
      );
      await p.restoreTransactions([row('r', 3240)]);
      await p.assignAccount('r', card);
      await pump(tester, p, opener(p, 'r'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Earns cashback'), findsOneWidget);
      expect(find.text('≈ ${fmtMoneyWhole(324)} at 10%'), findsOneWidget);

      await tapVisible(tester, find.text('Earns cashback'));
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, 'Save changes'),
      );
      expect(txOf(p, 'r').cashbackOff, isTrue);
      // The account stays on the row.
      expect(p.accountForKey(txOf(p, 'r').acctKey)?.id, card);
    });

    testWidgets('no tick on a card without rewards', (tester) async {
      final p = FinanceProvider();
      await p.load();
      final card = await p.addAccount(
        name: 'Plain Card',
        type: AccountType.creditCard,
      );
      await p.restoreTransactions([row('r', 3240)]);
      await p.assignAccount('r', card);
      await pump(tester, p, opener(p, 'r'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Earns cashback'), findsNothing);
    });

    testWidgets('a new entry with the tick off keeps its card', (tester) async {
      final p = FinanceProvider();
      await p.load();
      final card = await p.addAccount(
        name: 'Demo Card',
        type: AccountType.creditCard,
      );
      await p.setCardRewards(card, const CardRewards(baseRate: 1));
      await pump(
        tester,
        p,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddTransactionSheet(context),
            child: const Text('add'),
          ),
        ),
      );
      await tester.tap(find.text('add'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'),
        '1200',
      );
      await tapVisible(tester, find.text('Account (optional)'));
      await tester.tap(find.text('Demo Card').last);
      await tester.pumpAndSettle();
      expect(find.text('≈ ${fmtMoneyWhole(12)} at 1%'), findsOneWidget);
      await tapVisible(tester, find.text('Earns cashback'));
      await tapVisible(tester, find.widgetWithText(FilledButton, 'Add'));

      final added = p.transactions.single;
      expect(added.amount, 1200);
      expect(added.cashbackOff, isTrue);
      expect(p.accountForKey(added.acctKey)?.id, card);
    });

    testWidgets('saving a split part keeps it in its payment', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row('a', 3000, splitId: 'split_t'),
        row('b', 2000, category: 'shopping', splitId: 'split_t'),
      ]);
      await pump(tester, p, opener(p, 'b'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Category'));
      await tester.tap(find.text(label('food')).last);
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.widgetWithText(FilledButton, 'Save changes'),
      );

      final b = txOf(p, 'b');
      expect(b.categoryId, 'food');
      expect(b.splitId, 'split_t');
      expect(b.amount, 2000);
      expect(b.date, day);
      expect(txOf(p, 'a').amount, 3000);
      expect(p.splitPartsOf(b).map((t) => t.id), ['a', 'b']);
    });
  });

  group('split sheet', () {
    // The split sheet opens over the edit sheet, which has its own
    // Category and Amount fields.
    Finder inSplitSheet(Finder f) =>
        find.descendant(of: find.byType(BottomSheet).last, matching: f);

    Future<void> pickCategory(
      WidgetTester tester,
      int index,
      String category,
    ) async {
      await tapVisible(tester, inSplitSheet(find.text('Category')).at(index));
      await tester.tap(find.text(label(category)).last);
      await tester.pumpAndSettle();
    }

    testWidgets('splits a payment once the parts balance, with Undo', (
      tester,
    ) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([row('pay', 5000)]);
      await pump(tester, p, opener(p, 'pay'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Split by category'));

      // The row's category holds the whole payment, and an empty row waits.
      expect(find.text('Left to assign ${fmtMoney(0)}'), findsOneWidget);
      final amounts = inSplitSheet(find.widgetWithText(TextField, 'Amount'));
      expect(amounts, findsNWidgets(2));
      await tester.enterText(amounts.first, '3000');
      await tester.pumpAndSettle();
      expect(find.text('Left to assign ${fmtMoney(2000)}'), findsOneWidget);

      // Unbalanced: Save says why.
      await tapVisible(tester, find.text('Split payment'));
      expect(find.text('Add at least two parts'), findsOneWidget);

      await pickCategory(tester, 1, 'shopping');
      await tester.enterText(amounts.at(1), '2000');
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Split payment'));

      final parts = p.splitPartsOf(txOf(p, 'pay'));
      expect(parts.map((t) => t.categoryId), ['food', 'shopping']);
      expect(parts.map((t) => t.amount), [3000, 2000]);
      // Both sheets closed; the Undo is offered on the page.
      expect(find.text('Edit transaction'), findsNothing);
      expect(find.text('Split into 2 parts'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.transactions.single.id, 'pay');
      expect(p.transactions.single.amount, 5000);
      expect(p.transactions.single.splitId, isNull);
    });

    testWidgets('a part with a group split keeps Edit split, which says '
        'why it cannot open', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row('a', 3000, splitId: 'split_t'),
        row(
          'b',
          2000,
          category: 'shopping',
          splitId: 'split_t',
        ).copyWith(myShare: 1000),
      ]);
      expect(p.canSplit(txOf(p, 'a')), isFalse);
      await pump(tester, p, opener(p, 'a'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Edit split · 1 of 2'));
      expect(
        find.text('Remove the group split on its parts first'),
        findsOneWidget,
      );
      expect(find.text('Merge back'), findsNothing);
    });

    testWidgets('Merge back puts the payment together again', (tester) async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        row('a', 3000, splitId: 'split_t'),
        row('b', 2000, category: 'shopping', splitId: 'split_t'),
      ]);
      await pump(tester, p, opener(p, 'b'));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Edit split · 2 of 2'));
      expect(find.text('Left to assign ${fmtMoney(0)}'), findsOneWidget);
      await tapVisible(tester, find.text('Merge back'));

      expect(p.transactions.single.id, 'a');
      expect(p.transactions.single.amount, 5000);
      expect(find.text('Merged back into one payment'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.transactions.map((t) => t.id).toSet(), {'a', 'b'});
    });
  });
}
