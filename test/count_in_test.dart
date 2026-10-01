import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/spend_comparison.dart';

/// Count in ([Tx.countIn]): a row keeps its real date for balances while
/// every period figure counts it in another moment. The typical case is a
/// salary paid on the 30th that belongs to next month.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final sep30 = DateTime(2026, 9, 30, 18, 12);
  final oct1 = DateTime(2026, 10, 1);

  Tx row({DateTime? date, DateTime? countIn}) => Tx(
    id: 't1',
    type: TxType.income,
    categoryId: 'salary',
    amount: 85000,
    note: 'salary',
    date: date ?? sep30,
    countIn: countIn,
  );

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  group('model', () {
    test('toJson leaves the key out until set, and round-trips it', () {
      expect(row().toJson().containsKey('countIn'), isFalse);
      final moved = row(countIn: oct1);
      final back = Tx.fromJson(jsonDecode(jsonEncode(moved.toJson())));
      expect(back.countIn, oct1);
      expect(back.effectiveDate, oct1);
      expect(back.date, sep30);
    });

    test('fromJson tolerates junk and drops a value equal to the date', () {
      for (final bad in [42, 'junk', sep30.toIso8601String()]) {
        final json = row().toJson()..['countIn'] = bad;
        expect(Tx.fromJson(json).countIn, isNull, reason: '$bad');
      }
    });

    test('copyWith clears, and re-dating onto the moment drops it', () {
      final moved = row(countIn: oct1);
      expect(moved.copyWith(clearCountIn: true).countIn, isNull);
      expect(moved.copyWith(note: 'x').countIn, oct1);
      final redated = moved.copyWith(date: oct1);
      expect(redated.countIn, isNull);
      expect(redated.effectiveDate, oct1);
    });

    test('the SMS-body migration keeps it', () {
      final legacy = Tx(
        id: 's1',
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'Rs 85000 credited',
        date: sep30,
        source: TxSource.sms,
        countIn: oct1,
      );
      final migrated = legacy.migrateSmsBodyFromNote();
      expect(migrated.smsBody, 'Rs 85000 credited');
      expect(migrated.countIn, oct1);
    });
  });

  group('period figures', () {
    test('a Sep 30 salary counted Oct 1 is October income only', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'salary',
        date: sep30,
        countIn: oct1,
      );
      expect(p.incomeInMonth(DateTime(2026, 9)), 0);
      expect(p.incomeInMonth(DateTime(2026, 10)), 85000);
      expect(p.monthsWithData, contains(DateTime(2026, 10)));
      expect(p.monthsWithData, isNot(contains(DateTime(2026, 9))));
      expect(p.incomeInYear(2026), 85000);
    });

    test('day-level figures use the count-in day', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 400,
        note: 'rent-ish',
        date: sep30,
        countIn: oct1,
      );
      // Day 30 would have fallen outside "October through the 5th".
      expect(p.expenseInMonthThrough(DateTime(2026, 10), 5), 400);
      expect(p.expenseByDayInMonth(DateTime(2026, 10))[1], 400);
      expect(p.expenseByDayInMonth(DateTime(2026, 9)), isEmpty);
      expect(p.spendOnDay(oct1).spent, 400);
      expect(p.spendOnDay(sep30).spent, 0);
      expect(p.expensesOnDay(oct1).single.note, 'rent-ish');
      expect(p.expensesOnDay(sep30), isEmpty);
    });

    test('records start on the earliest real date, and months counted in '
        'before it never join the usual window', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 10,
        note: 'a',
        date: DateTime(2026, 8, 10),
        countIn: DateTime(2026, 7, 31),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 10,
        note: 'b',
        date: DateTime(2026, 8, 5),
      );
      expect(p.firstTransactionDate, DateTime(2026, 8, 5));
      expect(p.monthsWithData, contains(DateTime(2026, 7)));
      // August starts part-way and July is before the records: neither is a
      // month on record.
      expect(usualWindow(p, DateTime(2026, 9)), isEmpty);
      final c = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 20),
      );
      expect(c.vsPrevious.state, CompareState.notEnoughHistory);
    });

    test('a month not started yet is compared with nothing', () async {
      final p = await loaded();
      for (var m = 6; m <= 9; m++) {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 1000,
          note: 'm$m',
          date: DateTime(2026, m, 1, 10),
        );
      }
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'salary',
        date: sep30,
        countIn: oct1,
      );
      // Viewed on 30 Sep: October exists only through the salary.
      final c = buildMonthComparison(
        p,
        DateTime(2026, 10),
        now: DateTime(2026, 9, 30, 20),
      );
      expect(c.vsPrevious.state, CompareState.notEnoughHistory);
      expect(c.vsUsual.state, CompareState.notEnoughHistory);
      expect(c.usualMonths, 0);
      // September itself still compares normally.
      final sep = buildMonthComparison(
        p,
        DateTime(2026, 9),
        now: DateTime(2026, 9, 30, 20),
      );
      expect(sep.vsPrevious.state, isNot(CompareState.notEnoughHistory));
    });
  });

  group('balances stay on the real date', () {
    ParsedTxn bankTxn(DateTime date) => ParsedTxn(
      type: TxType.expense,
      amount: 100,
      merchant: 'X',
      date: date,
      ref: 'R1',
      categoryId: 'other_expense',
      sender: 'VM-HDFCBK',
      rawBody: 'Rs.100 debited from a/c XX1234. Avl Bal Rs.5000.',
      acctKey: 'HDFC:1234',
      balanceAfter: 5000,
    );

    test('the balance holds while the spent-this-month figure moves', () async {
      final p = await loaded();
      final now = DateTime.now();
      final start = DateTime(now.year, now.month);
      await p.addImported([bankTxn(start.add(const Duration(seconds: 1)))]);
      await p.confirmAllPending();
      final acc = p.accounts.single;
      expect(p.accountBalance(acc), 5000);
      expect(p.accountSpentThisMonth(acc), 100);

      final id = p.transactions.single.id;
      await p.setCountInForMany({id}, DateTime(now.year, now.month + 1));
      final after = p.accountById(acc.id)!;
      expect(p.accountBalance(after), 5000);
      expect(p.accountSpentThisMonth(after), 0);
      expect(p.transactions.single.balanceAfter, 5000);
    });

    test('an edit that only sets Count in keeps the stated balance', () async {
      final p = await loaded();
      await p.addImported([bankTxn(DateTime(2026, 9, 30, 10))]);
      final t = p.pendingTransactions.single;
      await p.updateTransaction(t.copyWith(countIn: oct1));
      final moved = p.pendingTransactions.single;
      expect(moved.countIn, oct1);
      expect(moved.balanceAfter, 5000);
    });
  });

  group('setCountInForMany', () {
    test('counts changes, clears on null, and Undo restores', () async {
      final p = await loaded();
      final a = await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'a',
        date: sep30,
      );
      final b = await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 50,
        note: 'b',
        date: oct1,
      );
      final snapshot = [...p.transactions];
      // b already sits on Oct 1: counting it there is no change.
      expect(await p.setCountInForMany({a, b}, oct1), 1);
      expect(p.transactions.firstWhere((t) => t.id == b).countIn, isNull);
      expect(p.incomeInMonth(DateTime(2026, 10)), 85000);
      expect(await p.setCountInForMany({a, b}, oct1), 0);

      await p.restoreEditedTransactions(snapshot);
      expect(p.transactions.firstWhere((t) => t.id == a).countIn, isNull);
      expect(p.incomeInMonth(DateTime(2026, 9)), 85000);

      await p.setCountInForMany({a}, oct1);
      expect(await p.setCountInForMany({a}, null), 1);
      expect(p.transactions.firstWhere((t) => t.id == a).countIn, isNull);
    });

    test('bulk Date & time puts moved rows back on their own dates', () async {
      final p = await loaded();
      final a = await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'a',
        date: sep30,
        countIn: oct1,
      );
      // Even onto the same moment: the Count in goes.
      expect(await p.setDateTimeForMany({a}, sep30), 1);
      final t = p.transactions.single;
      expect(t.date, sep30);
      expect(t.countIn, isNull);
      expect(p.incomeInMonth(DateTime(2026, 9)), 85000);
    });
  });

  group('backup', () {
    test('JSON backup round-trips countIn at version 18', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'salary',
        date: sep30,
        countIn: oct1,
      );
      final data = jsonDecode(jsonEncode(p.exportData()));
      expect(data['version'], 19);
      final q = await loaded();
      await q.importData(data as Map<String, dynamic>, replace: true);
      expect(q.transactions.single.countIn, oct1);
      expect(q.incomeInMonth(DateTime(2026, 10)), 85000);
    });

    test('CSV round-trips countIn and leaves it empty when unset', () {
      final csv = BackupService.buildCsvOf([row(countIn: oct1), row()]);
      final back = BackupService.txsFromCsv(csv);
      expect(back[0].countIn, oct1);
      expect(back[1].countIn, isNull);
    });
  });

  testWidgets('a month tap-through lists the row under the month it counts '
      'in, and the header total matches', (tester) async {
    final p = await loaded();
    await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 85000,
      note: 'salary',
      date: sep30,
      countIn: oct1,
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'lunch',
      date: DateTime(2026, 9, 12),
    );
    // The dashboard deep-links by bumping filterToken on a mounted screen.
    final settings = SettingsProvider()..load();
    Widget app(TxFilterRequest? request, int token) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: p),
        ChangeNotifierProvider.value(value: settings),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TransactionsScreen(request: request, filterToken: token),
        ),
      ),
    );
    await tester.pumpWidget(app(null, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpWidget(app(TxFilterRequest(month: DateTime(2026, 10)), 1));
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.textContaining('salary'), findsWidgets);
    expect(find.textContaining('lunch'), findsNothing);
    expect(find.text('Counts in 1 Oct'), findsOneWidget);
    // Contains: a header outside the current year adds the year.
    expect(find.textContaining('OCTOBER'), findsWidgets);
    expect(find.textContaining('SEPTEMBER'), findsNothing);
  });

  testWidgets('the edit sheet sets Count in with its link and clears it '
      'with the chip', (tester) async {
    final p = await loaded();
    final id = await p.addTransaction(
      type: TxType.income,
      categoryId: 'salary',
      amount: 85000,
      note: 'salary',
      date: sep30,
    );
    tester.view.physicalSize = const Size(400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddTransactionSheet(
                  context,
                  existing: p.transactions.firstWhere((t) => t.id == id),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    Future<void> open() async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> save() async {
      final button = find.widgetWithText(FilledButton, 'Save changes');
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await open();
    final link = find.text('Count in another date ›');
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.pumpAndSettle();
    // Opens on 1 Oct, midnight: accept both pickers.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Counts in Thu 1 Oct'), findsOneWidget);
    await save();
    final moved = p.transactions.single;
    expect(moved.countIn, oct1);
    expect(moved.date, sep30);

    // Moving the row to another day drops its Count in, as bulk Date &
    // time does.
    await open();
    final dateButton = find.text('30 Sep 2026');
    await tester.ensureVisible(dateButton);
    await tester.pumpAndSettle();
    await tester.tap(dateButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('15'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Count in another date ›'), findsOneWidget);
    await save();
    expect(p.transactions.single.countIn, isNull);
    expect(p.transactions.single.date, DateTime(2026, 9, 15, 18, 12));

    await p.setCountInForMany({id}, oct1);
    await open();
    final chip = find.widgetWithText(InputChip, 'Counts in Thu 1 Oct');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Count on its own date'));
    await tester.pumpAndSettle();
    expect(find.text('Count in another date ›'), findsOneWidget);
    await save();
    expect(p.transactions.single.countIn, isNull);
  });
}
