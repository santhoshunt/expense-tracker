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
import 'package:expense_tracker/widgets/status_dot.dart';

/// v1.38.1 on the Transactions tab: the opaque month band, the slim jump
/// panel, the review queue at 320dp with large text, the review row text,
/// the spam card, Mark all seen and the ⋮ menu's page entries.
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

  testWidgets('the review queue fits 320dp at 2x text', (tester) async {
    tester.view.physicalSize = const Size(640, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final p = await queue();
    await tester.pumpWidget(screen(p, await settings(), textScale: 2));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Not a transfer'), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
    expect(find.text('Confirm all'), findsOneWidget);
    expect(find.text('Discard all'), findsOneWidget);

    // The food row may sit below the review list's fold.
    expect(
      find.text(
        '${categoryById('food').label} · Tasty Corner',
        skipOffstage: false,
      ),
      findsOneWidget,
    );

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

  testWidgets('a review row reads category · merchant over date · sender', (
    tester,
  ) async {
    final p = await queue();
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();

    expect(
      find.text('${categoryById('food').label} · Tasty Corner'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        '−${fmtMoney(349)} · ${fmtDateCompact(food.date)} · VM-DEMOBK',
      ),
      findsOneWidget,
    );
    expect(fmtDateCompact(food.date), '13 Oct, 12:02 PM');
  });

  testWidgets('inside Home at 320x700 with 2x text, both open review cards '
      'leave the list real height', (tester) async {
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
    // Both cards are open: their fold contents are built.
    expect(find.text('Not a transfer'), findsOneWidget);
    expect(find.textContaining('Suspected spam · 1'), findsOneWidget);

    final screenHeight = tester.getSize(find.byType(TransactionsScreen)).height;
    final cards = tester.getSize(find.byKey(const ValueKey('review-cards')));
    expect(cards.height, lessThanOrEqualTo(screenHeight * 0.4 + 0.5));
    final list = tester.getSize(find.byType(PageView));
    expect(list.height, greaterThan(screenHeight * 0.3));

    // The full area says it scrolls: a visible scrollbar, and the last
    // card fades out on rounded corners while more lies below.
    final area = find.byKey(const ValueKey('review-cards'));
    Scrollbar bar() => tester.widget<Scrollbar>(
      find.ancestor(of: area, matching: find.byType(Scrollbar)).first,
    );
    ShaderMask fade() => tester.widget<ShaderMask>(
      find.ancestor(of: area, matching: find.byType(ShaderMask)).first,
    );
    expect(bar().thumbVisibility, isTrue);
    expect(fade().blendMode, BlendMode.dstIn);

    // Scrolled to its end, nothing lies below: no fade.
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: area, matching: find.byType(Scrollable)).first,
        )
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(fade().blendMode, BlendMode.dst);
    expect(bar().thumbVisibility, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review cards that fit show no scroll cue', (tester) async {
    tester.view.physicalSize = const Size(780, 3200);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final p = await queue();
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();

    final area = find.byKey(const ValueKey('review-cards'));
    expect(
      tester
          .widget<Scrollbar>(
            find.ancestor(of: area, matching: find.byType(Scrollbar)).first,
          )
          .thumbVisibility,
      isFalse,
    );
    expect(
      tester
          .widget<ShaderMask>(
            find.ancestor(of: area, matching: find.byType(ShaderMask)).first,
          )
          .blendMode,
      BlendMode.dst,
    );
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
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('pending-card'));
    final other = categoryById('other_expense').label;
    expect(find.textContaining('· Payment'), findsNothing);
    expect(find.descendant(of: card, matching: find.text(other)), findsWidgets);
  });

  testWidgets('Not a transfer hides the suggestion, and Undo brings it back', (
    tester,
  ) async {
    final p = await queue();
    final s = await settings();
    await tester.pumpWidget(screen(p, s));
    await tester.pumpAndSettle();

    final suggestion = find.textContaining('Looks like a transfer');
    expect(suggestion, findsOneWidget);
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

  testWidgets('spam amounts are plain text and the title counts them', (
    tester,
  ) async {
    final p = await queue();
    await tester.pumpWidget(screen(p, await settings()));
    await tester.pumpAndSettle();

    expect(find.text('Suspected spam · 1 to review'), findsOneWidget);
    final scheme = Theme.of(
      tester.element(find.byType(TransactionsScreen)),
    ).colorScheme;
    Color? amountColor(String sender) {
      final text = tester.widget<Text>(find.textContaining('· $sender').first);
      final span = text.textSpan! as TextSpan;
      return (span.children!.first as TextSpan).style?.color;
    }

    expect(amountColor('AX-PROMOS'), scheme.onSurface);
    // An ordinary review row keeps its money colour.
    expect(amountColor('VM-DEMOCC'), isNot(scheme.onSurface));
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

  testWidgets('the ⋮ menu gets Review imports, Select transactions and '
      'Export CSV', (tester) async {
    // Tall: both review cards, the selection bar and the list together
    // outgrow the default 600dp test height.
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final p = await queue();
    final s = await settings();
    await tester.pumpWidget(screen(p, s));
    await tester.pumpAndSettle();

    final menu = AppNav.instance.pageMenu;
    List<String> labels() => [
      for (final a in menu.actionsFor(kHomeTabTransactions)) a.label,
    ];
    expect(labels(), [
      'Review imports (4)',
      'Select transactions',
      'Export CSV',
    ]);

    // Review imports opens a folded review card.
    await s.toggleSection('pending_review');
    await tester.pumpAndSettle();
    expect(s.isSectionCollapsed('pending_review'), isTrue);
    menu.actionsFor(kHomeTabTransactions).first.onTap();
    await tester.pumpAndSettle();
    expect(s.isSectionCollapsed('pending_review'), isFalse);

    // Select transactions enters selection mode with nothing picked.
    expect(find.byTooltip('Clear selection'), findsNothing);
    menu.actionsFor(kHomeTabTransactions)[1].onTap();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clear selection'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear selection'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clear selection'), findsNothing);

    // An empty queue drops the review entry.
    await p.confirmAllPending();
    for (final t in p.pendingTransactions.toList()) {
      await p.deleteTransaction(t.id);
    }
    await tester.pumpAndSettle();
    expect(labels(), ['Select transactions', 'Export CSV']);
  });
}
