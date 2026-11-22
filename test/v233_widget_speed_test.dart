import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/dashboard_layout.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/import_health.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/ahead_projection.dart' show aheadClock;
import 'package:expense_tracker/widgets/animated_fold.dart';
import 'package:expense_tracker/widgets/card_spend_chart.dart';
import 'package:expense_tracker/widgets/dashboard_fold.dart';
import 'package:expense_tracker/widgets/facts_text.dart';
import 'package:expense_tracker/widgets/monthly_bar_chart.dart';
import 'package:expense_tracker/widgets/text_width.dart';

import 'dashboard_test_utils.dart';

/// A row whose sender reads are counted: each read past the first per scan
/// is a bank-code lookup through the sender patterns.
class _CountingTx extends Tx {
  int senderReads = 0;

  _CountingTx(String id, DateTime date, String sender)
    : _sender = sender,
      super(
        id: id,
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: '',
        date: date,
        source: TxSource.sms,
      );

  final String _sender;

  @override
  String get sender {
    senderReads++;
    return _sender;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnimatedFold.lazy', () {
    const tall = 120.0;
    var built = 0;

    Widget pair(bool collapsed, {bool still = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: still),
        child: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedFold(
                key: const ValueKey('eager'),
                collapsed: collapsed,
                child: const SizedBox(height: tall),
              ),
              AnimatedFold.lazy(
                key: const ValueKey('lazy'),
                collapsed: collapsed,
                builder: (_) {
                  built++;
                  return const SizedBox(height: tall);
                },
              ),
            ],
          ),
        ),
      ),
    );

    Size size(WidgetTester tester, String key) =>
        tester.getSize(find.byKey(ValueKey(key)));
    Finder lazyChild() => find.descendant(
      of: find.byKey(const ValueKey('lazy')),
      matching: find.byWidgetPredicate(
        (w) => w is SizedBox && w.height == tall,
      ),
    );

    setUp(() => built = 0);

    testWidgets('builds nothing at rest folded, and moves as the mounted '
        'fold does', (tester) async {
      await tester.pumpWidget(pair(true));
      expect(built, 0);
      expect(lazyChild(), findsNothing);
      expect(size(tester, 'lazy'), size(tester, 'eager'));

      // Opening: built from the first frame, the same height every frame.
      await tester.pumpWidget(pair(false));
      expect(built, greaterThan(0));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(size(tester, 'lazy'), size(tester, 'eager'), reason: 'open $i');
        expect(
          tester.getTopLeft(find.byKey(const ValueKey('lazy'))).dy,
          tester.getBottomLeft(find.byKey(const ValueKey('eager'))).dy,
        );
      }
      expect(size(tester, 'lazy').height, tall);

      // Closing: still built while it slides shut, gone once it has.
      await tester.pumpWidget(pair(true));
      await tester.pump(const Duration(milliseconds: 100));
      final mid = size(tester, 'lazy').height;
      expect(mid, greaterThan(0));
      expect(mid, lessThan(tall));
      expect(size(tester, 'lazy'), size(tester, 'eager'));
      expect(lazyChild(), findsOneWidget);
      await tester.pumpAndSettle();
      expect(lazyChild(), findsNothing);
      expect(size(tester, 'lazy'), size(tester, 'eager'));
      expect(size(tester, 'lazy').height, 0);

      // At rest folded, a rebuild builds nothing.
      built = 0;
      await tester.pumpWidget(pair(true));
      expect(built, 0);
    });

    testWidgets('with motion off a close lets go at once', (tester) async {
      await tester.pumpWidget(pair(false, still: true));
      expect(lazyChild(), findsOneWidget);
      await tester.pumpWidget(pair(true, still: true));
      expect(tester.takeException(), isNull);
      expect(lazyChild(), findsNothing);
      expect(size(tester, 'lazy').height, 0);
    });
  });

  group('DashboardFold', () {
    testWidgets('a folded section calls no body; an open one keeps its theme '
        'across rebuilds', (tester) async {
      var calls = 0;
      var open = false;
      final themes = <ThemeData>[];
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [AppColors.light]),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return DashboardFold(
                  title: 'Lakeside',
                  open: open,
                  onChanged: (v) => setState(() => open = v),
                  body: () {
                    calls++;
                    return [
                      Builder(
                        builder: (c) {
                          themes.add(Theme.of(c));
                          return const SizedBox(height: 40);
                        },
                      ),
                    ];
                  },
                );
              },
            ),
          ),
        ),
      );
      for (var i = 0; i < 3; i++) {
        rebuild(() {});
        await tester.pump();
      }
      expect(calls, 0);

      await tester.tap(find.text('Lakeside'));
      await tester.pumpAndSettle();
      expect(calls, greaterThan(0));
      final before = themes.length;
      for (var i = 0; i < 3; i++) {
        rebuild(() {});
        await tester.pump();
      }
      expect(themes.length, greaterThan(before));
      for (var i = before; i < themes.length; i++) {
        expect(identical(themes[i], themes[before - 1]), isTrue, reason: '$i');
      }
      final colors = themes.last.extension<AppColors>()!;
      expect(colors.cardFill, Colors.transparent);
      expect(colors.cardOutline, isNull);
      expect(colors.green, AppColors.light.green);
      expect(themes.last.cardTheme.margin, EdgeInsets.zero);
    });

    test('AppColors compares by value over every field', () {
      AppColors make({Color? outline, Color? fill}) => AppColors(
        green: const Color(0xFF112233),
        orange: const Color(0xFF445566),
        blue: const Color(0xFF778899),
        purple: const Color(0xFFAABBCC),
        cardOutline: outline,
        cardFill: fill,
      );
      expect(make(), make());
      expect(make().hashCode, make().hashCode);
      expect(make(fill: Colors.transparent), make(fill: Colors.transparent));
      expect(make(fill: Colors.transparent), isNot(make()));
      expect(make(outline: Colors.black), isNot(make()));
      expect(make().copyWith(green: Colors.red), isNot(make()));
      expect(make().copyWith(purple: Colors.red), isNot(make()));
      final full = make(outline: Colors.black, fill: Colors.white);
      expect(full.copyWith(), full);
      expect(full.lerp(full, 0.5), full);
      expect(full.lerp(make(), 0).cardOutline, Colors.black);
    });
  });

  group('Dashboard folds', () {
    setUp(() {
      final now = DateTime.now();
      recapClock = () => DateTime(now.year, now.month, 20, 10);
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() => recapClock = DateTime.now);

    const cats = [
      'food',
      'transport',
      'shopping',
      'bills',
      'health',
      'entertainment',
      'education',
    ];

    Future<(FinanceProvider, SettingsProvider)> pump(
      WidgetTester tester, {
      Future<void> Function(SettingsProvider s)? setup,
      DateTime? clock,
    }) async {
      tester.view.physicalSize = const Size(824, 1830);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final now = clock ?? DateTime.now();
      final p = FinanceProvider();
      await p.load();
      await p.restoreTransactions([
        for (final (i, c) in cats.indexed)
          for (final back in [0, 1])
            Tx(
              id: 'f$i-$back',
              type: TxType.expense,
              categoryId: c,
              amount: 300.0 + i * 70,
              note: 'Quillon stall $i',
              date: DateTime(now.year, now.month - back, 1),
            ),
      ]);
      final s = SettingsProvider();
      await s.load();
      await setup?.call(s);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider.value(value: s),
          ],
          child: MaterialApp(home: dashboardShell(const DashboardScreen())),
        ),
      );
      await tester.pumpAndSettle();
      return (p, s);
    }

    testWidgets('a folded section builds nothing on a data change', (
      tester,
    ) async {
      final (p, s) = await pump(tester);
      await openDashboardView(tester, 'Trends');
      expect(s.sectionOpen(DashboardSection.sixMonths), isFalse);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('fold-sixMonths')),
        300,
        scrollable: verticalScrollable(),
      );
      expect(find.byType(MonthlyBarChart), findsNothing);
      var charts = 0;
      debugOnRebuildDirtyWidget = (e, _) {
        if (e.widget is MonthlyBarChart) charts++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      p.notifyListeners();
      await tester.pumpAndSettle();
      expect(charts, 0);

      await openDashboardSection(tester, 'sixMonths');
      expect(find.byType(MonthlyBarChart), findsOneWidget);
      charts = 0;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      p.notifyListeners();
      await tester.pumpAndSettle();
      expect(charts, greaterThan(0));
    });

    testWidgets('Show all survives a fold and unfold, not a month change', (
      tester,
    ) async {
      await pump(tester);
      await openDashboardView(tester, 'Breakdown');
      final fold = find.byKey(const ValueKey('fold-byCategory'));
      final showAll = find.text('Show all 7 categories');
      await tester.scrollUntilVisible(
        showAll,
        300,
        scrollable: verticalScrollable(),
      );
      await tester.ensureVisible(showAll);
      await tester.pumpAndSettle();
      await tester.tap(showAll);
      await tester.pumpAndSettle();
      expect(find.text('Show less'), findsOneWidget);
      final openHeight = tester.getSize(fold).height;

      Future<void> tapHeading() async {
        // The chevron: the heading's middle may hold its info tip.
        final heading = find
            .descendant(of: fold, matching: find.byIcon(Icons.expand_less))
            .first;
        await tester.ensureVisible(heading);
        await tester.pumpAndSettle();
        await tester.tap(heading);
        await tester.pumpAndSettle();
      }

      await tapHeading();
      expect(tester.widget<DashboardFold>(fold).open, isFalse);
      expect(find.text('Show less'), findsNothing);
      await tapHeading();
      expect(tester.widget<DashboardFold>(fold).open, isTrue);
      expect(find.text('Show less'), findsOneWidget);
      expect(tester.getSize(fold).height, openHeight);

      // Another month starts at five, as before; so does coming back.
      await tester.drag(verticalScrollable(), const Offset(0, 4000));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Previous month'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next month'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        showAll,
        300,
        scrollable: verticalScrollable(),
      );
      expect(find.text('Show less'), findsNothing);
    });

    testWidgets('the Ahead chart keeps its chosen day through a fold', (
      tester,
    ) async {
      final now = DateTime.now();
      aheadClock = () => now;
      addTearDown(() => aheadClock = DateTime.now);
      await pump(tester, setup: (s) => s.setAheadCalendar(true), clock: now);
      await openDashboardView(tester, 'Ahead');
      final handle = tester.ensureSemantics();
      await tester.pump();
      final fold = find.byKey(const ValueKey('fold-projection'));
      expect(tester.widget<DashboardFold>(fold).open, isTrue);
      final label = fmtCountIn(DateTime(now.year, now.month, now.day + 3));
      Finder day() => find.bySemanticsLabel(label);
      await tester.ensureVisible(day());
      await tester.pumpAndSettle();
      await tester.tap(day());
      await tester.pumpAndSettle();
      expect(tester.getSemantics(day()), isSemantics(isSelected: true));

      final heading = find
          .descendant(of: fold, matching: find.byType(InkWell))
          .first;
      for (final open in [false, true]) {
        await tester.ensureVisible(heading);
        await tester.pumpAndSettle();
        await tester.tap(heading);
        await tester.pumpAndSettle();
        expect(tester.widget<DashboardFold>(fold).open, open);
        expect(day(), open ? findsOneWidget : findsNothing);
      }
      expect(tester.getSemantics(day()), isSemantics(isSelected: true));
      handle.dispose();
    });
  });

  // The painters lay their labels out once per painter (card chart, Ahead
  // line) or once per chart (bar chart); these pin what they draw and where
  // a tap lands. The Ahead line and the comparison chart are pinned by
  // ahead_projection_test and dashboard_feedback_test.
  group('chart painters', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Finder painted(String type) => find.byWidgetPredicate(
      (w) => w is CustomPaint && '${w.painter.runtimeType}' == type,
    );

    testWidgets('the card chart draws a label per bar and the grid label, '
        'and a tap picks the bar under it', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      final p = FinanceProvider();
      await p.load();
      final id = await p.addAccount(
        name: 'Lumen card',
        type: AccountType.creditCard,
      );
      await p.addAccountKey(id, 'QZRBNK:4821');
      await p.setCardCycle(id, statementDay: 12, dueDay: 2);
      await p.restoreTransactions([
        for (var i = 0; i < 40; i++)
          Tx(
            id: 'card$i',
            type: TxType.expense,
            categoryId: 'shopping',
            amount: 350.0 + (i * 733) % 5200,
            note: 'Kestrel Mart',
            date: DateTime(now.year, now.month, now.day - i * 4, 13),
            source: TxSource.sms,
            sender: 'AX-QZRBNK',
            acctKey: 'QZRBNK:4821',
          ),
      ]);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CardSpendSection(
                  account: p.accountById(id)!,
                  onView: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final chart = painted('_CardBarsPainter');
      // Six bar labels and the gridline's figure.
      expect(chart, paintsExactlyCountTimes(#drawParagraph, 7));
      int selected() =>
          (tester.widget<CustomPaint>(chart).painter as dynamic).selected
              as int;
      final rect = tester.getRect(chart);
      await tester.tapAt(Offset(rect.left + 8, rect.center.dy));
      await tester.pumpAndSettle();
      expect(selected(), 0);
      expect(chart, paintsExactlyCountTimes(#drawParagraph, 7));
      // The right edge sits in the grid label's gutter: the last bar.
      await tester.tapAt(Offset(rect.right - 2, rect.center.dy));
      await tester.pumpAndSettle();
      expect(selected(), 5);
    });

    testWidgets('the bar chart draws the same labels on every morph frame, '
        'and goes mid-morph without a fault', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final months = [for (var m = 1; m <= 6; m++) DateTime(2031, m)];
      Widget chart(double base) => MaterialApp(
        home: Scaffold(
          body: MonthlyBarChart(
            months: months,
            seriesOf: (m) => base + m.month * 410,
            seriesLabel: 'Kestrel Mart',
          ),
        ),
      );
      final bars = painted('_BarChartPainter');
      await tester.pumpWidget(chart(1200));
      // A month label and a peak figure for each of six months.
      expect(bars, paintsExactlyCountTimes(#drawParagraph, 12));
      await tester.pumpWidget(chart(2600));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(bars, paintsExactlyCountTimes(#drawParagraph, 12), reason: '$i');
      }
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  });

  group('measured text widths', () {
    testWidgets('match a fresh layout, repeat as lookups and stay bounded', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      const style = TextStyle(fontSize: 13);
      for (final s in [' · new', 'new', 'Kestrel Mart', '−₹1,250.00']) {
        final painter = TextPainter(
          text: TextSpan(text: s, style: style),
          textDirection: TextDirection.ltr,
          textScaler: const TextScaler.linear(1.3),
          maxLines: 1,
        )..layout();
        expect(
          measuredTextWidth(
            s,
            style,
            const TextScaler.linear(1.3),
            TextDirection.ltr,
          ),
          painter.width,
        );
        painter.dispose();
      }
      for (var i = 0; i < 1000; i++) {
        measuredTextWidth(
          'row $i',
          style,
          TextScaler.noScaling,
          TextDirection.ltr,
        );
      }
      expect(measuredTextWidthEntries, lessThanOrEqualTo(400));
    });

    testWidgets('a review-like row measures each fact once over many builds', (
      tester,
    ) async {
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return const SizedBox(
                  width: 220,
                  child: FactsText(
                    ['−₹4,310.00', 'Thu 15 Oct 4:12 PM', 'Plumtree Cafe'],
                    firstStyle: TextStyle(color: Colors.red),
                    maxLines: 3,
                  ),
                );
              },
            ),
          ),
        ),
      );
      final firstSize = tester.getSize(find.byType(FactsText));
      final entries = measuredTextWidthEntries;
      for (var i = 0; i < 20; i++) {
        rebuild(() {});
        await tester.pump();
      }
      expect(measuredTextWidthEntries, entries);
      expect(tester.getSize(find.byType(FactsText)), firstSize);
    });
  });

  test('cached date formats match their patterns', () {
    final days = [DateTime(2031, 1, 5, 9, 30), DateTime(2032, 11, 28)];
    for (final d in days) {
      expect(shortMonthFormat.format(d), DateFormat('MMM').format(d));
      expect(monthFormat.format(d), DateFormat('MMMM').format(d));
      expect(shortMonthYearFormat.format(d), DateFormat('MMM yyyy').format(d));
      expect(shortMonthDayFormat.format(d), DateFormat('MMM d').format(d));
      expect(
        weekdayShortMonthDayFormat.format(d),
        DateFormat('EEE MMM d').format(d),
      );
      expect(weekdayLetterFormat.format(d), DateFormat('EEEEE').format(d));
      expect(shortWeekdayFormat.format(d), DateFormat('EEE').format(d));
      expect(weekdayFormat.format(d), DateFormat('EEEE').format(d));
      expect(dayMonthFormat.format(d), DateFormat('d MMM').format(d));
      expect(fmtMonth(d), DateFormat('MMMM yyyy').format(d));
      expect(fmtDate(d), DateFormat('d MMM yyyy').format(d));
    }
  });

  group('detectSilentBanks', () {
    test('reads each row\'s bank once, and an edited row afresh', () {
      final now = DateTime(2031, 6, 30, 12);
      final rows = [
        for (var i = 0; i < 12; i++)
          _CountingTx(
            'q$i',
            now.subtract(Duration(days: 40 + i * 6)),
            i.isEven ? 'AX-QZRBNK' : 'Larkmoor Bank',
          ),
      ];
      final first = detectSilentBanks(rows, now, scannedUntil: now);
      // The empty-sender check reads it, and so does the bank lookup.
      expect(rows.every((t) => t.senderReads == 2), isTrue);
      final again = detectSilentBanks(rows, now, scannedUntil: now);
      // The second scan reads each sender once: no bank lookup.
      expect(rows.every((t) => t.senderReads == 3), isTrue);
      expect(
        [for (final s in again) (s.bank, s.lastAlert, s.usualGapDays)],
        [for (final s in first) (s.bank, s.lastAlert, s.usualGapDays)],
      );
      expect(first, isNotEmpty);

      // An edit is a new object: its bank is read again.
      final edited = _CountingTx('q0', rows[0].date, 'Brindle Savings Bank');
      rows[0] = edited;
      detectSilentBanks(rows, now, scannedUntil: now);
      expect(edited.senderReads, 2);
    });

    test('no scan yet reads no row', () {
      final now = DateTime(2031, 6, 30, 12);
      final row = _CountingTx('q', now, 'AX-QZRBNK');
      expect(detectSilentBanks([row], now, scannedUntil: null), isEmpty);
      expect(row.senderReads, 0);
    });
  });
}
