import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/glossy.dart';

/// GlassSegmented driven by a PageController: the glass thumb tracks the
/// pager continuously (mid-drag and mid-animation), taps animate the pager,
/// and the pages themselves swipe — including from blank space, which the
/// transparent ColoredBox wrapper keeps hit-testable.
void main() {
  testWidgets('the thumb tracks a held drag and lands on the page', (
    tester,
  ) async {
    final ctrl = PageController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_Harness(ctrl: ctrl));

    final x0 = tester.getTopLeft(_thumb()).dx;
    final segmentWidth =
        tester.getSize(find.byType(GlassSegmented<int>)).width / 3;

    // Hold a drag most of a page wide: the thumb must sit strictly between
    // segment 0 and segment 1 while the finger is down.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('first page')),
    );
    await gesture.moveBy(const Offset(-500, 0));
    await tester.pump();
    final mid = tester.getTopLeft(_thumb()).dx;
    expect(mid, greaterThan(x0 + 1));
    expect(mid, lessThan(x0 + segmentWidth));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);
    expect(tester.getTopLeft(_thumb()).dx, greaterThan(x0 + segmentWidth / 2));
  });

  testWidgets('a tap animates the thumb to the tapped segment', (tester) async {
    final ctrl = PageController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_Harness(ctrl: ctrl));

    final x0 = tester.getTopLeft(_thumb()).dx;
    await tester.tap(find.text('Three'));
    // First pump starts the ticker (elapsed 0), the second advances it.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final mid = tester.getTopLeft(_thumb()).dx;
    expect(mid, greaterThan(x0), reason: 'mid-flight, not a snap');

    await tester.pumpAndSettle();
    expect(find.text('third page'), findsOneWidget);
    expect(tester.getTopLeft(_thumb()).dx, greaterThan(mid));
  });

  testWidgets('the thumb carries an accent edge light', (tester) async {
    final ctrl = PageController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_Harness(ctrl: ctrl));

    final thumb = tester.widget<Container>(_thumb());
    final glow = thumb.foregroundDecoration! as BoxDecoration;
    final primary = Theme.of(tester.element(_thumb())).colorScheme.primary;
    expect((glow.border! as Border).top.color, primary.withValues(alpha: 0.55));
    expect(glow.boxShadow!.single.blurStyle, BlurStyle.inner);
  });

  testWidgets('the ends stop', (tester) async {
    final ctrl = PageController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_Harness(ctrl: ctrl));

    await tester.fling(find.text('first page'), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('first page'), findsOneWidget);
    expect(ctrl.page, 0);
  });

  testWidgets('blank space swipes too', (tester) async {
    final ctrl = PageController();
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(_Harness(ctrl: ctrl));

    // Nothing is painted at this offset: only the page's transparent
    // ColoredBox is there to be hit.
    await tester.flingFrom(const Offset(400, 500), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('second page'), findsOneWidget);
    expect(ctrl.page, 1);
  });
}

/// The glass thumb: the only Container with the 9px-radius decoration.
Finder _thumb() => find.byWidgetPredicate(
  (w) =>
      w is Container &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).borderRadius == BorderRadius.circular(9),
);

class _Harness extends StatefulWidget {
  final PageController ctrl;
  const _Harness({required this.ctrl});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          GlassSegmented<int>(
            options: const [(0, 'One'), (1, 'Two'), (2, 'Three')],
            icons: const [Icons.looks_one, Icons.looks_two, Icons.looks_3],
            selected: _selected,
            onChanged: (v) => widget.ctrl.animateToPage(
              v,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
            ),
            pager: widget.ctrl,
          ),
          Expanded(
            child: PageView(
              controller: widget.ctrl,
              onPageChanged: (i) => setState(() => _selected = i),
              children: const [
                ColoredBox(
                  color: Colors.transparent,
                  child: Center(child: Text('first page')),
                ),
                ColoredBox(
                  color: Colors.transparent,
                  child: Center(child: Text('second page')),
                ),
                ColoredBox(
                  color: Colors.transparent,
                  child: Center(child: Text('third page')),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
