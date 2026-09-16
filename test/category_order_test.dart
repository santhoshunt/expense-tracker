import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';

/// The category-order preference: persistence, the 90-day gross aggregate,
/// and the add sheet's picker order / default selection under each setting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  test('preference persists and rides the backup map', () async {
    final s = SettingsProvider();
    await s.load();
    expect(s.categoryOrder, CategoryOrder.mostUsed, reason: 'default');

    await s.setCategoryOrder(CategoryOrder.alphabetical);
    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.categoryOrder, CategoryOrder.alphabetical);

    expect(s.toBackupMap()['categoryOrder'], 'alphabetical');
    final fresh = SettingsProvider();
    await fresh.load();
    await fresh.applyBackupMap({'categoryOrder': 'alphabetical'});
    expect(fresh.categoryOrder, CategoryOrder.alphabetical);
  });

  test('categoryGrossRecent counts only the last 90 days', () async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'entertainment',
      amount: 9000,
      note: 'recent',
      date: now.subtract(const Duration(days: 5)),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'entertainment',
      amount: 5000,
      note: 'ancient',
      date: now.subtract(const Duration(days: 120)),
    );
    expect(p.categoryGrossRecent()['entertainment'], 9000);
  });

  group('add sheet picker', () {
    Widget app(FinanceProvider p, SettingsProvider s) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: p),
        ChangeNotifierProvider.value(value: s),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showAddTransactionSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    Future<(FinanceProvider, SettingsProvider)> seeded() async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 9000,
        note: 'movies',
        date: DateTime.now().subtract(const Duration(days: 5)),
      );
      final s = SettingsProvider();
      await s.load();
      return (p, s);
    }

    testWidgets('most used preselects the top-grossing category', (
      tester,
    ) async {
      final (p, s) = await seeded();
      await tester.pumpWidget(app(p, s));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // The dropdown field shows the current selection's label.
      expect(find.text('Entertainment'), findsOneWidget);
    });

    testWidgets('alphabetical preselects the A-to-Z first category', (
      tester,
    ) async {
      final (p, s) = await seeded();
      await s.setCategoryOrder(CategoryOrder.alphabetical);
      await tester.pumpWidget(app(p, s));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final labels = [
        for (final c in allCategories)
          if (c.type == TxType.expense && !c.isTransfer) c.label,
      ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      expect(find.text(labels.first), findsOneWidget);
      expect(find.text('Entertainment'), findsNothing);
    });
  });
}
