import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The failing store below extends the plugin's in-memory store, which only
// the platform interface exports. shared_preferences brings it in.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// The in-memory store, except that the first write to a key ending in
/// [failKey] reports false, as Android's commit() does when it cannot
/// write.
class _FailOnceStore extends InMemorySharedPreferencesStore {
  _FailOnceStore(this.failKey) : super.empty();

  final String failKey;
  bool _failed = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!_failed && key.endsWith(failKey)) {
      _failed = true;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

/// Data-safety fixes for 2.3.2: a collection that fails to load keeps its
/// bytes, a failure late in load still finishes loading, an unreadable row
/// costs only itself, a restore checks its numbers and lands whole, Delete
/// all data clears in one step, cached lists cannot be changed by a caller,
/// part refunds leave no ₹0.00 row and a bulk Undo restores by one lookup.
/// Every name, amount and id here is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Map<String, dynamic> rowJson(
    String id, {
    String type = 'expense',
    double amount = 120,
    String date = '2026-09-03T10:00:00.000',
  }) => {
    'id': id,
    'type': type,
    'categoryId': type == 'expense' ? 'food' : 'salary',
    'amount': amount,
    'note': 'Invented $id',
    'date': date,
    'source': 'manual',
  };

  Future<void> addRow(
    FinanceProvider p, {
    double amount = 250,
    DateTime? date,
    String note = 'Zeta Cafe',
  }) => p.addTransaction(
    type: TxType.expense,
    categoryId: 'food',
    amount: amount,
    note: note,
    date: date ?? DateTime(2026, 9, 10, 12),
  );

  group('a collection that fails to load', () {
    test('keeps its stored bytes under a side key through later saves', () async {
      const accountsRaw = '[{"id": "acc_1", "name": broken';
      const rulesRaw = 'not json at all';
      const budgetsRaw = '{"budgets": oops';
      SharedPreferences.setMockInitialValues({
        'accounts_v1': accountsRaw,
        'classifier_rules_v1': rulesRaw,
        'spend_budgets_v1': budgetsRaw,
      });
      final p = await loaded();
      expect(p.loadWarnings, containsAll(['accounts', 'rules', 'budgets']));

      await p.addAccount(name: 'Theta Bank', type: AccountType.bank);
      await p.retryPersist();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accounts_v1'), isNot(accountsRaw));
      expect(prefs.getString('accounts_v1_corrupt'), accountsRaw);
      expect(prefs.getString('classifier_rules_v1'), isNot(rulesRaw));
      expect(prefs.getString('classifier_rules_v1_corrupt'), rulesRaw);
      expect(prefs.getString('spend_budgets_v1'), isNot(budgetsRaw));
      expect(prefs.getString('spend_budgets_v1_corrupt'), budgetsRaw);
    });
  });

  group('a failure late in load', () {
    test('still finishes loading, warns, and runs the later steps', () async {
      SharedPreferences.setMockInitialValues({
        // A wrong-typed value: reading it as a list throws.
        'refund_suggest_ids_v1': 'not a list',
        'atm_auto_move_v1': true,
      });
      final p = FinanceProvider();
      await p.load();
      expect(p.loaded, isTrue);
      expect(p.loadWarnings, contains('setup'));
      // Read in a step after the one that threw.
      expect(p.atmAutoMove, isTrue);
    });
  });

  group('one unreadable transaction row', () {
    test('is left out; the rest load and the bytes are kept', () async {
      final raw = jsonEncode([
        rowJson('tx_a'),
        rowJson('tx_b', type: 'neither'),
        rowJson('tx_c', amount: 75),
      ]);
      SharedPreferences.setMockInitialValues({'transactions_v1': raw});
      final p = await loaded();
      expect(p.transactions.map((t) => t.id), unorderedEquals(['tx_a', 'tx_c']));
      expect(p.loadWarnings, ['some transactions']);

      await addRow(p);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('transactions_v1_corrupt'), raw);
      expect(prefs.getString('transactions_v1'), isNot(raw));
    });

    test('a row with a wrong-typed field cannot be read', () {
      // Read with a default, each would change money: an unreviewed row
      // counting, a split counting in full, a transfer leg losing its
      // category, an alert falling out of the duplicate check.
      for (final (field, value) in [
        ('pending', 'true'),
        ('myShare', '250'),
        ('source', 'SMS'),
        ('categoryId', null),
      ]) {
        final json = rowJson('tx_w');
        if (value == null) {
          json.remove(field);
        } else {
          json[field] = value;
        }
        expect(() => Tx.fromJson(json), throwsA(anything), reason: field);
      }
    });

    test('a stored row with "pending":"true" is left out, not confirmed',
        () async {
      final raw = jsonEncode([
        rowJson('tx_a'),
        {...rowJson('tx_p', amount: 640), 'pending': 'true'},
      ]);
      SharedPreferences.setMockInitialValues({'transactions_v1': raw});
      final p = await loaded();
      expect(p.transactions.map((t) => t.id), ['tx_a']);
      expect(p.pendingTransactions, isEmpty);
      expect(p.loadWarnings, ['some transactions']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('transactions_v1_corrupt'), raw);
    });

    test('a backup file with a "pending":"true" row is rejected', () async {
      final p = await loaded();
      await addRow(p, amount: 310);
      final data = p.exportData();
      (data['transactions'] as List).add({
        ...rowJson('tx_q', amount: 55),
        'pending': 'true',
      });
      await expectLater(p.importData(data, replace: true), throwsA(anything));
      await expectLater(p.importData(data, replace: false), throwsA(anything));
      expect(p.transactions.single.amount, 310);
    });

    test('load saves nothing over a ledger that loaded in part', () async {
      // The pair's incoming leg cannot be read: the outgoing leg only
      // looks orphaned, and the tag only the unread row carries only looks
      // unused.
      final raw = jsonEncode([
        {
          ...rowJson('tx_out', amount: 5000),
          'categoryId': kTransferOutCategoryId,
          'pairId': 'pair_7',
        },
        {
          ...rowJson('tx_in', type: 'income', amount: 5000),
          'categoryId': kTransferInCategoryId,
          'pairId': 'pair_7',
          'tags': ['Goa trip'],
          'amount': 'five thousand',
        },
        rowJson('tx_c', amount: 80),
      ]);
      final colours = jsonEncode({'goa trip': 0xFF2E7D32});
      SharedPreferences.setMockInitialValues({
        'transactions_v1': raw,
        'tag_colors_v1': colours,
      });
      final p = await loaded();
      expect(p.loadWarnings, ['some transactions']);
      final out = p.transactions.firstWhere((t) => t.id == 'tx_out');
      expect(out.pairId, 'pair_7');
      expect(p.tagColor('Goa trip'), isNotNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('transactions_v1'), raw);
      expect(prefs.getString('tag_colors_v1'), colours);
      // The one-time passes wait for a ledger that loads whole.
      expect(prefs.getBool('imports_count_first_v1'), isNull);
      expect(prefs.getBool('debit_cards_detected_v1'), isNull);
      expect(prefs.getBool('refunds_linked_v1'), isNull);
    });

    test('a budget that cannot be read is left out; the rest load', () async {
      final raw = jsonEncode([
        {'id': 'bud_1', 'name': 'Food', 'limit': 4000, 'mode': 'include'},
        {'name': 'No id', 'limit': 900},
      ]);
      SharedPreferences.setMockInitialValues({'spend_budgets_v1': raw});
      final p = await loaded();
      expect(p.budgets.map((b) => b.id), ['bud_1']);
      expect(p.loadWarnings, ['some budgets']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('spend_budgets_v1_corrupt'), raw);
    });

    test('a backup file with an unreadable row is still rejected', () async {
      final p = await loaded();
      await addRow(p, amount: 310);
      final data = p.exportData();
      (data['transactions'] as List).add(rowJson('tx_x', type: 'neither'));
      await expectLater(p.importData(data, replace: true), throwsA(anything));
      expect(p.transactions.single.amount, 310);
    });

    test('a replace restore clears the some-transactions warning', () async {
      final exporter = await loaded();
      await addRow(exporter, amount: 99);
      final data = exporter.exportData();

      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          rowJson('tx_a'),
          rowJson('tx_b', type: 'neither'),
        ]),
      });
      final p = await loaded();
      expect(p.loadWarnings, ['some transactions']);
      await p.importData(data, replace: true);
      expect(p.loadWarnings, isEmpty);
    });
  });

  group('a backup file', () {
    test('jsonDecode reads 1e999 as Infinity', () {
      final v = (jsonDecode('{"v": 1e999}') as Map)['v'];
      expect(v, isA<double>());
      expect((v as double).isInfinite, isTrue);
    });

    Future<(FinanceProvider, Map<String, dynamic>)> withBackup() async {
      final p = await loaded();
      await addRow(p, amount: 410);
      await p.addAccount(
        name: 'Iota Card',
        type: AccountType.creditCard,
        creditLimit: 50000,
      );
      final data = p.exportData();
      return (p, data);
    }

    test('with a non-finite number is rejected before anything changes', () async {
      final (p, data) = await withBackup();
      final text = jsonEncode(data).replaceFirst(
        RegExp(r'"creditLimit":[0-9.]+'),
        '"creditLimit":1e999',
      );
      final bad = jsonDecode(text) as Map<String, dynamic>;
      expect(((bad['accounts'] as List).single as Map)['creditLimit'], double.infinity);
      (bad['transactions'] as List).clear();
      await expectLater(
        p.importData(bad, replace: true),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('accounts[0].creditLimit'),
          ),
        ),
      );
      expect(p.transactions.single.amount, 410);
      expect(p.persistFailed, isFalse);
    });

    test('with an amount above the ceiling is rejected', () async {
      final (p, data) = await withBackup();
      data['budgets'] = [
        SpendBudget(
          id: 'bud_9',
          name: 'Huge',
          limit: SmsTxnParser.maxAmount * 5,
          mode: BudgetMode.exclude,
          categoryIds: const {},
        ).toJson(),
      ];
      await expectLater(
        p.importData(data, replace: true),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('budgets[0].limit'),
          ),
        ),
      );
      expect(p.budgets, isEmpty);
    });

    test('with a negative set balance restores', () async {
      final (p, data) = await withBackup();
      ((data['accounts'] as List).single as Map)['manualBalance'] = -1250.5;
      await p.importData(data, replace: true);
      expect(p.accounts.single.manualBalance, -1250.5);
    });

    test('from a newer format is rejected', () async {
      final (p, data) = await withBackup();
      data['version'] = (data['version'] as int) + 1;
      (data['transactions'] as List).clear();
      await expectLater(
        p.importData(data, replace: true),
        throwsA(isA<FormatException>()),
      );
      expect(p.transactions, hasLength(1));
    });

    test('keeps the first of duplicate transaction and account ids', () async {
      final (p, data) = await withBackup();
      final txs = data['transactions'] as List;
      txs.add(<String, dynamic>{
        ...(txs.single as Map<String, dynamic>),
        'amount': 999.0,
      });
      final accounts = data['accounts'] as List;
      accounts.add(<String, dynamic>{
        ...(accounts.single as Map<String, dynamic>),
        'name': 'Second copy',
      });

      await p.importData(data, replace: true);
      expect(p.transactions.single.amount, 410);
      expect(p.accounts.single.name, 'Iota Card');

      SharedPreferences.setMockInitialValues({});
      final fresh = await loaded();
      final added = await fresh.importData(data, replace: false);
      expect(added, 1);
      expect(fresh.transactions.single.amount, 410);
      expect(fresh.accounts.single.name, 'Iota Card');
    });

    test('a replace whose save fails puts the data from before back', () async {
      final source = await loaded();
      await addRow(source, amount: 777, note: 'From the file');
      await source.addAccount(name: 'File Bank', type: AccountType.bank);
      final data = source.exportData();

      SharedPreferences.setMockInitialValues({});
      final p = await loaded();
      await addRow(p, amount: 120, note: 'On the device');
      await p.addAccount(name: 'Device Bank', type: AccountType.bank);
      final prefs = await SharedPreferences.getInstance();
      final txBefore = prefs.getString('transactions_v1');
      final accountsBefore = prefs.getString('accounts_v1');
      final rulesBefore = prefs.getString('classifier_rules_v1');

      // A fresh platform store: what it holds afterwards is only what was
      // really written. The plugin's own cache takes a value even when its
      // write fails, so it proves nothing here.
      final store = _FailOnceStore('accounts_v1');
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));

      await expectLater(
        p.importData(data, replace: true),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Could not save the restored data'),
          ),
        ),
      );
      // Memory holds the device's data again.
      expect(p.transactions.single.note, 'On the device');
      expect(p.accounts.single.name, 'Device Bank');
      expect(p.persistFailed, isFalse);
      // So does the platform store: the ledger and rules written before the
      // failed account write, and the accounts, hold the device's data.
      final stored = await store.getAll();
      expect(stored['flutter.transactions_v1'], txBefore);
      expect(stored['flutter.accounts_v1'], accountsBefore);
      expect(stored['flutter.classifier_rules_v1'], rulesBefore);
    });

    test('a failed replace keeps an edit whose save was still encoding',
        () async {
      // Ledgers of 800 rows or more encode on another isolate, so the
      // edit's save is still in flight when the restore starts.
      FinanceProvider.useIsolateCodec = true;
      addTearDown(() => FinanceProvider.useIsolateCodec = false);
      SharedPreferences.setMockInitialValues({
        'transactions_v1': jsonEncode([
          for (var i = 0; i < 850; i++)
            rowJson('dev_$i', amount: 10.0 + i % 50),
        ]),
      });
      final p = await loaded();
      final data = <String, dynamic>{
        'app': 'expense_tracker',
        'version': 35,
        'transactions': [
          for (var i = 0; i < 850; i++)
            rowJson('file_$i', amount: 20.0 + i % 40),
        ],
        'accounts': <Object>[],
      };
      final store = _FailOnceStore('accounts_v1');
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));

      final edit = addRow(p, amount: 432, note: 'Edited just before');
      await expectLater(
        p.importData(data, replace: true),
        throwsA(isA<FormatException>()),
      );
      await edit;
      expect(p.transactionCount, 851);
      final stored = await store.getAll();
      final rows = jsonDecode(stored['flutter.transactions_v1']! as String)
          as List;
      expect(rows, hasLength(851));
      expect(
        rows.any((r) => (r as Map)['note'] == 'Edited just before'),
        isTrue,
      );
      expect(p.persistFailed, isFalse);
    });

    test('a replace removes the copies of what the file supplied', () async {
      final source = await loaded();
      await addRow(source, amount: 515);
      final data = source.exportData()..remove('budgets');

      SharedPreferences.setMockInitialValues({
        'accounts_v1': 'not json',
        'spend_budgets_v1': 'not json either',
      });
      final p = await loaded();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('accounts_v1_corrupt'), 'not json');
      await p.importData(data, replace: true);
      expect(prefs.containsKey('accounts_v1_corrupt'), isFalse);
      // The file had no budgets: that copy still stands.
      expect(prefs.getString('spend_budgets_v1_corrupt'), 'not json either');
    });
  });

  group('Delete all data', () {
    test('clears and notifies before its first await', () async {
      final p = await loaded();
      await addRow(p);
      await p.addAccount(name: 'Kappa Bank', type: AccountType.bank);
      expect(p.transactions, hasLength(1)); // fills the cache
      var notified = 0;
      p.addListener(() => notified++);

      final done = p.clearAll();
      expect(notified, 1);
      expect(p.transactions, isEmpty);
      expect(p.accounts, isEmpty);
      await done;
      expect(p.transactions, isEmpty);
    });

    test('still removes the alert markers', () async {
      SharedPreferences.setMockInitialValues({
        'budget_alert_fired_bud_1_2026_9': 1,
        'atm_auto_move_v1': true,
      });
      final p = await loaded();
      await p.clearAll();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('budget_alert_fired_bud_1_2026_9'), isFalse);
      expect(prefs.containsKey('atm_auto_move_v1'), isFalse);
      expect(p.atmAutoMove, isFalse);
    });

    test('removes the copies of what it clears', () async {
      SharedPreferences.setMockInitialValues({
        'transactions_v1_corrupt': '[{"smsBody": "Invented alert text"}',
        'accounts_v1_corrupt': '[{"name": "Mu Bank"',
        'spend_budgets_v1_corrupt': '[{"name": "Snacks"',
        'classifier_rules_v1_corrupt': '[{"pattern": "nu"',
      });
      final p = await loaded();
      final prefs = await SharedPreferences.getInstance();
      await p.clearAll();
      expect(prefs.containsKey('transactions_v1_corrupt'), isFalse);
      expect(prefs.containsKey('accounts_v1_corrupt'), isFalse);
      // Rules and budgets are kept, and so are their copies.
      expect(prefs.containsKey('spend_budgets_v1_corrupt'), isTrue);
      expect(prefs.containsKey('classifier_rules_v1_corrupt'), isTrue);

      await p.clearAll(includeConfig: true);
      expect(prefs.containsKey('spend_budgets_v1_corrupt'), isFalse);
      expect(prefs.containsKey('classifier_rules_v1_corrupt'), isFalse);
    });
  });

  group('cached lists', () {
    test('cannot be changed by a caller and keep their identity', () async {
      final p = await loaded();
      await addRow(p, amount: 300);
      final sep = DateTime(2026, 9);
      final t = p.transactions.single;
      expect(() => p.transactions.add(t), throwsUnsupportedError);
      expect(() => p.pendingTransactions.add(t), throwsUnsupportedError);
      expect(() => p.countedTransactions.clear(), throwsUnsupportedError);
      expect(() => p.confirmedInMonth(sep).add(t), throwsUnsupportedError);
      expect(
        () => p.expenseByCategory(sep).sort((a, b) => 0),
        throwsUnsupportedError,
      );
      expect(
        () => p.categoryGrossRecent()['food'] = 1,
        throwsUnsupportedError,
      );
      expect(() => p.avgExpenseByWeekday()[0] = 1, throwsUnsupportedError);
      expect(identical(p.transactions, p.transactions), isTrue);
      expect(identical(p.confirmedInMonth(sep), p.confirmedInMonth(sep)), isTrue);
      expect(identical(p.expenseByCategory(sep), p.expenseByCategory(sep)), isTrue);
    });
  });

  group('part refunds', () {
    test('a purchase refunded as 0.70, 0.20 and 0.10 leaves no row', () async {
      final p = await loaded();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'shopping',
        amount: 1.00,
        note: 'Lambda Store',
        date: DateTime(2026, 9, 25, 18),
      );
      final buy = p.transactions.single.id;
      for (final (day, amount) in [(4, 0.70), (5, 0.20), (6, 0.10)]) {
        final id = await p.addTransaction(
          type: TxType.income,
          categoryId: 'other_income',
          amount: amount,
          note: 'Lambda Store',
          date: DateTime(2026, 10, day, 11),
        );
        expect(await p.linkRefund(id, buy), isTrue);
      }
      final sep = DateTime(2026, 9);
      expect(p.refundedFor(p.transactions.firstWhere((t) => t.id == buy)), lessThan(1.0));
      expect(p.expenseByCategory(sep), isEmpty);
      expect(p.expenseByDayInMonth(sep).containsKey(25), isFalse);
      expect(p.spendOnDay(DateTime(2026, 9, 25)).count, 0);
    });
  });

  group('restoring edited rows', () {
    test('puts many rows back by id, deleted ones too', () async {
      final p = await loaded();
      final base = DateTime(2026, 8, 1, 9);
      for (var i = 0; i < 40; i++) {
        await addRow(p, amount: 10.0 + i, date: base.add(Duration(hours: i)), note: 'Row $i');
      }
      final before = [...p.transactions];
      final edited = [for (final t in before) t.copyWith(note: 'Edited ${t.note}')];
      await p.restoreEditedTransactions(edited);
      expect(p.transactions.map((t) => t.note), edited.map((t) => t.note));

      final gone = before.take(5).map((t) => t.id).toList();
      await p.deleteTransactions(gone);
      await p.restoreEditedTransactions(before, reAddMissing: true);
      expect(p.transactions.map((t) => (t.id, t.note)), before.map((t) => (t.id, t.note)));
    });

    test('a row deleted since stays deleted without reAddMissing', () async {
      final p = await loaded();
      await addRow(p, amount: 11, note: 'Keep');
      await addRow(p, amount: 12, note: 'Drop', date: DateTime(2026, 9, 11));
      final before = [...p.transactions];
      await p.deleteTransactions([before.firstWhere((t) => t.note == 'Drop').id]);
      await p.restoreEditedTransactions(before);
      expect(p.transactions.map((t) => t.note), ['Keep']);
    });
  });
}
