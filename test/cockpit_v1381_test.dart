import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/classifiers_screen.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/utils/format.dart';

/// Cockpit in v1.38.1 (Results rows merchant first since v1.43.0): Undo
/// and Make rule after a recategorise, the hub's passed limit in red and
/// the monthly cap field grouped.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    NotificationService.statusOverride = () async => NotificationStatus.enabled;
  });

  tearDown(() => NotificationService.statusOverride = null);

  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> pumpCockpit(
    WidgetTester tester,
    FinanceProvider p, {
    int? tab,
    SettingsProvider? settings,
    Size size = const Size(392, 872),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(
            value: settings ?? (SettingsProvider()..load()),
          ),
        ],
        child: MaterialApp(home: ClassifiersScreen(initialTab: tab)),
      ),
    );
    await pumpThrough(tester);
  }

  Future<(FinanceProvider, String)> withChai() async {
    final p = FinanceProvider();
    await p.load();
    final id = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 320,
      note: 'Chai stall',
      date: DateTime(2026, 10, 12, 13, 5),
    );
    return (p, id);
  }

  testWidgets('a Results row leads with the merchant, over its category and '
      'date', (tester) async {
    final (p, _) = await withChai();
    await pumpCockpit(tester, p, tab: kCockpitTabTransactions);

    // The row title the ledger shows: the note's first line as typed.
    expect(find.text('Chai stall'), findsOneWidget);
    expect(find.text('Food & Dining · 12 Oct, 1:05 PM'), findsOneWidget);
    // The old subtitle carried the year.
    expect(find.textContaining('12 Oct 2026'), findsNothing);
    expect(find.text('Make rule'), findsNothing);
  });

  testWidgets('a Results row names its payee, and a row naming nothing leads '
      'with its category over the date alone', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'shopping',
      amount: 1200,
      note: '',
      payee: 'Corner Florist',
      date: DateTime(2026, 10, 11, 10, 30),
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'transport',
      amount: 90,
      note: '',
      date: DateTime(2026, 10, 10, 9, 15),
    );
    await pumpCockpit(tester, p, tab: kCockpitTabTransactions);

    expect(find.text('Corner Florist'), findsOneWidget);
    expect(find.text('Shopping · 11 Oct, 10:30 AM'), findsOneWidget);
    expect(find.text('Transport'), findsOneWidget);
    expect(find.text('10 Oct, 9:15 AM'), findsOneWidget);

    // The payee a row shows is what its search finds.
    await tester.enterText(find.byType(TextField), 'florist');
    await tester.pump(const Duration(milliseconds: 300));
    await pumpThrough(tester);
    expect(find.text('Corner Florist'), findsOneWidget);
    expect(find.text('10 Oct, 9:15 AM'), findsNothing);
  });

  testWidgets('recategorising offers Undo and Make rule; Undo puts it back', (
    tester,
  ) async {
    final (p, id) = await withChai();
    await pumpCockpit(tester, p, tab: kCockpitTabTransactions);
    Tx row() => p.transactions.firstWhere((t) => t.id == id);
    final setByHandBefore = row().userCategorized;

    await tester.tap(find.text('Chai stall'));
    await pumpThrough(tester);
    await tester.tap(find.text('Transport').last);
    await pumpThrough(tester);

    expect(row().categoryId, 'transport');
    expect(row().userCategorized, isTrue);
    expect(find.text('Moved to Transport'), findsOneWidget);
    expect(find.text('Transport · 12 Oct, 1:05 PM'), findsOneWidget);
    expect(find.text('Make rule'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await pumpThrough(tester);
    expect(row().categoryId, 'food');
    expect(row().userCategorized, setByHandBefore);
    expect(find.text('Food & Dining · 12 Oct, 1:05 PM'), findsOneWidget);
    expect(find.text('Make rule'), findsNothing);
  });

  testWidgets('Make rule opens the rule dialog on the new category', (
    tester,
  ) async {
    final (p, _) = await withChai();
    await pumpCockpit(tester, p, tab: kCockpitTabTransactions);

    await tester.tap(find.text('Chai stall'));
    await pumpThrough(tester);
    await tester.tap(find.text('Transport').last);
    await pumpThrough(tester);
    await tester.tap(find.text('Make rule'));
    await pumpThrough(tester);

    expect(find.byType(Dialog), findsOneWidget);
    final dialog = find.byType(Dialog);
    expect(
      find.descendant(of: dialog, matching: find.text('Chai stall')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.textContaining('Transport')),
      findsWidgets,
    );
    // The offer goes once taken.
    expect(find.text('Make rule'), findsNothing);
  });

  testWidgets('the hub draws a passed limit in the error colour and the '
      'other counts muted', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await p.addBudget(
      name: 'Eating out',
      limit: 100,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    // Not a fixed date: the hub counts "over" for the current month from
    // DateTime.now() and has no clock to inject, so the spend has to sit in
    // the real current month (as in cockpit_tabs_test).
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'Dinner',
      date: DateTime(now.year, now.month, 1, 0, 0, 1),
    );
    await pumpCockpit(tester, p);

    const nb = '\u{a0}';
    // A non-breaking space between the number and its noun only: "over"
    // may wrap.
    final plan = find.textContaining('1${nb}budget over');
    expect(plan, findsOneWidget);
    final span = tester.widget<Text>(plan).textSpan!;
    final scheme = Theme.of(tester.element(plan)).colorScheme;
    TextStyle? styleOf(String text) {
      TextStyle? found;
      span.visitChildren((s) {
        if (s is TextSpan && s.text == text) {
          found = s.style;
          return false;
        }
        return true;
      });
      return found;
    }

    final over = styleOf('1${nb}budget over');
    expect(over?.color, scheme.error);
    expect(over?.fontWeight, FontWeight.w500);
    // The rest inherit the row's muted subtitle style.
    expect(styleOf('1${nb}budget'), isNull);
    final rendered = tester.widget<RichText>(
      find.descendant(of: plan, matching: find.byType(RichText)),
    );
    expect(rendered.text.style?.color, scheme.onSurfaceVariant);
  });

  testWidgets('at 320dp with 2x text the Review row with Make rule and the '
      'hub fit', (tester) async {
    final (p, _) = await withChai();
    await p.addBudget(
      name: 'Eating out',
      limit: 100,
      mode: BudgetMode.include,
      categoryIds: {'food'},
    );
    // Real current month: the hub has no clock to inject (see above).
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 500,
      note: 'Dinner',
      date: DateTime(now.year, now.month, 1, 0, 0, 1),
    );
    await pumpCockpit(tester, p, size: const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    // The words get the row's width: no group icon, no chevron.
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(CockpitGroup.plan.icon), findsNothing);
    // Plan sits below the fold at this size.
    await tester.scrollUntilVisible(
      find.textContaining('budget over'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);

    await pumpCockpit(
      tester,
      p,
      tab: kCockpitTabTransactions,
      size: const Size(320, 640),
      textScale: 2,
    );
    await tester.tap(find.text('Chai stall'));
    await pumpThrough(tester);
    await tester.tap(find.text('Transport').last);
    await pumpThrough(tester);
    expect(tester.takeException(), isNull);
    final makeRule = find.text('Make rule');
    expect(makeRule, findsOneWidget);
    // One line: every glyph box sits on the same top.
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: makeRule, matching: find.byType(RichText)),
    );
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 'Make rule'.length),
    );
    expect({for (final b in boxes) b.top}.length, 1);

    // The row: the title is not cut, and the amount sits under the date.
    final title = find.text('Chai stall');
    final titleText = tester.renderObject<RenderParagraph>(
      find.descendant(of: title, matching: find.byType(RichText)),
    );
    expect(titleText.didExceedMaxLines, isFalse);
    final date = find.text('Transport · 12 Oct, 1:05 PM');
    final amount = find.text('−${fmtMoney(320)}');
    expect(
      tester.getTopLeft(amount).dy,
      greaterThan(tester.getBottomLeft(date).dy - 1),
    );
    expect(tester.getTopLeft(amount).dx, tester.getTopLeft(title).dx);
  });

  testWidgets('at 2x text the Cockpit tab bars scroll, labels whole', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(
      tester,
      p,
      tab: kCockpitTabBudgets,
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    final bar = tester.widget<TabBar>(find.byType(TabBar));
    expect(bar.isScrollable, isTrue);
    expect(bar.tabAlignment, TabAlignment.start);
    final label = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('Budgets'),
        matching: find.byType(RichText),
      ),
    );
    expect(label.didExceedMaxLines, isFalse);
    // Whole: laid out as wide as the label wants, not cut to a tab third.
    expect(
      label.size.width,
      greaterThanOrEqualTo(label.getMaxIntrinsicWidth(double.infinity)),
    );
  });

  testWidgets('at 1.3x text on 360dp the Cockpit tab bars scroll, labels '
      'whole', (tester) async {
    final p = FinanceProvider();
    await p.load();
    for (final (tab, labels) in [
      (kCockpitTabRules, ['Rules', 'Categories', 'Import', 'Results']),
      (kCockpitTabBudgets, ['Budgets', 'Reminders', 'Subscriptions']),
    ]) {
      // A fresh tree per page: a new home on the same MaterialApp would
      // keep the first page's route.
      await tester.pumpWidget(const SizedBox());
      await pumpCockpit(
        tester,
        p,
        tab: tab,
        size: const Size(360, 780),
        textScale: 1.3,
      );
      expect(tester.takeException(), isNull);
      final bar = find.byType(TabBar);
      expect(tester.widget<TabBar>(bar).isScrollable, isTrue);
      for (final l in labels) {
        final label = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.descendant(of: bar, matching: find.text(l)),
            matching: find.byType(RichText),
          ),
        );
        expect(label.didExceedMaxLines, isFalse, reason: l);
        expect(
          label.size.width,
          greaterThanOrEqualTo(label.getMaxIntrinsicWidth(double.infinity)),
          reason: l,
        );
      }
    }
  });

  testWidgets('at normal text the Cockpit tab bars stay fixed', (tester) async {
    final p = FinanceProvider();
    await p.load();
    await pumpCockpit(tester, p, tab: kCockpitTabBudgets);
    expect(tester.widget<TabBar>(find.byType(TabBar)).isScrollable, isFalse);
  });

  testWidgets('the monthly cap field shows Indian grouping, and after an '
      'edit once it lets go', (tester) async {
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    await s.setMonthlyBudget(40000);
    await pumpCockpit(tester, p, tab: kCockpitTabBudgets, settings: s);

    final field = find.widgetWithText(TextField, 'Monthly cap');
    String shown() => tester.widget<TextField>(field).controller!.text;
    expect(shown(), '40,000');

    // The floating label sits inside the filled box, not across its top
    // edge: an underline border, not the theme's borderless outline.
    final decoration = tester.widget<TextField>(field).decoration!;
    expect(decoration.border, isA<UnderlineInputBorder>());
    expect(decoration.enabledBorder, isA<UnderlineInputBorder>());
    final box = tester.getRect(
      find.descendant(of: field, matching: find.byType(InputDecorator)),
    );
    expect(
      tester
          .getTopLeft(
            find.descendant(of: field, matching: find.text('Monthly cap')),
          )
          .dy,
      greaterThanOrEqualTo(box.top),
    );

    await tester.enterText(field, '150000');
    await tester.pump();
    expect(shown(), '150000', reason: 'left alone while typing');
    FocusManager.instance.primaryFocus?.unfocus();
    await pumpThrough(tester);
    expect(s.monthlyBudget, 150000);
    expect(shown(), '1,50,000');
  });
}
