import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/saved_filter.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/utils/money_colors.dart';
import 'package:expense_tracker/widgets/glossy.dart';
import 'package:expense_tracker/widgets/info_tip.dart';

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

  group('saved filters', () {
    final saveCurrent = find.text('Save current');
    final nameField = find.widgetWithText(TextField, 'Name');
    final save = find.widgetWithText(FilledButton, 'Save');
    final actions = find.byTooltip('Saved filter actions');
    const nothingSaved = 'No saved filters yet.';
    const nothingSet = 'Set some filters, then save them here.';

    Future<FinanceProvider> spends() => withRows([
      (TxType.expense, 'food', 100, 'tea', DateTime(2026, 7, 1, 9)),
      (TxType.expense, 'food', 1000, 'dinner', DateTime(2026, 7, 2, 9)),
      (TxType.income, 'salary', 5000, 'pay', DateTime(2026, 7, 3, 9)),
    ]);

    // Expenses of 500 and up: of the rows above, the dinner alone.
    const bigSpends = SavedFilter(
      id: 'flt_1_0',
      name: 'Big spends',
      tab: 'expense',
      min: 500,
    );

    Future<void> open(WidgetTester tester, FinanceProvider p) async {
      await tester.pumpWidget(screen(p));
      await tester.pumpAndSettle();
      await tester.tap(tune);
      await tester.pumpAndSettle();
    }

    // With a filter on the page the count badge sits over the button's
    // centre; the tap lands on the button all the same.
    Future<void> openFiltered(WidgetTester tester) async {
      await tester.tap(tune, warnIfMissed: false);
      await tester.pumpAndSettle();
    }

    bool saveEnabled(WidgetTester tester) =>
        tester.widget<FilledButton>(save).onPressed != null;

    testWidgets('the rail starts with Saved, which says nothing is saved '
        'and shows Save current once a filter is set', (tester) async {
      phone(tester);
      final p = await spends();
      await open(tester, p);

      // No saved filter: the sheet opens on Date, as before.
      expect(find.text('All time'), findsOneWidget);
      expect(
        tester.getTopLeft(railRow('saved')).dy,
        lessThan(tester.getTopLeft(railRow('date')).dy),
      );
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      expect(find.text(nothingSaved), findsOneWidget);
      expect(find.text(nothingSet), findsOneWidget);
      expect(saveCurrent, findsNothing);
      // Nothing to search here.
      expect(find.widgetWithText(TextField, 'Search filters…'), findsNothing);

      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Min'), '500');
      await tester.pumpAndSettle();
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      expect(find.text(nothingSaved), findsOneWidget);
      expect(find.text(nothingSet), findsNothing);
      expect(saveCurrent, findsOneWidget);
      // The Saved row never counts picks.
      expect(
        find.descendant(of: railRow('saved'), matching: find.text('Saved')),
        findsOneWidget,
      );
    });

    testWidgets('Save current names the draft: a taken name is refused and '
        'the new row appears', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await open(tester, p);

      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Max'), '200');
      await tester.pumpAndSettle();
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      await tester.tap(saveCurrent);
      await tester.pumpAndSettle();

      expect(find.text('Save filters'), findsOneWidget);
      // What is being saved, in a few words.
      expect(find.text('Amount up to ₹200'), findsOneWidget);
      final tip = tester.widget<InfoTip>(find.byType(InfoTip));
      expect(tip.message, contains('the type tab'));
      expect(tip.message, contains('"This month"'));
      expect(tip.message, contains('Search and sort are not saved'));
      expect(saveEnabled(tester), isFalse);

      await tester.enterText(nameField, 'big SPENDS ');
      await tester.pumpAndSettle();
      expect(find.text('That name is taken'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);

      await tester.enterText(nameField, ' Small ones ');
      await tester.pumpAndSettle();
      expect(find.text('That name is taken'), findsNothing);
      expect(saveEnabled(tester), isTrue);
      await tester.tap(save);
      await tester.pumpAndSettle();

      // The row in the list is the feedback: no toast behind the sheet.
      expect(find.text('Small ones'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(
        [for (final f in p.savedFilters) f.name],
        ['Big spends', 'Small ones'],
      );
      final saved = p.savedFilters.last;
      expect(saved.id, startsWith('flt_'));
      expect(saved.tab, 'all');
      expect(saved.max, 200);
      expect(saved.min, isNull);
      expect(saved.thisMonth, isFalse);
    });

    testWidgets('a tap on a saved row loads the draft, and Show applies it '
        'with its type tab', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await open(tester, p);

      expect(find.widgetWithText(FilledButton, 'Show 3'), findsOneWidget);
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      // The count follows the saved tab too: the pay is 500 and up, but
      // it is not an expense.
      expect(find.widgetWithText(FilledButton, 'Show 1'), findsOneWidget);
      expect(
        find.descendant(
          of: railRow('amount'),
          matching: find.text('Amount · 1'),
        ),
        findsOneWidget,
      );
      // Clear all puts the page's tab back in the draft with the rest:
      // all three rows, not the two expenses.
      await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Show 3'), findsOneWidget);
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      await tester.tap(show);
      await tester.pumpAndSettle();

      expect(find.text('dinner'), findsOneWidget);
      expect(find.text('tea'), findsNothing);
      expect(find.text('pay'), findsNothing);
      expect(find.text('Amount from ₹500'), findsOneWidget);
      final tabs = tester.widget(
        find.byWidgetPredicate((w) => w is UnderlineTabs),
      );
      expect('${(tabs as dynamic).selected}', endsWith('.expense'));
    });

    testWidgets('the sheet opens on Saved when a filter is saved and no '
        'chip is on the page, and on Date once one is', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await open(tester, p);

      expect(find.text('Big spends'), findsOneWidget);
      expect(find.text('All time'), findsNothing);
      expect(find.text(nothingSaved), findsNothing);
      // The tab is All and nothing is set: nothing to save yet.
      expect(find.text(nothingSet), findsOneWidget);

      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      await tester.tap(show);
      await tester.pumpAndSettle();
      await openFiltered(tester);
      expect(find.text('All time'), findsOneWidget);
      expect(find.text('Big spends'), findsNothing);
    });

    testWidgets('saving while the current month is picked stores This '
        'month, not the month', (tester) async {
      phone(tester);
      final p = await spends();
      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month);
      await tester.pumpWidget(screen(p));
      await tester.pumpAndSettle();
      // The month arrives as a dashboard tap sets it.
      await tester.pumpWidget(
        providers(
          p,
          Scaffold(
            body: TransactionsScreen(
              request: TxFilterRequest(month: thisMonth),
              filterToken: 1,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openFiltered(tester);
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      await tester.tap(saveCurrent);
      await tester.pumpAndSettle();
      expect(find.text('This month'), findsOneWidget);
      await tester.enterText(nameField, 'Month so far');
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      final saved = p.savedFilters.single;
      expect(saved.thisMonth, isTrue);
      expect(saved.month, isNull);
      // Nothing stored ties it to the month it was saved in.
      expect(saved.toJson(), {
        'id': saved.id,
        'name': 'Month so far',
        'tab': 'all',
        'thisMonth': true,
      });
    });

    testWidgets('a This month filter loads the month it is now, a fixed '
        'month the one saved', (tester) async {
      phone(tester);
      final p = await spends();
      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month);
      final fixed = DateTime(2026, 7);
      // As a filter saved in any earlier month reads from storage.
      await p.saveFilter(
        SavedFilter.fromJson({
          'id': 'flt_1_0',
          'name': 'Month so far',
          'thisMonth': true,
        })!,
      );
      await p.saveFilter(
        SavedFilter(id: 'flt_2_0', name: 'That July', month: fixed),
      );
      await open(tester, p);

      await tester.tap(find.text('Month so far'));
      await tester.pumpAndSettle();
      await tester.tap(railRow('date'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, fmtMonth(thisMonth)), findsOne);

      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('That July'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Show 3'), findsOneWidget);
      await tester.tap(railRow('date'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, fmtMonth(fixed)), findsOne);
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('Month · ${fmtMonth(fixed)}'), findsOneWidget);
    });

    testWidgets('a saved range keeps its year name and counted dates '
        'through a load', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(
        SavedFilter(
          id: 'flt_1_0',
          name: 'That year',
          rangeStart: DateTime(2026, 4, 1),
          rangeEnd: DateTime(2027, 3, 31),
          rangeCounted: true,
          rangeLabel: 'FY 2026-27',
        ),
      );
      await open(tester, p);
      await tester.tap(find.text('That year'));
      await tester.pumpAndSettle();
      await tester.tap(railRow('date'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, 'FY 2026-27'), findsOne);
      await tester.tap(show);
      await tester.pumpAndSettle();
      // The page's chip carries the name, as a dashboard year does.
      expect(find.text('FY 2026-27'), findsOneWidget);

      // Saved again from the applied page, the flavour is still there.
      await openFiltered(tester);
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      await tester.tap(saveCurrent);
      await tester.pumpAndSettle();
      await tester.enterText(nameField, 'Copy');
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final copy = p.savedFilters.last;
      expect(copy.rangeStart, DateTime(2026, 4, 1));
      expect(copy.rangeEnd, DateTime(2027, 3, 31));
      expect(copy.rangeCounted, isTrue);
      expect(copy.rangeLabel, 'FY 2026-27');
    });

    testWidgets('Rename keeps the filter under a new name; Delete asks '
        'first', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await p.saveFilter(const SavedFilter(id: 'flt_2_0', name: 'Rent'));
      await open(tester, p);

      await tester.tap(actions.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      // Its own title: nothing is being saved for the first time.
      expect(find.text('Rename saved filter'), findsOneWidget);
      expect(find.text('Save filters'), findsNothing);
      expect(find.text('Expenses · Amount from ₹500'), findsOneWidget);
      expect(
        tester.widget<TextField>(nameField).controller?.text,
        'Big spends',
      );
      // Unchanged: nothing to save.
      expect(saveEnabled(tester), isFalse);
      await tester.enterText(nameField, 'rent');
      await tester.pumpAndSettle();
      expect(find.text('That name is taken'), findsOneWidget);
      await tester.enterText(nameField, '  ');
      await tester.pumpAndSettle();
      expect(find.text('Enter a name'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
      await tester.enterText(nameField, 'Large');
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(find.text('Large'), findsOneWidget);
      expect(find.text('Big spends'), findsNothing);
      expect(p.savedFilters.first.toJson(), {
        ...bigSpends.toJson(),
        'name': 'Large',
      });

      await tester.tap(actions.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete saved filter'), findsOneWidget);
      expect(find.textContaining('"Rent"'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(p.savedFilters, hasLength(2));

      await tester.tap(actions.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Rent'), findsNothing);
      expect(find.text('Large'), findsOneWidget);
      expect([for (final f in p.savedFilters) f.name], ['Large']);
      expect(find.byType(SnackBar), findsNothing);
    });

    /// The page's type tab by name: all, income, expense or transfers.
    String pageTab(WidgetTester tester) {
      final tabs = tester.widget(
        find.byWidgetPredicate((w) => w is UnderlineTabs),
      );
      return '${(tabs as dynamic).selected}'.split('.').last;
    }

    /// The page as a deep link lands on it, set to [request].
    Future<void> openWith(
      WidgetTester tester,
      FinanceProvider p,
      TxFilterRequest request,
    ) async {
      await tester.pumpWidget(screen(p));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        providers(
          p,
          Scaffold(body: TransactionsScreen(request: request, filterToken: 1)),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder railLabel(String id, String label) =>
        find.descendant(of: railRow(id), matching: find.text(label));

    Future<void> pickCategory(WidgetTester tester, String id) async {
      await tester.tap(railRow('categories'));
      await tester.pumpAndSettle();
      final chip = find.widgetWithText(FilterChip, categoryById(id).label);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }

    // v2.3.0 review: the sheet has no control for the type tab, so a
    // loaded filter's tab holds only while the draft is still that filter.
    testWidgets('a loaded filter changed by hand leaves the page on its own '
        'tab', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await open(tester, p);
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Show 1'), findsOneWidget);

      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      final min = find.widgetWithText(TextField, 'Min');
      await tester.enterText(min, '');
      await tester.pumpAndSettle();
      // No longer the saved filter: counted on the page's tab, All.
      expect(find.widgetWithText(FilledButton, 'Show 3'), findsOneWidget);
      // Typed back, it is that filter again, tab and all.
      await tester.enterText(min, '500');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Show 1'), findsOneWidget);

      await tester.enterText(min, '');
      await tester.pumpAndSettle();
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(pageTab(tester), 'all');
      expect(find.text('tea'), findsOneWidget);
      expect(find.text('pay'), findsOneWidget);
    });

    // v2.3.0 review: a saved filter applied as saved replaces what the
    // page showed; one changed by hand is an edit of the page's filters.
    testWidgets('a saved filter shown as saved clears the To check ids, and '
        'one changed by hand keeps them', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      String idOf(String note) =>
          p.transactions.firstWhere((t) => t.note == note).id;
      await openWith(
        tester,
        p,
        TxFilterRequest(ids: {idOf('tea'), idOf('pay')}),
      );
      expect(find.text('To check · 2'), findsOneWidget);
      expect(find.text('dinner'), findsNothing);

      await openFiltered(tester);
      // The sheet does not edit the ids: they narrow its count.
      expect(find.widgetWithText(FilledButton, 'Show 2'), findsOneWidget);
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      // Counted as Show will list it: the dinner, which is not in the ids.
      expect(find.widgetWithText(FilledButton, 'Show 1'), findsOneWidget);
      // Changed by hand, the ids count again: the pay alone is 500 and up.
      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Max'), '9000');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Show 1'), findsOneWidget);
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('To check · 2'), findsOneWidget);
      expect(find.text('pay'), findsOneWidget);
      expect(find.text('dinner'), findsNothing);
      expect(pageTab(tester), 'all');

      // Loaded again and shown as it is.
      await openFiltered(tester);
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('To check · 2'), findsNothing);
      expect(find.text('dinner'), findsOneWidget);
      expect(find.text('pay'), findsNothing);
      expect(pageTab(tester), 'expense');
    });

    // v2.3.0 review: the page drops ids whose target is gone once Show
    // applies them, so the sheet drops them as the filter loads.
    testWidgets('a saved filter loads without its deleted category and '
        'account, so Show counts what it lists', (tester) async {
      phone(tester);
      final p = await spends();
      final account = await p.addAccount(
        name: 'Spare Bank',
        type: AccountType.bank,
      );
      final category = await p.addCategory(
        label: 'Street food',
        type: TxType.expense,
        icon: Icons.fastfood,
        color: Colors.teal,
      );
      await p.saveFilter(
        SavedFilter(
          id: 'flt_1_0',
          name: 'Meals',
          categories: ['food', category],
          accountId: account,
        ),
      );
      await p.deleteCategory(category);
      await p.deleteAccount(account);
      await open(tester, p);

      await tester.tap(find.text('Meals'));
      await tester.pumpAndSettle();
      expect(railLabel('categories', 'Categories · 1'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Show 2'), findsOneWidget);
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('tea'), findsOneWidget);
      expect(find.text('dinner'), findsOneWidget);
      expect(find.text('pay'), findsNothing);
      // The stored filter is left as it was saved.
      expect(p.savedFilters.single.accountId, account);
    });

    // v2.3.0 review: a category deleted into another one (a merge) left
    // the saved filter naming the dead id, so it loaded with no category
    // and listed everything.
    testWidgets('a saved filter follows its category into the one it is '
        'merged with, and Undo puts the filter back', (tester) async {
      phone(tester);
      final p = await spends();
      Future<String> category(String label) => p.addCategory(
        label: label,
        type: TxType.expense,
        icon: Icons.fastfood,
        color: Colors.teal,
      );
      final street = await category('Street food');
      final bakery = await category('Bakery');
      await p.addTransaction(
        type: TxType.expense,
        categoryId: street,
        amount: 60,
        note: 'chaat',
        date: DateTime(2026, 7, 4, 9),
      );
      // Sorted, as the sheet saves them.
      SavedFilter on(String id, String name, List<String> categories) =>
          SavedFilter(id: id, name: name, categories: categories..sort());
      await p.saveFilter(on('flt_1_0', 'Snacks', [street]));
      // Already on the target too: the merge must not list it twice.
      await p.saveFilter(on('flt_2_0', 'Meals', ['food', street]));
      await p.saveFilter(on('flt_3_0', 'Bread', [bakery]));
      final before = p.savedFilters;
      List<String> categoriesOf(FinanceProvider f, String id) =>
          f.savedFilters.firstWhere((x) => x.id == id).categories;

      final deleted = await p.deleteCategory(street, moveTo: 'food');
      expect(categoriesOf(p, 'flt_1_0'), ['food']);
      expect(categoriesOf(p, 'flt_2_0'), ['food']);
      // A filter on another category is the same object as before.
      expect(identical(p.savedFilters.last, before.last), isTrue);
      // Written, not only held in memory.
      final again = FinanceProvider();
      await again.load();
      expect(categoriesOf(again, 'flt_1_0'), ['food']);

      // Loaded, the filter lists the merged category's rows, the moved one
      // among them, and not the pay.
      await open(tester, p);
      await tester.tap(find.text('Snacks'));
      await tester.pumpAndSettle();
      expect(railLabel('categories', 'Categories · 1'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Show 3'), findsOneWidget);
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('chaat'), findsOneWidget);
      expect(find.text('tea'), findsOneWidget);
      expect(find.text('pay'), findsNothing);

      await p.restoreCategory(deleted);
      expect(categoriesOf(p, 'flt_1_0'), [street]);
      expect(categoriesOf(p, 'flt_2_0'), ['food', street]..sort());
      expect(categoriesOf(p, 'flt_3_0'), [bakery]);
      final undone = FinanceProvider();
      await undone.load();
      expect(categoriesOf(undone, 'flt_1_0'), [street]);
    });

    test('a category deleted with nowhere to move leaves saved filters as '
        'they were', () async {
      final p = await spends();
      final street = await p.addCategory(
        label: 'Street food',
        type: TxType.expense,
        icon: Icons.fastfood,
        color: Colors.teal,
      );
      await p.saveFilter(
        SavedFilter(id: 'flt_1_0', name: 'Snacks', categories: [street]),
      );
      final saved = p.savedFilters.single;

      final deleted = await p.deleteCategory(street);
      expect(identical(p.savedFilters.single, saved), isTrue);
      expect(deleted.filtersBefore, isEmpty);
      await p.restoreCategory(deleted);
      expect(identical(p.savedFilters.single, saved), isTrue);
    });

    testWidgets('loading a saved filter replaces the picks made in the sheet '
        'before it', (tester) async {
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await open(tester, p);

      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Max'), '200');
      await tester.pumpAndSettle();
      await pickCategory(tester, 'salary');
      expect(railLabel('categories', 'Categories · 1'), findsOneWidget);
      expect(railLabel('amount', 'Amount · 1'), findsOneWidget);

      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      expect(railLabel('categories', 'Categories'), findsOneWidget);
      expect(railLabel('amount', 'Amount · 1'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Show 1'), findsOneWidget);
      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      String? textOf(String field) => tester
          .widget<TextField>(find.widgetWithText(TextField, field))
          .controller
          ?.text;
      expect(textOf('Min'), '500');
      expect(textOf('Max'), '');
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text('Amount from ₹500'), findsOneWidget);
      expect(find.text('dinner'), findsOneWidget);
      expect(find.text('pay'), findsNothing);
    });

    testWidgets('Save current on a page whose tab is not All stores that '
        'tab', (tester) async {
      phone(tester);
      final p = await spends();
      await openWith(tester, p, const TxFilterRequest(type: TxType.expense));
      expect(pageTab(tester), 'expense');
      await openFiltered(tester);
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      // The tab alone is something to save.
      expect(find.text(nothingSet), findsNothing);
      await tester.tap(saveCurrent);
      await tester.pumpAndSettle();
      await tester.enterText(nameField, 'Spending');
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      final saved = p.savedFilters.single;
      expect(saved.toJson(), {
        'id': saved.id,
        'name': 'Spending',
        'tab': 'expense',
      });
    });

    // v2.3.0 review: a dashboard year arrives as a range with counted
    // dates and a name, and the sheet hands both back unless the range
    // itself is picked again.
    testWidgets('a dashboard year keeps its name through Show unchanged and '
        'a category change, and a new custom range drops it', (tester) async {
      // Wide: the range picker's own header needs the room in the test
      // font, where every letter is a full square.
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await withRows([
        (TxType.expense, 'food', 100, 'tea', DateTime(2025, 7, 1, 9)),
        (TxType.income, 'salary', 5000, 'pay', DateTime(2025, 7, 3, 9)),
      ]);
      final year = DateTimeRange(
        start: DateTime(2025, 4, 1),
        end: DateTime(2026, 3, 31),
      );
      const name = 'FY 2025-26';
      await openWith(
        tester,
        p,
        TxFilterRequest(range: year, rangeCounted: true, rangeLabel: name),
      );
      expect(find.text(name), findsOneWidget);

      // Opened and shown as it is.
      await openFiltered(tester);
      expect(find.widgetWithText(ChoiceChip, name), findsOne);
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);

      // A category picked beside it.
      await openFiltered(tester);
      await pickCategory(tester, 'food');
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text(name), findsOneWidget);
      expect(find.text('tea'), findsOneWidget);
      expect(find.text('pay'), findsNothing);

      // The same days picked again in the range picker are a plain range.
      await openFiltered(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, name));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ChoiceChip, name), findsNothing);
      expect(find.widgetWithText(ChoiceChip, fmtDateRange(year)), findsOne);
      await tester.tap(show);
      await tester.pumpAndSettle();
      expect(find.text(name), findsNothing);
      expect(find.text(fmtDateRange(year)), findsOneWidget);
    });

    testWidgets('a saved row and Save current read as buttons', (tester) async {
      final semantics = tester.ensureSemantics();
      phone(tester);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await open(tester, p);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('saved-filter-flt_1_0'))),
        isSemantics(isButton: true, hasTapAction: true),
      );
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byKey(const ValueKey('filters-save-current'))),
        isSemantics(isButton: true, hasTapAction: true, label: 'Save current'),
      );
      semantics.dispose();
    });

    // v2.3.0 rendered-screen pass.
    testWidgets('the empty line starts where a first saved row\'s name does, '
        'names that wrap keep a gap between them, and Save current is the '
        'pill at this size', (tester) async {
      phone(tester);
      final p = await spends();
      await open(tester, p);
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      // The centre of its first line, 16dp tall: in the test font the
      // words run to a second one.
      final emptyLine = tester.getTopLeft(find.text(nothingSaved)).dy + 8;

      await p.saveFilter(const SavedFilter(id: 'flt_1_0', name: 'Rent'));
      for (final (i, name) in const [
        'Household groceries and vegetables every week',
        'Fuel and tolls on the long weekend drives',
      ].indexed) {
        await p.saveFilter(
          SavedFilter(id: 'flt_${i + 2}_0', name: name, tab: 'expense'),
        );
      }
      // Any tap in the sheet rebuilds it with the new rows.
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      expect(find.text(nothingSaved), findsNothing);
      // A one-line name sits mid-row, level with where the empty line was.
      expect(
        tester.getCenter(find.text('Rent')).dy,
        moreOrLessEquals(emptyLine, epsilon: 0.5),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('saved-filter-flt_1_0')))
            .height,
        48,
      );
      // Two names of two lines each do not run into one block.
      final household = find.textContaining('Household');
      final first = tester.getRect(household);
      final second = tester.getRect(find.textContaining('Fuel and tolls'));
      expect(tester.widget<Text>(household).maxLines, 2);
      expect(
        first.height,
        greaterThan(tester.getSize(find.text('Rent')).height),
      );
      expect(second.top - first.bottom, greaterThanOrEqualTo(12));
      // Beside the name, the menu.
      expect(
        tester.getRect(actions.first).left,
        greaterThanOrEqualTo(tester.getRect(find.text('Rent')).right),
      );

      await tester.tap(find.text('Rent'));
      await tester.pumpAndSettle();
      // Rent holds no filter and the page is on All: nothing to save yet.
      await tester.tap(railRow('amount'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Min'), '500');
      await tester.pumpAndSettle();
      await tester.tap(railRow('saved'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('filters-save-current')),
          matching: find.widgetWithText(OutlinedPill, 'Save current'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('at 320dp and 2x text the Saved section, its menu and its '
        'dialogs fit', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await spends();
      await p.saveFilter(bigSpends);
      await p.saveFilter(
        const SavedFilter(
          id: 'flt_2_0',
          name: 'Household groceries and vegetables every week',
          tab: 'expense',
          categories: ['food'],
        ),
      );
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
      expect(find.text(nothingSet), findsOneWidget);

      // At this size a saved row's name has the pane's width, up to three
      // lines, with its menu on a line of its own under it, at the end.
      // Beside the menu the name broke inside words.
      final pane = tester.getRect(
        find.byKey(const ValueKey('saved-filter-flt_1_0')),
      );
      final name = tester.getRect(find.text('Big spends'));
      // The button with its 48dp tap target, not the 40dp circle inside.
      final menu = tester.getRect(
        find.byWidgetPredicate((w) => w is PopupMenuButton).first,
      );
      expect(tester.widget<Text>(find.text('Big spends')).maxLines, 3);
      expect(name.width, pane.width);
      expect(menu.top, greaterThanOrEqualTo(name.bottom));
      expect(menu.right, pane.right);
      expect(menu.height, greaterThanOrEqualTo(48));

      // Loaded, the draft can be saved, inside the sheet.
      await tester.tap(find.text('Big spends'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(saveCurrent);
      await tester.pumpAndSettle();
      expect(tester.getRect(saveCurrent).right, lessThanOrEqualTo(320 - 20));
      // A text button across the pane, its words at the size of the text
      // around them and free to wrap: the pill, scaled down to fit here,
      // was drawn at half that size.
      final target = find.byKey(const ValueKey('filters-save-current'));
      expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(target).width, pane.width);
      expect(
        find.descendant(of: target, matching: find.byType(OutlinedPill)),
        findsNothing,
      );
      expect(
        find.descendant(of: target, matching: find.byType(FittedBox)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: target,
          matching: find.byIcon(Icons.bookmark_add_outlined),
        ),
        findsOneWidget,
      );
      // A tap at the target's edge, away from the words, saves.
      final top = tester.getRect(target).topRight + const Offset(-3, 3);
      await tester.tapAt(top);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Save filters'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(actions.first);
      await tester.pumpAndSettle();
      await tester.tap(actions.first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Delete saved filter'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
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
