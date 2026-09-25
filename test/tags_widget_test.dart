import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';

/// Tags in the UI: the add sheet, the row's tag line, the filter deep
/// link, the bulk Tag action and the Tags tab.
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
      amount: 1840,
      note: 'beachshack',
      date: DateTime(2026, 9, 14),
      tags: ['Goa trip'],
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 90,
      note: 'coffeerun',
      date: DateTime(2026, 9, 15),
    );
    return p;
  }

  Widget withProviders(FinanceProvider p, Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: MaterialApp(home: home),
  );

  Tx row(FinanceProvider p, String note) =>
      p.transactions.singleWhere((t) => t.note == note);

  testWidgets('the add sheet takes a recent tag and typed text', (
    tester,
  ) async {
    final p = await seeded();
    await tester.pumpWidget(
      withProviders(
        p,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddTransactionSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '120');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Note (optional)'),
      'snacks',
    );
    final recent = find.widgetWithText(ActionChip, '+ Goa trip');
    await tester.ensureVisible(recent);
    await tester.pumpAndSettle();
    await tester.tap(recent);
    await tester.pump();
    expect(find.text('# Goa trip'), findsOneWidget);
    // Typed but never submitted: saved all the same.
    await tester.enterText(find.widgetWithText(TextField, 'Tags'), 'Work');
    final add = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(row(p, 'snacks').tags, ['Goa trip', 'Work']);
  });

  testWidgets('rows show tags; a tag deep link filters to them', (
    tester,
  ) async {
    final p = await seeded();
    Widget screen(TxFilterRequest? req, int token) => withProviders(
      p,
      Scaffold(
        body: TransactionsScreen(request: req, filterToken: token),
      ),
    );
    await tester.pumpWidget(screen(null, 0));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('# Goa trip'), findsOneWidget);
    expect(find.textContaining('coffeerun'), findsOneWidget);

    await tester.pumpWidget(screen(const TxFilterRequest(tag: 'goa TRIP'), 1));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.textContaining('coffeerun'), findsNothing);
    expect(find.textContaining('beachshack'), findsOneWidget);
    expect(find.text('Tag · Goa trip'), findsOneWidget);

    // The tag goes away while filtered by it: the filter must go too, not
    // leave an empty list with no chip to clear it.
    await p.deleteTag('Goa trip');
    // One frame to rebuild (the chip strip starts folding away), one to
    // let the fold finish.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Tag · Goa trip'), findsNothing);
    expect(find.textContaining('coffeerun'), findsOneWidget);
  });

  testWidgets('bulk Tag adds to the selection, and Undo takes it off', (
    tester,
  ) async {
    final p = await seeded();
    await tester.pumpWidget(
      withProviders(p, const Scaffold(body: TransactionsScreen())),
    );
    await tester.pump(const Duration(milliseconds: 700));

    await tester.longPress(find.textContaining('coffeerun'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Tags'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Tags'), 'Work,');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    // The blast-radius confirmation every bulk edit asks for.
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();

    expect(row(p, 'coffeerun').tags, ['Work']);
    expect(row(p, 'beachshack').tags, ['Goa trip'], reason: 'not selected');
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row(p, 'coffeerun').tags, isEmpty);
  });

  testWidgets('the Tags tab lists all-time totals and deletes with Undo', (
    tester,
  ) async {
    final p = await seeded();
    await tester.pumpWidget(
      withProviders(p, const ClassifiersScreen(initialTab: kCockpitTabTags)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Organise'), findsOneWidget);
    expect(find.text('Goa trip'), findsOneWidget);
    expect(find.textContaining('spent · 1 row'), findsOneWidget);

    await tester.longPress(find.text('Goa trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(row(p, 'beachshack').tags, isEmpty);
    expect(find.textContaining('Add tags when'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row(p, 'beachshack').tags, ['Goa trip']);
  });
}
