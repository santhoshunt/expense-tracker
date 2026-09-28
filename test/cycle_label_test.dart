import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/cycle_label.dart';

/// "Quarterly" wrapped onto two lines in the narrow cycle segments.
void main() {
  testWidgets('cycle names stay on one line in a narrow picker', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.dark,
          accent: FigmaPalette.primary,
        ),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 260,
                child: SegmentedButton<SubscriptionCycle>(
                  showSelectedIcon: false,
                  segments: [
                    for (final c in SubscriptionCycle.values)
                      ButtonSegment(value: c, label: cycleLabel(c.label)),
                  ],
                  selected: const {SubscriptionCycle.monthly},
                  onSelectionChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final quarterly = tester.renderObject<RenderParagraph>(
      find.text('Quarterly'),
    );
    final monthly = tester.renderObject<RenderParagraph>(find.text('Monthly'));
    expect(quarterly.size.height, monthly.size.height);
    // Shrunk to fit, not clipped: the label sits inside its segment.
    final segment = tester.getRect(
      find
          .ancestor(of: find.text('Quarterly'), matching: find.byType(InkWell))
          .first,
    );
    final label = tester.getRect(find.text('Quarterly'));
    expect(label.left, greaterThanOrEqualTo(segment.left));
    expect(label.right, lessThanOrEqualTo(segment.right));
    expect(tester.takeException(), isNull);
  });
}
