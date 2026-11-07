import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/subscriptions.dart';

/// Marking a merchant as a subscription by hand: the edit sheet's switch
/// and cycle, and the selection bar's action.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<(FinanceProvider, SettingsProvider)> seeded() async {
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'entertainment',
      amount: 1499,
      note: 'Prime',
      date: DateTime(now.year, now.month, 1),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'bills',
      amount: 300,
      note: 'Water bill',
      date: DateTime(now.year, now.month, 1),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: kTransferOutCategoryId,
      amount: 5000,
      note: 'To savings',
      date: DateTime(now.year, now.month, 1),
    );
    final s = SettingsProvider();
    await s.load();
    return (p, s);
  }

  Widget app(FinanceProvider p, SettingsProvider s, Widget home) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(home: home),
      );

  Tx row(FinanceProvider p, String note) =>
      p.transactions.singleWhere((t) => t.note == note);

  /// The add sheet's Subscription switch: a ListTile with its own Switch.
  Finder subscriptionSwitch() => find.descendant(
    of: find.widgetWithText(ListTile, 'Subscription'),
    matching: find.byType(Switch),
  );

  /// Opens the add sheet's Tags, subscription, count in group.
  Future<void> openExtras(WidgetTester tester) async {
    await tester.pumpAndSettle();
    final fold = find.byKey(const ValueKey('fold-extras'));
    await tester.ensureVisible(fold);
    await tester.pumpAndSettle();
    await tester.tap(fold);
    await tester.pumpAndSettle();
  }

  testWidgets('the edit sheet switch marks the merchant on Save', (
    tester,
  ) async {
    final (p, s) = await seeded();
    await tester.pumpWidget(
      app(
        p,
        s,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAddTransactionSheet(context, existing: row(p, 'Prime')),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await openExtras(tester);
    final toggle = subscriptionSwitch();
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Every payment to Prime counts'), findsOneWidget);
    expect(find.text('Yearly'), findsNothing, reason: 'cycle hidden while off');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    // The cycles open under the switch, toward the pinned footer.
    await tester.ensureVisible(find.text('Yearly'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yearly'));
    await tester.pumpAndSettle();
    expect(p.subscriptionPins, isEmpty, reason: 'nothing until Save');

    final save = find.widgetWithText(FilledButton, 'Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(p.subscriptionPins, {'expense|prime': SubscriptionCycle.yearly});
    final item = cachedSubscriptions(p, s.hiddenUpcoming).active.single;
    expect(item.hit.label, 'Prime');
    expect(item.yearly, 1499);
  });

  testWidgets('a new entry shows the switch once its note names a merchant, '
      'and off then on again changes nothing', (tester) async {
    final (p, s) = await seeded();
    // Phone-shaped: on the default 800x600 surface the sheet's Add button
    // sits below the bottom edge and the tap missed silently.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        p,
        s,
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
    // A new entry keeps the switch folded.
    await openExtras(tester);
    final toggle = subscriptionSwitch();
    expect(toggle, findsNothing, reason: 'no merchant yet');
    expect(
      find.text('Add Paid to or a note to mark a subscription'),
      findsOneWidget,
    );
    // Income can never be a subscription: no line telling the user to try.
    final income = find.text('Income');
    await tester.ensureVisible(income);
    await tester.pumpAndSettle();
    await tester.tap(income);
    await tester.pumpAndSettle();
    expect(
      find.text('Add Paid to or a note to mark a subscription'),
      findsNothing,
    );
    // Money out to savings hides Paid to: only the note is offered.
    final transfer = find.text('Transfer');
    await tester.ensureVisible(transfer);
    await tester.pumpAndSettle();
    await tester.tap(transfer);
    await tester.pumpAndSettle();
    expect(find.text('Add a note to mark a subscription'), findsOneWidget);
    expect(
      find.text('Add Paid to or a note to mark a subscription'),
      findsNothing,
    );
    final expense = find.text('Expense');
    await tester.ensureVisible(expense);
    await tester.pumpAndSettle();
    await tester.tap(expense);
    await tester.pumpAndSettle();
    expect(
      find.text('Add Paid to or a note to mark a subscription'),
      findsOneWidget,
    );
    expect(find.text('Add a note to mark a subscription'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Note (optional)'),
      'Spotify',
    );
    await tester.pump();
    expect(toggle, findsOneWidget);
    expect(find.text('Every payment to Spotify counts'), findsOneWidget);

    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pump();
    await tester.tap(toggle);
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '119');
    final add = find.widgetWithText(FilledButton, 'Add');
    await tester.ensureVisible(add);
    await tester.pumpAndSettle();
    await tester.tap(add);
    await tester.pumpAndSettle();
    // The row saved, so an empty pin set means the toggle really was off.
    expect(p.transactions.where((t) => t.note == 'Spotify'), hasLength(1));
    expect(p.subscriptionPins, isEmpty);
  });

  testWidgets('a money-out transfer offers the switch, as savings', (
    tester,
  ) async {
    final (p, s) = await seeded();
    await tester.pumpWidget(
      app(
        p,
        s,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddTransactionSheet(
                context,
                existing: row(p, 'To savings'),
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
    expect(subscriptionSwitch(), findsOneWidget);
  });

  testWidgets('the selection bar marks each merchant once, skips the '
      'transfer, and Undo restores', (tester) async {
    final (p, s) = await seeded();
    await tester.pumpWidget(
      app(p, s, const Scaffold(body: TransactionsScreen())),
    );
    await tester.pump(const Duration(milliseconds: 700));

    await tester.longPress(find.textContaining('Prime'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining('Water bill'));
    await tester.tap(find.textContaining('To savings'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk-more-subscription')));
    await tester.pumpAndSettle();
    // The title, and the footer button that reads the same.
    expect(find.text('Mark as subscriptions'), findsNWidgets(2));
    expect(find.textContaining('1 row skipped'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Quarterly'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Mark as subscriptions'),
    );
    await tester.pumpAndSettle();
    expect(p.subscriptionPins, {
      'expense|prime': SubscriptionCycle.quarterly,
      'expense|water bill': SubscriptionCycle.quarterly,
    });

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.subscriptionPins, isEmpty);
  });

  testWidgets('the bulk subscription sheet fits 2x text with many '
      'merchants', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    final now = DateTime.now();
    for (var i = 0; i < 12; i++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'entertainment',
        amount: 100.0 + i,
        note: 'Demo Service $i',
        date: DateTime(now.year, now.month, 1),
      );
    }
    final s = SettingsProvider();
    await s.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(body: TransactionsScreen()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));

    await tester.longPress(find.textContaining('Demo Service').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('Select all or none'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk-count-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bulk-more-subscription')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('and 9 more'), findsOneWidget);
    final save = find.byKey(const ValueKey('editor-save'));
    expect(save.hitTestable(), findsOneWidget);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(p.subscriptionPins, hasLength(12));
  });
}
