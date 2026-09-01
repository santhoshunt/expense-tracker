import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/default_rules.dart';
import 'package:expense_tracker/models/import_rule.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final smsDate = DateTime(2026, 7, 2, 10, 30);

  group('seeding', () {
    test('defaults are seeded as built-in rules on first load', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      expect(
        p.importRules.length,
        kDefaultIgnorePhrases.length + kDefaultSpamSignals.length,
      );
      expect(p.importRules.every((r) => r.isBuiltIn), isTrue);
      expect(
        p.importRules.any(
          (r) => r.pattern == 'otp' && r.kind == ImportRuleKind.ignore,
        ),
        isTrue,
      );
      expect(
        p.importRules.any(
          (r) => r.pattern == 'offer' && r.kind == ImportRuleKind.spamSignal,
        ),
        isTrue,
      );
      // Getters split by kind for the parser.
      expect(p.ignorePhrases, kDefaultIgnorePhrases);
      expect(p.spamSignals, kDefaultSpamSignals);
    });

    test('seeding happens once — no duplicates on reload', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      final count = p.importRules.length;

      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.importRules.length, count);
    });
  });

  group('CRUD + persistence', () {
    test('add/update/delete round-trip across provider instances', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      await p.addImportRule('lucky draw', ImportRuleKind.ignore);
      final rule = p.importRules.first; // newest first
      expect(rule.pattern, 'lucky draw');
      expect(rule.isBuiltIn, isFalse);

      await p.updateImportRule(
        rule.copyWith(pattern: 'lottery', kind: ImportRuleKind.spamSignal),
      );

      final p2 = FinanceProvider();
      await p2.load();
      final reloaded = p2.importRules.firstWhere((r) => r.id == rule.id);
      expect(reloaded.pattern, 'lottery');
      expect(reloaded.kind, ImportRuleKind.spamSignal);

      await p2.deleteImportRule(rule.id);
      final p3 = FinanceProvider();
      await p3.load();
      expect(p3.importRules.any((r) => r.id == rule.id), isFalse);
      // Deleting stays deleted — the seed marker prevents re-seeding.
      expect(
        p3.importRules.length,
        kDefaultIgnorePhrases.length + kDefaultSpamSignals.length,
      );
    });

    test('built-in rules are editable and deletable', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      final otp = p.importRules.firstWhere((r) => r.pattern == 'otp');
      await p.updateImportRule(otp.copyWith(pattern: 'one otp'));
      expect(
        p.importRules.firstWhere((r) => r.id == otp.id).pattern,
        'one otp',
      );

      final failed = p.importRules.firstWhere((r) => r.pattern == 'failed');
      await p.deleteImportRule(failed.id);
      expect(p.ignorePhrases, isNot(contains('failed')));
    });

    test('restore defaults resets built-ins, keeps user rules', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      final otp = p.importRules.firstWhere((r) => r.pattern == 'otp');
      await p.updateImportRule(otp.copyWith(pattern: 'mangled'));
      final failed = p.importRules.firstWhere((r) => r.pattern == 'failed');
      await p.deleteImportRule(failed.id);
      await p.addImportRule('my custom phrase', ImportRuleKind.ignore);

      await p.restoreDefaultImportRules();

      expect(p.ignorePhrases, contains('otp')); // edit reverted
      expect(p.ignorePhrases, contains('failed')); // deletion undone
      expect(p.ignorePhrases, isNot(contains('mangled')));
      expect(p.ignorePhrases, contains('my custom phrase')); // user rule kept
      expect(
        p.importRules.length,
        kDefaultIgnorePhrases.length + kDefaultSpamSignals.length + 1,
      );
    });
  });

  group('parser honors custom lists', () {
    const mandateBody =
        'Rs.649.00 will be debited from your a/c on 05-07-26 towards '
        'Netflix subscription.';

    test('removing an ignore phrase lets the message import', () {
      // Default list rejects the e-mandate ("will be debited")…
      expect(SmsTxnParser.parse('VM-HDFCBK', mandateBody, smsDate), isNull);
      // …an emptied ignore list lets it parse.
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        mandateBody,
        smsDate,
        ignorePhrases: const [],
      );
      expect(r, isNotNull);
      expect(r!.type, TxType.expense);
    });

    test('a custom ignore phrase suppresses a plain debit', () {
      const body =
          'Rs.99.00 debited from a/c XX1234 on 02-07-26 at JIO RECHARGE.';
      expect(SmsTxnParser.parse('VM-HDFCBK', body, smsDate), isNotNull);
      expect(
        SmsTxnParser.parse(
          'VM-HDFCBK',
          body,
          smsDate,
          ignorePhrases: const ['jio recharge'],
        ),
        isNull,
      );
    });

    test('custom spam signals flag and un-flag', () {
      const body =
          'Rs.500.00 debited from a/c XX1234 on 02-07-26 towards EMI '
          'Ref No 615243342718.';
      final flagged = SmsTxnParser.parse(
        'VM-HDFCBK',
        body,
        smsDate,
        spamSignals: const ['emi'],
      )!;
      expect(flagged.spamSuspect, isTrue);

      const promoBody =
          'Rs.245.00 refunded by Swiggy adjusted against HDFC Card 9631. '
          'View balance: https://hdfcbk.io/s/0RMe5PAv';
      final unflagged = SmsTxnParser.parse(
        'VM-HDFCBK',
        promoBody,
        smsDate,
        spamSignals: const [],
      )!;
      expect(unflagged.spamSuspect, isFalse);
    });
  });

  group('two-sided card payments survive dedup', () {
    test('same ref, opposite directions → both import', () async {
      // Bank-side debit and issuer-side credit of one bill payment often
      // quote the same reference (e.g. a BBPS id) — they are two different
      // transactions, not duplicates of each other.
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      final (first, _) = await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 5609.48,
          merchant: '',
          date: DateTime(2026, 6, 11),
          ref: 'BBPS12345678',
          categoryId: kCardBillCategoryId,
          sender: 'VM-ICICIB',
          rawBody:
              'Rs.5,609.48 debited towards your Credit Card payment. '
              'Ref BBPS12345678.',
        ),
      ]);
      expect(first, 1);

      final (second, _) = await p.addImported([
        ParsedTxn(
          type: TxType.income,
          amount: 5609.48,
          merchant: '',
          date: DateTime(2026, 6, 11),
          ref: 'BBPS12345678',
          categoryId: kCardPaymentCategoryId,
          sender: 'VM-ICICIB',
          rawBody:
              'Payment of Rs.5,609.48 received on your ICICI Bank '
              'Credit Card XX9005. Ref BBPS12345678.',
        ),
      ]);
      expect(second, 1, reason: 'credit side must not dedup against debit');
      expect(p.pendingTransactions.length, 2);

      // A true re-scan of the same message is still a duplicate.
      final (third, _) = await p.addImported([
        ParsedTxn(
          type: TxType.income,
          amount: 5609.48,
          merchant: '',
          date: DateTime(2026, 6, 11),
          ref: 'BBPS12345678',
          categoryId: kCardPaymentCategoryId,
          sender: 'VM-ICICIB',
          rawBody:
              'Payment of Rs.5,609.48 received on your ICICI Bank '
              'Credit Card XX9005. Ref BBPS12345678.',
        ),
      ]);
      expect(third, 0);
    });

    test('ref-less alerts hours apart are not duplicates', () async {
      // The fuzzy fallback treats same type + amount + sender within 3 minutes
      // as one alert sent twice. While body-dated messages all collapsed to
      // midnight, two genuinely distinct same-day payments differed by 0
      // minutes and the second was silently dropped.
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      ParsedTxn refless(DateTime at) => ParsedTxn(
        type: TxType.expense,
        amount: 120,
        merchant: 'CHAI',
        date: at,
        ref: null,
        categoryId: 'other_expense',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs.120.00 debited from a/c XX1234 at CHAI POINT.',
      );

      final (added, _) = await p.addImported([
        refless(DateTime(2026, 7, 4, 9, 15)),
        refless(DateTime(2026, 7, 4, 18, 40)),
      ]);
      expect(added, 2);

      // A genuine re-scan of the same alert still dedups.
      final (again, _) = await p.addImported([
        refless(DateTime(2026, 7, 4, 9, 16)),
      ]);
      expect(again, 0);
    });
  });

  group('transfers are excluded from aggregates', () {
    test('transfer categories skip income/expense/budget/donut', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      final month = DateTime(2026, 7);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 400,
        note: 'lunch',
        date: DateTime(2026, 7, 3),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: kCardBillCategoryId,
        amount: 5000,
        note: 'HDFC card bill',
        date: DateTime(2026, 7, 4),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: kCardPaymentCategoryId,
        amount: 5000,
        note: 'payment received on card',
        date: DateTime(2026, 7, 4),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: kTransferOutCategoryId,
        amount: 20000,
        note: 'moved to Indian Bank',
        date: DateTime(2026, 7, 5),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: kTransferInCategoryId,
        amount: 20000,
        note: 'received from HDFC',
        date: DateTime(2026, 7, 5),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'salary',
        date: DateTime(2026, 7, 1),
      );

      // Only the real expense and the real income count.
      expect(p.expenseInMonth(month), 400);
      expect(p.incomeInMonth(month), 85000);
      expect(p.budgetSpentInMonth(month), 400);
      expect(p.totalExpense, 400);
      expect(p.totalIncome, 85000);
      // Donut shows only the real expense category.
      final byCat = p.expenseByCategory(month);
      expect(byCat.length, 1);
      expect(byCat.single.key.id, 'food');
      // The transfers are still in the ledger for auditing.
      expect(p.transactions.length, 6);
    });
  });

  group('savings transfers', () {
    test('excluded from expenses but tracked as saved', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      final month = DateTime(2026, 7);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 400,
        note: 'lunch',
        date: DateTime(2026, 7, 3),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: kSavingsTransferCategoryId,
        amount: 5000,
        note: 'RD instalment',
        date: DateTime(2026, 7, 5),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 85000,
        note: 'salary',
        date: DateTime(2026, 7, 1),
      );

      expect(p.expenseInMonth(month), 400); // RD is not spending
      expect(p.budgetSpentInMonth(month), 400);
      expect(p.savingsTransfersInMonth(month), 5000);
      expect(p.totalSavingsTransfers, 5000);
      // …but it is no longer disposable income.
      expect(p.balance, 85000 - 400 - 5000);
    });
  });

  group('rules re-apply to history', () {
    ParsedTxn msg(String ref, String body) => ParsedTxn(
      type: TxType.expense,
      amount: 100,
      merchant: '',
      date: DateTime(2026, 7, 2),
      ref: ref,
      categoryId: 'other_expense',
      sender: 'VM-HDFCBK',
      rawBody: body,
    );

    test('editing a rule re-classifies matching history', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      await p.addImported([
        msg('REFAAA111', 'Rs.100 debited at CHAI KINGS Ref REFAAA111'),
        msg('REFBBB222', 'Rs.100 debited at RK TRADERS Ref REFBBB222'),
      ]);
      await p.confirmAllPending();

      await p.addRule('chai kings', 'food');
      Tx byRef(String ref) =>
          p.transactions.firstWhere((t) => t.externalRef == ref);
      expect(byRef('REFAAA111').categoryId, 'food');
      expect(byRef('REFBBB222').categoryId, 'other_expense');

      // Repoint the rule at a different pattern + category: the newly
      // matching message re-classifies.
      final rule = p.rules.firstWhere((r) => r.pattern == 'chai kings');
      await p.updateRule(
        rule.copyWith(pattern: 'rk traders', categoryId: 'shopping'),
      );
      expect(byRef('REFBBB222').categoryId, 'shopping');
    });
  });

  group('manual account balances', () {
    test('manual figure wins until a newer SMS figure arrives', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 500,
          merchant: 'SWIGGY',
          date: DateTime(2026, 7, 1),
          ref: 'REF00000001',
          categoryId: 'food',
          sender: 'VM-HDFCBK',
          rawBody: 'Rs.500 debited from a/c XX1234 Avl Bal Rs.40,000.00',
          acctKey: 'HDFC:1234',
          balanceAfter: 40000,
        ),
      ]);
      await p.confirmAllPending();
      final acct = p.accounts.single;
      expect(p.accountBalance(acct), 40000);

      // Manual entry is newer than the July-1 SMS → it wins.
      await p.setManualBalance(acct.id, 55000);
      expect(p.accountBalance(p.accounts.single), 55000);

      // Clearing goes back to the SMS figure.
      await p.setManualBalance(acct.id, null);
      expect(p.accountBalance(p.accounts.single), 40000);

      // Persists across reloads.
      await p.setManualBalance(acct.id, 60000);
      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.accountBalance(p2.accounts.single), 60000);
    });

    test('card manual outstanding wins over derived figure', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      await p.addImported([
        ParsedTxn(
          type: TxType.expense,
          amount: 500,
          merchant: 'AMAZON',
          date: DateTime(2026, 7, 1),
          ref: 'REF00000002',
          categoryId: 'shopping',
          sender: 'VM-ICICIB',
          rawBody: 'INR 500 spent on Credit Card XX9005 Avl Lmt INR 1,90,000',
          acctKey: 'ICICI:9005',
          balanceAfter: 190000,
          isCard: true,
        ),
      ]);
      await p.confirmAllPending();
      var card = p.accounts.single;
      await p.setCreditLimit(card.id, 200000);
      card = p.accountById(card.id)!;
      expect(p.accountOutstanding(card), 10000); // 200000 − 190000

      await p.setManualBalance(card.id, 25000);
      card = p.accountById(card.id)!;
      expect(p.accountOutstanding(card), 25000);
      // Available derives from the manual outstanding.
      expect(p.accountAvailable(card), 175000);
    });
  });

  group('savings/asset accounts', () {
    test('custom kind + icon persist and drive display', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();

      final id = await p.addAccount(
        name: 'Zerodha',
        type: AccountType.savings,
        kind: 'Stocks',
        kindIcon: 'stocks',
      );
      var acct = p.accountById(id)!;
      expect(acct.typeLabel, 'Stocks');
      expect(acct.icon, kAssetIconChoices['stocks']);
      // Savings/asset value is tracked separately and stays OUT of the
      // liquid net worth (not spendable cash).
      await p.setManualBalance(id, 150000);
      expect(p.savingsBalanceTotal, 150000);
      expect(p.bankBalanceTotal, 0);
      expect(p.netWorth, 0);

      final p2 = FinanceProvider();
      await p2.load();
      acct = p2.accountById(id)!;
      expect(acct.kind, 'Stocks');
      expect(acct.kindIcon, 'stocks');

      // Clearing the kind reverts to the generic Savings label.
      await p2.setAccountKind(id, null);
      expect(p2.accountById(id)!.typeLabel, 'Savings');
    });
  });

  group('custom categories', () {
    test('create, persist, and delete with reassignment', () async {
      SharedPreferences.setMockInitialValues({});
      setCustomCategories(const []); // isolate from other tests
      final p = FinanceProvider();
      await p.load();

      final id = await p.addCategory(
        label: 'Home',
        type: TxType.expense,
        icon: Icons.home,
        color: const Color(0xFF65B0F6),
      );
      expect(categoryById(id).label, 'Home');
      expect(allCategories.any((c) => c.id == id), isTrue);

      await p.addTransaction(
        type: TxType.expense,
        categoryId: id,
        amount: 1200,
        note: 'plumber',
        date: DateTime(2026, 7, 2),
      );
      await p.addRule('plumber', id);

      // Round-trips through persistence.
      final p2 = FinanceProvider();
      await p2.load();
      expect(categoryById(id).label, 'Home');
      expect(categoryById(id).icon, Icons.home);
      expect(categoryById(id).type, TxType.expense);

      // Delete: transactions fall back to Other, targeting rules removed.
      await p2.deleteCategory(id);
      expect(allCategories.any((c) => c.id == id), isFalse);
      expect(p2.transactions.single.categoryId, 'other_expense');
      expect(p2.rules.any((r) => r.categoryId == id), isFalse);
    });
  });
}
