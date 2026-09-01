import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/utils/contrast.dart';

/// Regression tests for the 2026-08-28 audit fix round. Each group pins one
/// confirmed finding from AUDIT_FINDINGS.md.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final july = DateTime(2026, 7);

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  ParsedTxn parsed({
    String? ref,
    String rawBody = 'Rs.100 debited at SWIGGY',
    double amount = 100,
    bool spamSuspect = false,
  }) => ParsedTxn(
    type: TxType.expense,
    amount: amount,
    merchant: 'Swiggy',
    date: DateTime(2026, 7, 1, 13),
    ref: ref,
    categoryId: 'food',
    sender: 'VM-HDFCBK',
    rawBody: rawBody,
    spamSuspect: spamSuspect,
  );

  group('bulk-edit undo (H1)', () {
    test('restoreEditedTransactions puts pre-edit copies back by id', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: '',
        date: DateTime(2026, 7, 3, 12),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 200,
        note: '',
        date: DateTime(2026, 7, 4, 12),
      );
      final snapshot = List<Tx>.from(p.transactions);
      final ids = snapshot.map((t) => t.id).toSet();

      final stamp = DateTime(2026, 7, 10, 9, 30);
      await p.setDateTimeForMany(ids, stamp);
      expect(p.transactions.every((t) => t.date == stamp), isTrue);

      await p.restoreEditedTransactions(snapshot);
      final byId = {for (final t in p.transactions) t.id: t};
      for (final old in snapshot) {
        expect(byId[old.id]!.date, old.date);
      }
    });

    test('restore also re-adds rows deleted in the meantime', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 100,
        note: '',
        date: DateTime(2026, 7, 3, 12),
      );
      final old = p.transactions.single;
      await p.deleteTransaction(old.id);
      expect(p.transactions, isEmpty);
      await p.restoreEditedTransactions([old]);
      expect(p.transactions.single.id, old.id);
    });

    test('confirm undo: restoring the pending copy re-queues it', () async {
      final p = await loaded();
      await p.addImported([parsed(ref: 'A')]);
      final pendingCopy = p.pendingTransactions.single;

      await p.confirmTransaction(pendingCopy.id);
      expect(p.pendingTransactions, isEmpty);
      expect(p.transactions.length, 1);

      await p.restoreEditedTransactions([pendingCopy]);
      expect(p.pendingTransactions.single.id, pendingCopy.id);
      expect(p.transactions, isEmpty);
    });
  });

  group('spam rule pre-warning and restore (H3)', () {
    test(
      'pendingSpamDropsFor counts what a new spam rule would drop',
      () async {
        final p = await loaded();
        await p.addImported([
          parsed(ref: 'A', rawBody: 'Rs.100 debited. MEGA OFFER inside'),
          parsed(ref: 'B', rawBody: 'Rs.200 debited at SWIGGY'),
        ]);
        expect(p.pendingSpamDropsFor('mega offer', 'spam'), 1);
        expect(p.pendingSpamDropsFor('swiggy', 'spam'), 1);
        expect(p.pendingSpamDropsFor('nowhere', 'spam'), 0);
        // A non-spam rule never drops anything.
        expect(p.pendingSpamDropsFor('mega offer', 'food'), 0);
        // The queue itself is untouched by the dry run.
        expect(p.pendingTransactions.length, 2);
      },
    );

    test('a higher-priority claiming rule shadows the candidate', () async {
      final p = await loaded();
      await p.addImported([
        parsed(ref: 'A', rawBody: 'Rs.100 debited. MEGA OFFER inside'),
      ]);
      // Rules are matched newest-first (addRule inserts at the top), so the
      // food rule created LAST sits above the older 'nothing here' rule.
      final unrelated = await p.addRule('nothing here', 'transport');
      expect(unrelated.droppedPending, 0);
      await p.addRule('mega offer', 'food');
      final unrelatedRule = p.rules.firstWhere(
        (r) => r.pattern == 'nothing here',
      );
      // Editing the OLDER rule into spam: the food rule above still claims
      // the message first, so nothing would drop…
      expect(
        p.pendingSpamDropsFor(
          'mega offer',
          'spam',
          replacingRuleId: unrelatedRule.id,
        ),
        0,
      );
      // …while a brand-new spam rule (inserted at the top) would claim it.
      expect(p.pendingSpamDropsFor('mega offer', 'spam'), 1);
    });

    test('addRule returns the dropped rows; restore re-queues them', () async {
      final p = await loaded();
      await p.addImported([
        parsed(ref: 'A', rawBody: 'Rs.100 debited. MEGA OFFER inside'),
        parsed(ref: 'B', rawBody: 'Rs.200 debited at SWIGGY'),
      ]);
      final applied = await p.addRule('mega offer', 'spam');
      expect(applied.droppedPending, 1);
      expect(applied.dropped.single.externalRef, 'A');
      expect(p.pendingTransactions.length, 1);

      await p.restoreEditedTransactions(applied.dropped);
      expect(p.pendingTransactions.length, 2);
    });
  });

  group('JSON import validation (M2)', () {
    Map<String, dynamic> backupWith(Map<String, dynamic> tx) => {
      'app': 'expense_tracker',
      'version': 11,
      'transactions': [tx],
      'accounts': <dynamic>[],
    };

    Map<String, dynamic> row(Object amount) => {
      'id': 'x1',
      'type': 'expense',
      'categoryId': 'food',
      'amount': amount,
      'note': '',
      'date': DateTime(2026, 7, 1).toIso8601String(),
    };

    test('negative and non-finite amounts are rejected', () async {
      final p = await loaded();
      await expectLater(
        p.importData(backupWith(row(-500)), replace: false),
        throwsFormatException,
      );
      await expectLater(
        p.importData(backupWith(row(1e400)), replace: false),
        throwsFormatException,
      );
      expect(p.transactions, isEmpty);
    });

    test('a valid amount still imports', () async {
      final p = await loaded();
      final added = await p.importData(backupWith(row(500)), replace: false);
      expect(added, 1);
      expect(p.transactions.single.amount, 500);
    });
  });

  group('merge-mode account import (M4)', () {
    test(
      'an imported account sharing an acctKey folds into the owner',
      () async {
        final p = await loaded();
        final devId = await p.addAccount(
          name: 'HDFC Salary',
          type: AccountType.bank,
        );
        expect(await p.addAccountKey(devId, 'HDFC:1234'), isTrue);
        await p.setManualBalance(devId, 45000);

        final added = await p.importData({
          'app': 'expense_tracker',
          'version': 11,
          'transactions': <dynamic>[],
          'accounts': [
            Account(
              id: 'other_device_acct',
              name: 'HDFC ••1234',
              type: AccountType.bank,
              keys: {'HDFC:1234', 'HDFC:9999'},
            ).toJson(),
          ],
        }, replace: false);
        expect(added, 0);

        // No duplicate appended; the device account keeps its identity and
        // absorbs the imported keys; the key index still resolves to it.
        expect(p.accounts.where((a) => a.id == 'other_device_acct'), isEmpty);
        final device = p.accounts.singleWhere((a) => a.id == devId);
        expect(device.keys, containsAll({'HDFC:1234', 'HDFC:9999'}));
        expect(device.manualBalance, 45000);
        expect(p.accountForKey('HDFC:1234')!.id, devId);
        expect(p.accountForKey('HDFC:9999')!.id, devId);
      },
    );

    test('an imported account with disjoint keys is still appended', () async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 11,
        'transactions': <dynamic>[],
        'accounts': [
          Account(
            id: 'fresh',
            name: 'ICICI ••5678',
            type: AccountType.bank,
            keys: {'ICICI:5678'},
          ).toJson(),
        ],
      }, replace: false);
      expect(p.accounts.map((a) => a.id), contains('fresh'));
    });
  });

  group('CSV fixes (M5, M6, L12)', () {
    test('suspectedSpam survives a CSV round-trip', () async {
      final p = await loaded();
      await p.addImported([
        parsed(
          ref: 'A',
          rawBody: 'Rs.100 debited at SWIGGY',
          spamSuspect: true,
        ),
      ]);
      expect(p.pendingTransactions.single.suspectedSpam, isTrue);
      final csv = BackupService.buildCsv(p);
      final back = BackupService.txsFromCsv(csv).single;
      expect(back.pending, isTrue);
      expect(back.suspectedSpam, isTrue);
    });

    test(
      'formula-leading cells are neutralised and round-trip losslessly',
      () async {
        final p = await loaded();
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 100,
          note: '=SUM(A1:A9)',
          date: DateTime(2026, 7, 3, 12),
          sender: '@upi handle',
        );
        final csv = BackupService.buildCsv(p);
        // The raw file must not carry a bare leading formula trigger inside
        // its quoted cells.
        expect(csv, isNot(contains('"=SUM')));
        expect(csv, contains('"\'=SUM'));
        final back = BackupService.txsFromCsv(csv).single;
        expect(back.note, '=SUM(A1:A9)');
        expect(back.sender, '@upi handle');
      },
    );

    test('comma-decimal amounts are rejected, not inflated 100x', () {
      const header = 'id,date,type,category,amount';
      String csvOf(String amount) =>
          '$header\r\nr1,2026-07-01T00:00:00.000,expense,food,"$amount"';
      expect(
        () => BackupService.txsFromCsv(csvOf('1234,56')),
        throwsFormatException,
      );
      // Indian grouping still parses (3 digits after the last comma).
      expect(
        BackupService.txsFromCsv(csvOf('1,23,456.78')).single.amount,
        123456.78,
      );
      expect(BackupService.txsFromCsv(csvOf('1,234')).single.amount, 1234);
    });

    test('balanceAfter now strips grouping commas too', () {
      const header = 'id,date,type,category,amount,balanceAfter';
      final txs = BackupService.txsFromCsv(
        '$header\r\nr1,2026-07-01T00:00:00.000,expense,food,100,"1,23,456.78"',
      );
      expect(txs.single.balanceAfter, 123456.78);
    });
  });

  group('split remainder vs budget/group math (M1)', () {
    Future<FinanceProvider> withSplit() async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 500,
        note: '',
        date: DateTime(2026, 7, 5, 21),
        myShare: 125,
      );
      return p;
    }

    SpendBudget budget(Set<String> ids) => SpendBudget(
      id: 'b1',
      name: 'b',
      limit: 1000,
      mode: BudgetMode.include,
      categoryIds: ids,
    );

    test(
      'bar and drill-down agree for a Paid-for-Others include budget',
      () async {
        final p = await withSplit();
        final b = budget({kPaidForOthersCategoryId});
        final viaRows = p.transactions
            .where((t) => p.countsTowardBudget(t, b))
            .fold(0.0, (s, t) => s + t.amount);
        expect(p.budgetSpentFor(b, july), viaRows);
        expect(p.budgetSpentFor(b, july), 0);
      },
    );

    test('display figures keep the remainder', () async {
      final p = await withSplit();
      expect(p.transferOutInMonth(july), 375);
      expect(
        p
            .transfersByCategoryInMonth(july)
            .singleWhere((e) => e.key.id == kPaidForOthersCategoryId)
            .value,
        375,
      );
      // The food budget still counts only the share.
      expect(p.budgetSpentFor(budget({'food'}), july), 125);
    });

    test('a literal paid_for_others row still counts in its budget', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: kPaidForOthersCategoryId,
        amount: 300,
        note: '',
        date: DateTime(2026, 7, 6, 12),
      );
      final b = budget({kPaidForOthersCategoryId});
      expect(p.budgetSpentFor(b, july), 300);
      final viaRows = p.transactions
          .where((t) => p.countsTowardBudget(t, b))
          .fold(0.0, (s, t) => s + t.amount);
      expect(viaRows, 300);
    });
  });

  test('bulk move into a transfer category clears myShare (L3)', () async {
    final p = await loaded();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: '',
      date: DateTime(2026, 7, 5, 21),
      myShare: 125,
    );
    final id = p.transactions.single.id;
    await p.setCategoryForMany({id}, kSavingsTransferCategoryId);
    final moved = p.transactions.single;
    expect(moved.categoryId, kSavingsTransferCategoryId);
    expect(moved.myShare, isNull);
  });

  group('category fallback (L6)', () {
    test('unknown id on an expense row falls back to Other-expense', () {
      expect(
        categoryById('vanished', fallbackType: TxType.expense).id,
        'other_expense',
      );
      expect(categoryById('vanished').id, 'other_income');
      final t = Tx(
        id: 'x',
        type: TxType.expense,
        categoryId: 'vanished',
        amount: 100,
        note: '',
        date: DateTime(2026, 7, 1),
      );
      expect(t.category.id, 'other_expense');
      expect(t.category.type, TxType.expense);
    });

    test('dashboard buckets keep the raw id for deep-links', () async {
      final p = await loaded();
      final custom = await p.addCategory(
        label: 'Gadgets',
        type: TxType.expense,
        icon: Icons.devices_other,
        color: Colors.blue,
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: custom,
        amount: 100,
        note: '',
        date: DateTime(2026, 7, 5, 12),
      );
      // Simulate the corrupt-registry recovery: definitions gone, rows stay.
      setCustomCategories(const []);
      final entry = p
          .expenseByCategory(july)
          .singleWhere((e) => e.value == 100);
      // The definition fell back to Other, but the bucket key must still be
      // the raw id the ledger rows carry — that's what the tap filters on.
      expect(entry.key.id, custom);
      expect(entry.key.label, categoryById('other_expense').label);
    });
  });

  group('SMS parser (L8, L11)', () {
    test(
      'a balance-first body no longer imports the balance as the amount',
      () {
        final r = SmsTxnParser.parse(
          'VM-HDFCBK',
          'Avl Bal Rs.20,146.51 in a/c XX1234. Rs.500 debited at SWIGGY.',
          DateTime(2026, 7, 1, 13),
        );
        expect(r, isNotNull);
        expect(r!.amount, 500);
      },
    );

    test('a body whose only prefixed number is the balance is refused', () {
      final r = SmsTxnParser.parse(
        'VM-HDFCBK',
        '500 debited from a/c XX1234. Avl Bal Rs.20,146.51.',
        DateTime(2026, 7, 1, 13),
      );
      expect(r, isNull);
    });

    test('explain uses the boundary matcher for ignore rules', () {
      final verdict = SmsTxnParser.explain(
        'VM-HDFCBK',
        'Rs.500 debited at SWIGGY. Overdue amount Rs.0.',
        DateTime(2026, 7, 1, 13),
        ignorePhrases: const ['due'],
      );
      // 'due' inside 'Overdue' must not read as an ignore-rule hit — the
      // pipeline's boundary matcher doesn't fire there either.
      expect(verdict, isNot(contains('ignore rule')));
      expect(verdict, contains('Imports as'));
    });
  });

  group('settings backup block (L9)', () {
    test('toBackupMap → applyBackupMap round-trips the preferences', () async {
      final s1 = SettingsProvider();
      await s1.load();
      await s1.setMonthlyBudget(60000);
      await s1.setAutoImport(AutoImportFrequency.daily);
      await s1.setAlertThreshold(90, false);
      final block = s1.toBackupMap();

      SharedPreferences.setMockInitialValues({});
      final s2 = SettingsProvider();
      await s2.load();
      expect(s2.monthlyBudget, 0);
      await s2.applyBackupMap(block);
      expect(s2.monthlyBudget, 60000);
      expect(s2.autoImport, AutoImportFrequency.daily);
      expect(s2.alert90, isFalse);
      expect(s2.alert80, isTrue);

      // And it persisted.
      final s3 = SettingsProvider();
      await s3.load();
      expect(s3.monthlyBudget, 60000);
      expect(s3.autoImport, AutoImportFrequency.daily);
    });

    test('a backup without the block leaves settings untouched', () async {
      final s = SettingsProvider();
      await s.load();
      await s.setMonthlyBudget(500);
      await s.applyBackupMap(const {});
      expect(s.monthlyBudget, 500);
    });
  });

  group('contrast helpers (M16)', () {
    test('onSwatch picks black87 on the mid-band accent presets', () {
      // Coral (default), Rose, Sky, Iris: white measured 2.3–2.8:1; black87
      // reads at 6–7.5:1 on the same swatches.
      expect(onSwatch(const Color(0xFFEA7C69)), Colors.black87); // Coral
      expect(onSwatch(const Color(0xFFFF7CA3)), Colors.black87); // Rose
      expect(onSwatch(const Color(0xFF65B0F6)), Colors.black87); // Sky
      expect(onSwatch(const Color(0xFF9290FE)), Colors.black87); // Iris
      // Dark surfaces still get white.
      expect(onSwatch(const Color(0xFF252836)), Colors.white);
      expect(onSwatch(const Color(0xFFC0264F)), Colors.white);
    });

    test('contrastRatio is symmetric and sane', () {
      expect(contrastRatio(Colors.white, Colors.black), closeTo(21, 0.1));
      expect(
        contrastRatio(Colors.black, Colors.white),
        contrastRatio(Colors.white, Colors.black),
      );
    });
  });
}
