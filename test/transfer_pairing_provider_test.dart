import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/savings_goal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final d = DateTime(2026, 7, 10, 10);

  Tx row(
    String id,
    TxType type,
    double amount, {
    required String acct,
    DateTime? date,
    bool pending = true,
    String? categoryId,
  }) => Tx(
    id: id,
    type: type,
    categoryId:
        categoryId ??
        (type == TxType.expense ? 'other_expense' : 'other_income'),
    amount: amount,
    note: '',
    smsBody: 'Rs.$amount ${type == TxType.expense ? 'debited' : 'credited'}',
    date: date ?? d,
    source: TxSource.sms,
    sender: 'VM-HDFCBK',
    acctKey: acct,
    pending: pending,
  );

  /// Bank (HDFC:1111), FD savings (HDFC:2222), card (HDFC:3010); a bank
  /// debit + savings credit of ₹5,000, both pending.
  Future<FinanceProvider> seeded({List<Tx>? rows}) async {
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        for (final t
            in rows ??
                [
                  row('out', TxType.expense, 5000, acct: 'HDFC:1111'),
                  row('in', TxType.income, 5000, acct: 'HDFC:2222'),
                ])
          t.toJson(),
      ]),
    });
    final p = FinanceProvider();
    await p.load();
    // Accounts are created explicitly: a bank, an FD (savings) and a card,
    // each owning one key, so the pair kinds resolve.
    Future<void> account(String name, AccountType type, String key) async {
      final existing = p.accountForKey(key);
      if (existing != null) {
        await p.setAccountType(existing.id, type);
        return;
      }
      final id = await p.addAccount(name: name, type: type);
      expect(await p.addAccountKey(id, key), isTrue);
    }

    await account('HDFC Bank', AccountType.bank, 'HDFC:1111');
    await account('FD', AccountType.savings, 'HDFC:2222');
    await account('Card', AccountType.creditCard, 'HDFC:3010');
    return p;
  }

  test(
    'pairing links, re-categorises, confirms and fixes the double count',
    () async {
      final p = await seeded();
      // Before: the pending legs are not in totals yet; confirm to see the
      // double count the pairing exists to remove.
      await p.confirmTransaction('out');
      await p.confirmTransaction('in');
      final month = DateTime(2026, 7);
      expect(p.expenseInMonth(month), 5000);
      expect(p.incomeInMonth(month), 5000);

      final pairId = await p.pairTransactions('out', 'in');
      expect(pairId, isNotNull);
      final out = p.transactions.singleWhere((t) => t.id == 'out');
      final inn = p.transactions.singleWhere((t) => t.id == 'in');
      expect(out.pairId, pairId);
      expect(inn.pairId, pairId);
      expect(
        out.categoryId,
        kSavingsTransferCategoryId,
        reason: 'receiver is savings',
      );
      expect(inn.categoryId, 'transfer_in');
      expect(out.userCategorized, isTrue);
      expect(out.pending, isFalse);
      expect(p.pairPartnerOf(out)?.id, 'in');

      expect(p.expenseInMonth(month), 0);
      expect(p.incomeInMonth(month), 0);
      expect(p.savingsOutflowInMonth(month), 5000);

      // Balances: bank −5000, savings +5000 (the paired leg is NOT inverted).
      final bank = p.accountForKey('HDFC:1111')!;
      final fd = p.accountForKey('HDFC:2222')!;
      expect(p.accountBalance(bank), -5000);
      expect(p.accountBalance(fd), 5000);
      expect(signedForSavings(inn), 5000);

      // Survives reload.
      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.transactions.where((t) => t.pairId == pairId), hasLength(2));
    },
  );

  test(
    'legacy unpaired "To savings" row still inverts on the savings account',
    () async {
      final p = await seeded(
        rows: [
          row(
            'legacy',
            TxType.expense,
            3000,
            acct: 'HDFC:2222',
            pending: false,
            categoryId: kSavingsTransferCategoryId,
          ),
        ],
      );
      final fd = p.accountForKey('HDFC:2222')!;
      expect(p.accountBalance(fd), 3000);
      expect(signedForSavings(p.transactions.single), 3000);
    },
  );

  test(
    'card receiver → card_bill / card_payment and outstanding drops',
    () async {
      final p = await seeded(
        rows: [
          row('out', TxType.expense, 2000, acct: 'HDFC:1111'),
          row('in', TxType.income, 2000, acct: 'HDFC:3010'),
        ],
      );
      await p.pairTransactions('out', 'in');
      final out = p.transactions.singleWhere((t) => t.id == 'out');
      final inn = p.transactions.singleWhere((t) => t.id == 'in');
      expect(out.categoryId, 'card_bill');
      expect(inn.categoryId, 'card_payment');
      // The bank leg is money out of the bank; neither leg is spend.
      expect(p.accountBalance(p.accountForKey('HDFC:1111')!), -2000);
      expect(p.expenseInMonth(DateTime(2026, 7)), 0);
      expect(p.incomeInMonth(DateTime(2026, 7)), 0);
    },
  );

  test('refuses same-typed or already-paired rows', () async {
    final p = await seeded(
      rows: [
        row('a', TxType.expense, 100, acct: 'HDFC:1111'),
        row('b', TxType.expense, 100, acct: 'HDFC:2222'),
        row('c', TxType.income, 100, acct: 'HDFC:2222'),
      ],
    );
    expect(await p.pairTransactions('a', 'b'), isNull);
    expect(await p.pairTransactions('a', 'c'), isNotNull);
    expect(await p.pairTransactions('b', 'c'), isNull, reason: 'c is paired');
    expect(await p.pairTransactions('a', 'zzz'), isNull);
  });

  test('unpair clears both and keeps the transfer categories', () async {
    final p = await seeded();
    final pairId = (await p.pairTransactions('out', 'in'))!;
    await p.unpair(pairId);
    expect(p.transactions.every((t) => t.pairId == null), isTrue);
    expect(
      p.transactions.singleWhere((t) => t.id == 'out').categoryId,
      kSavingsTransferCategoryId,
    );
  });

  test(
    'deleting a leg unlinks the partner and returns its snapshot for Undo',
    () async {
      final p = await seeded();
      final pairId = (await p.pairTransactions('out', 'in'))!;
      final out = p.transactions.singleWhere((t) => t.id == 'out');
      final partner = await p.deleteTransaction('out');
      expect(partner?.id, 'in');
      expect(partner?.pairId, pairId, reason: 'pre-unlink copy');
      expect(p.transactions.single.pairId, isNull);

      await p.restoreEditedTransactions([out, partner!]);
      expect(p.transactions.where((t) => t.pairId == pairId), hasLength(2));

      // Unpaired rows report no partner.
      expect(await p.deleteTransaction('nope'), isNull);
    },
  );

  test('moving a leg to a non-transfer category dissolves the pair', () async {
    final p = await seeded();
    await p.pairTransactions('out', 'in');
    final out = p.transactions.singleWhere((t) => t.id == 'out');
    await p.updateTransaction(out.copyWith(categoryId: 'food'));
    expect(p.transactions.every((t) => t.pairId == null), isTrue);

    // Same via bulk category.
    await p.pairTransactions('out', 'in');
    await p.setCategoryForMany({'in'}, 'salary');
    expect(p.transactions.every((t) => t.pairId == null), isTrue);
  });

  test('dangling pairIds are cleared on load and import', () async {
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        row(
          'lonely',
          TxType.expense,
          10,
          acct: 'HDFC:1111',
          pending: false,
          categoryId: 'transfer_out',
        ).copyWith(pairId: 'pair_x').toJson(),
      ]),
    });
    final p = FinanceProvider();
    await p.load();
    expect(p.transactions.single.pairId, isNull);

    final data = p.exportData();
    (data['transactions'] as List).add(
      row(
        'ghost',
        TxType.income,
        10,
        acct: 'HDFC:2222',
        pending: false,
        categoryId: 'transfer_in',
      ).copyWith(pairId: 'pair_y').toJson(),
    );
    await p.importData(data, replace: true);
    expect(p.transactions.every((t) => t.pairId == null), isTrue);
  });

  test('pairId round-trips through JSON backup and CSV', () async {
    final p = await seeded();
    final pairId = (await p.pairTransactions('out', 'in'))!;

    final json = jsonEncode(p.exportData());
    SharedPreferences.setMockInitialValues({});
    final viaJson = FinanceProvider();
    await viaJson.load();
    await viaJson.importData(
      jsonDecode(json) as Map<String, dynamic>,
      replace: true,
    );
    expect(viaJson.transactions.where((t) => t.pairId == pairId), hasLength(2));

    final csv = BackupService.buildCsv(p);
    expect(csv.split('\r\n').first, endsWith(',pairId'));
    final rows = BackupService.txsFromCsv(csv);
    expect(rows.where((t) => t.pairId == pairId), hasLength(2));
  });

  test(
    'settings remember dismissed suggestions, including via backup',
    () async {
      final s = SettingsProvider();
      await s.load();
      await s.dismissPairSuggestion('a|b');
      await s.dismissPairSuggestion('a|b');
      expect(s.dismissedPairSuggestions, {'a|b'});

      final s2 = SettingsProvider();
      await s2.load();
      expect(s2.dismissedPairSuggestions, {'a|b'}, reason: 'persisted');

      final map = s2.toBackupMap();
      expect(map['dismissedPairs'], ['a|b']);
      SharedPreferences.setMockInitialValues({});
      final s3 = SettingsProvider();
      await s3.load();
      await s3.applyBackupMap(map);
      expect(s3.dismissedPairSuggestions, {'a|b'});
    },
  );
}
