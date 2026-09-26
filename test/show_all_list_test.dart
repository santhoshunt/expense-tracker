import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/animated_fold.dart';
import 'package:expense_tracker/widgets/show_all_list.dart';

void main() {
  Future<void> pump(WidgetTester tester, int count) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ShowAllList(
            noun: 'tags',
            rows: [for (var i = 0; i < count; i++) Text('row $i')],
          ),
        ),
      ),
    ),
  );

  double foldHeight(WidgetTester tester) =>
      tester.getSize(find.byType(AnimatedFold)).height;

  testWidgets('five rows or fewer get no toggle', (tester) async {
    await pump(tester, 5);
    expect(find.text('row 4'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(AnimatedFold), findsNothing);
  });

  testWidgets('more than five fold after the fifth and open on tap', (
    tester,
  ) async {
    await pump(tester, 7);
    expect(find.text('Show all 7 tags'), findsOneWidget);
    expect(foldHeight(tester), 0, reason: 'rows 6 and 7 folded');

    await tester.tap(find.text('Show all 7 tags'));
    await tester.pumpAndSettle();
    expect(foldHeight(tester), greaterThan(0));
    expect(find.text('Show less'), findsOneWidget);

    await tester.tap(find.text('Show less'));
    await tester.pumpAndSettle();
    expect(foldHeight(tester), 0);
    expect(find.text('Show all 7 tags'), findsOneWidget);
  });
}
