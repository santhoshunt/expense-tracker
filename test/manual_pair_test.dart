import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';

/// The manual "Pair as transfer" action in the selection bar: shown only at
/// exactly two selected rows, delegates the rules to the provider, undoable.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> seeded() async {
    final p = FinanceProvider();
    await p.load();
    // The user's real case: a bank debit on the 15th and the card issuer's
    // credit acknowledged days later — amounts equal, dates apart.
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 5000,
      note: 'billdebit',
      date: DateTime(2026, 9, 15),
    );
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'other_income',
      amount: 5000,
      note: 'cardack',
      date: DateTime(2026, 9, 18),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 100,
      note: 'coffeerun',
      date: DateTime(2026, 9, 16),
    );
    return p;
  }

  Future<void> pump(WidgetTester tester, FinanceProvider p) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: const MaterialApp(home: Scaffold(body: TransactionsScreen())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
  }

  final pairButton = find.byTooltip('Pair as transfer');

  testWidgets('two opposite rows pair, link, and undo unlinks', (tester) async {
    final p = await seeded();
    await pump(tester, p);

    await tester.longPress(find.textContaining('billdebit'));
    await tester.pump();
    expect(pairButton, findsNothing, reason: 'one selected');

    await tester.tap(find.textContaining('cardack'));
    await tester.pump();
    expect(pairButton, findsOneWidget);

    await tester.tap(pairButton);
    // Settle fully: the snackbar slides in from below the 600px surface and
    // its Undo must be at rest before it can be hit.
    await tester.pumpAndSettle();

    expect(find.text('Paired as transfer'), findsOneWidget);
    final out = p.transactions.singleWhere((t) => t.note == 'billdebit');
    final inn = p.transactions.singleWhere((t) => t.note == 'cardack');
    expect(out.pairId, isNotNull);
    expect(out.pairId, inn.pairId);
    // No account on either leg → plain transfer categories.
    expect(out.categoryId, 'transfer_out');
    expect(inn.categoryId, 'transfer_in');
    expect(
      find.byIcon(Icons.link, skipOffstage: false),
      findsNWidgets(2),
      reason: 'both tiles carry the link marker',
    );

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(
      p.transactions.where((t) => t.pairId != null),
      isEmpty,
      reason: 'undo unpairs both legs',
    );
  });

  testWidgets('same-typed rows are refused with an explanation', (
    tester,
  ) async {
    final p = await seeded();
    await pump(tester, p);

    await tester.longPress(find.textContaining('billdebit'));
    await tester.pump();
    await tester.tap(find.textContaining('coffeerun'));
    await tester.pump();
    await tester.tap(pairButton);
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.textContaining('one money-in and one money-out'),
      findsOneWidget,
    );
    expect(p.transactions.where((t) => t.pairId != null), isEmpty);
  });

  testWidgets('three selected rows hide the pair action', (tester) async {
    final p = await seeded();
    await pump(tester, p);

    await tester.longPress(find.textContaining('billdebit'));
    await tester.pump();
    await tester.tap(find.textContaining('cardack'));
    await tester.pump();
    await tester.tap(find.textContaining('coffeerun'));
    await tester.pump();
    expect(pairButton, findsNothing);
  });
}
