import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/services/notification_source.dart';
import 'package:expense_tracker/services/sms_import_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/sms_source.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/status_dot.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

/// Sure SMS imports count at once, marked new ([Tx.unseen]); every other
/// import waits pending in review. All names, numbers and texts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  const bank = 'HDFC:1234';
  const savings = 'SBI:5678';

  ParsedTxn alert({
    TxType type = TxType.expense,
    double amount = 250,
    required DateTime date,
    required String ref,
    String categoryId = 'food',
    String rawBody = 'Rs.250 debited at SWIGGY',
    String? acctKey = bank,
    bool spamSuspect = false,
  }) => ParsedTxn(
    type: type,
    amount: amount,
    merchant: '',
    date: date,
    ref: ref,
    categoryId: categoryId,
    sender: 'VM-HDFCBK',
    rawBody: rawBody,
    acctKey: acctKey,
    spamSuspect: spamSuspect,
  );

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  /// A provider whose [bank] account already has one confirmed row, from a
  /// merchant no rule knows.
  Future<FinanceProvider> withHistory() async {
    final p = await loaded();
    await p.addImported([
      alert(
        amount: 450,
        date: DateTime(2026, 7, 1, 9),
        ref: 'SEED1',
        rawBody: 'Rs.450 debited at KETTLE NOOK',
      ),
    ]);
    await p.confirmAllPending();
    expect(p.pendingCount, 0);
    return p;
  }

  Tx byRef(FinanceProvider p, String ref) => [
    ...p.transactions,
    ...p.pendingTransactions,
  ].firstWhere((t) => t.externalRef == ref);

  group('the sure test', () {
    test(
      'a built-in rule match on a known account counts, marked new',
      () async {
        final p = await withHistory();
        final (added, _, _) = await p.addImported([
          alert(date: DateTime(2026, 7, 5, 13), ref: 'A'),
        ]);
        expect(added, 1);
        expect(p.lastImportCounted, 1);
        expect(
          p.rules.firstWhere((r) => r.matches('SWIGGY')).isBuiltIn,
          isTrue,
        );
        final t = byRef(p, 'A');
        expect(t.pending, isFalse);
        expect(t.unseen, isTrue);
        expect(t.categoryId, 'food');
        expect(p.pendingCount, 0);
        expect(p.unseenCount, 1);
        // Counted rows are in the totals like any confirmed row.
        expect(p.transactions.length, 2);
      },
    );

    test('a user rule match counts too', () async {
      final p = await withHistory();
      await p.addRule('Tiffin Box', 'food');
      await p.addImported([
        alert(
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          categoryId: 'other_expense',
          rawBody: 'Rs.250 debited at TIFFIN BOX',
        ),
      ]);
      expect(byRef(p, 'A').pending, isFalse);
      expect(p.lastImportCounted, 1);
    });

    test('an alert nothing places counts at once in To sort', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          categoryId: 'other_expense',
          rawBody: 'Rs.250 debited at PEBBLE MART',
        ),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isFalse);
      expect(t.unseen, isTrue);
      expect(t.categoryId, kToSortExpenseId);
      expect(t.categoryGuessed, isFalse);
      expect(p.lastImportCounted, 1);
    });

    test(
      'a new account waits, and so does one with only pending rows',
      () async {
        final p = await withHistory();
        await p.addImported([
          alert(
            date: DateTime(2026, 7, 5, 13),
            ref: 'A',
            acctKey: 'ICICI:9999',
          ),
        ]);
        expect(byRef(p, 'A').pending, isTrue);
        // The account exists now, but nothing on it is confirmed yet.
        await p.addImported([
          alert(
            date: DateTime(2026, 7, 6, 13),
            ref: 'B',
            acctKey: 'ICICI:9999',
          ),
        ]);
        expect(byRef(p, 'B').pending, isTrue);
        expect(p.lastImportCounted, 0);
      },
    );

    test('an alert with no account waits', () async {
      final p = await withHistory();
      await p.addImported([
        alert(date: DateTime(2026, 7, 5, 13), ref: 'A', acctKey: null),
      ]);
      expect(byRef(p, 'A').pending, isTrue);
    });

    test('a spam suspect waits', () async {
      final p = await withHistory();
      await p.addImported([
        alert(date: DateTime(2026, 7, 5, 13), ref: 'A', spamSuspect: true),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isTrue);
      expect(t.suspectedSpam, isTrue);
    });

    test('a transfer category waits', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          categoryId: 'transfer_out',
          rawBody: 'Rs.250 debited at PEBBLE MART',
        ),
      ]);
      expect(byRef(p, 'A').pending, isTrue);
    });

    test('a merchant seen before with the same category counts', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 120,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          rawBody: 'Rs.120 debited at KETTLE NOOK',
        ),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isFalse);
      expect(t.unseen, isTrue);
    });

    test('a category needs no merchant history to count', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 120,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          categoryId: 'shopping',
          rawBody: 'Rs.120 debited at KETTLE NOOK',
        ),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isFalse);
      expect(t.categoryId, 'shopping');
      expect(t.categoryGuessed, isFalse);
    });

    test('an Other alert from a known merchant takes its category, '
        'marked guessed', () async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 120,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          categoryId: 'other_expense',
          rawBody: 'Rs.120 debited at KETTLE NOOK',
        ),
      ]);
      final t = byRef(p, 'A');
      expect(t.pending, isFalse);
      expect(t.categoryId, 'food');
      expect(t.categoryGuessed, isTrue);
    });
  });

  group('possible transfer partners', () {
    /// [bank] and [savings] both with a confirmed row, and a user rule
    /// that names the income.
    Future<FinanceProvider> twoAccounts() async {
      final p = await withHistory();
      await p.addRule('Acme Payroll', 'salary');
      await p.addImported([
        alert(
          type: TxType.income,
          amount: 100,
          date: DateTime(2026, 7, 1, 10),
          ref: 'SEED2',
          categoryId: 'salary',
          rawBody: 'Rs.100 credited from ACME PAYROLL',
          acctKey: savings,
        ),
      ]);
      await p.confirmAllPending();
      return p;
    }

    ParsedTxn out(double amount, DateTime date, String ref) => alert(
      amount: amount,
      date: date,
      ref: ref,
      rawBody: 'Rs.$amount debited at SWIGGY',
    );

    ParsedTxn inn(double amount, DateTime date, String ref) => alert(
      type: TxType.income,
      amount: amount,
      date: date,
      ref: ref,
      categoryId: 'salary',
      rawBody: 'Rs.$amount credited from ACME PAYROLL',
      acctKey: savings,
    );

    test(
      'both legs in one batch stay pending, whichever comes first',
      () async {
        final p = await twoAccounts();
        await p.addImported([
          out(5000, DateTime(2026, 7, 5, 10), 'OUT'),
          inn(5000, DateTime(2026, 7, 5, 10, 2), 'IN'),
        ]);
        expect(byRef(p, 'OUT').pending, isTrue);
        expect(byRef(p, 'IN').pending, isTrue);
        expect(p.lastImportCounted, 0);

        // The incoming leg first in the batch, on a fresh ledger.
        SharedPreferences.setMockInitialValues({});
        final q = await twoAccounts();
        await q.addImported([
          inn(5000, DateTime(2026, 7, 5, 10), 'IN'),
          out(5000, DateTime(2026, 7, 5, 10, 2), 'OUT'),
        ]);
        expect(byRef(q, 'OUT').pending, isTrue);
        expect(byRef(q, 'IN').pending, isTrue);
        expect(q.lastImportCounted, 0);
      },
    );

    test('amounts a paisa apart are not partners: both count', () async {
      final p = await twoAccounts();
      await p.addImported([
        out(5000, DateTime(2026, 7, 5, 10), 'OUT'),
        inn(5000.01, DateTime(2026, 7, 5, 10, 2), 'IN'),
      ]);
      expect(byRef(p, 'OUT').pending, isFalse);
      expect(byRef(p, 'IN').pending, isFalse);
      expect(p.lastImportCounted, 2);
    });

    test(
      'a reviewed partner in the ledger keeps the new leg pending',
      () async {
        final p = await twoAccounts();
        await p.addImported([inn(5000, DateTime(2026, 7, 4, 10), 'IN')]);
        await p.markSeen(byRef(p, 'IN').id);
        await p.addImported([out(5000, DateTime(2026, 7, 5, 10), 'OUT')]);
        expect(byRef(p, 'OUT').pending, isTrue);
        // Seen already: it stays counted.
        expect(byRef(p, 'IN').pending, isFalse);
      },
    );

    test('a partner that counted at once and is still new goes back to '
        'review with the new leg', () async {
      final p = await twoAccounts();
      await p.addImported([inn(5000, DateTime(2026, 7, 4, 10), 'IN')]);
      expect(byRef(p, 'IN').unseen, isTrue);
      await p.addImported([out(5000, DateTime(2026, 7, 5, 10), 'OUT')]);
      expect(byRef(p, 'OUT').pending, isTrue);
      final back = byRef(p, 'IN');
      expect(back.pending, isTrue);
      expect(back.unseen, isFalse);
      expect(p.unseenCount, 0);
      expect(p.lastImportCounted, 0);
    });

    test('pairing two legs clears their new markers', () async {
      final p = await twoAccounts();
      await p.addImported([
        out(5000, DateTime(2026, 7, 5, 10), 'OUT'),
        inn(5000.01, DateTime(2026, 7, 5, 10, 2), 'IN'),
      ]);
      expect(p.unseenCount, 2);
      final pairId = await p.pairTransactions(
        byRef(p, 'OUT').id,
        byRef(p, 'IN').id,
      );
      expect(pairId, isNotNull);
      expect(byRef(p, 'OUT').unseen, isFalse);
      expect(byRef(p, 'IN').unseen, isFalse);
      expect(p.unseenCount, 0);
    });

    test('a partner outside the pair window does not hold a row', () async {
      final p = await twoAccounts();
      await p.addImported([inn(5000, DateTime(2026, 7, 1, 11), 'IN')]);
      await p.confirmAllPending();
      await p.addImported([out(5000, DateTime(2026, 7, 5, 10), 'OUT')]);
      expect(byRef(p, 'OUT').pending, isFalse);
    });
  });

  group('possible duplicates', () {
    test('two copies in one batch both wait', () async {
      final p = await withHistory();
      await p.addImported([
        alert(date: DateTime(2026, 7, 5, 13), ref: 'A'),
        alert(
          date: DateTime(2026, 7, 5, 20),
          ref: 'B',
          rawBody: 'Rs.250 debited at SWIGGY Ref B',
        ),
      ]);
      expect(byRef(p, 'A').pending, isTrue);
      expect(byRef(p, 'B').pending, isTrue);
      expect(p.lastImportCounted, 0);
    });

    test('a copy already in the ledger holds the new row', () async {
      final p = await withHistory();
      await p.addImported([alert(date: DateTime(2026, 7, 5, 13), ref: 'A')]);
      expect(byRef(p, 'A').pending, isFalse);
      await p.addImported([
        alert(
          date: DateTime(2026, 7, 6, 9),
          ref: 'B',
          rawBody: 'Rs.250 debited at SWIGGY Ref B',
        ),
      ]);
      expect(byRef(p, 'B').pending, isTrue);
    });

    test('a copy with no account holds it too', () async {
      final p = await withHistory();
      await p.addImported([
        alert(date: DateTime(2026, 7, 5, 13), ref: 'A', acctKey: null),
      ]);
      await p.addImported([
        alert(
          date: DateTime(2026, 7, 5, 18),
          ref: 'B',
          rawBody: 'Rs.250 debited at SWIGGY Ref B',
        ),
      ]);
      expect(byRef(p, 'B').pending, isTrue);
    });

    test('the same amount on another account, or a day and more apart, '
        'counts', () async {
      final p = await withHistory();
      await p.addImported([
        alert(date: DateTime(2026, 7, 5, 13), ref: 'A', acctKey: 'ICICI:9999'),
        alert(
          date: DateTime(2026, 7, 5, 14),
          ref: 'B',
          rawBody: 'Rs.250 debited at SWIGGY Ref B',
        ),
        alert(
          date: DateTime(2026, 7, 7, 14),
          ref: 'C',
          rawBody: 'Rs.250 debited at SWIGGY Ref C',
        ),
      ]);
      expect(byRef(p, 'A').pending, isTrue); // a new account
      expect(byRef(p, 'B').pending, isFalse);
      expect(byRef(p, 'C').pending, isFalse);
    });
  });

  group('guess evidence', () {
    test('a row still marked new does not teach a guess', () async {
      final p = await withHistory();
      final rule = await p.addRule('Pebble Mart', 'food');
      expect(rule.reclassified, 0);
      await p.addImported([
        alert(
          amount: 80,
          date: DateTime(2026, 7, 5, 13),
          ref: 'A',
          rawBody: 'Rs.80 debited at PEBBLE MART',
        ),
      ]);
      expect(byRef(p, 'A').unseen, isTrue);
      await p.deleteRule(p.rules.firstWhere((r) => !r.isBuiltIn).id);

      // Filed that way only by a row the user has not looked at: To sort.
      await p.addImported([
        alert(
          amount: 90,
          date: DateTime(2026, 7, 8, 13),
          ref: 'B',
          categoryId: 'other_expense',
          rawBody: 'Rs.90 debited at PEBBLE MART',
        ),
      ]);
      expect(byRef(p, 'B').pending, isFalse);
      expect(byRef(p, 'B').categoryId, kToSortExpenseId);

      // Once seen, it does.
      await p.markSeen(byRef(p, 'A').id);
      await p.addImported([
        alert(
          amount: 95,
          date: DateTime(2026, 7, 11, 13),
          ref: 'C',
          categoryId: 'other_expense',
          rawBody: 'Rs.95 debited at PEBBLE MART',
        ),
      ]);
      expect(byRef(p, 'C').pending, isFalse);
      expect(byRef(p, 'C').categoryId, 'food');
      expect(byRef(p, 'C').categoryGuessed, isTrue);
    });
  });

  group('one-time pass on load', () {
    Map<String, Object> stored({required bool done}) {
      final rows = [
        Tx(
          id: 'seed',
          type: TxType.expense,
          categoryId: 'food',
          amount: 450,
          note: '',
          smsBody: 'Rs.450 debited at KETTLE NOOK',
          date: DateTime(2026, 7, 1, 9),
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
          acctKey: bank,
        ),
        Tx(
          id: 'sure',
          type: TxType.expense,
          categoryId: 'food',
          amount: 250,
          note: '',
          smsBody: 'Rs.250 debited at SWIGGY',
          date: DateTime(2026, 7, 5, 13),
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
          acctKey: bank,
          pending: true,
        ),
        Tx(
          id: 'unsure',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 75,
          note: '',
          smsBody: 'Rs.75 debited at PEBBLE MART',
          date: DateTime(2026, 7, 6, 13),
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
          acctKey: bank,
          pending: true,
        ),
        Tx(
          id: 'waits',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 60,
          note: '',
          smsBody: 'Rs.60 debited at PEBBLE MART',
          date: DateTime(2026, 7, 7, 13),
          source: TxSource.sms,
          sender: 'VM-ICICIB',
          acctKey: 'ICICI:9999',
          pending: true,
        ),
      ];
      final account = Account(
        id: 'acc1',
        name: 'HDFC Bank ••1234',
        type: AccountType.bank,
        keys: {bank},
      );
      return {
        'transactions_v1': jsonEncode([for (final t in rows) t.toJson()]),
        'accounts_v1': jsonEncode([account.toJson()]),
        'accounts_migrated_v1': true,
        'accounts_migrated_v2': true,
        'accounts_migrated_v3': true,
        'accounts_migrated_v4': true,
        'accounts_migrated_v5': true,
        'sms_body_migrated_v1': true,
        'imports_count_first_v1': done,
      };
    }

    test('places and converts qualifying pending rows, once', () async {
      SharedPreferences.setMockInitialValues(stored(done: false));
      final p = await loaded();
      final sure = p.transactions.firstWhere((t) => t.id == 'sure');
      expect(sure.unseen, isTrue);
      expect(sure.categoryId, 'food');
      // Other becomes To sort, and on a known account it counts.
      final unsure = p.transactions.firstWhere((t) => t.id == 'unsure');
      expect(unsure.unseen, isTrue);
      expect(unsure.categoryId, kToSortExpenseId);
      // An account with no confirmed row still waits, placed all the same.
      final waits = p.pendingTransactions.single;
      expect(waits.id, 'waits');
      expect(waits.categoryId, kToSortExpenseId);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('imports_count_first_v1'), isTrue);

      // The conversion was written, and a later launch leaves it alone.
      await p.markSeen('sure');
      final again = await loaded();
      expect(
        again.transactions.firstWhere((t) => t.id == 'sure').unseen,
        isFalse,
      );
      expect(again.pendingTransactions.single.id, 'waits');
    });

    test('does nothing once the flag is set', () async {
      SharedPreferences.setMockInitialValues(stored(done: true));
      final p = await loaded();
      expect(p.pendingCount, 3);
      expect(p.unseenCount, 0);
      expect(
        p.pendingTransactions.firstWhere((t) => t.id == 'unsure').categoryId,
        'other_expense',
      );
    });
  });

  group('spam rules and the new marker', () {
    test('a later spam rule drops an unseen row, not a seen one', () async {
      final p = await withHistory();
      await p.addImported([
        alert(date: DateTime(2026, 7, 5, 13), ref: 'A'),
        alert(
          amount: 300,
          date: DateTime(2026, 7, 6, 13),
          ref: 'B',
          rawBody: 'Rs.300 debited at SWIGGY',
        ),
      ]);
      expect(p.lastImportCounted, 2);
      await p.markSeen(byRef(p, 'B').id);
      expect(p.pendingSpamDropsFor('swiggy', 'spam'), 1);

      final result = await p.addRule('swiggy', 'spam');
      expect(result.droppedPending, 1);
      expect(result.dropped.single.externalRef, 'A');
      expect(p.transactions.any((t) => t.externalRef == 'B'), isTrue);
      expect(p.unseenCount, 0);
    });
  });

  group('seen', () {
    test('markSeen clears one marker and markAllSeen the rest', () async {
      final p = await withHistory();
      await p.addImported([
        alert(date: DateTime(2026, 7, 5, 13), ref: 'A'),
        alert(
          amount: 300,
          date: DateTime(2026, 7, 6, 13),
          ref: 'B',
          rawBody: 'Rs.300 debited at SWIGGY',
        ),
        alert(
          amount: 350,
          date: DateTime(2026, 7, 7, 13),
          ref: 'C',
          rawBody: 'Rs.350 debited at SWIGGY',
        ),
      ]);
      expect(p.unseenCount, 3);
      await p.markSeen(byRef(p, 'A').id);
      expect(byRef(p, 'A').unseen, isFalse);
      expect(p.unseenCount, 2);
      await p.markAllSeen();
      expect(p.unseenCount, 0);
      // Persisted.
      expect((await loaded()).unseenCount, 0);
    });

    test('lastImportCounted resets on every call', () async {
      final p = await withHistory();
      await p.addImported([alert(date: DateTime(2026, 7, 5, 13), ref: 'A')]);
      expect(p.lastImportCounted, 1);
      await p.addImported(const []);
      expect(p.lastImportCounted, 0);
    });

    test('a drain that imports nothing reports nothing counted', () async {
      final p = await withHistory();
      await p.addImported([alert(date: DateTime(2026, 7, 5, 13), ref: 'A')]);
      expect(p.lastImportCounted, 1);
      final service = SmsImportService(
        source: _Inbox(),
        notifications: _NoNotifications(),
      );
      service.lastDrainCounted = 5;
      expect(await service.drainNotifications(p), 0);
      expect(service.lastDrainCounted, 0);
    });

    test('SmsImportResult splits imported into counted and to review', () {
      const r = SmsImportResult(
        scanned: 10,
        matched: 8,
        imported: 6,
        spamDropped: 1,
        counted: 4,
      );
      expect(r.toReview, 2);
      expect(r.duplicates, 1);
    });

    test('an import run reports what counted', () async {
      final now = DateTime.now();
      final p = await loaded();
      final source = _Inbox();
      final service = SmsImportService(
        source: source,
        notifications: _NoNotifications(),
      );
      SmsMessage msg(int hoursAgo, String ref, int amount) => SmsMessage(
        sender: 'VM-ICICIB',
        body:
            'Rs.$amount.00 debited from a/c XX1234 at SWIGGY. '
            'Ref $ref.',
        date: now.subtract(Duration(hours: hoursAgo)),
      );
      source.inbox = [msg(5, '111122223333', 210)];
      final first = await service.run(p, lookback: const Duration(days: 1));
      expect(first!.imported, 1);
      expect(first.counted, 0); // a new account waits
      expect(first.toReview, 1);
      await p.confirmAllPending();

      source.inbox = [...source.inbox, msg(4, '444455556666', 230)];
      final second = await service.run(p, lookback: const Duration(days: 1));
      expect(second!.imported, 1);
      expect(second.counted, 1);
      expect(second.toReview, 0);
    });
  });

  group('screens', () {
    Future<void> pump(
      WidgetTester tester,
      FinanceProvider p,
      Widget home, {
      Size size = const Size(400, 900),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: Scaffold(body: home),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 700));
    }

    final date = DateTime(2026, 7, 5, 13);
    Tx smsRow({bool unseen = true, String body = 'Rs.250 debited at SWIGGY'}) =>
        Tx(
          id: 'r1',
          type: TxType.expense,
          categoryId: 'food',
          amount: 250,
          note: '',
          smsBody: body,
          date: date,
          source: TxSource.sms,
          sender: 'VM-HDFCBK',
          acctKey: bank,
          unseen: unseen,
        );

    testWidgets('the edit sheet clears new on open and save keeps it clear', (
      tester,
    ) async {
      final p = await withHistory();
      await p.addImported([alert(date: date, ref: 'A')]);
      final id = byRef(p, 'A').id;
      await pump(
        tester,
        p,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddTransactionSheet(
              context,
              existing: p.transactions.firstWhere((t) => t.id == id),
            ),
            child: const Text('open'),
          ),
        ),
      );
      expect(byRef(p, 'A').unseen, isTrue);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(byRef(p, 'A').unseen, isFalse);

      final save = find.widgetWithText(FilledButton, 'Save changes');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(byRef(p, 'A').unseen, isFalse);
      expect(p.unseenCount, 0);
    });

    testWidgets('a new row shows the dot and "new", read as New', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final p = await loaded();
      await pump(
        tester,
        p,
        ListView(children: [TransactionTile(tx: smsRow())]),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(StatusDot), findsOneWidget);
      expect(find.text(fmtDateCompact(date)), findsOneWidget);
      expect(find.text(' · new'), findsOneWidget);
      // The dot's label joins the row's own; the visible "new" is not read
      // a second time.
      expect(find.bySemanticsLabel(RegExp(r'\bNew\b')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'\bnew\b')), findsNothing);
      semantics.dispose();
    });

    testWidgets('a seen row shows neither', (tester) async {
      final p = await loaded();
      await pump(
        tester,
        p,
        ListView(children: [TransactionTile(tx: smsRow(unseen: false))]),
      );
      expect(find.byType(StatusDot), findsNothing);
      expect(find.textContaining('new'), findsNothing);
      expect(find.text(fmtDateCompact(date)), findsOneWidget);
    });

    testWidgets('an SMS row with no note shows its merchant', (tester) async {
      final p = await loaded();
      await pump(
        tester,
        p,
        ListView(
          children: [
            TransactionTile(
              tx: smsRow(unseen: false, body: 'Rs.250 debited at KETTLE NOOK'),
            ),
          ],
        ),
      );
      expect(find.text('Kettle Nook'), findsOneWidget);
    });

    testWidgets('an alert with no merchant leaves the slot empty', (
      tester,
    ) async {
      final p = await loaded();
      await pump(
        tester,
        p,
        ListView(
          children: [
            TransactionTile(
              tx: smsRow(unseen: false, body: 'Rs.250 debited from a/c XX1234'),
            ),
          ],
        ),
      );
      expect(find.text('Payment'), findsNothing);
      expect(find.text(fmtDateCompact(date)), findsOneWidget);
    });

    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('a new row with a long merchant never overflows at $scale', (
        tester,
      ) async {
        final p = await loaded();
        final row = smsRow(
          body: 'Rs.250 debited at THE VERY LONG NAMED NEIGHBOURHOOD STORE',
        );
        for (final width in <double>[280, 320, 400]) {
          await pump(
            tester,
            p,
            ListView(
              children: [
                TransactionTile(tx: row),
                TransactionTile(tx: row, showDate: false),
                TransactionTile(
                  tx: row.copyWith(date: DateTime(2026, 7, 5)),
                  showDate: false,
                ),
              ],
            ),
            size: Size(width, 900),
            textScale: scale,
          );
          expect(tester.takeException(), isNull, reason: 'width $width');
        }
      });
    }

    for (final (width, scale) in [(390.0, 1.0), (320.0, 2.0)]) {
      testWidgets('"new" shows whole beside a long merchant at '
          '${width.toInt()}dp and ${scale}x', (tester) async {
        final semantics = tester.ensureSemantics();
        final p = await loaded();
        final row = smsRow(
          body: 'Rs.250 debited at THE VERY LONG NAMED NEIGHBOURHOOD STORE',
        );
        await pump(
          tester,
          p,
          ListView(
            children: [
              TransactionTile(tx: row),
              TransactionTile(tx: row, showDate: false),
            ],
          ),
          size: Size(width, 900),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        final suffixes = find.text(' · new');
        expect(suffixes, findsNWidgets(2));
        for (final element in suffixes.evaluate()) {
          final paragraph = element.renderObject! as RenderParagraph;
          expect(paragraph.didExceedMaxLines, isFalse);
          // Laid out at its full natural width, so nothing is clipped.
          expect(
            paragraph.size.width,
            moreOrLessEquals(
              paragraph.getMaxIntrinsicWidth(double.infinity),
              epsilon: 0.01,
            ),
          );
          expect(
            paragraph.localToGlobal(Offset(paragraph.size.width, 0)).dx,
            lessThanOrEqualTo(width),
          );
        }
        // The merchant gives way instead. The test font's glyphs are a full
        // em wide, so here it drops out; TalkBack still reads it.
        expect(
          find.bySemanticsLabel(RegExp('Neighbourhood Store')),
          findsWidgets,
        );
        semantics.dispose();
      });
    }
  });
}

class _Inbox implements SmsSource {
  List<SmsMessage> inbox = [];

  @override
  bool get isSupported => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<SmsPermission> requestPermission() async => SmsPermission.granted;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<SmsQueryResult> query({
    required DateTime since,
    DateTime? until,
  }) async => SmsQueryResult(
    messages: [
      for (final m in inbox)
        if (m.date.isAfter(since) && (until == null || m.date.isBefore(until)))
          m,
    ],
    complete: true,
  );
}

class _NoNotifications implements NotificationSource {
  @override
  bool get isSupported => false;

  @override
  Future<bool> hasAccess() async => false;

  @override
  Future<void> openAccessSettings() async {}

  @override
  Future<Map<String, dynamic>> diagnostics() async => const {};

  @override
  Future<DateTime?> lastCapture() async => null;

  @override
  Future<NotificationBatch> peek() async => NotificationBatch(const [], -1);

  @override
  Future<void> ack(NotificationBatch batch) async {}
}
