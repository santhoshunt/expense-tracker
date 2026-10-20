import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/home_widgets_service.dart';
import 'package:expense_tracker/services/merchant_stats.dart';
import 'package:expense_tracker/services/month_forecast.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/spend_history.dart';
import 'package:expense_tracker/services/weekly_digest.dart';

/// v1.42.0: a refund linked to its purchase comes off the purchase's own
/// day and month in the builders outside the provider, and never counts as
/// income. Every name and amount is made up. 12 Oct 2026 is a Monday.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Tx row(
    String id,
    TxType type,
    String category,
    double amount,
    DateTime date, {
    String note = '',
    String? refundOf,
  }) => Tx(
    id: id,
    type: type,
    categoryId: category,
    amount: amount,
    note: note,
    date: date,
    refundOf: refundOf,
  );

  /// [rows] on a fresh provider over empty storage, so a second ledger in
  /// one test does not load the first; [link] false drops every refundOf,
  /// so the same refund counts as plain income.
  Future<FinanceProvider> ledger(List<Tx> rows, {bool link = true}) async {
    SharedPreferences.setMockInitialValues({});
    final p = FinanceProvider();
    await p.load();
    for (final t in rows) {
      await p.restoreTransaction(link ? t : t.copyWith(clearRefundOf: true));
    }
    return p;
  }

  group('weekly digest', () {
    // Tuesday of the week of 5 Oct: a 1,000 purchase; the 300 refund lands
    // on Tuesday of the next week, beside a 5,000 salary.
    final rows = [
      row('buy', TxType.expense, 'food', 1000, DateTime(2026, 10, 6, 12)),
      row(
        'back',
        TxType.income,
        'other_income',
        300,
        DateTime(2026, 10, 13, 12),
        refundOf: 'buy',
      ),
      row('pay', TxType.income, 'salary', 5000, DateTime(2026, 10, 12, 9)),
    ];
    final now = DateTime(2026, 10, 14, 10);

    test(
      "the refund comes off the purchase's week, day and category",
      () async {
        final p = await ledger(rows);
        final refund = p.transactions.firstWhere((t) => t.id == 'back');
        expect(p.isLinkedRefund(refund), isTrue);

        final d = buildWeekDigest(p, DateTime(2026, 10, 5), now: now);
        expect(d.spent, 700);
        expect(d.byDay, [0, 700, 0, 0, 0, 0, 0]);
        expect(d.topCategories.single.key.id, 'food');
        expect(d.topCategories.single.value, 700);

        final plain = await ledger(rows, link: false);
        final before = buildWeekDigest(plain, DateTime(2026, 10, 5), now: now);
        expect(before.spent, 1000);
      },
    );

    test('the refund adds nothing to income in its own week', () async {
      final p = await ledger(rows);
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      expect(d.income, 5000);

      final plain = await ledger(rows, link: false);
      final before = buildWeekDigest(plain, DateTime(2026, 10, 12), now: now);
      expect(before.income, 5300);
    });

    test('a purchase refunded in full leaves the biggest list', () async {
      final p = await ledger([
        row('buy', TxType.expense, 'shopping', 800, DateTime(2026, 10, 12)),
        row('tea', TxType.expense, 'food', 40, DateTime(2026, 10, 13)),
        row(
          'back',
          TxType.income,
          'other_income',
          800,
          DateTime(2026, 10, 14),
          refundOf: 'buy',
        ),
      ]);
      final d = buildWeekDigest(p, DateTime(2026, 10, 12), now: now);
      expect(d.spent, 40);
      expect([for (final t in d.biggest) t.id], ['tea']);
      expect([for (final e in d.topCategories) e.key.id], ['food']);
    });

    test('the usual week counts the purchase less its refund', () async {
      final p = await ledger([
        row('w1', TxType.expense, 'food', 200, DateTime(2026, 9, 28)),
        row('buy', TxType.expense, 'food', 1000, DateTime(2026, 10, 5)),
        row(
          'back',
          TxType.income,
          'other_income',
          600,
          DateTime(2026, 10, 8),
          refundOf: 'buy',
        ),
      ]);
      // Weeks of 5 Oct (400 net) and 28 Sep (200): the median is 300.
      expect(usualWeekByDay(p, DateTime(2026, 10, 12)).first, 300);
      expect(
        buildWeekDigest(p, DateTime(2026, 10, 12), now: now).usual,
        usualWeekByDay(p, DateTime(2026, 10, 12))[2],
      );
    });
  });

  test('the forecast pace counts the purchase less its refund', () async {
    // October only, so the everyday figure is this month's own pace.
    final rows = [
      row('buy', TxType.expense, 'shopping', 2000, DateTime(2026, 10, 1)),
      row('tea', TxType.expense, 'food', 100, DateTime(2026, 10, 3)),
      row(
        'back',
        TxType.income,
        'other_income',
        500,
        DateTime(2026, 10, 10),
        refundOf: 'buy',
      ),
    ];
    final now = DateTime(2026, 10, 20, 10);
    MonthForecast? forecast(FinanceProvider p) =>
        computeMonthForecast(p, patterns: const [], hidden: const {}, now: now);

    final linked = forecast(await ledger(rows))!;
    expect(linked.basis, EverydayBasis.pace);
    // 1,500 + 100 over 20 days.
    expect(linked.perDay, closeTo(80, 1e-9));
    final plain = forecast(await ledger(rows, link: false))!;
    expect(plain.perDay, closeTo(105, 1e-9));
  });

  group('merchant figures', () {
    // A September purchase refunded in October, in part.
    final rows = [
      row(
        'buy',
        TxType.expense,
        'shopping',
        1200,
        DateTime(2026, 9, 5),
        note: 'Gadget store',
      ),
      row(
        'back',
        TxType.income,
        'other_income',
        400,
        DateTime(2026, 10, 2),
        refundOf: 'buy',
      ),
    ];

    test('the history takes the refund off the purchase month', () async {
      final p = await ledger(rows);
      final key = recurringKeyOf(
        p.transactions.firstWhere((t) => t.id == 'buy'),
      );
      expect(key, isNotNull);
      final h = buildSpendHistory(
        p,
        subject: HistorySubject.merchant(key!, 'Gadget store'),
        months: [DateTime(2026, 9), DateTime(2026, 10)],
        now: DateTime(2026, 10, 20),
      );
      expect(h.amounts, [800, 0]);
    });

    test('top merchants nets the refund when given netSpendOf', () async {
      final p = await ledger(rows);
      final top = topMerchants(
        p.countedTransactions,
        month: DateTime(2026, 9),
        spendOf: p.netSpendOf,
      );
      expect(top.single.total, 800);
      // Without it, the gross amount, as before.
      expect(
        topMerchants(
          p.countedTransactions,
          month: DateTime(2026, 9),
        ).single.total,
        1200,
      );
    });

    test('a purchase refunded in full leaves no ₹0 merchant', () async {
      final p = await ledger([
        row(
          'buy',
          TxType.expense,
          'shopping',
          1200,
          DateTime(2026, 9, 5),
          note: 'Gadget store',
        ),
        row(
          'tea',
          TxType.expense,
          'food',
          60,
          DateTime(2026, 9, 6),
          note: 'Tea stall',
        ),
        row(
          'back',
          TxType.income,
          'other_income',
          1200,
          DateTime(2026, 10, 2),
          refundOf: 'buy',
        ),
      ]);
      final top = topMerchants(
        p.countedTransactions,
        month: DateTime(2026, 9),
        spendOf: p.netSpendOf,
      );
      // Only the tea stall: no ₹0 entry, no payment counted for the buy.
      expect(top.single.total, 60);
      expect(top.single.count, 1);
      expect(
        top.single.key,
        recurringKeyOf(p.transactions.firstWhere((t) => t.id == 'tea')),
      );
    });
  });

  group('CSV refundOf', () {
    Tx refund() => row(
      'back',
      TxType.income,
      'other_income',
      300,
      DateTime(2026, 10, 13, 12),
      refundOf: 'buy',
    );

    test('round trip keeps the link, even to an id not in the file', () {
      final csv = BackupService.buildCsvOf([
        refund(),
        row('pay', TxType.income, 'salary', 5000, DateTime(2026, 10, 12)),
      ]);
      expect(
        csv.split('\r\n').first,
        endsWith(',unseen,refundOf,payee,acctKind,smsAt'),
      );
      final back = {for (final t in BackupService.txsFromCsv(csv)) t.id: t};
      expect(back['back']!.refundOf, 'buy');
      expect(back['pay']!.refundOf, isNull);
    });

    test('an older file without the column still imports', () {
      final csv = BackupService.buildCsvOf([refund()]);
      // Drops the last four columns: refundOf and the later payee, acctKind
      // and smsAt.
      String dropLast4(String line) {
        var end = line.length;
        for (var i = 0; i < 4; i++) {
          end = line.lastIndexOf(',', end - 1);
        }
        return line.substring(0, end);
      }

      final old = [
        for (final line in csv.split('\r\n')) dropLast4(line),
      ].join('\r\n');
      expect(old.split('\r\n').first, endsWith(',unseen'));
      final t = BackupService.txsFromCsv(old).single;
      expect(t.id, 'back');
      expect(t.amount, 300);
      expect(t.refundOf, isNull);
    });

    test('an import into a fresh ledger keeps the refund linked', () async {
      final p = await ledger([
        row('buy', TxType.expense, 'shopping', 1000, DateTime(2026, 10, 6)),
        refund(),
      ]);
      final csv = BackupService.buildCsv(p);

      final fresh = await ledger(const []);
      await fresh.importTransactions(
        BackupService.txsFromCsv(csv),
        replace: true,
      );
      Tx byId(String id) => fresh.transactions.firstWhere((t) => t.id == id);
      expect(fresh.isLinkedRefund(byId('back')), isTrue);
      expect(fresh.netSpendOf(byId('buy')), 700);
    });
  });

  test('a linked refund is a neutral Recent widget row', () async {
    final p = await ledger([
      row('buy', TxType.expense, 'shopping', 1000, DateTime(2026, 10, 6)),
      row(
        'back',
        TxType.income,
        'other_income',
        300,
        DateTime(2026, 10, 13, 12),
        refundOf: 'buy',
      ),
      row('pay', TxType.income, 'salary', 5000, DateTime(2026, 10, 12, 9)),
    ]);
    final s = SettingsProvider();
    await s.load();
    final snap =
        jsonDecode(
              jsonEncode(
                buildHomeWidgetSnapshot(
                  p,
                  s,
                  DateTime(2026, 10, 14, 10),
                  const [],
                  patterns: const [],
                ),
              ),
            )
            as Map<String, dynamic>;
    final kinds = {
      for (final r in snap['recent'] as List) (r as Map)['label']: r['kind'],
    };
    expect(kinds[categoryById('other_income').label], 'neutral');
    expect(kinds[categoryById('salary').label], 'in');
    expect(kinds[categoryById('shopping').label], 'out');
  });
}
