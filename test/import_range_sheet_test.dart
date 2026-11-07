import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/utils/format.dart';

/// Import from SMS asks how far back with quick-range chips, and Scan
/// messages hands back what was picked.
void main() {
  testWidgets('a quick range scans that many days; Since last scan scans '
      'from the last scan', (tester) async {
    final lastScan = DateTime(2026, 11, 2, 9, 14);
    ({Duration? lookback, DateTimeRange? range})? result;
    var answered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await askImportRange(context, lastScan: lastScan);
                answered = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('How far back'), findsOneWidget);
    expect(
      find.text('Since last scan (${fmtDateMaybeTime(lastScan)})'),
      findsOneWidget,
    );
    expect(find.text('7 days'), findsOneWidget);
    expect(find.text('Custom…'), findsOneWidget);
    expect(find.text('Scan messages'), findsOneWidget);

    await tester.tap(find.text('30 days'));
    await tester.pump();
    await tester.tap(find.text('Scan messages'));
    await tester.pumpAndSettle();
    expect(answered, isTrue);
    expect(result?.lookback, const Duration(days: 30));
    expect(result?.range, isNull);

    answered = false;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan messages'));
    await tester.pumpAndSettle();
    expect(answered, isTrue);
    expect(result, isNotNull);
    expect(result?.lookback, isNull);
    expect(result?.range, isNull);
  });
}
