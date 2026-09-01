import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';

/// Regression tests for the add/edit sheet's two safety guards from the
/// audit fix round: the double-submit latch (duplicate ledger rows) and the
/// unsaved-changes pop guard (typed input lost to a stray dismissal).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget app(FinanceProvider provider) => ChangeNotifierProvider.value(
    value: provider,
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

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  Future<void> openSheet(WidgetTester tester, FinanceProvider p) async {
    await tester.pumpWidget(app(p));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add transaction'), findsOneWidget);
  }

  testWidgets('double-tapping Add creates exactly one transaction', (
    tester,
  ) async {
    final p = await loaded();
    await openSheet(tester, p);

    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '250');
    await tester.pump();

    // Two taps with no settle in between — the second lands while the first
    // save's awaits are still in flight. The button sits below the fold on
    // the 600px test surface, so scroll it into view first.
    final add = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(add);
    await tester.pump();
    await tester.tap(add);
    await tester.pump();
    await tester.tap(add, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(p.transactions.length, 1);
    expect(p.transactions.single.amount, 250);
  });

  testWidgets('a dirty sheet asks before discarding; Discard closes it', (
    tester,
  ) async {
    final p = await loaded();
    await openSheet(tester, p);

    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '99');
    await tester.pump();

    // System back (what the barrier tap and swipe-down also route through).
    final NavigatorState nav = tester.state(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsOneWidget);
    expect(find.text('Add transaction'), findsOneWidget); // still open

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Add transaction'), findsOneWidget);

    await nav.maybePop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Add transaction'), findsNothing);
    expect(p.transactions, isEmpty);
  });

  testWidgets('a clean sheet closes without asking', (tester) async {
    final p = await loaded();
    await openSheet(tester, p);

    final NavigatorState nav = tester.state(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();

    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('Add transaction'), findsNothing);
  });
}
