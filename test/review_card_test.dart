import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/sms_parser.dart';
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
    // v2.3.0: each group has its name and count, the refund's over its
    // card and the food row's over the row.
    double top(Finder f) => tester.getTopLeft(f).dy;
    expect(top(find.text('Possible refund · 1')), lessThan(top(card)));
    expect(top(card), lessThan(top(find.text('No account number · 1'))));
    expect(find.text('Suggestions'), findsNothing);
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
    // One group under its name, and no batch bar.
    expect(find.text('Possible refund · 1'), findsOneWidget);
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

  // v2.3.0: rows grouped by why they wait, "Confirm N" on a group, and
  // every confirm's Undo taking back the imports it let count.
  group('groups', () {
    const bank = 'SAMPLEBK:1234';
    const fresh = 'SAMPLEBK:5678';

    ParsedTxn alert({
      TxType type = TxType.expense,
      required double amount,
      required DateTime date,
      required String? ref,
      String categoryId = 'food',
      String? rawBody,
      String? acctKey = bank,
      bool spamSuspect = false,
    }) => ParsedTxn(
      type: type,
      amount: amount,
      merchant: '',
      date: date,
      ref: ref,
      categoryId: categoryId,
      sender: 'VM-SAMPLE',
      rawBody: rawBody ?? 'Rs.$amount debited at LANTERN CAFE',
      acctKey: acctKey,
      spamSuspect: spamSuspect,
    );

    /// [bank] with one confirmed row, so its later alerts can count.
    Future<FinanceProvider> withHistory() async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        alert(amount: 450, date: DateTime(2026, 10, 1, 9), ref: 'SEED'),
      ]);
      await p.confirmAllPending();
      return p;
    }

    Tx byRef(FinanceProvider p, String ref) => [
      ...p.transactions,
      ...p.pendingTransactions,
    ].firstWhere((t) => t.externalRef == ref);

    /// Imports an alert that counts at once, then sends it back to review:
    /// a waiting row nothing holds.
    Future<void> addSentBack(FinanceProvider p) async {
      await p.addImported([
        alert(amount: 410, date: DateTime(2026, 10, 6, 17), ref: 'O1'),
      ]);
      final counted = byRef(p, 'O1');
      expect(counted.pending, isFalse);
      await p.restoreEditedTransactions([
        counted.copyWith(pending: true, unseen: false),
      ]);
    }

    Future<void> open(WidgetTester tester, FinanceProvider p) async {
      tester.view.physicalSize = const Size(800, 6000);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(screen(p, await settings(), home: sheetOpener));
      await openSheet(tester);
    }

    /// The Confirm button of the review row showing [amount].
    Finder confirmOf(double amount) => find.descendant(
      of: find.ancestor(
        of: find.textContaining('−${fmtMoney(amount)}'),
        matching: find.byType(ListTile),
      ),
      matching: find.byTooltip('Confirm'),
    );

    testWidgets('each group sits under its name and count, in order; a group '
        'with nothing in it has no name', (tester) async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 2000,
          date: DateTime(2026, 10, 6, 9),
          ref: 'W1',
          categoryId: 'other_expense',
          rawBody: 'Rs.2000 withdrawn at ATM',
        ),
        alert(
          amount: 5000,
          date: DateTime(2026, 10, 6, 10),
          ref: 'T1',
          categoryId: 'other_expense',
          rawBody: 'Rs.5000 debited from a/c XX1234',
        ),
        alert(
          type: TxType.income,
          amount: 5000,
          date: DateTime(2026, 10, 6, 10, 2),
          ref: 'T2',
          categoryId: 'other_income',
          rawBody: 'Rs.5000 credited to a/c XX5678',
          acctKey: fresh,
        ),
        alert(
          type: TxType.income,
          amount: 200,
          date: DateTime(2026, 10, 6, 11),
          ref: 'R1',
          categoryId: 'other_income',
          rawBody: 'Refund of Rs.200 credited to a/c XX1234',
        ),
        alert(amount: 250, date: DateTime(2026, 10, 6, 12), ref: 'D1'),
        alert(
          amount: 250,
          date: DateTime(2026, 10, 6, 19),
          ref: null,
          rawBody: 'Rs.250 debited at LANTERN CAFE again',
        ),
        alert(
          amount: 300,
          date: DateTime(2026, 10, 6, 13),
          ref: 'N1',
          acctKey: 'SAMPLEBK:9999',
        ),
        alert(
          amount: 350,
          date: DateTime(2026, 10, 6, 14),
          ref: 'X1',
          acctKey: null,
        ),
        alert(
          amount: 320,
          date: DateTime(2026, 10, 6, 15),
          ref: 'M1',
          categoryId: 'transfer_out',
        ),
        alert(
          amount: 330,
          date: DateTime(2026, 10, 6, 16),
          ref: 'S1',
          spamSuspect: true,
        ),
      ]);
      await open(tester, p);
      expect(tester.takeException(), isNull);

      final names = [
        'Cash withdrawals · 1',
        'Possible transfer · 1',
        'Possible refund · 1',
        'Possible duplicates · 2',
        'New account · 1',
        'No account number · 1',
        'Transfers · 1',
        'Suspected spam · 1',
      ];
      var last = double.negativeInfinity;
      for (final name in names) {
        expect(find.text(name), findsOneWidget, reason: name);
        final top = tester.getTopLeft(find.text(name)).dy;
        expect(top, greaterThan(last), reason: name);
        last = top;
      }
      // Nothing was sent back to review, and the old two labels are gone.
      expect(find.textContaining('To review ·'), findsNothing);
      expect(find.text('Suggestions'), findsNothing);
      // The three cards sit in the first three groups.
      expect(card, findsNWidgets(3));
      expect(
        tester.getTopLeft(find.textContaining('ATM withdrawal')).dy,
        lessThan(tester.getTopLeft(find.text(names[1])).dy),
      );
      expect(
        tester.getTopLeft(find.text('Looks like a refund')).dy,
        lessThan(tester.getTopLeft(find.text(names[3])).dy),
      );
      // "Confirm N" on the three groups a look at the name settles.
      expect(find.widgetWithText(TextButton, 'Confirm 1'), findsNWidgets(3));
      expect(find.widgetWithText(TextButton, 'Confirm 2'), findsNothing);
      for (final name in names.sublist(4, 7)) {
        final button = find.descendant(
          of: find.ancestor(
            of: find.text(name),
            matching: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_GroupHeader',
            ),
          ),
          matching: find.widgetWithText(TextButton, 'Confirm 1'),
        );
        expect(button, findsOneWidget, reason: name);
        expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('a group header fits 320dp at 2x text, its button under the '
        'name', (tester) async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 350,
          date: DateTime(2026, 10, 6, 14),
          ref: 'X1',
          acctKey: null,
        ),
      ]);
      tester.view.physicalSize = const Size(640, 3200);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        screen(p, await settings(), textScale: 2, home: sheetOpener),
      );
      await openSheet(tester);

      expect(tester.takeException(), isNull);
      // At this size the name runs to a second line rather than lose its
      // count to an ellipsis, and no-break spaces keep the count with the
      // name's last word.
      final name = find.text('No account number\u{00A0}·\u{00A0}1');
      expect(tester.widget<Text>(name).maxLines, 2);
      final button = find.widgetWithText(TextButton, 'Confirm 1');
      expect(
        tester.getTopLeft(button).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(name).dy),
      );
    });

    // v2.3.0 review: under the large-text switch the button sits beside
    // the name, and the two must share a 360dp row at 1.3x text.
    testWidgets('a group header fits 360dp at 1.3x text, its button beside '
        'the name', (tester) async {
      final p = await withHistory();
      await p.addImported([
        for (var i = 0; i < 12; i++)
          alert(
            amount: 350.0 + i,
            date: DateTime(2026, 10, 6, 14, i),
            ref: 'X$i',
            acctKey: null,
          ),
      ]);
      tester.view.physicalSize = const Size(720, 3200);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        screen(p, await settings(), textScale: 1.3, home: sheetOpener),
      );
      await openSheet(tester);

      expect(tester.takeException(), isNull);
      final name = find.text('No account number · 12');
      final button = find.widgetWithText(TextButton, 'Confirm 12');
      expect(name, findsOneWidget);
      expect(button, findsOneWidget);
      // One row: the button starts after the name ends, inside the sheet.
      expect(
        tester.getTopLeft(button).dy,
        lessThan(tester.getBottomLeft(name).dy),
      );
      expect(
        tester.getTopLeft(button).dx,
        greaterThanOrEqualTo(tester.getTopRight(name).dx),
      );
      expect(tester.getTopRight(button).dx, lessThanOrEqualTo(360));
      expect(tester.getTopLeft(name).dx, greaterThanOrEqualTo(0));
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      // Beside the name it stays on one line, and the two share a text
      // baseline: both are one text size, so their words sit level.
      expect(tester.widget<Text>(name).maxLines, 1);
      final words = find.text('Confirm 12');
      expect(tester.getSize(words).height, tester.getSize(name).height);
      expect(
        tester.getCenter(words).dy,
        moreOrLessEquals(tester.getCenter(name).dy, epsilon: 0.5),
      );
    });

    // v2.3.0 review: several groups can show a "Confirm N", and a screen
    // reader heard the same words for each.
    testWidgets('Confirm N is read out with its group name', (tester) async {
      final semantics = tester.ensureSemantics();
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 300,
          date: DateTime(2026, 10, 6, 13),
          ref: 'N1',
          acctKey: fresh,
        ),
        alert(
          amount: 350,
          date: DateTime(2026, 10, 6, 14),
          ref: 'X1',
          acctKey: null,
        ),
      ]);
      await open(tester, p);

      // The words on screen are the same for both.
      final buttons = find.widgetWithText(TextButton, 'Confirm 1');
      expect(buttons, findsNWidgets(2));
      expect(
        tester.getSemantics(buttons.first),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Confirm 1 in New account',
        ),
      );
      expect(
        tester.getSemantics(buttons.last),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label: 'Confirm 1 in No account number',
        ),
      );
      semantics.dispose();
    });

    testWidgets('Confirm N confirms its group, and Undo puts the rows back '
        'with the import they let count', (tester) async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 300,
          date: DateTime(2026, 10, 6, 13),
          ref: 'N1',
          acctKey: fresh,
        ),
        alert(
          amount: 310,
          date: DateTime(2026, 10, 6, 13, 30),
          ref: 'N2',
          acctKey: fresh,
        ),
        alert(
          amount: 350,
          date: DateTime(2026, 10, 6, 14),
          ref: 'X1',
          acctKey: null,
        ),
      ]);
      await addSentBack(p);
      await open(tester, p);
      expect(find.text('New account · 2'), findsOneWidget);
      expect(find.text('No account number · 1'), findsOneWidget);
      expect(find.text('To review · 1'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Confirm 1'));
      await tester.pumpAndSettle();
      expect(byRef(p, 'X1').pending, isFalse);
      // The row sent back to review counts again, marked new.
      expect(byRef(p, 'O1').pending, isFalse);
      expect(byRef(p, 'O1').unseen, isTrue);
      expect(p.pendingCount, 2);
      expect(find.text('No account number · 1'), findsNothing);
      expect(find.text('To review · 1'), findsNothing);
      expect(find.text('Confirmed 1 import'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(byRef(p, 'X1').pending, isTrue);
      expect(byRef(p, 'O1').pending, isTrue);
      expect(byRef(p, 'O1').unseen, isFalse);
      expect(find.text('No account number · 1'), findsOneWidget);
      expect(find.text('To review · 1'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Confirm 2'));
      await tester.pumpAndSettle();
      expect(byRef(p, 'N1').pending, isFalse);
      expect(byRef(p, 'N2').pending, isFalse);
      expect(byRef(p, 'N1').unseen, isFalse);
      expect(byRef(p, 'X1').pending, isTrue);
      expect(find.text('New account · 2'), findsNothing);
      expect(find.text('Confirmed 2 imports'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(p.pendingCount, 4);
      expect(find.text('New account · 2'), findsOneWidget);
    });

    testWidgets('confirming a row lets the rest of its account count, and '
        'Undo puts them all back in review', (tester) async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 300,
          date: DateTime(2026, 10, 6, 13),
          ref: 'N1',
          acctKey: fresh,
        ),
        alert(
          amount: 310,
          date: DateTime(2026, 10, 6, 13, 30),
          ref: 'N2',
          acctKey: fresh,
        ),
        alert(
          amount: 350,
          date: DateTime(2026, 10, 6, 14),
          ref: 'X1',
          acctKey: null,
        ),
      ]);
      await open(tester, p);
      expect(find.text('New account · 2'), findsOneWidget);

      await tester.tap(confirmOf(300));
      await tester.pumpAndSettle();
      expect(byRef(p, 'N1').pending, isFalse);
      expect(byRef(p, 'N1').unseen, isFalse);
      expect(byRef(p, 'N2').pending, isFalse);
      expect(byRef(p, 'N2').unseen, isTrue);
      expect(byRef(p, 'X1').pending, isTrue);
      expect(find.textContaining('New account'), findsNothing);
      expect(find.text('1 to review'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(byRef(p, 'N1').pending, isTrue);
      expect(byRef(p, 'N2').pending, isTrue);
      expect(byRef(p, 'N2').unseen, isFalse);
      expect(find.text('New account · 2'), findsOneWidget);
    });

    testWidgets('Keep as spending on a cash withdrawal: its Undo takes back '
        'the import it let count too', (tester) async {
      final p = await withHistory();
      await p.addImported([
        alert(
          amount: 2000,
          date: DateTime(2026, 10, 6, 9),
          ref: 'W1',
          categoryId: 'other_expense',
          rawBody: 'Rs.2000 withdrawn at ATM',
        ),
        alert(
          amount: 350,
          date: DateTime(2026, 10, 6, 14),
          ref: 'X1',
          acctKey: null,
        ),
      ]);
      await addSentBack(p);
      await open(tester, p);
      expect(find.text('Cash withdrawals · 1'), findsOneWidget);

      await tester.tap(find.text('Keep as spending'));
      await tester.pumpAndSettle();
      expect(byRef(p, 'W1').pending, isFalse);
      expect(byRef(p, 'O1').pending, isFalse);
      expect(find.text('Cash withdrawals · 1'), findsNothing);
      expect(find.text('Kept as spending'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(byRef(p, 'W1').pending, isTrue);
      expect(byRef(p, 'O1').pending, isTrue);
      expect(find.text('Cash withdrawals · 1'), findsOneWidget);
      expect(find.text('To review · 1'), findsOneWidget);
    });
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
