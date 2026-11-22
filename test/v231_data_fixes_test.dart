import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The failing store below extends the plugin's in-memory store, which only
// the platform interface exports. shared_preferences brings it in.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/default_rules.dart';
import 'package:expense_tracker/models/import_rule.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// The in-memory store, except that every write reports false while
/// [failWrites] is on, as Android's commit() does when it cannot write.
class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore() : super.empty();

  bool failWrites = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      failWrites ? false : super.setValue(valueType, key, value);
}

/// Runs [body] and fails the test when it takes longer than a bound no
/// fixed pattern comes near, while the old patterns took many seconds.
void _quick(String what, void Function() body) {
  final sw = Stopwatch()..start();
  body();
  expect(
    sw.elapsed,
    lessThan(const Duration(seconds: 3)),
    reason: '$what took ${sw.elapsedMilliseconds} ms',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final smsDate = DateTime(2026, 7, 2, 10, 30);

  group('an overflowing figure', () {
    test('an amount of 310 digits does not import', () {
      final body =
          'Rs.${'9' * 310} debited from a/c XX4821 on 02-07-26 at TESTMART.';
      expect(SmsTxnParser.parse('VM-HDFCBK', body, smsDate), isNull);
      expect(
        SmsTxnParser.explain('VM-HDFCBK', body, smsDate),
        startsWith('Not imported.'),
      );
    });

    test('an amount above the ceiling does not import', () {
      const body =
          'Rs.5,00,00,00,00,00,000.00 debited from a/c XX4821 on 02-07-26 '
          'at TESTMART.';
      expect(SmsTxnParser.parse('VM-HDFCBK', body, smsDate), isNull);
      // An alert the parser cannot read, as one with no amount is.
      expect(SmsTxnParser.looksUnreadable('VM-HDFCBK', body), isTrue);
      expect(
        SmsTxnParser.explain('VM-HDFCBK', body, smsDate),
        'Not imported. The amount could not be read.',
      );
    });

    test('a balance of 310 digits is dropped, the row still imports', () {
      final body =
          'Rs.250.00 debited from a/c XX4821 on 02-07-26 at TESTMART. '
          'Avl Bal Rs.${'9' * 310}';
      final r = SmsTxnParser.parse('VM-HDFCBK', body, smsDate)!;
      expect(r.amount, 250);
      expect(r.balanceAfter, isNull);
      expect(SmsTxnParser.balanceAfterOf(body), isNull);
    });

    test('a balance above the ceiling is dropped', () {
      const body =
          'Rs.250.00 debited from a/c XX4821 on 02-07-26 at TESTMART. '
          'Avl Bal Rs.90,00,00,00,00,00,000.00';
      expect(SmsTxnParser.balanceAfterOf(body), isNull);
      expect(SmsTxnParser.parse('VM-HDFCBK', body, smsDate)!.amount, 250);
    });

    test('addImported skips a non-finite row and keeps the rest', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      ParsedTxn row(double amount, {double? balance, String ref = 'R1'}) =>
          ParsedTxn(
            type: TxType.expense,
            amount: amount,
            merchant: 'TESTMART',
            date: DateTime(2026, 7, 2, 9),
            ref: ref,
            categoryId: 'other_expense',
            sender: 'VM-HDFCBK',
            rawBody: 'Invented alert $ref',
            balanceAfter: balance,
          );
      final (added, _, _) = await p.addImported([
        row(double.infinity, ref: 'BAD000001'),
        row(120, balance: double.nan, ref: 'BAD000002'),
        row(SmsTxnParser.maxAmount * 2, ref: 'BAD000003'),
        row(80, balance: 1000, ref: 'GOOD00001'),
      ]);
      expect(added, 1);
      expect(p.persistFailed, isFalse);
      final again = FinanceProvider();
      await again.load();
      expect(
        [
          ...again.transactions,
          ...again.pendingTransactions,
        ].map((t) => t.amount),
        [80],
      );
    });
  });

  group('patterns on long runs of spaces', () {
    test('balance patterns stay fast', () {
      for (final n in [300, 5000]) {
        final avl = 'Rs.10 debited. Avl Bal${' ' * n}x';
        final bare = 'Rs.10 debited. Bal${' ' * n}x';
        _quick('Avl Bal, $n spaces', () {
          expect(SmsTxnParser.balanceAfterOf(avl), isNull);
          SmsTxnParser.parse('VM-HDFCBK', avl, smsDate);
          SmsTxnParser.looksUnreadable('VM-HDFCBK', avl);
        });
        _quick('bare Bal, $n spaces', () {
          expect(SmsTxnParser.balanceAfterOf(bare), isNull);
          SmsTxnParser.parse('VM-HDFCBK', bare, smsDate);
        });
      }
    });

    test('the merchant pattern stays fast', () {
      for (final n in [1600, 20000]) {
        final body = 'Rs.10 debited to${' ' * n}!';
        _quick('merchant, $n spaces', () {
          expect(SmsTxnParser.merchantOf(body), '');
          SmsTxnParser.parse('VM-HDFCBK', body, smsDate);
          SmsTxnParser.explain('VM-HDFCBK', body, smsDate);
        });
      }
      // No-break spaces and tabs are spaces to the patterns too.
      final nbsp = 'Rs.10 debited to${'\u{00A0}\t' * 2000}!';
      _quick('merchant, no-break spaces', () {
        SmsTxnParser.parse('VM-HDFCBK', nbsp, smsDate);
      });
    });

    test('a very long body stays fast and still reads its amount', () {
      final body =
          'Rs.250.00 debited from a/c XX4821 at TESTMART. ${'ref ' * 25000}';
      _quick('long body', () {
        final r = SmsTxnParser.parse('VM-HDFCBK', body, smsDate)!;
        expect(r.amount, 250);
        // The stored text is the message as it arrived, not the cut one.
        expect(r.rawBody, body.trim());
      });
    });

    test('the date is read from the whole message', () {
      // The date is part of the duplicate keys, so the cut text must not
      // move it: here it sits past the cut.
      final body =
          'Rs.250.00 debited from a/c XX4821 at TESTMART. '
          '${'Thank you. ' * 200}Done on 01-07-26 10:15.';
      expect(body.length, greaterThan(2200));
      final r = SmsTxnParser.parse('VM-HDFCBK', body, smsDate)!;
      expect(r.date, DateTime(2026, 7, 1, 10, 15));
      expect(r.amount, 250);
    });

    test('a long run is read as one space, the stored text keeps it', () {
      final body =
          'Rs.250.00 debited from a/c XX4821 on 02-07-26 to TESTMART'
          '${' ' * 50}\nAvl Bal Rs.1,000.00';
      final r = SmsTxnParser.parse('VM-HDFCBK', body, smsDate)!;
      expect(r.rawBody, body.trim());
      expect(r.merchant, 'TESTMART');
      expect(r.balanceAfter, 1000);
    });

    test('a body with short runs reads as before', () {
      const body =
          'Rs.250.00 debited from a/c XX4821 on 02-07-26 to TESTMART  '
          'Ref 604817293561.\nAvl Bal Rs.1,000.00';
      final r = SmsTxnParser.parse('VM-HDFCBK', body, smsDate)!;
      expect(r.rawBody, body);
      expect(r.merchant, 'TESTMART');
      expect(r.ref, '604817293561');
      expect(r.balanceAfter, 1000);
    });
  });

  group('the amount needs a boundary on its left', () {
    test('"rs" inside a word is not the currency', () {
      final r = SmsTxnParser.parse(
        'VK-PAYTM',
        'Order of 2 burgers 1 coke confirmed. Rs.450 paid from Wallet.',
        smsDate,
      )!;
      expect(r.amount, 450);
      expect(r.type, TxType.expense);
    });
  });

  group('money that has not moved', () {
    final augDate = DateTime(2026, 8, 3, 10, 30);

    test('a card-due reminder that says ignore if already paid', () {
      const body =
          'Your Credit Card XX4523 bill: Total Amt Due Rs.12,345.00, Min Amt '
          'Due Rs.620.00, due by 15-08-26. Please ignore if already paid.';
      expect(SmsTxnParser.parse('VM-ICICIB', body, augDate), isNull);
      expect(SmsTxnParser.looksUnreadable('VM-ICICIB', body), isFalse);
    });

    test('a future auto-debit', () {
      const body =
          'Rs.1,499.00 will be auto-debited from your Credit Card ending 4523 '
          'on 05-08-26 for STREAMFLIX subscription.';
      expect(SmsTxnParser.parse('VM-ICICIB', body, augDate), isNull);
      expect(SmsTxnParser.looksUnreadable('VM-ICICIB', body), isFalse);
      // Without any ignore phrase too: no verb says the money moved.
      expect(
        SmsTxnParser.parse('VM-ICICIB', body, augDate, ignorePhrases: []),
        isNull,
      );
    });

    test('a failed payment that may be refunded', () {
      const body =
          'Your UPI transaction of Rs.750.00 to QUICKCART was unsuccessful. '
          'If your a/c XX1234 was debited, the amount will be refunded in 3 '
          'days.';
      expect(SmsTxnParser.parse('VM-HDFCBK', body, augDate), isNull);
      expect(SmsTxnParser.looksUnreadable('VM-HDFCBK', body), isFalse);
      const notSuccessful =
          'Your UPI payment of Rs.750.00 to QUICKCART was not successful. '
          'If debited, the amount will be refunded in 3 days.';
      expect(SmsTxnParser.parse('VM-HDFCBK', notSuccessful, augDate), isNull);
    });

    test('a completed debit with a future auto-debit footer imports', () {
      const body =
          'Rs.2,150.00 debited from A/c XX9876 on 03-08-26 towards loan EMI. '
          'Next EMI will be auto-debited on 03-09-26.';
      final r = SmsTxnParser.parse('VM-HDFCBK', body, augDate)!;
      expect(r.amount, 2150);
      expect(r.type, TxType.expense);
    });

    test('a completed auto-debit imports', () {
      const body =
          'Rs.2,150.00 has been auto-debited from A/c XX9876 on 03-08-26 '
          'towards loan EMI.';
      final r = SmsTxnParser.parse('VM-HDFCBK', body, augDate)!;
      expect(r.amount, 2150);
      expect(r.type, TxType.expense);
    });

    test('existing users get the new phrases once', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      // A 2.3.0 store: no 2.3.1 phrases yet, and a 1.28 phrase the user
      // deleted.
      for (final r in p.importRules.toList()) {
        if (kIgnorePhrasesAddedV231.contains(r.pattern) ||
            r.pattern == 'is blocked') {
          await p.deleteImportRule(r.id);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('import_rules_seeded_v3');
      final upgraded = FinanceProvider();
      await upgraded.load();
      for (final phrase in kIgnorePhrasesAddedV231) {
        expect(upgraded.ignorePhrases, contains(phrase));
      }
      expect(upgraded.ignorePhrases, isNot(contains('is blocked')));
      expect(
        upgraded.importRules
            .where((r) => r.kind == ImportRuleKind.ignore && r.isBuiltIn)
            .where((r) => kIgnorePhrasesAddedV231.contains(r.pattern))
            .length,
        kIgnorePhrasesAddedV231.length,
      );
      // Once: deleting one again sticks.
      final gone = upgraded.importRules.firstWhere(
        (r) => r.pattern == 'unsuccessful',
      );
      await upgraded.deleteImportRule(gone.id);
      final later = FinanceProvider();
      await later.load();
      expect(later.ignorePhrases, isNot(contains('unsuccessful')));
    });
  });

  group('a failed storage write', () {
    test('turns persistFailed on, and a good write turns it off', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      final store = _FailingStore()..failWrites = true;
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));

      await p.retryPersist();
      expect(p.persistFailed, isTrue);

      store.failWrites = false;
      await p.retryPersist();
      expect(p.persistFailed, isFalse);
    });

    test('a failed reminder write is not taken as saved', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      SharedPreferencesStorePlatform.instance = _FailingStore()
        ..failWrites = true;
      addTearDown(() => SharedPreferences.setMockInitialValues({}));

      await p.addReminder(name: 'Rent', dayOfMonth: 5, categoryId: 'bills');
      expect(p.persistFailed, isTrue);
    });
  });

  group('merging accounts', () {
    test('reminders on the removed account move to the target', () async {
      SharedPreferences.setMockInitialValues({});
      final p = FinanceProvider();
      await p.load();
      final a = await p.addAccount(name: 'Alpha', type: AccountType.bank);
      final b = await p.addAccount(name: 'Beta', type: AccountType.bank);
      final c = await p.addAccount(name: 'Gamma', type: AccountType.bank);
      final onB = await p.addReminder(
        name: 'Rent',
        dayOfMonth: 5,
        categoryId: 'bills',
        accountId: b,
      );
      final onC = await p.addReminder(
        name: 'Gym',
        dayOfMonth: 9,
        categoryId: 'bills',
        accountId: c,
      );

      await p.mergeAccounts(b, a);

      String? accountOf(FinanceProvider f, String id) =>
          f.reminders.firstWhere((r) => r.id == id).accountId;
      expect(accountOf(p, onB), a);
      expect(accountOf(p, onC), c);
      final again = FinanceProvider();
      await again.load();
      expect(accountOf(again, onB), a);
      expect(accountOf(again, onC), c);
    });
  });

  group('rule matching on lower-cased text', () {
    const rules = [
      ClassifierRule(id: 'r1', pattern: 'Zestbite', categoryId: 'food'),
      ClassifierRule(
        id: 'r2',
        pattern: ' chai |  | BIRYANI ',
        categoryId: 'food',
      ),
      ClassifierRule(id: 'r3', pattern: '7316', categoryId: 'bills'),
      ClassifierRule(id: 'r4', pattern: 'RD Ac', categoryId: 'savings_out'),
      ClassifierRule(id: 'r5', pattern: 'CAFÉ İSTAN', categoryId: 'food'),
      ClassifierRule(id: 'r6', pattern: '|', categoryId: 'food'),
    ];
    const texts = [
      'Paid Rs.120 to ZESTBITE8 on 02-07-26',
      'Paid to zestbitex',
      'Masala Chai at stall',
      'machair',
      'biryani house',
      'UPI Ref 307316123456',
      'card no 7316 used',
      'credit card account',
      'RD AC opened',
      'café istan bul',
      'CAFÉ İSTAN',
      '',
    ];

    test('matchesLowered agrees with patternMatchesText', () {
      for (final r in rules) {
        for (final t in texts) {
          final expected = r.patterns.any((p) => patternMatchesText(p, t));
          expect(r.matches(t), expected, reason: '${r.pattern} on "$t"');
          expect(
            r.matchesLowered(t.toLowerCase()),
            expected,
            reason: '${r.pattern} on "$t"',
          );
        }
      }
    });

    test('patternMatchesLowered agrees with patternMatchesText', () {
      for (final p in ['Zestbite', ' chai ', '7316', 'RD Ac', 'İSTAN', '']) {
        for (final t in texts) {
          expect(
            patternMatchesLowered(p.toLowerCase().trim(), t.toLowerCase()),
            patternMatchesText(p, t),
            reason: '"$p" on "$t"',
          );
        }
      }
    });
  });
}
