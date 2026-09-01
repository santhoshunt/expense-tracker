import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/budget_widget_service.dart';

/// The Android budget widget renders whatever [buildWidgetSnapshot] writes —
/// these tests pin the snapshot's contents; the native side is display-only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final now = DateTime(2026, 7, 18, 14, 30);

  Future<(FinanceProvider, SettingsProvider)> loaded() async {
    final f = FinanceProvider();
    await f.load();
    final s = SettingsProvider();
    await s.load();
    return (f, s);
  }

  test(
    'overall cap appears only when set; zero-limit budgets excluded',
    () async {
      final (f, s) = await loaded();
      expect(buildWidgetSnapshot(f, s, now), isEmpty);

      await s.setMonthlyBudget(60000);
      await f.addBudget(
        name: 'Personal',
        limit: 10000,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );
      await f.addBudget(
        name: 'Disabled',
        limit: 0,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );

      final snapshot = buildWidgetSnapshot(f, s, now);
      expect(snapshot.map((e) => e['name']), ['Monthly budget', 'Personal']);
      expect(snapshot.first['id'], kOverallBudgetWidgetId);
    },
  );

  test('spent figures match the app math, split share included', () async {
    final (f, s) = await loaded();
    await s.setMonthlyBudget(60000);
    // ₹500 bill, own share ₹125: only the share is spend.
    await f.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: '',
      date: DateTime(2026, 7, 5, 21),
      myShare: 125,
    );
    await f.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 300,
      note: '',
      date: DateTime(2026, 7, 6, 9),
    );

    final overall = buildWidgetSnapshot(f, s, now).first;
    expect(overall['spent'], 425);
    expect(overall['limit'], 60000);
    expect(overall['spentLabel'], '₹425');
    expect(overall['limitLabel'], '₹60,000');
    expect(overall['statusLabel'], '₹59,575 left');
    expect(overall['monthLabel'], 'July 2026');
    expect(overall['updatedLabel'], '18 Jul 2026');
  });

  test('over-budget entries say so; paise survive when present', () async {
    final (f, s) = await loaded();
    await s.setMonthlyBudget(100);
    await f.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 250.50,
      note: '',
      date: DateTime(2026, 7, 5, 21),
    );
    final overall = buildWidgetSnapshot(f, s, now).first;
    expect(overall['spentLabel'], '₹250.50');
    expect(overall['statusLabel'], 'Over by ₹150.50');
  });

  test('snapshot is valid JSON the native side can parse', () async {
    final (f, s) = await loaded();
    await s.setMonthlyBudget(60000);
    final json = jsonEncode(buildWidgetSnapshot(f, s, now));
    final decoded = jsonDecode(json) as List;
    expect(decoded.single, containsPair('id', kOverallBudgetWidgetId));
    expect(decoded.single, contains('spent'));
    expect(decoded.single, contains('limit'));
  });
}
