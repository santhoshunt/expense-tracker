import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/transfer_pairing.dart';

/// Wallets: money or points that only spend on one platform. Out of net
/// balance, and their rows count in spending only when turned on per row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // In the past, so balances never depend on today's date.
  final sep5 = DateTime(2026, 9, 5, 12);
  final sep = DateTime(2026, 9);

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  /// A wallet plus one ₹250 food purchase on it; returns (walletId, txId).
  Future<(String, String)> walletWithSpend(
    FinanceProvider p, {
    bool counted = false,
    bool points = false,
  }) async {
    final wallet = await p.addAccount(
      name: 'me',
      type: AccountType.wallet,
      service: 'Amazon Pay',
      holdsPoints: points,
      pointValue: points ? 0.25 : null,
    );
    final tx = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'groceries',
      date: sep5,
      walletCounted: counted,
    );
    await p.assignAccount(tx, wallet);
    return (wallet, tx);
  }

  group('model', () {
    test('Account round-trips the wallet fields and reads old JSON', () {
      final a = Account(
        id: 'w1',
        name: 'me',
        type: AccountType.wallet,
        keys: {'manual:t1'},
        service: 'Swiggy',
        holdsPoints: true,
        pointValue: 0.25,
      );
      final back = Account.fromJson(jsonDecode(jsonEncode(a.toJson())));
      expect(back.type, AccountType.wallet);
      expect(back.service, 'Swiggy');
      expect(back.holdsPoints, isTrue);
      expect(back.pointValue, 0.25);
      expect(back.displayName, 'Swiggy · me');
      expect(back.typeLabel, 'Points wallet');
      expect(back.pointsOf(125), 500);

      final bank = Account.fromJson({
        'id': 'b1',
        'name': 'HDFC',
        'type': 'bank',
        'keys': ['HDFC:1234'],
      });
      expect(bank.service, isNull);
      expect(bank.holdsPoints, isFalse);
      expect(bank.displayName, 'HDFC');
      expect(bank.toJson().containsKey('holdsPoints'), isFalse);
      // A money wallet has no points to show.
      expect(a.copyWith(holdsPoints: false).pointsOf(125), isNull);
    });

    test('Tx carries walletCounted only when set', () {
      final t = Tx(
        id: 't1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 10,
        note: '',
        date: sep5,
      );
      expect(t.toJson().containsKey('walletCounted'), isFalse);
      final on = t.copyWith(walletCounted: true);
      expect(
        Tx.fromJson(jsonDecode(jsonEncode(on.toJson()))).walletCounted,
        isTrue,
      );
      expect(on.copyWith(note: 'x').walletCounted, isTrue);
    });
  });

  group('totals', () {
    test(
      'an uncounted wallet purchase is in no figure but the balance',
      () async {
        final p = await loaded();
        final budget = await p.addBudget(
          name: 'All',
          limit: 1000,
          mode: BudgetMode.exclude,
          categoryIds: const {},
        );
        final (wallet, tx) = await walletWithSpend(p);
        await p.setManualBalance(wallet, 840);
        // The manual balance is stamped now, after the purchase: add another
        // purchase dated after it so the wallet balance moves.
        final later = await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 90,
          note: 'snacks',
          date: DateTime.now().add(const Duration(milliseconds: 200)),
        );
        await p.assignAccount(later, wallet);

        final row = p.transactions.firstWhere((t) => t.id == tx);
        final b = p.budgets.firstWhere((x) => x.id == budget);
        expect(p.countsInTotals(row), isFalse);
        expect(p.expenseInMonth(sep), 0);
        expect(p.expenseByDayInMonth(sep), isEmpty);
        expect(p.spendOnDay(sep5).spent, 0);
        expect(p.expensesOnDay(sep5), isEmpty);
        expect(p.budgetSpentFor(b, sep), 0);
        expect(p.countsTowardBudget(row, b), isFalse);
        expect(p.countedTransactions.any((t) => t.id == tx), isFalse);
        // Still on the wallet's balance.
        expect(p.accountBalance(p.accountById(wallet)!), 840 - 90);
      },
    );

    test('Count as spending on puts it back in every figure', () async {
      final p = await loaded();
      final (_, tx) = await walletWithSpend(p, counted: true);
      final row = p.transactions.firstWhere((t) => t.id == tx);
      expect(p.countsInTotals(row), isTrue);
      expect(p.expenseInMonth(sep), 250);
      expect(p.spendOnDay(sep5).spent, 250);
    });

    test('tags keep the row but not its spend', () async {
      final p = await loaded();
      final (_, tx) = await walletWithSpend(p);
      final row = p.transactions.firstWhere((t) => t.id == tx);
      await p.updateTransaction(row.copyWith(tags: ['Goa']));
      final s = p.tagSummaries.single;
      expect(s.count, 1);
      expect(s.spent, 0);
      expect(p.expenseByTagInMonth(sep), isEmpty);
    });

    test('a Count in date does not make an uncounted row count', () async {
      final p = await loaded();
      final (_, tx) = await walletWithSpend(p);
      await p.setCountInForMany({tx}, DateTime(2026, 11, 1));
      expect(p.expenseInMonth(DateTime(2026, 11)), 0);
      expect(p.expenseInMonth(sep), 0);
    });

    test('moving a row off a wallet resets Count as spending', () async {
      final p = await loaded();
      final (_, tx) = await walletWithSpend(p, counted: true);
      final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      await p.assignAccount(tx, bank);
      final row = p.transactions.firstWhere((t) => t.id == tx);
      expect(row.walletCounted, isFalse);
      expect(p.expenseInMonth(sep), 250);
    });
  });

  group('accounts', () {
    test('wallets stay out of net balance', () async {
      final p = await loaded();
      final (wallet, _) = await walletWithSpend(p);
      await p.setManualBalance(wallet, 840);
      expect(p.netWorth, 0);
      expect(p.bankBalanceTotal, 0);
      expect(p.walletBalanceTotal, 840);
      expect(p.hasNetAccounts, isFalse);
      await p.addAccount(name: 'HDFC', type: AccountType.bank);
      expect(p.hasNetAccounts, isTrue);
    });

    test('a new value per point keeps the point count', () async {
      final p = await loaded();
      final wallet = await p.addAccount(
        name: 'me',
        type: AccountType.wallet,
        service: 'Swiggy',
        holdsPoints: true,
        pointValue: 0.25,
      );
      await p.setManualBalance(wallet, 125); // 500 points
      await p.setWalletDetails(wallet, pointValue: 0.5);
      final a = p.accountById(wallet)!;
      expect(a.pointValue, 0.5);
      expect(p.accountBalance(a), 250);
      expect(a.pointsOf(p.accountBalance(a)), 500);
    });

    test(
      'guards: no bank numbers, no merging across the wallet line',
      () async {
        final p = await loaded();
        final (wallet, _) = await walletWithSpend(p);
        final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
        expect(await p.addAccountKey(wallet, 'HDFC:1234'), isFalse);
        expect(await p.addAccountKey(bank, 'HDFC:1234'), isTrue);
        // A bank that owns an SMS number can't become a wallet.
        expect(await p.setAccountType(bank, AccountType.wallet), isFalse);
        expect(p.accountById(bank)!.type, AccountType.bank);
        await p.mergeAccounts(wallet, bank);
        expect(p.accountById(wallet), isNotNull);
        // One holding only hand-assigned rows can.
        final cash = await p.addAccount(name: 'Cash', type: AccountType.bank);
        expect(await p.setAccountType(cash, AccountType.wallet), isTrue);
      },
    );

    test('wallet rows never pair, and never pay a card bill', () async {
      final p = await loaded();
      final (wallet, spend) = await walletWithSpend(p);
      final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      final credit = await p.addTransaction(
        type: TxType.income,
        categoryId: 'other_income',
        amount: 250,
        note: 'top-up',
        date: sep5,
      );
      await p.assignAccount(credit, bank);
      expect(await p.pairTransactions(spend, credit), isNull);
      expect(
        pairKindFor(send: p.accountById(bank), recv: p.accountById(wallet)),
        isNull,
      );
      final card = await p.addAccount(
        name: 'Card',
        type: AccountType.creditCard,
      );
      final result = await p.recordCardPayment(
        accountId: card,
        amount: 250,
        paidOn: sep5,
        due: sep5,
      );
      // Recorded, but the wallet debit of the same amount isn't its bank leg.
      expect(result, isNotNull);
      expect(result!.bankLegBefore, isNull);
    });
  });

  group('crossing the wallet line', () {
    test(
      'hand-assigned rows can go, transfer legs and bank numbers not',
      () async {
        final p = await loaded();
        final cash = await p.addAccount(name: 'Cash', type: AccountType.bank);
        final spend = await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 100,
          note: 'tea',
          date: sep5,
        );
        await p.assignAccount(spend, cash);
        // Only a manual: key, so it can be a wallet.
        expect(p.accountById(cash)!.keys.single, startsWith('manual:'));
        expect(p.canBecomeWallet(p.accountById(cash)!), isTrue);

        // Half of a transfer pair: no.
        final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
        final debit = await p.addTransaction(
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 500,
          note: 'top-up',
          date: sep5,
        );
        final credit = await p.addTransaction(
          type: TxType.income,
          categoryId: 'other_income',
          amount: 500,
          note: 'top-up in',
          date: sep5,
        );
        await p.assignAccount(debit, bank);
        await p.assignAccount(credit, cash);
        expect(await p.pairTransactions(debit, credit), isNotNull);
        expect(p.canBecomeWallet(p.accountById(cash)!), isFalse);
        expect(await p.setAccountType(cash, AccountType.wallet), isFalse);

        // And a paired leg can't be moved onto a wallet either.
        final (wallet, _) = await walletWithSpend(p);
        await p.assignAccount(credit, wallet);
        expect(
          p
              .accountForKey(
                p.transactions.firstWhere((t) => t.id == credit).acctKey,
              )!
              .id,
          cash,
        );
      },
    );

    test(
      'a type change clears old Count as spending and keeps the name',
      () async {
        final p = await loaded();
        final (wallet, tx) = await walletWithSpend(p, counted: true);
        expect(await p.setAccountType(wallet, AccountType.bank), isTrue);
        final bank = p.accountById(wallet)!;
        expect(bank.name, 'Amazon Pay · me');
        expect(
          p.transactions.firstWhere((t) => t.id == tx).walletCounted,
          isFalse,
        );
        expect(p.expenseInMonth(sep), 250);
        // Back to a wallet: the old setting doesn't return, and the
        // service isn't doubled into the name.
        expect(await p.setAccountType(wallet, AccountType.wallet), isTrue);
        expect(p.expenseInMonth(sep), 0);
        expect(p.accountById(wallet)!.displayName, 'Amazon Pay · me');
      },
    );

    test('a savings account holding To savings rows stays savings', () async {
      final p = await loaded();
      final gold = await p.addAccount(name: 'Gold', type: AccountType.savings);
      final buy = await p.addTransaction(
        type: TxType.expense,
        categoryId: kSavingsTransferCategoryId,
        amount: 10000,
        note: 'coins',
        date: sep5,
      );
      await p.assignAccount(buy, gold);
      expect(await p.setAccountType(gold, AccountType.wallet), isFalse);
      expect(p.accountBalance(p.accountById(gold)!), 10000);
    });

    test('deleting a wallet clears its rows\' setting', () async {
      final p = await loaded();
      final (wallet, tx) = await walletWithSpend(p, counted: true);
      await p.deleteAccount(wallet);
      expect(
        p.transactions.firstWhere((t) => t.id == tx).walletCounted,
        isFalse,
      );
    });
  });

  group('backup', () {
    test('JSON at version 19 round-trips wallets and the flag', () async {
      final p = await loaded();
      await walletWithSpend(p, counted: true, points: true);
      final data = jsonDecode(jsonEncode(p.exportData()));
      expect(data['version'], 19);
      final q = await loaded();
      await q.importData(data as Map<String, dynamic>, replace: true);
      final a = q.accounts.single;
      expect(a.isWallet, isTrue);
      expect(a.pointValue, 0.25);
      expect(q.transactions.single.walletCounted, isTrue);
      expect(q.expenseInMonth(sep), 250);
    });

    test('merging a backup never folds a wallet into a bank', () async {
      final p = await loaded();
      final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      await p.addAccountKey(bank, 'HDFC:1234');
      await p.importData({
        'app': 'expense_tracker',
        'version': 19,
        'transactions': <Object>[],
        'accounts': [
          {
            'id': 'imported',
            'name': 'me',
            'type': 'wallet',
            'service': 'Paytm',
            'keys': ['HDFC:1234', 'manual:x'],
          },
        ],
      }, replace: false);
      final wallet = p.accounts.firstWhere((a) => a.isWallet);
      expect(wallet.keys, {'manual:x'});
      expect(p.accountById(bank)!.keys, {'HDFC:1234'});
    });

    test('a merge never hands a wallet\'s key to a bank', () async {
      final p = await loaded();
      final (wallet, tx) = await walletWithSpend(p);
      final walletKey = p.transactions.firstWhere((t) => t.id == tx).acctKey!;
      final bank = await p.addAccount(name: 'HDFC', type: AccountType.bank);
      await p.addAccountKey(bank, 'HDFC:1234');
      await p.importData({
        'app': 'expense_tracker',
        'version': 19,
        'transactions': <Object>[],
        'accounts': [
          {
            'id': 'other-device',
            'name': 'HDFC',
            'type': 'bank',
            'keys': ['HDFC:1234', walletKey],
          },
        ],
      }, replace: false);
      expect(p.accountById(bank)!.keys, {'HDFC:1234'});
      expect(p.accountById(wallet)!.keys, contains(walletKey));
      expect(p.expenseInMonth(sep), 0, reason: 'still uncounted');
    });

    test('CSV carries walletCounted', () {
      final t = Tx(
        id: 't1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 10,
        note: '',
        date: sep5,
        walletCounted: true,
      );
      final csv = BackupService.buildCsvOf([t]);
      expect(csv.split('\r\n').first, endsWith(',countIn,walletCounted'));
      expect(BackupService.txsFromCsv(csv).single.walletCounted, isTrue);
    });
  });
}
