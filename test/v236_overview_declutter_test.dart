import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/safe_to_spend.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/glossy.dart';
import 'package:expense_tracker/widgets/status_dot.dart';

/// v2.3.6: the Overview without the daily safe to spend row, and a leaner
/// Monthly budget card (a legend only when the bar has more than one part,
/// the verdict as a plain line). Amounts, names and merchants are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final now = DateTime.now();

  Future<void> pump(
    WidgetTester tester,
    FinanceProvider p,
    SettingsProvider s, {
    Size size = const Size(400, 2400),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const Scaffold(body: DashboardScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// One confirmed row of 12,345 on the 1st of the running month; with
  /// [waiting] a 1,750 import still waiting for review, and with [bill] a
  /// 2,400 reminder due on the month's last day.
  Future<FinanceProvider> ledger({
    bool waiting = false,
    bool bill = false,
  }) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 12345,
      note: 'groceries',
      date: DateTime(now.year, now.month, 1),
    );
    if (waiting) {
      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 1750,
          merchant: 'qqvx',
          // Midnight on the 1st: never in the future.
          date: DateTime(now.year, now.month, 1),
          ref: null,
          categoryId: 'other_expense',
          sender: 'VM-HDFCBK',
        ),
      ]);
      expect(p.pendingTransactions, hasLength(1));
    }
    if (bill) {
      final last = DateTime(now.year, now.month - 1);
      await p.restoreReminder(
        Reminder(
          id: 'fibre',
          name: 'Fibre line',
          dayOfMonth: DateTime(now.year, now.month + 1, 0).day,
          categoryId: 'other_expense',
          expectedAmount: 2400,
          // Last month's paid, so only this month's is due.
          lastPaidMonth:
              '${last.year}-${last.month.toString().padLeft(2, '0')}',
        ),
      );
    }
    return p;
  }

  Future<SettingsProvider> settings({double cap = 50000}) async {
    final s = SettingsProvider();
    await s.load();
    await s.setMonthlyBudget(cap);
    return s;
  }

  testWidgets('the Overview has no safe to spend row with a cap set', (
    tester,
  ) async {
    await pump(tester, await ledger(), await settings());
    expect(find.text('Monthly budget'), findsOneWidget);
    expect(find.byKey(const ValueKey('presence-safe-today')), findsNothing);
    expect(
      find.textContaining(RegExp('safe to spend', caseSensitive: false)),
      findsNothing,
    );
  });

  testWidgets('spend alone: no legend, the verdict under the bar', (
    tester,
  ) async {
    await pump(tester, await ledger(), await settings());
    expect(find.text('Spent, confirmed'), findsNothing);
    expect(find.textContaining('Waiting for review'), findsNothing);
    expect(find.textContaining('Due this month'), findsNothing);
    expect(find.text('${fmtMoneyWhole(50000 - 12345)} left'), findsOneWidget);
  });

  testWidgets('a row waiting for review shows both legend rows', (
    tester,
  ) async {
    await pump(tester, await ledger(waiting: true), await settings());
    expect(find.text('Spent, confirmed'), findsOneWidget);
    expect(find.text('Waiting for review (1)'), findsOneWidget);
    expect(find.textContaining('Due this month'), findsNothing);
    expect(
      find.text('${fmtMoneyWhole(50000 - 12345 - 1750)} left'),
      findsOneWidget,
    );
  });

  testWidgets('a bill due shows Spent, confirmed and Due this month', (
    tester,
  ) async {
    await pump(tester, await ledger(bill: true), await settings());
    expect(find.text('Spent, confirmed'), findsOneWidget);
    expect(find.text('Due this month (1)'), findsOneWidget);
    expect(find.textContaining('Waiting for review'), findsNothing);
    final left = fmtMoneyWhole(50000 - 12345 - 2400);
    expect(find.text('$left left after these bills'), findsOneWidget);
  });

  testWidgets('the verdict is plain text: no outline and no dot', (
    tester,
  ) async {
    await pump(tester, await ledger(), await settings(cap: 10000));
    final verdict = find.text('${fmtMoneyWhole(12345 - 10000)} over the cap');
    expect(verdict, findsOneWidget);
    final card = find
        .ancestor(of: verdict, matching: find.byType(FrostedPanel))
        .first;
    expect(
      find.descendant(of: card, matching: find.byType(StatusDot)),
      findsNothing,
    );
    // The panel may draw its own outline; nothing between the card's
    // column and the verdict may.
    final column = find.ancestor(of: verdict, matching: find.byType(Column));
    final bordered = find.descendant(
      of: column.first,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    );
    expect(find.ancestor(of: verdict, matching: bordered), findsNothing);
    // Same weight and the error colour over the cap.
    final style = tester.widget<Text>(verdict).style!;
    expect(style.fontWeight, FontWeight.w700);
    final context = tester.element(verdict);
    expect(style.color, Theme.of(context).colorScheme.error);
  });

  testWidgets('no overflow at 1.3 times text on a 360 wide screen', (
    tester,
  ) async {
    await pump(
      tester,
      await ledger(waiting: true, bill: true),
      await settings(),
      size: const Size(360, 2400),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Spent, confirmed'), findsOneWidget);
    expect(find.text('Waiting for review (1)'), findsOneWidget);
    expect(find.text('Due this month (1)'), findsOneWidget);
  });

  test('the widget snapshot has no safe block', () async {
    final p = await ledger(bill: true);
    final s = await settings();
    final data =
        jsonDecode(jsonEncode(buildHomeWidgetSnapshot(p, s, now, const [])))
            as Map<String, dynamic>;
    expect(data.containsKey('safe'), isFalse);
    // The Today and Add widget's own block is still there.
    expect(data['today'], isA<Map<String, dynamic>>());
  });

  test('remainingAfterToday and billsDue keep their figures', () async {
    // 19 September 2026, 14:00.
    final at = DateTime(2026, 9, 19, 14);
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 9000,
      note: '',
      date: DateTime(2026, 9, 5, 10),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 600,
      note: '',
      date: DateTime(2026, 9, 19, 9),
    );
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 1100,
        merchant: 'zvbn',
        date: DateTime(2026, 9, 19, 11),
        ref: null,
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
      ),
    ]);
    await p.restoreReminder(
      const Reminder(
        id: 'gym',
        name: 'Gym',
        dayOfMonth: 27,
        categoryId: 'other_expense',
        expectedAmount: 2500,
      ),
    );
    final s = computeSafeToSpend(
      p,
      cap: 30000,
      patterns: const [],
      hidden: const {},
      now: at,
    )!;
    expect(s.billsDue, 2500);
    expect(s.billsCount, 1);
    expect(s.pendingSpent, 1100);
    // 30,000 less 9,000, 600 and 1,100 spent, less the 2,500 bill.
    expect(s.remainingAfterToday, 16800);
    expect(s.committed, 13200);
    expect(s.over, isFalse);
    expect(s.overCap, isFalse);
  });
}
