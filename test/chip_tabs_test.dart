import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/glossy.dart';

/// ChipTabs keeps the selected pill in view when the row scrolls sideways:
/// on the first frame and whenever the selection changes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const options = [
    (0, 'All accounts'),
    (1, 'Banks'),
    (2, 'Credit cards'),
    (3, 'Savings'),
    (4, 'Wallets'),
  ];

  Widget host(int selected, {double width = 220, Widget? above}) => MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [
          ?above,
          Center(
            child: SizedBox(
              width: width,
              child: ChipTabs<int>(
                options: options,
                selected: selected,
                onChanged: (_) {},
              ),
            ),
          ),
          // Room to scroll, so a vertical move would show.
          const SizedBox(height: 900),
        ],
      ),
    ),
  );

  /// Whether [label]'s pill lies inside the row's visible width.
  bool shown(WidgetTester tester, String label) {
    final row = tester.getRect(find.byType(SingleChildScrollView));
    final pill = tester.getRect(find.text(label));
    return pill.left >= row.left - 0.5 && pill.right <= row.right + 0.5;
  }

  testWidgets('a last option selected on a narrow row opens in view', (
    tester,
  ) async {
    await tester.pumpWidget(host(4));
    await tester.pumpAndSettle();
    expect(shown(tester, 'Wallets'), isTrue);
    expect(shown(tester, 'All accounts'), isFalse);
  });

  testWidgets('a new selection scrolls into view', (tester) async {
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    expect(shown(tester, 'All accounts'), isTrue);
    expect(shown(tester, 'Wallets'), isFalse);

    await tester.pumpWidget(host(4));
    await tester.pumpAndSettle();
    expect(shown(tester, 'Wallets'), isTrue);
  });

  testWidgets('only the chip row scrolls, not a list it sits in', (
    tester,
  ) async {
    // Low on the screen: centring it in the list would scroll the list.
    await tester.pumpWidget(host(4, above: const SizedBox(height: 500)));
    await tester.pumpAndSettle();
    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(list.position.axis, Axis.vertical);
    expect(list.position.pixels, 0);
    expect(shown(tester, 'Wallets'), isTrue, reason: 'the row still moved');
  });
}
