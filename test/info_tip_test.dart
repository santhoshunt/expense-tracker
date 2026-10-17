import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/info_tip.dart';

/// The outlined "i": a tap opens the anchored bubble with its example line,
/// and "Got it" or a tap outside closes it.
void main() {
  Future<void> pump(
    WidgetTester tester, {
    String? Function()? example,
    Alignment at = Alignment.topLeft,
    bool icon = false,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(
        brightness: Brightness.dark,
        accent: FigmaPalette.primary,
      ),
      home: Scaffold(
        body: Align(
          alignment: at,
          child: InfoLabel(
            icon: icon,
            label: const Text('Net balance'),
            tip: InfoTip(
              title: 'Net balance',
              message: 'Bank balances minus card outstanding.',
              example: example,
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('the "i" is a 32dp target, 48dp under InfoTipTarget', (
    tester,
  ) async {
    Future<Size> sizeUnder(double? target) async {
      const tip = InfoTip(title: 'Next 7 days', message: 'Due soon.');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: target == null
                  ? tip
                  : InfoTipTarget(size: target, child: tip),
            ),
          ),
        ),
      );
      // The outer box: the glyph's own sits inside it.
      return tester.getSize(
        find
            .descendant(
              of: find.byType(InfoTip),
              matching: find.byType(SizedBox),
            )
            .first,
      );
    }

    expect(await sizeUnder(null), const Size(32, 32));
    expect(await sizeUnder(48), const Size(48, 48));
  });

  testWidgets('opens with the example, closes on Got it', (tester) async {
    var calls = 0;
    await pump(
      tester,
      example: () {
        calls++;
        return '₹10 − ₹4 = ₹6';
      },
    );
    expect(calls, 0, reason: 'computed only when opened');

    await tester.tap(find.bySemanticsLabel('About Net balance'));
    await tester.pumpAndSettle();
    expect(find.text('Bank balances minus card outstanding.'), findsOneWidget);
    expect(find.text('₹10 − ₹4 = ₹6'), findsOneWidget);
    expect(calls, 1);

    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();
    expect(find.text('Bank balances minus card outstanding.'), findsNothing);
  });

  testWidgets('a null example leaves the line out; outside tap closes', (
    tester,
  ) async {
    await pump(tester, example: () => null, at: Alignment.bottomRight);
    await tester.tap(find.bySemanticsLabel('About Net balance'));
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsOneWidget);
    expect(find.textContaining('₹'), findsNothing);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsNothing);
  });

  testWidgets('a link closes the bubble and runs from the host screen', (
    tester,
  ) async {
    BuildContext? got;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (host) => InfoTip(
              title: 'By category',
              message: 'Share of the month.',
              link: InfoLink(
                prompt: 'Transactions not classified right?',
                label: 'Set up transaction rules',
                onTap: (c) => got = c,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('About By category'));
    await tester.pumpAndSettle();
    expect(find.text('Transactions not classified right?'), findsOneWidget);

    await tester.tap(find.text('Set up transaction rules'));
    await tester.pumpAndSettle();
    expect(find.text('Share of the month.'), findsNothing, reason: 'closed');
    expect(got, isNotNull);
    expect(got!.mounted, isTrue, reason: 'the host, not the dismissed bubble');
  });

  testWidgets('by default the label is the tip: dotted, no "i", opens the '
      'bubble', (tester) async {
    await pump(tester);
    expect(find.byIcon(Icons.info_outline), findsNothing);
    expect(find.byType(TipTitle), findsOneWidget);
    expect(find.bySemanticsLabel('About Net balance'), findsOneWidget);
    final rendered = tester.widget<RichText>(
      find.descendant(
        of: find.byType(TipTitle),
        matching: find.byType(RichText),
      ),
    );
    expect(rendered.text.style?.decoration, TextDecoration.underline);
    expect(rendered.text.style?.decorationStyle, TextDecorationStyle.dotted);

    // The label itself is the target.
    await tester.tap(find.text('Net balance'));
    await tester.pumpAndSettle();
    expect(find.text('Bank balances minus card outstanding.'), findsOneWidget);
  });

  testWidgets('with icon the label stays plain and the "i" opens the bubble', (
    tester,
  ) async {
    await pump(tester, icon: true);
    expect(find.byType(TipTitle), findsNothing);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);

    // A plain label: a tap on it opens nothing.
    await tester.tap(find.text('Net balance'));
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsNothing);

    await tester.tap(find.bySemanticsLabel('About Net balance'));
    await tester.pumpAndSettle();
    expect(find.text('Bank balances minus card outstanding.'), findsOneWidget);
  });

  testWidgets('the bubble stays on screen near an edge', (tester) async {
    await pump(tester, at: Alignment.bottomRight);
    await tester.tap(find.bySemanticsLabel('About Net balance'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.text('Got it'));
    final screen = tester.getRect(find.byType(Scaffold));
    expect(screen.contains(rect.topLeft), isTrue);
    expect(screen.contains(rect.bottomRight), isTrue);
  });
}
