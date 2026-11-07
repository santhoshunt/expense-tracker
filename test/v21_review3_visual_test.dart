import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/widgets/category_split_sheet.dart';
import 'package:expense_tracker/widgets/dialog_expander.dart';

/// Layout checks for the v2.1.0 final review's visual fixes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  void phone(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('a fold title beside a short value takes the rest of the row', (
    tester,
  ) async {
    // The test font: each letter as wide as its size. The row holds 260dp;
    // the 132dp title used to get only half of it (124dp) and wrap.
    phone(tester, const Size(360, 800));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: DialogExpander(
              title: 'Bank SMS',
              value: 'Off',
              open: false,
              onToggle: () {},
              child: const SizedBox(),
            ),
          ),
        ),
      ),
    );
    final title = tester.renderObject<RenderParagraph>(find.text('Bank SMS'));
    expect(title.getMaxIntrinsicHeight(double.infinity), title.size.height);
    expect(title.size.width, greaterThan(150));
  });

  testWidgets('a disabled filled button sits flat; an enabled one glows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(brightness: Brightness.light, accent: Colors.blue),
        home: const Scaffold(
          body: Column(
            children: [
              FilledButton(onPressed: null, child: Text('off')),
              FilledButton(onPressed: _noop, child: Text('on')),
            ],
          ),
        ),
      ),
    );
    double elevationOf(String label) => tester
        .widget<Material>(
          find.descendant(
            of: find.widgetWithText(FilledButton, label),
            matching: find.byType(Material),
          ),
        )
        .elevation;
    expect(elevationOf('off'), 0);
    expect(elevationOf('on'), 6);
  });

  testWidgets('a split part stacks Amount under Category on a small row or '
      'at large text', (tester) async {
    for (final (size, scale) in [
      (const Size(360, 800), 1.0),
      (const Size(320, 568), 2.0),
    ]) {
      phone(tester, size);
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 640,
        note: 'lunch',
        date: DateTime.now(),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            builder: (c, child) => MediaQuery(
              data: MediaQuery.of(
                c,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (c) => TextButton(
                  onPressed: () =>
                      showCategorySplitSheet(c, p.transactions.last),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final category = find.text('Category').first;
      final amount = find.text('Amount').first;
      expect(
        tester.getTopLeft(amount).dy,
        greaterThan(tester.getBottomLeft(category).dy),
        reason: '$size at ${scale}x',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
}

void _noop() {}
