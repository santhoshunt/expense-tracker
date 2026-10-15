import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/budget_widget_service.dart';
import 'package:expense_tracker/widgets/budget_dialog.dart';

/// A budget's own icon: stored under 'icon', read back only when it is one
/// of the category icon choices, shown everywhere through one rule, and
/// picked from the budget dialog's icon button.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  const food = SpendBudget(
    id: 'b1',
    name: 'Eating out',
    limit: 2000,
    mode: BudgetMode.include,
    categoryIds: {'food'},
  );
  const several = SpendBudget(
    id: 'b2',
    name: 'Home',
    limit: 5000,
    mode: BudgetMode.include,
    categoryIds: {'bills', 'shopping'},
  );
  const allBut = SpendBudget(
    id: 'b3',
    name: 'Personal',
    limit: 9000,
    mode: BudgetMode.exclude,
    categoryIds: {'food'},
  );

  group('JSON', () {
    test('a budget on Automatic writes no icon key and reads back null', () {
      final json = food.toJson();
      expect(json.containsKey('icon'), isFalse);
      final back = SpendBudget.fromJson(json);
      expect(back.iconKey, isNull);
      expect(back.icon, isNull);
    });

    test('a picked icon round-trips', () {
      final json = food.copyWith(iconKey: 'pets').toJson();
      expect(json['icon'], 'pets');
      final back = SpendBudget.fromJson(json);
      expect(back.iconKey, 'pets');
      expect(back.icon, Icons.pets);
    });

    test('an unknown or malformed icon reads as Automatic', () {
      final unknown = food.toJson()..['icon'] = 'rocket';
      expect(SpendBudget.fromJson(unknown).iconKey, isNull);
      final number = food.toJson()..['icon'] = 7;
      expect(SpendBudget.fromJson(number).iconKey, isNull);
    });

    test('copyWith keeps the icon unless told to go Automatic', () {
      final picked = food.copyWith(iconKey: 'star');
      expect(picked.copyWith(name: 'Dining').iconKey, 'star');
      expect(picked.copyWith(clearIconKey: true).iconKey, isNull);
    });

    test('the backup is version 24 and carries the icon', () async {
      final p = FinanceProvider();
      await p.load();
      final id = await p.addBudget(
        name: 'Eating out',
        limit: 2000,
        mode: BudgetMode.include,
        categoryIds: {'food'},
      );
      await p.updateBudget(p.budgets.single.copyWith(iconKey: 'cafe'));
      final data = p.exportData();
      expect(data['version'], 26);
      final budgets = data['budgets'] as List;
      expect((budgets.single as Map)['icon'], 'cafe');
      expect(p.budgets.single.id, id);
    });
  });

  group('one rule for the icon', () {
    test('Automatic: one "Only these" category gives its icon', () {
      expect(budgetIcon(food), Icons.restaurant);
      expect(budgetIconKey(food, fallback: 'wallet'), 'food');
    });

    test(
      'Automatic: several categories or All except give the generic one',
      () {
        expect(budgetIcon(several), Icons.category_outlined);
        expect(budgetIcon(allBut), Icons.category_outlined);
        expect(budgetIconKey(several, fallback: 'wallet'), 'wallet');
        expect(budgetIconKey(allBut, fallback: 'wallet'), 'wallet');
      },
    );

    test('a picked icon wins over the automatic one', () {
      for (final b in [food, several, allBut]) {
        final picked = b.copyWith(iconKey: 'pets');
        expect(budgetIcon(picked), Icons.pets);
        expect(budgetIconKey(picked, fallback: 'wallet'), 'pets');
      }
    });

    test('the home-screen widgets follow the same rule', () {
      expect(budgetWidgetIcon(food), 'food');
      expect(budgetWidgetIcon(several), kWalletWidgetIcon);
      expect(budgetWidgetIcon(several.copyWith(iconKey: 'home')), 'home');
    });
  });

  group('budget dialog', () {
    Future<FinanceProvider> pumpDialog(
      WidgetTester tester, {
      required bool existing,
    }) async {
      final p = FinanceProvider();
      await p.load();
      if (existing) {
        await p.addBudget(
          name: 'Personal',
          limit: 9000,
          mode: BudgetMode.exclude,
          categoryIds: const {},
        );
      }
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: ElevatedButton(
                    onPressed: () => showBudgetDialog(
                      context,
                      existing: existing ? p.budgets.single : null,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return p;
    }

    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Budget icon'));
      await tester.pumpAndSettle();
      expect(find.text('Budget icon'), findsOneWidget, reason: 'sheet title');
      expect(find.text('Automatic'), findsOneWidget);
    }

    testWidgets('the icon button opens the picker and saves the choice', (
      tester,
    ) async {
      final p = await pumpDialog(tester, existing: true);
      // Automatic for an All except budget: the generic icon.
      expect(find.byIcon(Icons.category_outlined), findsOneWidget);

      await openPicker(tester);
      await tester.tap(find.byIcon(Icons.pets));
      await tester.pumpAndSettle();
      expect(find.text('Automatic'), findsNothing, reason: 'sheet closed');
      expect(find.byIcon(Icons.pets), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(p.budgets.single.iconKey, 'pets');
    });

    testWidgets('dismissing the picker keeps the icon; Automatic clears it', (
      tester,
    ) async {
      final p = await pumpDialog(tester, existing: true);
      await p.updateBudget(p.budgets.single.copyWith(iconKey: 'star'));
      // Reopen on the stored icon.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.star), findsOneWidget);

      await openPicker(tester);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Automatic'), findsNothing);
      expect(find.byIcon(Icons.star), findsOneWidget);

      await openPicker(tester);
      // The Automatic tile shows what Automatic gives this budget.
      await tester.tap(find.byIcon(Icons.category_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(p.budgets.single.iconKey, isNull);
    });

    testWidgets('a new budget keeps the icon picked while creating it', (
      tester,
    ) async {
      final p = await pumpDialog(tester, existing: false);
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'Treats');
      await tester.enterText(fields.at(1), '3000');
      await tester.pump();
      await openPicker(tester);
      await tester.tap(find.byIcon(Icons.local_cafe));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(p.budgets.single.name, 'Treats');
      expect(p.budgets.single.iconKey, 'cafe');
    });
  });
}
