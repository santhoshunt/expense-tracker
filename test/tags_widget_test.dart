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
import 'package:expense_tracker/widgets/budget_dialog.dart';

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

  /// Opens the add sheet's Tags, subscription, count in group. Settles
  /// first: a field just typed in scrolls its caret back into view.
  Future<void> openExtras(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final fold = find.byKey(const ValueKey('fold-extras'));
    await tester.ensureVisible(fold);
    await tester.pumpAndSettle();
    await tester.tap(fold);
    await tester.pumpAndSettle();
  }

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
    // A new entry keeps Tags folded.
    await openExtras(tester);
    final recent = find.widgetWithText(ActionChip, '+ Goa trip');
    await tester.ensureVisible(recent);
    await tester.pumpAndSettle();
    await tester.tap(recent);
    await tester.pump();
    // The group's closed line repeats it, so the chip is found by type.
    expect(find.widgetWithText(InputChip, '# Goa trip'), findsOneWidget);
    // Typed but never submitted: saved all the same.
    await tester.enterText(find.widgetWithText(TextField, 'Tags'), 'Work');
    final add = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(row(p, 'snacks').tags, ['Goa trip', 'Work']);
  });

  testWidgets('a saved tag is offered in the add sheet before any payment '
      'carries it', (tester) async {
    final p = await seeded();
    expect(await p.addSavedTag('Diwali', null), isTrue);
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
    await openExtras(tester);
    expect(find.widgetWithText(ActionChip, '+ Diwali'), findsOneWidget);
  });

  testWidgets('a saved tag is offered for a trip before any payment '
      'carries it', (tester) async {
    final p = await seeded();
    expect(await p.addSavedTag('Diwali', null), isTrue);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showBudgetDialog(context),
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
    await tester.tap(find.text('Trip or event'));
    await tester.pumpAndSettle();
    final fold = find.byKey(const ValueKey('trip-tag'));
    await tester.ensureVisible(fold);
    await tester.pumpAndSettle();
    await tester.tap(fold);
    await tester.pumpAndSettle();

    final diwali = find.widgetWithText(ChoiceChip, '# Diwali');
    expect(diwali, findsOneWidget);
    await tester.ensureVisible(diwali);
    await tester.pumpAndSettle();
    await tester.tap(diwali);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('trip-tag-field')),
    );
    expect(field.controller!.text, 'Diwali');
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
    // The filter pill reads "# Goa trip" and is spoken "Tag Goa trip".
    expect(find.byTooltip('Remove Tag Goa trip'), findsOneWidget);

    // The tag goes away while filtered by it: the filter must go too, not
    // leave an empty list with no chip to clear it.
    await p.deleteTag('Goa trip');
    // One frame to rebuild (the chip strip starts folding away), one to
    // let the fold finish.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byTooltip('Remove Tag Goa trip'), findsNothing);
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
    // Tags sits in the bar's More menu.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk-more-tags')));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Tags'), 'Work,');
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Apply to 1 transaction'),
    );
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
    expect(find.text('Groups and tags'), findsOneWidget);
    expect(find.text('Goa trip'), findsOneWidget);
    // v1.43.2: each fact keeps its words together (no-break spaces).
    expect(find.textContaining('spent · 1 transaction · '), findsOneWidget);

    // A tap opens the editor, which also offers the tag's transactions.
    await tester.tap(find.text('Goa trip'));
    await tester.pumpAndSettle();
    expect(find.text('See 1 transaction'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(row(p, 'beachshack').tags, isEmpty);
    expect(find.textContaining('Add tags when'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row(p, 'beachshack').tags, ['Goa trip']);
  });

  testWidgets('New tag adds a tag with no payments, and a taken name cannot '
      'be saved', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      withProviders(p, const ClassifiersScreen(initialTab: kCockpitTabTags)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('New tag'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Goa trip');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Goa trip'), findsOneWidget);
    expect(find.text('No payments yet'), findsOneWidget);

    await tester.tap(find.text('New tag'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'goa TRIP');
    await tester.pump();
    expect(find.text('A tag named "Goa trip" already exists'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Goa trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('No payments yet'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(find.text('No payments yet'), findsOneWidget);

    // A small phone at 2x text.
    tester.view.physicalSize = const Size(320, 568) * 3;
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New tag'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
  });

  testWidgets('New tag and Edit tag say a name is needed, and the done key '
      'saves', (tester) async {
    final p = await seeded();
    await tester.pumpWidget(
      withProviders(p, const ClassifiersScreen(initialTab: kCockpitTabTags)),
    );
    await tester.pumpAndSettle();
    bool saveOn() =>
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed !=
        null;

    await tester.tap(find.text('New tag'));
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, 'Name');
    // A name that normalises to nothing.
    await tester.enterText(name, ' | ');
    await tester.pump();
    expect(find.text('Enter a name'), findsOneWidget);
    expect(saveOn(), isFalse);
    // Done does nothing while Save is off.
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Enter a name'), findsOneWidget);
    await tester.enterText(name, 'Beach');
    await tester.pump();
    expect(find.text('Enter a name'), findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(p.emptyTags, contains('Beach'));

    await tester.tap(find.text('Goa trip'));
    await tester.pumpAndSettle();
    await tester.enterText(name, ' | ');
    await tester.pump();
    expect(find.text('Enter a name'), findsOneWidget);
    expect(saveOn(), isFalse);
    await tester.enterText(name, 'Holiday');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Edit tag'), findsNothing);
    expect(row(p, 'beachshack').tags, ['Holiday']);
  });

  testWidgets('a tap opens the editor, which renames, merges and colours a '
      'tag, with Undo', (tester) async {
    final p = await seeded();
    await p.setTagsForMany({row(p, 'coffeerun').id}, add: {'Work'});
    await tester.pumpWidget(
      withProviders(p, const ClassifiersScreen(initialTab: kCockpitTabTags)),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Edit tag'), findsNothing);
    await tester.tap(find.text('Goa trip'));
    await tester.pumpAndSettle();
    expect(find.text('Edit tag'), findsOneWidget);
    final name = find.widgetWithText(TextField, 'Name');
    await tester.enterText(name, 'work');
    await tester.pump();
    expect(find.text('Merges with the existing tag "Work"'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Merge'), findsOneWidget);

    await tester.enterText(name, 'Holiday');
    await tester.pump();
    final mint = find.byTooltip('Mint');
    await tester.ensureVisible(mint);
    await tester.pumpAndSettle();
    await tester.tap(mint);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(row(p, 'beachshack').tags, ['Holiday']);
    expect(p.tagColor('Holiday'), isNotNull);
    expect(find.text('Renamed "Goa trip" to "Holiday"'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row(p, 'beachshack').tags, ['Goa trip']);
    expect(p.tagColor('Goa trip'), isNull);
    expect(p.tagColor('Holiday'), isNull);
  });

  testWidgets('a coloured tag shows its colour on the chip in the edit sheet', (
    tester,
  ) async {
    final p = await seeded();
    await p.setTagColor('Goa trip', const Color(0xFF50D1AA));
    await tester.pumpWidget(
      withProviders(
        p,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddTransactionSheet(
                context,
                existing: row(p, 'beachshack'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await openExtras(tester);
    final chip = find.widgetWithText(InputChip, '# Goa trip');
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    final avatar = tester.widget<InputChip>(chip).avatar! as CircleAvatar;
    expect(avatar.backgroundColor, const Color(0xFF50D1AA));
  });
}
