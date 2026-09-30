import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';

/// The tile's "note · date" line fits any width and text scale: the note
/// and its separator give way before the line can overflow, and the date
/// always shows.
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

  testWidgets('fits 320dp at text scale 2.0 with the date showing', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final p = await seeded('coffeerun');
    await pump(
      tester,
      p,
      const TransactionsScreen(),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.text(dateLabel)).width, greaterThan(0));
    // The note no longer fits the line, but TalkBack still reads it.
    expect(find.text('coffeerun'), findsNothing);
    expect(
      find.bySemanticsLabel(RegExp('coffeerun · $dateLabel')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('at normal size the note, separator and date all show', (
    tester,
  ) async {
    final p = await seeded('coffeerun');
    await pump(
      tester,
      p,
      const TransactionsScreen(),
      size: const Size(400, 800),
      textScale: 1,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(' · '), findsOneWidget);
    expect(find.text(dateLabel), findsOneWidget);
    // Laid out as before: the note gets its natural width, capped at its
    // 3/5 share of the line after the " · ".
    final note = tester.renderObject<RenderParagraph>(find.text('coffeerun'));
    final line = tester.getSize(
      find.ancestor(of: find.text('coffeerun'), matching: find.byType(Row)).first,
    );
    final separator = tester.getSize(find.text(' · '));
    final natural = note.getMaxIntrinsicWidth(double.infinity);
    expect(
      note.size.width,
      moreOrLessEquals(
        min(natural, (line.width - separator.width) * 3 / 5),
        epsilon: 0.01,
      ),
    );
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
