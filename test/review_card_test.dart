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
import 'package:expense_tracker/widgets/review_sheet.dart';

/// The review suggestions, now in the review sheet (v1.43.0): suggestions
/// as their own cards, Link for a refund, rows in a suggestion out of the
/// list, the bulk actions pinned under it, past refunds keeping the sheet
/// up, and the filter sheet's year label.
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

  /// v1.43.0: the suggestions live in the review sheet; this page opens it.
  final sheetOpener = Builder(
    builder: (context) => Center(
      child: TextButton(
        onPressed: () => showReviewSheet(context),
        child: const Text('open'),
      ),
    ),
  );

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a refund suggestion shows both sides and Link links it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([buy, refund(), food]);
    await tester.pumpWidget(screen(p, await settings(), home: sheetOpener));
    await openSheet(tester);

    expect(find.text('Imported from SMS'), findsOneWidget);
    expect(find.text('2 to review'), findsOneWidget);
    // Suggestions and rows both wait: each part has its label.
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(top(find.text('Suggestions')), lessThan(top(card)));
    expect(top(card), lessThan(top(find.text('To review'))));
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
    final foodTitle = find.text('Tasty Corner');
    expect(foodTitle, findsOneWidget);
    // Discard all and Confirm all sit pinned under the list.
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
    // The food row is left, so the sheet stays and shows the toast itself.
    expect(find.text('Imported from SMS'), findsOneWidget);
    expect(find.text('Linked as a refund'), findsOneWidget);

    // Undo puts the refund back in review, linked to nothing.
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(row().pending, isTrue);
    expect(row().refundOf, isNull);
    expect(find.text('Looks like a refund'), findsOneWidget);
  });

  testWidgets('a counted refund to review fills the sheet with no imports, '
      'and Not a refund closes it with Undo on the page', (tester) async {
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
    await tester.pumpWidget(screen(p, s, home: sheetOpener));
    await openSheet(tester);

    expect(find.text('1 to review'), findsOneWidget);
    expect(find.text('Looks like a refund'), findsOneWidget);
    // One part only: no section labels, and no batch bar.
    expect(find.text('Suggestions'), findsNothing);
    expect(find.text('Confirm all'), findsNothing);
    expect(find.byTooltip('Confirm'), findsNothing);

    await tester.tap(find.text('Not a refund'));
    await tester.pumpAndSettle();
    expect(s.dismissedPairSuggestions, contains('refund|r-past|buy'));
    expect(p.refundReviewIds, isEmpty);
    // Emptied, the sheet closes; the toast waits on the page.
    expect(find.text('Imported from SMS'), findsNothing);
    expect(find.text('Marked not a refund'), findsOneWidget);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.refundReviewIds, {'r-past'});
    expect(s.dismissedPairSuggestions, isNot(contains('refund|r-past|buy')));
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
    await tester.pumpWidget(
      screen(p, await settings(), textScale: 2, home: sheetOpener),
    );
    await openSheet(tester);

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
