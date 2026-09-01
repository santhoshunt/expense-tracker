import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/import_rule.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> seeded() async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 100,
      note: 'lunch',
      date: DateTime(2026, 8, 1),
    );
    await p.addRule('mypattern', 'food');
    await p.addImportRule('my promo phrase', ImportRuleKind.ignore);
    await p.addCategory(
      label: 'Pets',
      type: TxType.expense,
      icon: Icons.pets,
      color: Colors.brown,
    );
    await p.addGroup(label: 'Leisure', color: Colors.teal);
    await p.addBudget(
      name: 'Personal',
      limit: 5000,
      mode: BudgetMode.exclude,
      categoryIds: const {},
    );
    // Simulate an already-fired alert marker for this month.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('budget_alert_fired_2026-08', 80);
    return p;
  }

  test(
    'clearAll keeps config but clears data and fired-alert markers',
    () async {
      final p = await seeded();
      await p.clearAll();

      expect(p.transactions, isEmpty);
      expect(p.accounts, isEmpty);
      // Config survives.
      expect(p.rules.any((r) => r.pattern == 'mypattern'), isTrue);
      expect(p.importRules.any((r) => r.pattern == 'my promo phrase'), isTrue);
      expect(customCategories.any((c) => c.label == 'Pets'), isTrue);
      expect(p.groups.any((g) => g.label == 'Leisure'), isTrue);
      expect(p.budgets, isNotEmpty);
      // Stale markers would suppress this month's re-alerts after a re-import.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('budget_alert_fired_2026-08'), isNull);
    },
  );

  test(
    'clearAll(includeConfig) is a factory reset that reseeds built-ins',
    () async {
      final p = await seeded();
      await p.clearAll(includeConfig: true);

      expect(p.transactions, isEmpty);
      expect(p.rules.any((r) => r.pattern == 'mypattern'), isFalse);
      expect(p.rules.any((r) => r.isBuiltIn), isTrue, reason: 'reseeded');
      expect(p.importRules.any((r) => r.pattern == 'my promo phrase'), isFalse);
      expect(p.importRules.any((r) => r.isBuiltIn), isTrue);
      expect(customCategories, isEmpty);
      expect(p.groups.map((g) => g.label), containsAll(['Needs', 'Wants']));
      expect(p.groups.any((g) => g.label == 'Leisure'), isFalse);
      expect(p.budgets, isEmpty);

      // The reset state survives a reload (nothing reappears, nothing lost).
      setCustomCategories(const []);
      setBuiltinOverrides(const {});
      final p2 = FinanceProvider();
      await p2.load();
      expect(p2.rules.any((r) => r.pattern == 'mypattern'), isFalse);
      expect(p2.rules.any((r) => r.isBuiltIn), isTrue);
      expect(p2.groups.map((g) => g.label), containsAll(['Needs', 'Wants']));
      expect(p2.budgets, isEmpty);
    },
  );
}
