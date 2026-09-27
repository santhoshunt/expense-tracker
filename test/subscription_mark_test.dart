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

    final toggle = find.widgetWithText(SwitchListTile, 'Subscription');
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(find.text('Every payment to Prime counts'), findsOneWidget);
    expect(find.text('Yearly'), findsNothing, reason: 'cycle hidden while off');
    await tester.tap(toggle);
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
    final toggle = find.widgetWithText(SwitchListTile, 'Subscription');
    expect(toggle, findsNothing, reason: 'no merchant yet');
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
    expect(p.subscriptionPins, isEmpty);
  });

  testWidgets('a transfer offers no switch', (tester) async {
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
    expect(find.widgetWithText(SwitchListTile, 'Subscription'), findsNothing);
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
    await tester.tap(find.byTooltip('Mark as subscription'));
    await tester.pumpAndSettle();
    expect(find.text('Mark 2 merchants as subscriptions'), findsOneWidget);
    expect(find.textContaining('1 row skipped'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Quarterly'));
    await tester.pumpAndSettle();
    expect(p.subscriptionPins, {
      'expense|prime': SubscriptionCycle.quarterly,
      'expense|water bill': SubscriptionCycle.quarterly,
    });

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.subscriptionPins, isEmpty);
  });
}
