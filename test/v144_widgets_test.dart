import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/weekly_digest.dart';
import 'package:expense_tracker/utils/format.dart';

/// The review amount, the This week To sort line and the Accounts widget's
/// block in the home widgets' snapshot. Names and amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  Future<Map<String, dynamic>> snapshot(
    FinanceProvider p, {
    bool hideIncome = false,
  }) async {
    final s = SettingsProvider();
    await s.load();
    if (hideIncome) await s.setHideIncome(true);
    final snap = buildHomeWidgetSnapshot(
      p,
      s,
      now,
      const [],
      patterns: const [],
    );
    return jsonDecode(jsonEncode(snap)) as Map<String, dynamic>;
  }

  Tx waiting(
    String id,
    double amount, {
    TxType type = TxType.expense,
    bool spam = false,
  }) => Tx(
    id: id,
    type: type,
    categoryId: type == TxType.income ? 'salary' : 'food',
    amount: amount,
    note: 'test $id',
    date: today,
    pending: true,
    suspectedSpam: spam,
  );

  group('review amount', () {
    test('sums the waiting imports, spam suspects left out', () async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransaction(waiting('w1', 40000));
      await p.restoreTransaction(waiting('w2', 5000));
      await p.restoreTransaction(waiting('w3', 999, spam: true));
      final snap = await snapshot(p);
      expect(snap['reviewAmount'], 45000);
      expect(snap['reviewAmountLabel'], '₹45,000');
      final week = snap['week'] as Map;
      expect(week['reviewAmountLabel'], '₹45,000');
    });

    test('leaves waiting income out while Hide income is on', () async {
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransaction(waiting('w1', 1200));
      await p.restoreTransaction(waiting('w2', 50000, type: TxType.income));
      expect((await snapshot(p))['reviewAmountLabel'], '₹51,200');
      expect(
        (await snapshot(p, hideIncome: true))['reviewAmountLabel'],
        '₹1,200',
      );
    });

    test('is empty with nothing waiting', () async {
      final p = FinanceProvider();
      await p.load();
      final snap = await snapshot(p);
      expect(snap['reviewAmount'], 0);
      expect(snap['reviewAmountLabel'], '');
      expect((snap['week'] as Map)['reviewAmountLabel'], '');
    });
  });

  group('week To sort line', () {
    Future<void> spend(
      FinanceProvider p,
      String category,
      double amount,
      DateTime date,
    ) => p.addTransaction(
      type: TxType.expense,
      categoryId: category,
      amount: amount,
      note: 'test $category',
      date: date,
    );

    test("carries this week's To sort spend only", () async {
      final p = FinanceProvider();
      await p.load();
      final monday = weekStartOf(today);
      await spend(p, kToSortExpenseId, 18500, today);
      await spend(p, 'food', 100, today);
      // Last week's To sort row is not this week's.
      await spend(
        p,
        kToSortExpenseId,
        700,
        DateTime(monday.year, monday.month, monday.day - 1),
      );
      final week = (await snapshot(p))['week'] as Map;
      expect(week['toSortLabel'], '₹18,500');
    });

    test('is empty when nothing is in To sort', () async {
      final p = FinanceProvider();
      await p.load();
      await spend(p, 'food', 100, today);
      expect(((await snapshot(p))['week'] as Map)['toSortLabel'], '');
    });
  });

  group('accounts block', () {
    test('lists open accounts in the Accounts screen order', () async {
      final p = FinanceProvider();
      await p.load();
      final wallet = await p.addAccount(
        name: 'me',
        type: AccountType.wallet,
        service: 'Test pay',
      );
      final card = await p.addAccount(
        name: 'Travel card',
        type: AccountType.creditCard,
        creditLimit: 150000,
      );
      final bank = await p.addAccount(
        name: 'Salary account',
        type: AccountType.bank,
      );
      final linked = await p.addAccount(
        name: 'Everyday debit card',
        type: AccountType.debitCard,
      );
      final loose = await p.addAccount(
        name: 'Spare debit card',
        type: AccountType.debitCard,
      );
      final savings = await p.addAccount(
        name: 'Test deposit',
        type: AccountType.savings,
      );
      final closed = await p.addAccount(
        name: 'Old account',
        type: AccountType.bank,
      );
      await p.linkDebitCard(linked, bank);
      await p.closeAccount(closed);
      await p.setManualBalance(bank, 84210);

      final rows = [
        for (final r in (await snapshot(p))['accounts'] as List)
          r as Map<String, dynamic>,
      ];
      expect(
        [for (final r in rows) r['id']],
        [bank, card, linked, loose, savings, wallet],
      );
      expect(
        [for (final r in rows) r['kind']],
        ['bank', 'card', 'debit', 'debit', 'savings', 'wallet'],
      );
      expect(rows[0]['name'], 'Salary account');
      expect(rows[0]['leftLabel'], '₹84,210');
      // A wallet is named with its service, as the app's lists name it.
      expect(rows[5]['name'], 'Test pay · me');
      // A debit card drawing from a bank has no left of its own; one
      // linked to none counts like a bank.
      expect(rows[2]['leftLabel'], '');
      expect(rows[3]['leftLabel'], isNotEmpty);
    });

    test("uses each account's own figures", () async {
      final p = FinanceProvider();
      await p.load();
      final bank = await p.addAccount(
        name: 'Salary account',
        type: AccountType.bank,
      );
      final card = await p.addAccount(
        name: 'Travel card',
        type: AccountType.creditCard,
        creditLimit: 150000,
      );
      await p.addAccountKey(bank, 'TB:1111');
      await p.addAccountKey(card, 'TC:2222');
      for (final (id, key, amount) in [
        ('b1', 'TB:1111', 1200.0),
        ('c1', 'TC:2222', 9850.0),
      ]) {
        await p.restoreTransaction(
          Tx(
            id: id,
            type: TxType.expense,
            categoryId: 'food',
            amount: amount,
            note: 'test $id',
            date: today,
            acctKey: key,
          ),
        );
      }
      final rows = [
        for (final r in (await snapshot(p))['accounts'] as List)
          r as Map<String, dynamic>,
      ];
      final b = p.accounts.firstWhere((a) => a.id == bank);
      final c = p.accounts.firstWhere((a) => a.id == card);
      expect(rows[0]['spentLabel'], fmtMoneyWhole(p.accountSpentThisMonth(b)));
      expect(rows[0]['leftLabel'], fmtMoneyWhole(p.accountBalance(b)));
      expect(rows[1]['spentLabel'], fmtMoneyWhole(p.cardCycleSpend(c)));
      final available = p.accountAvailable(c);
      expect(
        rows[1]['leftLabel'],
        available == null ? '' : fmtMoneyWhole(available),
      );
    });

    test('is an empty list with no accounts', () async {
      final p = FinanceProvider();
      await p.load();
      expect((await snapshot(p))['accounts'], isEmpty);
    });
  });

  test('the Accounts widget names its action', () {
    expect(LaunchActions.fromName('open_accounts'), LaunchAction.openAccounts);
  });
}
