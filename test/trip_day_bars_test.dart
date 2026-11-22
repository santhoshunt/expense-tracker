import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/trip_budget_card.dart';

/// The trip card's day numbers under the bars, at large text.
void main() {
  for (final scale in [1.3, 2.0]) {
    testWidgets('the day numbers stay inside their strip at ${scale}x text', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TripDayBars(
                    byDay: const [400, 250, 0, 0, 0],
                    range: DateTimeRange(
                      start: DateTime(2026, 3, 10),
                      end: DateTime(2026, 3, 14),
                    ),
                    limit: 3000,
                    spent: 650,
                    today: DateTime(2026, 3, 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // The strip is the nearest Stack round a day number.
      final strip = tester.getRect(
        find.ancestor(of: find.text('12'), matching: find.byType(Stack)).first,
      );
      for (final day in ['10', '11', '12', '13', '14']) {
        final label = tester.getRect(find.text(day));
        expect(label.top, greaterThanOrEqualTo(strip.top), reason: day);
        expect(label.bottom, lessThanOrEqualTo(strip.bottom), reason: day);
      }
      // And the caption starts below the strip.
      expect(
        tester.getRect(find.textContaining('Dashed:')).top,
        greaterThanOrEqualTo(strip.bottom),
      );
    });
  }
}
