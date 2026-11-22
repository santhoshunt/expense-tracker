import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/widgets/ahead_projection.dart';

/// The Ahead section's balance chart: the readout bubble while a finger
/// drags, and the day labels under the line.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => aheadClock = DateTime.now);

  Future<FinanceProvider> pump(WidgetTester tester) async {
    final finance = FinanceProvider();
    await finance.load();
    final settings = SettingsProvider();
    await settings.load();
    await tester.pumpWidget(host(finance, settings));
    await tester.pumpAndSettle();
    return finance;
  }

  final chart = find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        (w.properties.label ?? '').startsWith('Expected balance for the next'),
  );

  testWidgets('a long press the system cancels drops the readout bubble', (
    tester,
  ) async {
    await pump(tester);
    final gesture = await tester.startGesture(tester.getCenter(chart));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(find.textContaining('Balance after'), findsOneWidget);

    // The back-edge gesture or the notification shade: Android cancels the
    // pointer instead of lifting it.
    await gesture.cancel();
    await tester.pump();
    expect(find.textContaining('Balance after'), findsNothing);
  });

  testWidgets('the balance line repaints its day labels when the day turns', (
    tester,
  ) async {
    // Late evening, so a few hours later is the next day.
    final start = DateTime(2026, 3, 9, 22);
    aheadClock = () => start;
    final finance = await pump(tester);
    final settings = Provider.of<SettingsProvider>(
      tester.element(chart),
      listen: false,
    );

    CustomPainter painter() => tester
        .widget<CustomPaint>(
          find.descendant(of: chart, matching: find.byType(CustomPaint)).first,
        )
        .painter!;
    final before = painter();

    // The same day again: nothing to repaint.
    await tester.pumpWidget(host(finance, settings));
    expect(painter().shouldRepaint(before), isFalse);

    // Past midnight with the balances unchanged: only the dates move.
    aheadClock = () => start.add(const Duration(hours: 4));
    await tester.pumpWidget(host(finance, settings));
    expect(painter().shouldRepaint(before), isTrue);
  });
}

Widget host(FinanceProvider finance, SettingsProvider settings) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: finance),
        ChangeNotifierProvider.value(value: settings),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AheadProjection(finance: finance, patterns: const []),
          ),
        ),
      ),
    );
