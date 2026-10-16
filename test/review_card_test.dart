import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';

/// v1.42.0 review card: suggestions as their own cards, Link for a refund,
/// rows in a suggestion out of the list, the bulk actions under it, past
/// refunds keeping the card up, and the filter sheet's year label.
/// Invented merchants, accounts and alerts only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget screen(
    FinanceProvider p,
    SettingsProvider s, {
    double textScale = 1,
    Widget home = const TransactionsScreen(),
  }) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider.value(value: s),
    ],
    child: MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(body: home),
    ),
  );

  Future<SettingsProvider> settings() async {
    final s = SettingsProvider();
    await s.load();
    return s;
  }

  const acct = 'DEMOBK:4321';
  final buy = Tx(
    id: 'buy',
    type: TxType.expense,
    categoryId: 'shopping',
    amount: 1200,
    note: 'Gadget Hub',
    date: DateTime(2026, 10, 1, 18, 30),
    acctKey: acct,
  );
  Tx refund({String id = 'back', bool pending = true}) => Tx(
    id: id,
    type: TxType.income,
    categoryId: 'other_income',
    amount: 1200,
    note: '',
    smsBody: 'Refund of Rs 1200.00 credited to a/c XX4321. -Demo Bank',
    source: TxSource.sms,
    sender: 'VM-DEMOBK',
    acctKey: acct,
    date: DateTime(2026, 10, 4, 10),
    pending: pending,
  );
  final food = Tx(
    id: 'q-food',
    type: TxType.expense,
    categoryId: 'food',
    amount: 349,
    note: 'Tasty Corner',
    date: DateTime(2026, 10, 5, 12, 2),
    sender: 'VM-DEMOBK',
    pending: true,
  );

  final card = find.byWidgetPredicate(
    (w) => w.runtimeType.toString() == '_SuggestionCard',
  );

  testWidgets('a refund suggestion shows both sides and Link links it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([buy, refund(), food]);
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();

    expect(find.text('Imported from SMS · 2 to review'), findsOneWidget);
    expect(find.text('Looks like a refund'), findsOneWidget);
    expect(card, findsOneWidget);
    Finder inCard(Finder f) => find.descendant(of: card, matching: f);
    expect(inCard(find.text('−${fmtMoneyTidy(1200)}')), findsOneWidget);
    expect(inCard(find.text('+${fmtMoneyTidy(1200)}')), findsOneWidget);
    expect(
      inCard(find.textContaining('Gadget Hub', findRichText: true)),
      findsOneWidget,
    );
    expect(
      inCard(find.textContaining('VM-DEMOBK', findRichText: true)),
      findsOneWidget,
    );
    expect(inCard(find.text('Not a refund')), findsOneWidget);

    // The refund sits in its card only: the list keeps the food row.
    expect(find.byTooltip('Confirm'), findsOneWidget);
    final foodTitle = find.text('${categoryById('food').label} · Tasty Corner');
    expect(foodTitle, findsOneWidget);
    // Discard all and Confirm all sit under the list.
    expect(
      tester.getTopLeft(find.text('Confirm all')).dy,
      greaterThan(tester.getBottomLeft(foodTitle).dy),
    );
    expect(
      tester.getTopLeft(find.text('Discard all')).dy,
      greaterThan(tester.getBottomLeft(foodTitle).dy),
    );

    await tester.tap(inCard(find.text('Link')));
    await tester.pumpAndSettle();
    Tx row() => [
      ...p.transactions,
      ...p.pendingTransactions,
    ].firstWhere((t) => t.id == 'back');
    expect(row().pending, isFalse);
    expect(row().refundOf, 'buy');
    expect(p.isLinkedRefund(row()), isTrue);
    expect(find.text('Looks like a refund'), findsNothing);
    expect(find.text('Linked as a refund'), findsOneWidget);

    // Undo puts the refund back in review, linked to nothing.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row().pending, isTrue);
    expect(row().refundOf, isNull);
    expect(find.text('Looks like a refund'), findsOneWidget);
  });

  testWidgets('a counted refund to review keeps the card up with no imports, '
      'and Not a refund drops it', (tester) async {
    SharedPreferences.setMockInitialValues({
      'transactions_v1': jsonEncode([
        buy.toJson(),
        refund(id: 'r-past', pending: false).toJson(),
      ]),
      'refunds_linked_v1': true,
      'refund_suggest_ids_v1': ['r-past'],
    });
    final p = FinanceProvider();
    await p.load();
    final s = await settings();
    expect(p.refundReviewIds, {'r-past'});
    await tester.pumpWidget(screen(p, s));
    await tester.pumpAndSettle();

    expect(find.text('Imported from SMS · 1 to review'), findsOneWidget);
    expect(find.text('Looks like a refund'), findsOneWidget);
    expect(find.text('Confirm all'), findsNothing);
    expect(find.byTooltip('Confirm'), findsNothing);

    await tester.ensureVisible(find.text('Not a refund'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not a refund'));
    await tester.pumpAndSettle();
    expect(s.dismissedPairSuggestions, contains('refund|r-past|buy'));
    expect(p.refundReviewIds, isEmpty);
    expect(find.text('Looks like a refund'), findsNothing);
    expect(find.textContaining('Imported from SMS'), findsNothing);
  });

  testWidgets('suggestion cards fit 320dp at 2x text', (tester) async {
    tester.view.physicalSize = const Size(640, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      buy.copyWith(amount: 1234567.89),
      refund().copyWith(amount: 1234567.89),
      food,
    ]);
    await tester.pumpWidget(screen(p, await settings(), textScale: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Looks like a refund'), findsOneWidget);
    // The whole figure is there, shrunk to fit rather than cut.
    expect(
      find.descendant(
        of: card,
        matching: find.text('+${fmtMoney(1234567.89)}'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the filter sheet Date chip keeps a dashboard year name', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    final token = ValueNotifier<int>(0);
    addTearDown(token.dispose);
    await tester.pumpWidget(
      screen(
        p,
        await settings(),
        home: ValueListenableBuilder<int>(
          valueListenable: token,
          builder: (_, t, _) => TransactionsScreen(
            filterToken: t,
            request: TxFilterRequest(
              range: DateTimeRange(
                start: DateTime(2026, 4, 1),
                end: DateTime(2027, 3, 31),
              ),
              rangeCounted: true,
              rangeLabel: 'FY 2026-27',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    token.value = 1;
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'FY 2026-27'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Custom range…'), findsNothing);

    // Another pick drops the name: All time shows the plain choice again.
    await tester.tap(find.widgetWithText(ChoiceChip, 'All time'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'FY 2026-27'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Custom range…'), findsOneWidget);
  });
}
