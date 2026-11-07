import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/utils/money_colors.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// v1.38.0 Transactions feedback: the plain "Search" hint, lakh amounts in
/// search, the Amount chip, rows under a day header showing their time,
/// money colours on the rows, and the add sheet's Tags, subscription,
/// count in fold with Add pinned above the keyboard.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget providers(FinanceProvider p, Widget home) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
    ],
    child: MaterialApp(home: home),
  );

  Widget screen(FinanceProvider p) =>
      providers(p, const Scaffold(body: TransactionsScreen()));

  Future<FinanceProvider> withRows(
    List<(TxType, String, num, String, DateTime)> rows,
  ) async {
    final p = FinanceProvider();
    await p.load();
    for (final (type, categoryId, amount, note, date) in rows) {
      await p.addTransaction(
        type: type,
        categoryId: categoryId,
        amount: amount.toDouble(),
        note: note,
        date: date,
      );
    }
    return p;
  }

  // The Filters button in the search field opens the sheet; the sort has
  // its own button beside it.
  final tune = find.byIcon(Icons.tune);
  final sortButton = find.byIcon(Icons.swap_vert);

  // The filters sheet's pinned "Show N", and a section row of its rail.
  final show = find.ancestor(
    of: find.textContaining(RegExp(r'^Show ')),
    matching: find.byType(FilledButton),
  );
  Finder railRow(String id) => find.byKey(ValueKey('filters-section-$id'));

  /// One active filter chip: the 48dp box around the pill and its close.
  Finder filterChip(String label) =>
      find.ancestor(of: find.text(label), matching: find.byType(Stack)).first;

  testWidgets('the search hint reads Search, and a lakh amount matches its '
      'Indian grouping', (tester) async {
    final p = await withRows([
      (TxType.expense, 'food', 125000, 'big dinner', DateTime(2026, 7, 1, 9)),
      (TxType.expense, 'food', 340, 'cab', DateTime(2026, 7, 2, 9)),
    ]);
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    final field = find.byType(TextField).first;
    expect(tester.widget<TextField>(field).decoration?.hintText, 'Search');

    await tester.enterText(field, '1,25,000');
    await tester.pump(const Duration(milliseconds: 300)); // debounce
    await tester.pumpAndSettle();
    expect(find.text('big dinner'), findsOneWidget);
    expect(find.text('cab'), findsNothing);
  });

  testWidgets('an amount range shows one chip whose delete clears both '
      'bounds', (tester) async {
    phone(tester);
    final p = await withRows([
      (TxType.expense, 'food', 100, 'tea', DateTime(2026, 7, 1, 9)),
      (TxType.expense, 'food', 1000, 'dinner', DateTime(2026, 7, 2, 9)),
      (TxType.expense, 'food', 5000, 'party', DateTime(2026, 7, 3, 9)),
    ]);
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    await tester.tap(tune);
    await tester.pumpAndSettle();
    Future<void> type(String label, String text) async {
      final f = find.widgetWithText(TextField, label);
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.enterText(f, text);
    }

    await tester.tap(railRow('amount'));
    await tester.pumpAndSettle();
    await type('Min', '500');
    await type('Max', '2000');
    await tester.tap(show);
    await tester.pumpAndSettle();

    const label = 'Amount ₹500 to ₹2,000';
    final chip = filterChip(label);
    expect(find.text(label), findsOneWidget);
    // Left-aligned with the type tabs above it (both start at the
    // screen's 16dp gutter, as the search field does), not centred.
    expect(tester.getTopLeft(chip).dx, moreOrLessEquals(16, epsilon: 1));
    expect(
      tester.getTopLeft(find.text('All').first).dx,
      greaterThanOrEqualTo(16),
    );
    expect(
      tester.getTopLeft(find.byWidgetPredicate((w) => w is UnderlineTabs)).dx,
      moreOrLessEquals(16, epsilon: 1),
    );
    expect(find.text('dinner'), findsOneWidget);
    expect(find.text('tea'), findsNothing);
    expect(find.text('party'), findsNothing);

    // The close is a full 44 by 48dp target.
    final close = find.byTooltip('Remove $label');
    expect(
      tester.getSize(
        find.ancestor(of: close, matching: find.byType(IconButton)),
      ),
      const Size(44, 48),
    );
    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text(label), findsNothing);
    expect(find.text('tea'), findsOneWidget);
    expect(find.text('party'), findsOneWidget);
    // Both bounds went: the sheet opens with empty fields.
    await tester.tap(tune);
    await tester.pumpAndSettle();
    await tester.tap(railRow('amount'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Min'))
          .controller
          ?.text,
      isEmpty,
    );
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Max'))
          .controller
          ?.text,
      isEmpty,
    );
  });

  testWidgets('the Filters header holds the title and Clear all, and Show '
      'sits at the bottom', (tester) async {
    final p = await withRows([
      (TxType.expense, 'food', 100, 'tea', DateTime(2026, 7, 1, 9)),
    ]);
    final title = find.byKey(const ValueKey('filters-title'));
    final clearAll = find.widgetWithText(TextButton, 'Clear all');

    for (final width in [390.0, 600.0]) {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(screen(p));
      await tester.pumpAndSettle();
      await tester.tap(tune);
      await tester.pumpAndSettle();

      // The sheet's content padding is 20dp each side: never centred.
      expect(
        tester.getTopLeft(title).dx,
        moreOrLessEquals(20, epsilon: 0.5),
        reason: 'width $width',
      );
      expect(
        tester.getTopRight(clearAll).dx,
        moreOrLessEquals(width - 20, epsilon: 0.5),
        reason: 'width $width',
      );
      expect(
        tester.getCenter(clearAll).dy,
        moreOrLessEquals(tester.getCenter(title).dy, epsilon: 2),
        reason: 'one line: Clear all beside the title',
      );
      expect(show, findsOneWidget);
      expect(
        tester.getBottomLeft(show).dy,
        lessThanOrEqualTo(844),
        reason: 'width $width',
      );
      expect(
        tester.getTopLeft(show).dy,
        greaterThan(tester.getBottomLeft(title).dy),
      );
      // Close the sheet before the next width.
      await tester.tap(show);
      await tester.pumpAndSettle();
    }

    // At 320dp and 2x text nothing overflows, and the rail's labels stay
    // inside the rail.
    tester.view.physicalSize = const Size(320, 568);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
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
    await tester.pumpAndSettle();
    await tester.tap(tune);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final railFinder = find.byKey(const ValueKey('filters-rail'));
    final rail = tester.getRect(railFinder);
    // The rows the rail has built; it scrolls at this height.
    final labels = find.descendant(of: railFinder, matching: find.byType(Text));
    expect(labels, findsAtLeastNWidgets(2));
    for (final label in tester.widgetList<Text>(labels)) {
      final r = tester.getRect(find.byWidget(label));
      expect(r.left, greaterThanOrEqualTo(rail.left), reason: label.data);
      expect(r.right, lessThanOrEqualTo(rail.right + 0.5), reason: label.data);
    }
    await tester.tap(railRow('amount'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getBottomLeft(show).dy, lessThanOrEqualTo(568));
  });

  testWidgets('with the keyboard up the filters sheet fits a small phone: '
      'Show hides and the search stays above the keyboard', (tester) async {
    final p = await withRows([
      (TxType.expense, 'food', 100, 'tea', DateTime(2026, 7, 1, 9)),
    ]);
    final search = find.widgetWithText(TextField, 'Search filters…');
    for (final (size, scale) in [
      (const Size(320, 568), 1.0),
      (const Size(360, 640), 2.0),
    ]) {
      final why = '$size at ${scale}x';
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const Scaffold(body: TransactionsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(tune);
      await tester.pumpAndSettle();
      await tester.tap(railRow('categories'));
      await tester.pumpAndSettle();
      expect(search, findsOneWidget, reason: why);

      // A 280dp keyboard while typing in Search filters.
      await tester.showKeyboard(search);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: why);
      expect(show, findsNothing, reason: why);
      expect(
        tester.getBottomLeft(search).dy,
        lessThanOrEqualTo(size.height - 280),
        reason: why,
      );

      // The keyboard closed: Show is back.
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(show, findsOneWidget, reason: why);

      // On Amount, the focused Min stays above the keyboard.
      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      final min = find.widgetWithText(TextField, 'Min');
      await tester.showKeyboard(min);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: why);
      expect(
        tester.getBottomLeft(min).dy,
        lessThanOrEqualTo(size.height - 280),
        reason: why,
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(show).dy,
        lessThanOrEqualTo(size.height),
        reason: why,
      );
      // Close the sheet before the next size.
      await tester.tap(show);
      await tester.pumpAndSettle();
    }
  });

  testWidgets('Show counts the draft and a fractional bound survives a '
      'reopen', (tester) async {
    phone(tester);
    final p = await withRows([
      (TxType.expense, 'food', 99, 'tea', DateTime(2026, 7, 1, 9)),
      (TxType.expense, 'food', 99.5, 'coffee', DateTime(2026, 7, 2, 9)),
      (TxType.expense, 'food', 250, 'lunch', DateTime(2026, 7, 3, 9)),
    ]);
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();
    await tester.tap(tune);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Show 3'), findsOneWidget);

    await tester.tap(railRow('amount'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Min'), '99.5');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Show 2'), findsOneWidget);
    await tester.tap(show);
    await tester.pumpAndSettle();
    expect(find.text('tea'), findsNothing);
    expect(find.text('coffee'), findsOneWidget);

    await tester.tap(tune);
    await tester.pumpAndSettle();
    await tester.tap(railRow('amount'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Min'))
          .controller
          ?.text,
      '99.5',
    );
  });

  testWidgets('at 320dp and 2x text the amount chip keeps its delete on '
      'screen and the month header its whole short name', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = await withRows([
      (TxType.income, 'salary', 85000, 'pay', DateTime(2026, 7, 1, 9)),
      (TxType.expense, 'food', 12345, 'dinner', DateTime(2026, 7, 2, 9)),
    ]);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
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
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The list's own header (the one with Select month), not the pinned
    // copy: the short name in full, never "J…".
    final july = DateTime(2026, 7);
    final label =
        (july.year == DateTime.now().year
                ? DateFormat('MMM').format(july)
                : DateFormat('MMM yyyy').format(july))
            .toUpperCase();
    expect(find.byTooltip('Select month'), findsOneWidget);
    final name = tester.renderObject<RenderParagraph>(find.text(label));
    expect(name.didExceedMaxLines, isFalse, reason: 'label "$label" cut');

    await tester.tap(tune);
    await tester.pumpAndSettle();
    Future<void> type(String field, String text) async {
      final f = find.widgetWithText(TextField, field);
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.enterText(f, text);
    }

    await tester.tap(railRow('amount'));
    await tester.pumpAndSettle();
    await type('Min', '100000');
    await type('Max', '2000000');
    await tester.tap(show);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final delete = find.byWidgetPredicate(
      (w) => w is Tooltip && (w.message ?? '').startsWith('Remove Amount'),
    );
    expect(delete, findsOneWidget);
    final chip = find.ancestor(of: delete, matching: find.byType(Stack)).first;
    expect(tester.getTopRight(chip).dx, lessThanOrEqualTo(320));
    expect(tester.getTopRight(delete).dx, lessThanOrEqualTo(320));
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(delete, findsNothing);
  });

  testWidgets('under a day header a row shows its time, not the date', (
    tester,
  ) async {
    phone(tester);
    final teaTime = DateTime(2026, 7, 1, 16, 12);
    final lunchDay = DateTime(2026, 7, 1);
    final p = await withRows([
      (TxType.expense, 'food', 40, 'tea', teaTime),
      // Midnight: the app's "no time known".
      (TxType.expense, 'food', 90, 'lunch', lunchDay),
    ]);
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    // v1.43.0: the time sits under the amount; line two is the category.
    final time = find.text(fmtTime(teaTime));
    expect(time, findsOneWidget);
    expect(
      tester.getTopLeft(time).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.text('−${fmtMoney(40)}')).dy,
      ),
    );
    expect(find.text(fmtDateCompact(teaTime)), findsNothing);
    // The midnight row shows no time.
    expect(find.text('lunch'), findsOneWidget);
    expect(find.text(' · '), findsNothing);
    expect(find.text(fmtDateCompact(lunchDay)), findsNothing);

    // Any other sort has no day headers: the date comes back.
    await tester.tap(sortButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Amount · high to low'));
    await tester.pumpAndSettle();
    expect(find.text(fmtDateCompact(teaTime)), findsOneWidget);
    expect(find.text(fmtDateCompact(lunchDay)), findsOneWidget);
  });

  testWidgets('row amounts: money in green, money out red, a transfer '
      'plain', (tester) async {
    phone(tester);
    final p = await withRows([
      (TxType.income, 'salary', 500, 'pay', DateTime(2026, 7, 1, 9)),
      (TxType.expense, 'food', 100, 'tea', DateTime(2026, 7, 2, 9)),
      (
        TxType.expense,
        kSavingsTransferCategoryId,
        2000,
        'deposit',
        DateTime(2026, 7, 3, 9),
      ),
    ]);
    await tester.pumpWidget(screen(p));
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(TransactionsScreen));
    Color? colorOf(String text) =>
        tester.widget<Text>(find.text(text)).style?.color;

    expect(
      colorOf('+${fmtMoney(500)}'),
      moneyColor(context, type: TxType.income),
    );
    expect(
      colorOf('−${fmtMoney(100)}'),
      moneyColor(context, type: TxType.expense),
    );
    expect(
      colorOf('−${fmtMoney(2000)}'),
      moneyColor(context, type: TxType.expense, transfer: true),
    );
    expect(
      moneyColor(context, type: TxType.income),
      isNot(moneyColor(context, type: TxType.expense)),
    );
  });

  group('add sheet', () {
    Widget opener(FinanceProvider p, {Tx? existing}) => providers(
      p,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showAddTransactionSheet(context, existing: existing),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('a new entry folds the extras under the Tags, subscription, '
        'count in fold and keeps Add above the keyboard', (tester) async {
      phone(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      final p = FinanceProvider();
      await p.load();
      await tester.pumpWidget(opener(p));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // v1.43.0: Paid to sits in the form; Sender left the add sheet.
      final sender = find.widgetWithText(TextFormField, 'Sender (optional)');
      final payee = find.widgetWithText(TextFormField, 'Paid to');
      final more = find.text('Tags, subscription, count in');
      final fold = find.byKey(const ValueKey('fold-extras'));
      expect(more, findsOneWidget);
      expect(find.text('None'), findsOne);
      expect(payee, findsOneWidget);
      expect(sender, findsNothing);
      expect(find.text('Count in another date'), findsNothing);

      // Add sits in the footer, above the keyboard's 300px.
      final add = find.widgetWithText(FilledButton, 'Add');
      expect(add, findsOneWidget);
      expect(tester.getBottomLeft(add).dy, lessThanOrEqualTo(900 - 300));

      // TalkBack hears the fold's state.
      bool? expanded() => tester
          .widget<Semantics>(
            find.ancestor(
              of: more,
              matching: find.byWidgetPredicate(
                (w) => w is Semantics && w.properties.expanded != null,
              ),
            ),
          )
          .properties
          .expanded;
      expect(expanded(), isFalse);

      await tester.ensureVisible(fold);
      await tester.pumpAndSettle();
      await tester.tap(fold);
      await tester.pumpAndSettle();
      expect(expanded(), isTrue);
      expect(sender, findsNothing);
      expect(find.widgetWithText(TextField, 'Tags'), findsOneWidget);
      expect(find.text('Count in another date'), findsOneWidget);
      // The footer stays put with the fold open.
      expect(tester.getBottomLeft(add).dy, lessThanOrEqualTo(900 - 300));

      // A payee typed in Paid to saves with the row, tidied.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Amount'),
        '80',
      );
      await tester.enterText(payee, '  Corner   shop ');
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(p.transactions.single.payee, 'Corner shop');
      expect(p.transactions.single.sender, isEmpty);
    });

    testWidgets('editing keeps every field in place and Save at the bottom', (
      tester,
    ) async {
      phone(tester);
      final p = await withRows([
        (TxType.expense, 'food', 80, 'tea', DateTime(2026, 7, 1, 9)),
      ]);
      await tester.pumpWidget(opener(p, existing: p.transactions.single));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('More details'), findsNothing);
      // A manual row with no sender shows Paid to, not Sender.
      expect(
        find.widgetWithText(TextFormField, 'Sender (optional)'),
        findsNothing,
      );
      expect(find.widgetWithText(TextFormField, 'Paid to'), findsOneWidget);
      final fold = find.byKey(const ValueKey('fold-extras'));
      await tester.ensureVisible(fold);
      await tester.pumpAndSettle();
      await tester.tap(fold);
      await tester.pumpAndSettle();
      expect(find.text('Count in another date'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Add'), findsNothing);
      final save = find.widgetWithText(FilledButton, 'Save changes');
      final delete = find.text('Delete transaction');
      expect(save, findsOneWidget);
      // Delete waits in the ⋮ menu; Save is pinned in view.
      expect(delete, findsNothing);
      await tester.tap(find.byTooltip('Transaction actions'));
      await tester.pumpAndSettle();
      expect(delete, findsOneWidget);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      expect(tester.getBottomLeft(save).dy, lessThanOrEqualTo(900));
    });

    testWidgets('Discard changes? styles Discard as a destructive action', (
      tester,
    ) async {
      phone(tester);
      final p = FinanceProvider();
      await p.load();
      await tester.pumpWidget(opener(p));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'Amount'), '9');
      await tester.pump();
      final NavigatorState nav = tester.state(find.byType(Navigator));
      await nav.maybePop();
      await tester.pumpAndSettle();

      final discard = find.widgetWithText(FilledButton, 'Discard');
      expect(discard, findsOneWidget);
      final context = tester.element(discard);
      final style = tester.widget<FilledButton>(discard).style;
      expect(
        style?.backgroundColor?.resolve({}),
        Theme.of(context).colorScheme.error,
      );
    });
  });
}
