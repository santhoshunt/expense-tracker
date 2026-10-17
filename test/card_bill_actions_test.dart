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
import 'package:expense_tracker/utils/app_theme.dart';
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

  /// The Upcoming card sits below the balance and the month block, so the
  /// surface is tall enough to keep it on screen for taps.
  Future<void> pumpApp(WidgetTester tester, FinanceProvider finance) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(finance));
  }

  /// A card due today with ₹5,000 outstanding (manual figure, stamped well
  /// in the past so a recorded payment dated "now" is strictly newer).
  /// [dueInDays] shifts the due day; [stmtDay] sets a statement day.
  Future<(FinanceProvider, String)> seeded({
    int? stmtDay,
    int dueInDays = 0,
  }) async {
    final past = DateTime.now().subtract(const Duration(days: 10));
    SharedPreferences.setMockInitialValues({
      'accounts_v1': jsonEncode([
        Account(
          id: 'card1',
          name: 'HDFC Card',
          type: AccountType.creditCard,
          keys: const {'HDFC:7031'},
          manualBalance: 5000,
          manualBalanceAt: past,
          statementDay: stmtDay,
          dueDay: DateTime.now().add(Duration(days: dueInDays)).day,
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
    await pumpApp(tester, finance);
    await pumpThrough(tester);

    expect(find.text('HDFC Card bill'), findsOneWidget);
    expect(find.textContaining('Due '), findsOneWidget);
    expect(find.text(fmtMoneyWhole(5000)), findsOneWidget);

    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    expect(find.text('Mark paid for this cycle'), findsOneWidget);
    expect(find.text('Record a payment…'), findsOneWidget);

    await tester.tap(find.text('Mark paid for this cycle'));
    await pumpThrough(tester);

    // The row survives, its next bill under the name and a Paid tag in
    // place of the amount, so Mark unpaid stays in reach.
    expect(finance.accountById(id)!.billPaidMonth, isNotNull);
    expect(find.text('HDFC Card bill'), findsOneWidget);
    expect(find.textContaining('Next bill '), findsOneWidget);
    expect(find.text('Paid'), findsOneWidget);
    expect(find.text(fmtMoneyWhole(5000)), findsNothing);

    // Reopening offers the undo.
    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    expect(find.text('Mark unpaid'), findsOneWidget);
    await tester.tap(find.text('Mark unpaid'));
    await pumpThrough(tester);
    expect(finance.accountById(id)!.billPaidMonth, isNull);
    expect(find.textContaining('Due '), findsOneWidget);
  });

  testWidgets('record a payment drops the amount and flags the cycle', (
    tester,
  ) async {
    final (finance, id) = await seeded();
    await pumpApp(tester, finance);
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
    // The cycle is paid: the row keeps its place with the Paid tag.
    expect(find.text('Paid'), findsOneWidget);
    expect(find.textContaining('Next bill '), findsOneWidget);

    // Empty / junk amounts are rejected inline, not saved.
    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    await tester.tap(find.text('Record a payment…'));
    await pumpThrough(tester);
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter the amount you paid'), findsOneWidget);
  });

  testWidgets('actions sheet opens the statement & due dates dialog', (
    tester,
  ) async {
    final (finance, _) = await seeded();
    await pumpApp(tester, finance);
    await pumpThrough(tester);

    await tester.tap(find.text('HDFC Card bill'));
    await pumpThrough(tester);
    expect(find.text('Statement & due dates…'), findsOneWidget);

    await tester.tap(find.text('Statement & due dates…'));
    await pumpThrough(tester);
    expect(find.text('Statement & due dates'), findsOneWidget);
    expect(find.text('Statement day'), findsOneWidget);
    expect(find.text('Payment due day'), findsOneWidget);
  });

  testWidgets('a card not billed yet is left off Next 7 days', (tester) async {
    // Due in 3 days, but the statement generates tomorrow: nothing is owed
    // this week.
    final now = DateTime.now();
    final (finance, _) = await seeded(
      stmtDay: now.add(const Duration(days: 1)).day,
      dueInDays: 3,
    );
    await pumpApp(tester, finance);
    await pumpThrough(tester);

    expect(find.text('HDFC Card bill'), findsNothing);
    expect(find.text('Nothing due in the next 7 days.'), findsOneWidget);
  });

  testWidgets('billed with time to spare renders orange', (tester) async {
    // Statement well in the past, due in 6 days: billed, outside the
    // 5-day urgent window and inside the 7-day list.
    final now = DateTime.now();
    final (finance, _) = await seeded(
      stmtDay: now.subtract(const Duration(days: 15)).day,
      dueInDays: 6,
    );
    await pumpApp(tester, finance);
    await pumpThrough(tester);

    final ctx = tester.element(find.byIcon(Icons.credit_card));
    final icon = tester.widget<Icon>(find.byIcon(Icons.credit_card));
    expect(icon.color, AppColors.of(ctx).orange);
  });

  testWidgets('billed row: the due line leaves the statement date out', (
    tester,
  ) async {
    // Statement 15 days back, due today: billed and urgent.
    final now = DateTime.now();
    final (finance, _) = await seeded(
      stmtDay: now.subtract(const Duration(days: 15)).day,
    );
    await pumpApp(tester, finance);
    await pumpThrough(tester);

    // Accounts and the actions sheet keep "Billed 3 Oct · due ...".
    expect(find.textContaining('Billed '), findsNothing);
    expect(
      find.text(
        'Due ${fmtDateCompact(DateTime(now.year, now.month, now.day))} · today',
      ),
      findsOneWidget,
    );
    final icon = tester.widget<Icon>(find.byIcon(Icons.credit_card));
    final scheme = Theme.of(
      tester.element(find.byIcon(Icons.credit_card)),
    ).colorScheme;
    expect(icon.color, scheme.error, reason: 'due today is inside the window');
    final amount = tester.widget<Text>(find.text(fmtMoneyWhole(5000)));
    expect(
      amount.style?.color,
      scheme.onSurface,
      reason: 'paying a card bill is a transfer: the figure stays plain',
    );
  });
}
