import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/utils/format.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget app(FinanceProvider finance) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: finance),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: const MaterialApp(home: Scaffold(body: DashboardScreen())),
  );

  /// A card due today with ₹5,000 outstanding (manual figure, stamped well
  /// in the past so a recorded payment dated "now" is strictly newer).
  Future<(FinanceProvider, String)> seeded() async {
    final past = DateTime.now().subtract(const Duration(days: 10));
    SharedPreferences.setMockInitialValues({
      'accounts_v1': jsonEncode([
        Account(
          id: 'card1',
          name: 'HDFC Card',
          type: AccountType.creditCard,
          keys: const {'HDFC:3010'},
          manualBalance: 5000,
          manualBalanceAt: past,
          dueDay: DateTime.now().day,
        ).toJson(),
      ]),
    });
    final finance = FinanceProvider();
    await finance.load();
    return (finance, 'card1');
  }

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  testWidgets('mark paid keeps the row and amount, moves the due date', (
    tester,
  ) async {
    final (finance, id) = await seeded();
    await tester.pumpWidget(app(finance));
    await pumpThrough(tester);

    expect(find.text('HDFC Card bill'), findsOneWidget);
    expect(find.textContaining('Due '), findsOneWidget);
    expect(find.text(fmtMoney(5000)), findsOneWidget);

    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    expect(find.text('Mark paid for this cycle'), findsOneWidget);
    expect(find.text('Record a payment…'), findsOneWidget);

    await tester.tap(find.text('Mark paid for this cycle'));
    await pumpThrough(tester);

    // The row survives with the live amount; only the urgency is gone.
    expect(finance.accountById(id)!.billPaidMonth, isNotNull);
    expect(find.text('HDFC Card bill'), findsOneWidget);
    expect(find.textContaining('Paid · next bill '), findsOneWidget);
    expect(find.text(fmtMoney(5000)), findsOneWidget);

    // Reopening offers the undo.
    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    expect(find.text('Undo mark paid'), findsOneWidget);
    await tester.tap(find.text('Undo mark paid'));
    await pumpThrough(tester);
    expect(finance.accountById(id)!.billPaidMonth, isNull);
    expect(find.textContaining('Due '), findsOneWidget);
  });

  testWidgets('record a payment drops the amount and flags the cycle', (
    tester,
  ) async {
    final (finance, id) = await seeded();
    await tester.pumpWidget(app(finance));
    await pumpThrough(tester);

    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    await tester.tap(find.text('Record a payment…'));
    await pumpThrough(tester);

    expect(find.text('Record a payment'), findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '2000',
    );
    await tester.tap(find.text('Save'));
    await pumpThrough(tester);

    expect(finance.accountById(id)!.billPaidMonth, isNotNull);
    final payment = finance.transactions.single;
    expect(payment.type, TxType.income);
    expect(payment.categoryId, 'card_payment');
    expect(payment.amount, 2000);
    // Manual figure 5,000 minus the recorded payment.
    expect(finance.accountOutstanding(finance.accountById(id)!), 3000);
    expect(find.text(fmtMoney(3000)), findsOneWidget);
    expect(find.textContaining('Paid · next bill '), findsOneWidget);

    // Empty / junk amounts are rejected inline, not saved.
    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    await tester.tap(find.text('Record a payment…'));
    await pumpThrough(tester);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter the amount you paid'), findsOneWidget);
  });
}
