import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/widgets/color_picker_dialog.dart';

/// The custom colour picker: hex in and out, any colour allowed (a warning,
/// never a block), and saved colours that last.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Color? result;

  Future<void> open(WidgetTester tester, {Color initial = Colors.teal}) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async => result = await showColorPickerDialog(
                  context,
                  initial: initial,
                  title: 'Accent colour',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the colour code and takes a typed one', (tester) async {
    await open(tester, initial: const Color(0xFF2EC4B6));
    expect(find.text('Accent colour'), findsOneWidget);
    expect(find.text('2EC4B6'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '7F56D9');
    await tester.pump();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(result, const Color(0xFF7F56D9));
  });

  testWidgets('a hard-to-read colour warns but can still be chosen', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), '050505');
    await tester.pump();
    expect(find.textContaining('Very dark'), findsOneWidget);
    final select = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Select'),
    );
    expect(select.onPressed, isNotNull, reason: 'a warning, not a block');
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(result, const Color(0xFF050505));
  });

  testWidgets('a vertical drag on the shade square changes brightness', (
    tester,
  ) async {
    await open(tester, initial: const Color(0xFFFF0000));
    final square = find.bySemanticsLabel('Shade');
    // Straight down from near the top: the sheet must not take the drag.
    final top = tester.getTopLeft(square) + const Offset(40, 4);
    final gesture = await tester.startGesture(top);
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('Select'), findsOneWidget, reason: 'the sheet stayed');
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(HSVColor.fromColor(result!).value, lessThan(0.2));
  });

  testWidgets('Add keeps a colour for next time', (tester) async {
    await open(tester, initial: const Color(0xFF7F56D9));
    expect(find.textContaining('Add keeps this colour'), findsOneWidget);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Saved colour #7F56D9'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await open(tester, initial: Colors.teal);
    expect(find.bySemanticsLabel('Saved colour #7F56D9'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Saved colour #7F56D9'));
    await tester.pump();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(result, const Color(0xFF7F56D9));
  });
}
