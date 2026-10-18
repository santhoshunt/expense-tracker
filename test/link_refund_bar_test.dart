import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';

/// "Link as refund" in the selection bar's More menu files the money in as
/// the purchase's refund. v1.43.4: any money in and money out qualify,
/// transfers too, and no category changes: the pair counts as nothing.
/// Undo puts both rows back.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> seeded({required String refundCategory}) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'bills',
      amount: 1200,
      note: 'powerbill',
      date: DateTime(2026, 9, 15),
    );
    await p.addTransaction(
      type: TxType.income,
      categoryId: refundCategory,
      amount: 1200,
      note: 'billrefund',
      date: DateTime(2026, 9, 17),
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

  final linkButton = find.byKey(const ValueKey('bulk-more-link-refund'));

  Future<void> selectBoth(WidgetTester tester) async {
    await tester.longPress(find.textContaining('powerbill'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining('billrefund'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
  }

  Tx row(FinanceProvider p, String note) =>
      p.transactions.firstWhere((t) => t.note == note);

  testWidgets('a refund filed as Transfer in links as it is, and Undo puts '
      'it back', (tester) async {
    final p = await seeded(refundCategory: kTransferInCategoryId);
    await pump(tester, p);
    await selectBoth(tester);
    expect(linkButton, findsOneWidget);

    await tester.tap(linkButton);
    await tester.pumpAndSettle();
    final refund = row(p, 'billrefund');
    expect(refund.categoryId, kTransferInCategoryId);
    expect(refund.refundOf, row(p, 'powerbill').id);
    expect(p.expenseInMonth(DateTime(2026, 9)), 0);
    expect(p.transferInInMonth(DateTime(2026, 9)), 0);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final back = row(p, 'billrefund');
    expect(back.categoryId, kTransferInCategoryId);
    expect(back.refundOf, isNull);
    expect(p.expenseInMonth(DateTime(2026, 9)), 1200);
  });

  testWidgets('money back larger than the purchase is refused with a reason', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transfer_out',
      amount: 100,
      note: 'powerbill',
      date: DateTime(2026, 9, 15),
    );
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'other_income',
      amount: 300,
      note: 'billrefund',
      date: DateTime(2026, 9, 17),
    );
    await pump(tester, p);
    await selectBoth(tester);
    await tester.tap(linkButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('More came back than went out'), findsOneWidget);
    expect(row(p, 'billrefund').refundOf, isNull);
  });

  testWidgets('two money-out rows offer no refund link', (tester) async {
    final p = FinanceProvider();
    await p.load();
    for (final note in ['powerbill', 'billrefund']) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'bills',
        amount: 100,
        note: note,
        date: DateTime(2026, 9, 15),
      );
    }
    await pump(tester, p);
    await selectBoth(tester);
    expect(linkButton, findsNothing);
  });
}
