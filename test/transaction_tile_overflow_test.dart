import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

/// The tile leads with its merchant (Paid to or the note), the category
/// under it, and the date or time under the amount (v1.43.0). It fits any
/// width and text scale, and the date always shows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  final date = DateTime(2026, 9, 16);
  final dateLabel = fmtDateCompact(date);

  Future<FinanceProvider> seeded(String note) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 120,
      note: note,
      date: date,
    );
    return p;
  }

  Future<void> pump(
    WidgetTester tester,
    FinanceProvider p,
    Widget body, {
    required Size size,
    required double textScale,
  }) async {
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
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: body),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 700));
  }

  testWidgets('the screen fits 320dp at text scale 2.0', (tester) async {
    final p = await seeded('coffeerun');
    await pump(
      tester,
      p,
      const TransactionsScreen(),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(TransactionTile), findsOneWidget);
  });

  testWidgets('a tile fits 320dp at text scale 2.0 with the date showing', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final p = await seeded('coffeerun');
    await pump(
      tester,
      p,
      ListView(children: [TransactionTile(tx: p.transactions.single)]),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.text(dateLabel)).width, greaterThan(0));
    // The note shows, or, squeezed out, TalkBack still reads it.
    final noteShown = find.text('coffeerun').evaluate().isNotEmpty;
    final noteRead = find
        .bySemanticsLabel(RegExp('coffeerun · $dateLabel'))
        .evaluate()
        .isNotEmpty;
    expect(noteShown || noteRead, isTrue);
    semantics.dispose();
  });

  testWidgets('above 1.6x text the amount sits on its own line', (
    tester,
  ) async {
    final p = await seeded('coffeerun');
    final amount = find.text('−${fmtMoney(120)}');
    Future<void> at(double scale) => pump(
      tester,
      p,
      ListView(children: [TransactionTile(tx: p.transactions.single)]),
      size: const Size(320, 640),
      textScale: scale,
    );

    // Side by side: the amount level with the title, to its right.
    await at(1.3);
    final title = find.text('coffeerun');
    expect(
      tester.getTopLeft(amount).dx,
      greaterThan(tester.getTopRight(title).dx),
    );

    // Stacked: under the category, starting where it starts.
    await at(2.0);
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(amount).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
    );
    expect(
      tester.getTopLeft(amount).dx,
      moreOrLessEquals(tester.getTopLeft(title).dx, epsilon: 0.5),
    );
  });

  testWidgets('at normal size the note leads, the category sits under it '
      'and the date under the amount', (tester) async {
    final p = await seeded('coffeerun');
    await pump(
      tester,
      p,
      ListView(children: [TransactionTile(tx: p.transactions.single)]),
      size: const Size(400, 800),
      textScale: 1,
    );
    expect(tester.takeException(), isNull);
    final title = find.text('coffeerun');
    final category = find.text('Food & Dining');
    final amount = find.text('−${fmtMoney(120)}');
    final day = find.text(dateLabel);
    expect(
      tester.getTopLeft(category).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(title).dy),
    );
    expect(
      tester.getTopLeft(day).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(amount).dy),
    );
    expect(
      tester.getTopRight(day).dx,
      moreOrLessEquals(tester.getTopRight(amount).dx, epsilon: 0.5),
    );
    // The note is the title, so line two does not repeat it.
    expect(title, findsOneWidget);
  });

  testWidgets('Paid to leads, line two adds the note; no name, no line two', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 90,
      payee: 'Sample Mess',
      note: 'lunch with team',
      date: date,
    );
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 40,
      note: '',
      date: date.add(const Duration(hours: 13, minutes: 5)),
    );
    final named = p.transactions.firstWhere((t) => t.payee.isNotEmpty);
    final plain = p.transactions.firstWhere((t) => t.payee.isEmpty);
    await pump(
      tester,
      p,
      ListView(
        children: [
          TransactionTile(tx: named),
          // Under a day header: the time under the amount.
          TransactionTile(tx: plain, showDate: false),
        ],
      ),
      size: const Size(400, 800),
      textScale: 1,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Sample Mess'), findsOneWidget);
    expect(find.text('Food & Dining · lunch with team'), findsOneWidget);
    // The row with no name is titled by its category and has no line two.
    expect(find.text('Food & Dining'), findsOneWidget);
    final time = find.text(fmtTime(plain.date));
    expect(time, findsOneWidget);
    expect(
      tester.getTopLeft(time).dy,
      greaterThanOrEqualTo(
        tester.getBottomLeft(find.text('−${fmtMoney(40)}')).dy,
      ),
    );
  });

  testWidgets('a search reason stays whole when line two ellipsizes', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'shopping',
      amount: 650,
      payee: 'Sample Gifts',
      note: 'Birthday gift for a close friend from college',
      date: date,
    );
    // A short reason and wide screens: the test font draws every glyph a
    // square as wide as the font size, about twice a phone font, so line
    // two measures only 70dp at 320dp here and 150dp at 400dp, where
    // " · via ABC" takes 124dp. A longer reason, or a narrower screen, would
    // not fit whole in this test even though it does on a phone.
    Future<void> at(double width, double scale, {bool guessed = false}) => pump(
      tester,
      p,
      ListView(
        children: [
          TransactionTile(
            tx: p.transactions.single.copyWith(categoryGuessed: guessed),
            matchNote: 'via ABC',
          ),
        ],
      ),
      size: Size(width, 800),
      textScale: scale,
    );
    RenderParagraph paragraph(Finder f) =>
        tester.renderObject<RenderParagraph>(f);
    void expectWhole(String where) {
      final reason = find.textContaining('via ABC');
      expect(reason, findsOneWidget, reason: where);
      expect(paragraph(reason).didExceedMaxLines, isFalse, reason: where);
    }

    // The category and note ellipsize; the reason after them stays whole.
    for (final width in <double>[400, 480]) {
      await at(width, 1);
      final where = 'width $width';
      expect(tester.takeException(), isNull, reason: where);
      final base = find.textContaining('Birthday gift');
      expect(paragraph(base).didExceedMaxLines, isTrue, reason: where);
      expect(find.text(' · via ABC'), findsOneWidget, reason: where);
      expectWhole(where);
    }
    // A guessed category's pill gives way to the reason too, up to half the
    // line.
    for (final width in <double>[560, 600]) {
      await at(width, 1, guessed: true);
      final where = 'guessed, width $width';
      expect(tester.takeException(), isNull, reason: where);
      expect(find.textContaining('guessed'), findsOneWidget, reason: where);
      expectWhole(where);
    }
    // Narrower, larger text: where " · via ABC" no longer fits, the reason
    // alone takes the line.
    for (final scale in [1.0, 1.3, 2.0, 3.0]) {
      for (final width in <double>[280, 320]) {
        for (final guessed in [false, true]) {
          await at(width, scale, guessed: guessed);
          final where = 'width $width, scale $scale, guessed $guessed';
          expect(tester.takeException(), isNull, reason: where);
          expect(find.textContaining('via ABC'), findsOneWidget, reason: where);
        }
      }
    }
  });

  // From 280dp: below that the tile's fixed parts (padding, icon, gaps and
  // the amount's 140dp cap) outgrow the row before this line is involved.
  for (final scale in [1.0, 1.3, 1.6, 2.0, 2.5, 3.0]) {
    testWidgets('a long note never overflows at text scale $scale', (
      tester,
    ) async {
      final p = await seeded('coffee run with the whole team downtown');
      for (final width in <double>[280, 300, 320, 360, 400, 480, 600]) {
        await pump(
          tester,
          p,
          ListView(children: [TransactionTile(tx: p.transactions.single)]),
          size: Size(width, 800),
          textScale: scale,
        );
        expect(tester.takeException(), isNull, reason: 'width $width');
        expect(
          tester.getSize(find.text(dateLabel)).width,
          greaterThan(0),
          reason: 'width $width',
        );
      }
    });
  }
}
