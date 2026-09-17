import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/glossy.dart';

/// The page-level swipe must work from blank space too: an empty filtered
/// list is mostly unpainted area, and a deferToChild detector would let the
/// swipe die there (the v1.8.0 on-device finding).
void main() {
  testWidgets('a swipe on blank space still switches the view', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SegmentedSwipe<int>(
              values: const [0, 1, 2],
              selected: selected,
              onChanged: (v) => setState(() => selected = v),
              child: const Column(
                children: [Expanded(child: Center(child: Text('empty')))],
              ),
            ),
          ),
        ),
      ),
    );

    // Fling from a point with nothing painted under it.
    await tester.flingFrom(
      const Offset(400, 500),
      const Offset(-300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    expect(selected, 1);

    await tester.flingFrom(const Offset(400, 500), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(selected, 0, reason: 'swiping back returns');

    // The first view is the left end: another swipe back changes nothing.
    await tester.flingFrom(const Offset(400, 500), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(selected, 0);
  });
}
