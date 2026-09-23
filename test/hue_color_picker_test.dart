import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/category_management.dart';
import 'package:expense_tracker/utils/contrast.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/hue_color_picker.dart';

/// The category colour palette and its hue-family picker.
void main() {
  test('24 distinct colours, none of them the "no colour" grey', () {
    expect(kCategoryColorChoices, hasLength(24));
    expect(kCategoryColorChoices.toSet(), hasLength(24));
    expect(kCategoryColorChoices, isNot(contains(kNoCategoryColor)));
  });

  test('every built-in category colour is pickable', () {
    for (final c in kCategories) {
      expect(
        c.color == kNoCategoryColor || kCategoryColorChoices.contains(c.color),
        isTrue,
        reason: c.id,
      );
    }
  });

  test('every choice reads as a glyph on the dark card surface', () {
    for (final c in kCategoryColorChoices) {
      expect(
        contrastRatio(c, FigmaPalette.surface),
        greaterThanOrEqualTo(3),
        reason: hueColorName(c),
      );
    }
  });

  test('names follow the hue columns and tone rows', () {
    expect(hueColorName(kNoCategoryColor), 'None');
    expect(hueColorName(FigmaPalette.primary), 'Coral');
    expect(hueColorName(FigmaPalette.primaryLight), 'Coral, light');
    expect(hueColorName(kCategoryColorChoices.last), 'Rose, deep');
    expect(hueColorName(const Color(0xFF123456)), 'Custom');
  });

  Future<List<Color>> pump(WidgetTester tester, Color initial) async {
    final picked = <Color>[];
    // Hosted in an AlertDialog like the real category/group dialogs: its
    // IntrinsicWidth sizing is what the picker's layout must survive.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AlertDialog(
            content: StatefulBuilder(
              builder: (context, setState) => HueColorPicker(
                value: picked.isEmpty ? initial : picked.last,
                onChanged: (c) => setState(() => picked.add(c)),
              ),
            ),
          ),
        ),
      ),
    );
    return picked;
  }

  testWidgets('tapping swatches picks and names them', (tester) async {
    final picked = await pump(tester, kNoCategoryColor);
    expect(find.text('Colour · None'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Teal'));
    await tester.pump();
    expect(picked.last, const Color(0xFF2EC4B6));
    expect(find.text('Colour · Teal'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('None'));
    await tester.pump();
    expect(picked.last, kNoCategoryColor);
  });

  testWidgets('an off-palette colour shows as Custom', (tester) async {
    await pump(tester, const Color(0xFF123456));
    expect(find.text('Colour · Custom'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Custom colour')),
      isSemantics(isButton: true, isSelected: true),
    );
  });

  testWidgets('a new category starts with no colour', (tester) async {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    final finance = FinanceProvider();
    await finance.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: finance,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCategoryDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('New category'), findsOneWidget);
    expect(find.text('Colour · None'), findsOneWidget);
  });

  testWidgets('the accent picker offers the theme accent as "Theme"', (
    tester,
  ) async {
    const themeAccent = Color(0xFF00E5FF);
    final picked = <Color>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => HueColorPicker(
              title: 'Accent',
              value: picked.isEmpty ? FigmaPalette.primary : picked.last,
              onChanged: (c) => setState(() => picked.add(c)),
              none: themeAccent,
              noneLabel: 'Theme',
              noneIsNeutral: false,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Accent · Coral'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Theme'));
    await tester.pump();
    expect(picked.last, themeAccent);
    expect(find.text('Accent · Theme'), findsOneWidget);
  });

  testWidgets('a theme accent that is a palette colour selects only Theme', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HueColorPicker(
            value: FigmaPalette.primary,
            onChanged: (_) {},
            none: FigmaPalette.primary,
            noneLabel: 'Theme',
            noneIsNeutral: false,
          ),
        ),
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Theme')),
      isSemantics(isSelected: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Coral')),
      isSemantics(isSelected: false),
    );
  });

  testWidgets('Custom opens the colour dialog', (tester) async {
    await pump(tester, kNoCategoryColor);
    await tester.tap(find.bySemanticsLabel('Custom colour'));
    await tester.pumpAndSettle();
    expect(find.text('Category colour'), findsOneWidget);
  });
}
