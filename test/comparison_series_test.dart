import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/comparison_series.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/services/sms_parser.dart';

/// The Trends comparison chart's lines. Amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // 20 October: 11 days after today.
  final now = DateTime(2026, 10, 20, 14);

  Future<FinanceProvider> ledger() async {
    final p = FinanceProvider();
    await p.load();
    for (final m in [7, 8, 9]) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 400,
        note: '',
        date: DateTime(2026, m, 1, 10),
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1100,
        note: '',
        date: DateTime(2026, m, 25, 10),
      );
    }
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 300,
      note: '',
      date: DateTime(2026, 10, 2, 10),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 200,
      note: '',
      date: DateTime(2026, 10, 15, 10),
    );
    return p;
  }

  test('actual stops at today, waiting rows included', () async {
    final p = await ledger();
    await p.addImported([
      ParsedTxn(
        type: TxType.expense,
        amount: 50,
        merchant: 'SHOP',
        date: DateTime(2026, 10, 19, 10),
        ref: 'R1',
        categoryId: 'food',
        sender: 'VM-HDFCBK',
        rawBody: 'Rs.50 spent at SHOP on 19-10-26.',
        acctKey: null,
      ),
    ]);
    final s = buildComparisonSeries(
      p,
      DateTime(2026, 10),
      now: now,
      lastMonthOnRecord: true,
    );
    expect(s.days, 31);
    expect(s.today, 20);
    expect(s.running, isTrue);
    expect(s.actual, hasLength(20));
    expect(s.actual[1], 300);
    expect(s.actual.last, 550, reason: 'pending included');
    expect(s.lastMonth, hasLength(30));
    expect(s.lastMonth!.last, 1500);
    expect(s.usual, hasLength(31));
  });

  test('a month that has ended runs to its last day', () async {
    final p = await ledger();
    final s = buildComparisonSeries(
      p,
      DateTime(2026, 9),
      now: now,
      lastMonthOnRecord: true,
    );
    expect(s.today, 30);
    expect(s.running, isFalse);
    expect(s.actual.last, 1500);
  });

  test("a 30-day month's usual line ends at a usual whole month", () async {
    final p = await ledger();
    final nov = DateTime(2026, 11, 10, 12);
    final s = buildComparisonSeries(
      p,
      DateTime(2026, 11),
      now: nov,
      lastMonthOnRecord: true,
    );
    final full = usualCumulativeByDay(p, DateTime(2026, 11))!;
    expect(s.usual, hasLength(30));
    expect(s.usual!.last, full.last);
  });

  test('last month not on record leaves its line out', () async {
    final p = await ledger();
    final s = buildComparisonSeries(
      p,
      DateTime(2026, 10),
      now: now,
      lastMonthOnRecord: false,
    );
    expect(s.lastMonth, isNull);
  });
}
