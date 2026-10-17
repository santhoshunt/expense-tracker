import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/category_tile_icon.dart';
import 'package:expense_tracker/widgets/review_sheet.dart';
import 'package:expense_tracker/widgets/status_dot.dart';

/// v1.38.1 on the Transactions tab: the opaque month band, the slim jump
/// panel, Mark all seen and the ⋮ menu's page entries. The review queue,
/// its rows and the spam fold moved to the review sheet in v1.43.0; their
/// tests here run against the sheet.
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
      home: const Scaffold(body: TransactionsScreen()),
    ),
  );

  /// A page with one button that opens the review sheet.
  Widget sheetHost(
    FinanceProvider p,
    SettingsProvider s, {
    double textScale = 1,
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
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showReviewSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<SettingsProvider> settings() async {
    final s = SettingsProvider();
    await s.load();
    return s;
  }

  /// Thirty confirmed rows over July and June 2026, enough to scroll.
  Future<FinanceProvider> longLedger() async {
    final p = FinanceProvider();
    await p.load();
    for (var d = 1; d <= 20; d++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 10.0 + d,
        note: 'jul $d',
        date: DateTime(2026, 7, d),
      );
    }
    for (var d = 1; d <= 10; d++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 50.0 + d,
        note: 'jun $d',
        date: DateTime(2026, 6, d),
      );
    }
    return p;
  }

  // Fake review queue: two legs of one move (a pair suggestion), a food
  // spend and a spam suspect. Added with restoreTransactions so they stay
  // pending whatever the import rules decide.
  final outLeg = Tx(
    id: 'q-out',
    type: TxType.expense,
    categoryId: 'other_expense',
    amount: 5000,
    note: '',
    date: DateTime(2026, 10, 13, 12, 0),
    sender: 'VM-DEMOBK',
    acctKey: 'DEMOBK:1111',
    pending: true,
  );
  final inLeg = Tx(
    id: 'q-in',
    type: TxType.income,
    categoryId: 'other_income',
    amount: 5000,
    note: '',
    date: DateTime(2026, 10, 13, 12, 2),
    sender: 'VM-DEMOCC',
    acctKey: 'DEMOCC:2222',
    pending: true,
  );
  final food = Tx(
    id: 'q-food',
    type: TxType.expense,
    categoryId: 'food',
    amount: 349,
    note: 'Tasty Corner',
    date: DateTime(2026, 10, 13, 12, 2),
    sender: 'VM-DEMOBK',
    pending: true,
  );
  final spam = Tx(
    id: 'q-spam',
    type: TxType.income,
    categoryId: 'other_income',
    amount: 10000,
    note: 'Prize Desk',
    date: DateTime(2026, 10, 13, 10, 0),
    sender: 'AX-PROMOS',
    pending: true,
    suspectedSpam: true,
  );

  Future<FinanceProvider> queue() async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([outLeg, inLeg, food, spam]);
    return p;
  }

  final sticky = find.byKey(const ValueKey('sticky-month-header'));
  final jump = find.byKey(const ValueKey('jump-controls'));
  double jumpOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(jump).opacity;

  testWidgets('the sticky month band is fully opaque', (tester) async {
    final p = await longLedger();
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(300, 450), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(sticky, findsOneWidget);
    final box = tester.widget<Container>(sticky);
    final color = (box.decoration! as BoxDecoration).color!;
    expect(color.a, 1.0);
  });

  testWidgets('the jump panel has up and down only, 32dp wide, hidden '
      'during a drag and shown when the scroll ends', (tester) async {
    final p = await longLedger();
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();
    expect(jumpOpacity(tester), 0, reason: 'hidden until a scroll');

    await tester.dragFrom(const Offset(300, 450), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(jumpOpacity(tester), 1, reason: 'shown once the scroll ends');
    expect(find.byTooltip('Newer month'), findsOneWidget);
    expect(find.byTooltip('Older month'), findsOneWidget);
    expect(find.byTooltip('Jump to month'), findsNothing);
    expect(
      find.descendant(of: jump, matching: find.byIcon(Icons.calendar_month)),
      findsNothing,
    );
    expect(tester.getSize(jump).width, lessThanOrEqualTo(34));
    expect(tester.getSize(find.byKey(const ValueKey('jump-down'))).height, 48);

    // A finger on the list: the panel steps aside while it drags.
    final g = await tester.startGesture(const Offset(300, 450));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(jumpOpacity(tester), 0, reason: 'hidden during the drag');

    // Held still, then lifted: no fling, so the scroll ends at once.
    await tester.pump(const Duration(milliseconds: 300));
    await g.up();
    await tester.pumpAndSettle();
    expect(jumpOpacity(tester), 1, reason: 'back when the scroll ends');

    await tester.pump(const Duration(milliseconds: 1700));
    await tester.pumpAndSettle();
    expect(jumpOpacity(tester), 0, reason: 'gone 1.6 s later');
  });

  testWidgets('the review sheet fits 320dp at 2x text', (tester) async {
    tester.view.physicalSize = const Size(640, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final p = await queue();
    await tester.pumpWidget(sheetHost(p, await settings(), textScale: 2));
    await openSheet(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('Not a transfer'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
    expect(find.text('Confirm all'), findsOneWidget);
    expect(find.text('Discard all'), findsOneWidget);

    // Merchant first: the note names the row.
    expect(find.text('Tasty Corner', skipOffstage: false), findsOneWidget);

    // Large text: Confirm and Discard sit under the row's text.
    final confirm = find.byTooltip('Confirm').first;
    final row = find.ancestor(of: confirm, matching: find.byType(Column)).first;
    final tile = find.descendant(of: row, matching: find.byType(ListTile));
    expect(tile, findsOneWidget);
    expect(
      tester.getTopLeft(confirm).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(tile).dy),
    );
    expect(
      find.descendant(of: row, matching: find.byTooltip('Discard')),
      findsOneWidget,
    );
  });

  testWidgets('a review row reads merchant over amount · category, under '
      'its day', (tester) async {
    final p = await queue();
    await tester.pumpWidget(sheetHost(p, await settings()));
    await openSheet(tester);

    final title = find.text('Tasty Corner');
    expect(title, findsOneWidget);
    final line = find.text('−${fmtMoney(349)} · ${categoryById('food').label}');
    expect(line, findsOneWidget);
    // Time and sender stay in the edit sheet (the suggestion card above
    // names its sides' senders, not the rows).
    Finder inRows(Finder f) =>
        find.descendant(of: find.byType(ListTile), matching: f);
    expect(inRows(find.textContaining('VM-DEMOBK')), findsNothing);
    expect(inRows(find.textContaining('12:02 PM')), findsNothing);
    // The day label sits over the row.
    final day = find.text(fmtDayHeading(food.date));
    expect(day, findsOneWidget);
    expect(tester.getTopLeft(day).dy, lessThan(tester.getTopLeft(title).dy));
    // The category's tile leads the row.
    expect(
      find.ancestor(of: title, matching: find.byType(ListTile)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.ancestor(of: title, matching: find.byType(ListTile)),
        matching: find.byType(CategoryTileIcon),
      ),
      findsOneWidget,
    );
  });

  testWidgets('inside Home at 320x700 with 2x text, nothing sits above the '
      'list but the bars, and the message icon opens the sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 1400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final p = await queue();
    for (var d = 1; d <= 6; d++) {
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 40.0 + d,
        note: 'oct $d',
        date: DateTime(2026, 10, d),
      );
    }
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const HomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    AppNav.instance.openHomeTab(
      tester.element(find.byType(HomeScreen)),
      kHomeTabTransactions,
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // No review card on the tab: the list keeps the height.
    expect(find.text('Not a transfer'), findsNothing);
    expect(find.byKey(const ValueKey('review-cards')), findsNothing);
    final screenHeight = tester.getSize(find.byType(TransactionsScreen)).height;
    final list = tester.getSize(find.byType(PageView));
    expect(list.height, greaterThan(screenHeight * 0.3));

    // The badge counts what the sheet lists: three imports and the spam.
    expect(
      find.descendant(
        of: find.byTooltip('Review imports'),
        matching: find.text('4'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Review imports'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Not a transfer'), findsOneWidget);
    expect(find.text('Imported from SMS'), findsOneWidget);
  });

  testWidgets('the new line starts at the list inset, one text size', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      Tx(
        id: 'n1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'counted import',
        date: DateTime(2026, 10, 12, 9, 30),
        unseen: true,
      ),
    ]);
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();

    final line = find.byKey(const ValueKey('unseen-line'));
    final dot = find.descendant(of: line, matching: find.byType(StatusDot));
    expect(tester.getTopLeft(dot).dx, 20);
    double? sizeOf(Finder f) => tester
        .widget<RichText>(
          find.descendant(of: f, matching: find.byType(RichText)),
        )
        .text
        .style
        ?.fontSize;
    expect(sizeOf(find.text('1 new ·')), sizeOf(find.text('Mark all seen')));
    // A full 48dp tap target.
    final button = find.ancestor(
      of: find.text('Mark all seen'),
      matching: find.byType(TextButton),
    );
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));

    // The month header follows closely: its usual 24dp top gap shrinks
    // while the line sits above it.
    final october = DateTime(2026, 10);
    final label = find.text(
      (october.year == DateTime.now().year
              ? DateFormat('MMMM').format(october)
              : DateFormat('MMMM yyyy').format(october))
          .toUpperCase(),
    );
    final gap = tester.getTopLeft(label).dy - tester.getBottomLeft(button).dy;
    expect(gap, lessThan(24));
    expect(gap, greaterThanOrEqualTo(0));
  });

  testWidgets('a review row with no merchant is titled by its category', (
    tester,
  ) async {
    final p = await queue();
    final s = await settings();
    // The no-merchant row is a transfer leg: it shows in the list once the
    // suggestion holding it is dismissed.
    await s.dismissPairSuggestion('q-in|q-out');
    await tester.pumpWidget(sheetHost(p, s));
    await openSheet(tester);

    final other = categoryById('other_expense').label;
    expect(find.textContaining('· Payment'), findsNothing);
    // Both legs are titled by their category ("Other" either way), and
    // line two is the amount alone.
    expect(find.text(other), findsNWidgets(2));
    expect(find.text('−${fmtMoney(5000)}'), findsOneWidget);
    expect(find.text('+${fmtMoney(5000)}'), findsOneWidget);
  });

  testWidgets('Not a transfer hides the suggestion, and Undo brings it back', (
    tester,
  ) async {
    final p = await queue();
    final s = await settings();
    await tester.pumpWidget(sheetHost(p, s));
    await openSheet(tester);

    final suggestion = find.textContaining('Looks like a transfer');
    expect(suggestion, findsOneWidget);
    await tester.ensureVisible(find.text('Not a transfer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not a transfer'));
    await tester.pumpAndSettle();
    expect(suggestion, findsNothing);
    expect(s.dismissedPairSuggestions, contains('q-in|q-out'));
    expect(find.text('Marked not a transfer'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(s.dismissedPairSuggestions, isEmpty);
    expect(suggestion, findsOneWidget);
  });

  testWidgets('spam amounts are plain text, the fold counts them and its '
      'rows carry their day', (tester) async {
    final p = await queue();
    await tester.pumpWidget(sheetHost(p, await settings()));
    await openSheet(tester);

    final fold = find.text('Suspected spam · 1');
    expect(fold, findsOneWidget);
    // Folded while imports wait: open it.
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(
      find.text('Confirm all and Discard all skip these.'),
      findsOneWidget,
    );

    final scheme = Theme.of(tester.element(fold)).colorScheme;
    Color? amountColor(Finder line) {
      final text = tester.widget<Text>(line.first);
      final span = text.textSpan! as TextSpan;
      return (span.children!.first as TextSpan).style?.color;
    }

    // The spam row ends its line with its day: the fold has no day labels.
    final spamLine = find.descendant(
      of: find.ancestor(of: fold, matching: find.byType(Card)).first,
      matching: find.textContaining(
        ' · ${fmtDateCompact(DateUtils.dateOnly(spam.date))}',
      ),
    );
    expect(spamLine, findsOneWidget);
    expect(amountColor(spamLine), scheme.onSurface);
    // An ordinary review row keeps its money colour. The food row: the
    // transfer legs sit in their suggestion card, not the list.
    expect(
      amountColor(find.textContaining('−${fmtMoney(349)}')),
      isNot(scheme.onSurface),
    );
  });

  testWidgets('Mark all seen clears the new markers, and Undo restores them', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions([
      Tx(
        id: 'n1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'counted import',
        date: DateTime(2026, 10, 12, 9, 30),
        sender: 'VM-DEMOBK',
        unseen: true,
      ),
    ]);
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();

    expect(find.text('1 new ·'), findsOneWidget);
    await tester.tap(find.text('Mark all seen'));
    await tester.pumpAndSettle();
    expect(p.unseenCount, 0);
    expect(find.text('1 new ·'), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(p.unseenCount, 1);
    expect(find.text('1 new ·'), findsOneWidget);
  });

  testWidgets('the ⋮ menu gets Import from SMS, Select and Export CSV', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    // Home registers the SMS import; stood in for here.
    final owner = Object();
    var imports = 0;
    AppNav.instance.attachHome(
      owner,
      setTab: (_) {},
      openTransactions: (_) {},
      importSms: () => imports++,
    );
    addTearDown(() => AppNav.instance.detachHome(owner));
    final p = await queue();
    final s = await settings();
    await tester.pumpWidget(screen(p, s));
    await tester.pumpAndSettle();

    final menu = AppNav.instance.pageMenu;
    List<String> labels() => [
      for (final a in menu.actionsFor(kHomeTabTransactions)) a.label,
    ];
    // No review entry: the message icon opens the review sheet.
    expect(labels(), ['Import from SMS', 'Select', 'Export CSV']);
    menu.actionsFor(kHomeTabTransactions).first.onTap();
    await tester.pumpAndSettle();
    expect(imports, 1);

    // Select enters selection mode with nothing picked.
    expect(find.byTooltip('Clear selection'), findsNothing);
    menu.actionsFor(kHomeTabTransactions)[1].onTap();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clear selection'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear selection'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clear selection'), findsNothing);

    // The entries do not depend on the queue.
    await p.confirmAllPending();
    await tester.pumpAndSettle();
    expect(labels(), ['Import from SMS', 'Select', 'Export CSV']);
  });

  testWidgets('without SMS import the ⋮ menu has Select and Export CSV', (
    tester,
  ) async {
    final p = await queue();
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();
    expect(
      [
        for (final a in AppNav.instance.pageMenu.actionsFor(
          kHomeTabTransactions,
        ))
          a.label,
      ],
      ['Select', 'Export CSV'],
    );
  });
}
