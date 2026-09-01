import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/import_rule.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';

/// Backups v8 carry classifier + import rules. Before this, a restore on a
/// fresh device silently lost every user rule — and because built-ins
/// reseed, the Classifiers page looked populated and the loss was invisible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  void freshDevice() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  }

  test(
    'export carries rules and import rules; replace-import restores them',
    () async {
      final p = await loaded();
      await p.addRule('chai kings', 'food');
      await p.addImportRule('lucky draw', ImportRuleKind.spamSignal);
      final data = p.exportData();
      expect(data['version'], greaterThanOrEqualTo(8));

      freshDevice();
      final p2 = await loaded();
      await p2.importData(data, replace: true);
      expect(p2.rules.any((r) => r.pattern == 'chai kings'), isTrue);
      expect(
        p2.importRules.any(
          (r) =>
              r.pattern == 'lucky draw' && r.kind == ImportRuleKind.spamSignal,
        ),
        isTrue,
      );

      // And the restore survives a reload.
      final p3 = await loaded();
      expect(p3.rules.any((r) => r.pattern == 'chai kings'), isTrue);
    },
  );

  test(
    'merge keeps device rules, adds file-only ones, device priority wins',
    () async {
      final exporter = await loaded();
      await exporter.addRule('from the file', 'transport');
      final data = exporter.exportData();
      final expectedBuiltins = exporter.rules.where((r) => r.isBuiltIn).length;

      freshDevice();
      final device = await loaded();
      await device.addRule('on the device', 'food');
      await device.importData(data, replace: false);

      final userRules = device.rules.where((r) => !r.isBuiltIn).toList();
      expect(userRules.map((r) => r.pattern), [
        'on the device', // device user rules keep top match priority
        'from the file',
      ]);
      // Built-ins were identical on both sides — merged by id, no duplicates.
      expect(device.rules.where((r) => r.isBuiltIn).length, expectedBuiltins);
    },
  );

  test(
    'a pre-v8 payload (no rules keys) leaves device rules untouched',
    () async {
      final p = await loaded();
      await p.addRule('keep me', 'food');
      final data = p.exportData()
        ..remove('rules')
        ..remove('importRules')
        ..['version'] = 7;

      await p.importData(data, replace: true);
      expect(p.rules.any((r) => r.pattern == 'keep me'), isTrue);
      expect(p.importRules, isNotEmpty);
    },
  );

  group('backups exclude SMS bodies', () {
    Map<String, dynamic> smsRow({
      required String id,
      String smsBody = '',
      String categoryId = 'other_expense',
    }) => {
      'id': id,
      'type': 'expense',
      'categoryId': categoryId,
      'amount': 100,
      'note': '',
      if (smsBody.isNotEmpty) 'smsBody': smsBody,
      'date': '2026-07-01T10:00:00.000',
      'source': 'sms',
      'sender': 'VM-HDFCBK',
      'externalRef': 'REF123',
    };

    test('exportData drops smsBody but keeps every other field', () async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 8,
        'transactions': [
          smsRow(id: 's1', smsBody: 'Rs.100 debited at Chai Kings'),
        ],
      }, replace: true);
      // On-device the body is intact…
      expect(p.transactions.single.smsBody, isNotEmpty);

      // …but the export has no smsBody key, while the fields a restore
      // depends on all survive.
      final row =
          (p.exportData()['transactions'] as List).single
              as Map<String, dynamic>;
      expect(row.containsKey('smsBody'), isFalse);
      expect(row['sender'], 'VM-HDFCBK');
      expect(row['externalRef'], 'REF123');
      expect(row['amount'], 100);

      // And the stripped payload restores cleanly.
      freshDevice();
      final p2 = await loaded();
      final added = await p2.importData(p.exportData(), replace: true);
      expect(added, 1);
      expect(p2.transactions.single.smsBody, isEmpty);
      expect(p2.transactions.single.note, isEmpty); // no body-in-note leak
    });

    test(
      'new rules skip body-less restored rows instead of matching sender',
      () async {
        final p = await loaded();
        await p.importData({
          'app': 'expense_tracker',
          'version': 8,
          'transactions': [
            // Restored (body-less) row whose SENDER contains "hdfc".
            smsRow(id: 'restored'),
            // Body-carrying row that genuinely mentions the pattern.
            smsRow(id: 'fresh', smsBody: 'Paid via HDFC card at store'),
          ],
        }, replace: true);

        final applied = await p.addRule('hdfc', 'shopping');

        final restored = p.transactions.singleWhere((t) => t.id == 'restored');
        final fresh = p.transactions.singleWhere((t) => t.id == 'fresh');
        expect(applied.reclassified, 1);
        expect(fresh.categoryId, 'shopping');
        // The sender "VM-HDFCBK" must NOT have been used as match text.
        expect(restored.categoryId, 'other_expense');
      },
    );
  });

  group('importData sanitization (v9)', () {
    test('a wrong-typed row is coerced to its category type', () async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 9,
        'transactions': [
          {
            'id': 'bad1',
            'type': 'income', // food is an expense category
            'categoryId': 'food',
            'amount': 100,
            'note': '',
            'date': '2026-07-01T10:00:00.000',
          },
        ],
      }, replace: true);
      expect(p.transactions.single.type, TxType.expense);
    });

    test('an unknown category id remaps to the row-type Other', () async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 9,
        'transactions': [
          {
            'id': 'bad2',
            'type': 'expense',
            'categoryId': 'no_such_category',
            'amount': 100,
            'note': '',
            'date': '2026-07-01T10:00:00.000',
          },
        ],
      }, replace: true);
      expect(p.transactions.single.categoryId, 'other_expense');
    });

    test(
      'rows referencing the backup\'s own custom categories survive',
      () async {
        final p = await loaded();
        final catId = await p.addCategory(
          label: 'Gym',
          type: TxType.expense,
          icon: Icons.fitness_center,
          color: Colors.teal,
        );
        await p.addTransaction(
          type: TxType.expense,
          categoryId: catId,
          amount: 500,
          note: 'membership',
          date: DateTime(2026, 7, 1),
        );
        final data = p.exportData();

        freshDevice();
        final p2 = await loaded();
        await p2.importData(data, replace: true);
        // Sanitize runs AFTER the registry reflects the backup — the custom
        // category must not be remapped to "Other".
        expect(p2.transactions.single.categoryId, catId);
      },
    );
  });

  group('acctKinds card-ness round-trip (v9)', () {
    test('export records card kind; orphan-key restore keeps it', () async {
      final p = await loaded();
      // A card row whose account was deleted before export: only the
      // acctKinds hint can tell the restore it was a card.
      await p.importData({
        'app': 'expense_tracker',
        'version': 9,
        'transactions': [
          {
            'id': 'card1',
            'type': 'expense',
            'categoryId': 'other_expense',
            'amount': 1000,
            'note': '',
            'date': '2026-07-01T10:00:00.000',
            'source': 'sms',
            'sender': 'VM-HDFCBK',
            'acctKey': 'HDFC:4412',
          },
        ],
        'acctKinds': {'HDFC:4412': 'card'},
      }, replace: true);

      expect(p.accounts.single.type, AccountType.creditCard);
      // And a fresh export re-emits the hint from the owning account.
      expect(p.exportData()['acctKinds'], {'HDFC:4412': 'card'});
    });

    test('without a hint or body, an orphan key defaults to bank', () async {
      final p = await loaded();
      await p.importData({
        'app': 'expense_tracker',
        'version': 8, // pre-acctKinds backup
        'transactions': [
          {
            'id': 'bank1',
            'type': 'expense',
            'categoryId': 'other_expense',
            'amount': 1000,
            'note': '',
            'date': '2026-07-01T10:00:00.000',
            'source': 'sms',
            'sender': 'VM-ICICIB',
            'acctKey': 'ICICI:9001',
          },
        ],
      }, replace: true);
      expect(p.accounts.single.type, AccountType.bank);
    });
  });

  group('CSV import hardening', () {
    test('NaN / Infinity amounts are rejected as invalid rows', () {
      // NaN parsed, passed `<= 0` (false), and then poisoned every
      // jsonEncode persist for the rest of the session.
      const nan = 'date,type,amount\n2026-08-01T00:00:00,expense,NaN';
      expect(() => BackupService.txsFromCsv(nan), throwsFormatException);
      const inf = 'date,type,amount\n2026-08-01T00:00:00,expense,Infinity';
      expect(() => BackupService.txsFromCsv(inf), throwsFormatException);
    });

    test('duplicate ids within one file are uniquified', () {
      const csv =
          'id,date,type,amount\n'
          'A1,2026-08-01T00:00:00,expense,10\n'
          'A1,2026-08-02T00:00:00,expense,20';
      final txs = BackupService.txsFromCsv(csv);
      expect(txs[0].id, 'A1');
      // deleteTransaction removes by id — a shared id would delete both.
      expect(txs[1].id, isNot('A1'));
    });

    test('fallback ids differ across two imports of the same file', () async {
      const csv = 'date,type,amount\n2026-08-01T00:00:00,expense,10';
      final first = BackupService.txsFromCsv(csv).single.id;
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = BackupService.txsFromCsv(csv).single.id;
      // The old txDate-derived id collided across files, so re-importing a
      // corrected file silently dropped rows as "already imported".
      expect(first, isNot(second));
    });

    test('type disagreeing with a known category is coerced', () async {
      final p = await loaded();
      await p.importTransactions([
        Tx(
          id: 'x1',
          type: TxType.income, // food is an expense category
          categoryId: 'food',
          amount: 10,
          note: '',
          date: DateTime(2026, 8, 1),
        ),
      ], replace: false);
      expect(p.transactions.single.type, TxType.expense);
    });

    test('an unknown category id remaps to the row-type Other', () async {
      final p = await loaded();
      await p.importTransactions([
        Tx(
          id: 'x2',
          type: TxType.expense,
          categoryId: 'no_such_category',
          amount: 10,
          note: '',
          date: DateTime(2026, 8, 1),
        ),
      ], replace: false);
      expect(p.transactions.single.categoryId, 'other_expense');
    });
  });
}
