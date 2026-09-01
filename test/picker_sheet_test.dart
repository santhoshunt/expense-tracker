import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/picker_sheet.dart';

void main() {
  Widget host({
    required List<PickerItem<String>> items,
    String? value,
    required ValueChanged<String?> onChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: AppDropdownField<String>(
          items: items,
          value: value,
          onChanged: onChanged,
          label: 'Pick one',
          hint: 'Nothing yet',
        ),
      ),
    ),
  );

  final fruit = [
    const PickerItem(value: 'apple', label: 'Apple'),
    const PickerItem(value: 'banana', label: 'Banana'),
    const PickerItem(value: 'cherry', label: 'Cherry'),
  ];

  testWidgets('opens a sheet with a bold title and returns the tapped value', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      host(items: fruit, value: 'apple', onChanged: (v) => picked = v),
    );
    await tester.tap(find.text('Apple')); // field shows the selection
    await tester.pumpAndSettle();

    // Field label + the sheet's own title.
    expect(find.text('Pick one'), findsNWidgets(2));
    expect(find.text('Banana'), findsOneWidget);
    await tester.tap(find.text('Banana'));
    await tester.pumpAndSettle();

    expect(picked, 'banana');
    expect(find.text('Cherry'), findsNothing); // sheet closed
  });

  testWidgets('selected row carries the check_circle, others do not', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(items: fruit, value: 'banana', onChanged: (_) {}),
    );
    await tester.tap(find.text('Banana'));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    final row = find.ancestor(
      of: find.byIcon(Icons.check_circle),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: row.first, matching: find.text('Banana')),
      findsOneWidget,
    );
  });

  testWidgets('dismissing does not fire onChanged', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(items: fruit, value: 'apple', onChanged: (_) => calls++),
    );
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    // Tap the barrier well above the sheet.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('null-valued item is selectable and distinct from dismissal', (
    tester,
  ) async {
    String? picked = 'sentinel';
    var fired = false;
    final items = [
      const PickerItem<String>(value: null, label: 'Unassigned'),
      ...fruit,
    ];
    await tester.pumpWidget(
      host(
        items: items,
        value: 'apple',
        onChanged: (v) {
          fired = true;
          picked = v;
        },
      ),
    );
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unassigned'));
    await tester.pumpAndSettle();
    expect(fired, isTrue);
    expect(picked, isNull);
  });

  testWidgets(
    'search filters rows, hides emptied section headers, keeps selection',
    (tester) async {
      final items = <PickerItem<String>>[
        const PickerItem.header('Fruit'),
        ...fruit,
        const PickerItem.header('Veg'),
        const PickerItem(value: 'carrot', label: 'Carrot'),
        const PickerItem(value: 'potato', label: 'Potato'),
      ];
      await tester.pumpWidget(
        host(items: items, value: 'banana', onChanged: (_) {}),
      );
      await tester.tap(find.text('Banana'));
      await tester.pumpAndSettle();
      expect(find.text('FRUIT'), findsOneWidget);
      expect(find.text('VEG'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'carr');
      await tester.pumpAndSettle();

      expect(find.text('Carrot'), findsOneWidget);
      expect(find.text('Potato'), findsNothing);
      expect(find.text('VEG'), findsOneWidget);
      // Fruit section survives only through the always-visible selection.
      expect(find.text('Apple'), findsNothing);
      expect(find.text('Banana'), findsWidgets); // field + sheet row
      expect(find.text('FRUIT'), findsOneWidget);
    },
  );

  testWidgets('search field is always shown, even for a 3-item list', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(items: fruit, value: 'apple', onChanged: (_) {}),
    );
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('header rows are not tappable', (tester) async {
    var calls = 0;
    final items = <PickerItem<String>>[
      const PickerItem.header('Fruit'),
      ...fruit,
    ];
    await tester.pumpWidget(
      host(items: items, value: 'apple', onChanged: (_) => calls++),
    );
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('FRUIT'));
    await tester.pumpAndSettle();
    // Sheet still open, nothing fired.
    expect(find.text('Banana'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('selected row is auto-scrolled into view in a long list', (
    tester,
  ) async {
    final many = [
      for (var i = 0; i < 40; i++)
        PickerItem(value: 'v$i', label: 'Option number $i'),
    ];
    await tester.pumpWidget(host(items: many, value: 'v35', onChanged: (_) {}));
    await tester.tap(find.text('Option number 35'));
    await tester.pumpAndSettle();

    // Visible (hit-testable) without any manual scrolling.
    final row = find.text('Option number 35').last;
    expect(tester.getRect(row).height, greaterThan(0));
    await tester.tap(row); // would throw if off-screen
    await tester.pumpAndSettle();
  });

  testWidgets('sheet opened from inside an AlertDialog returns a value', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  content: AppDropdownField<String>(
                    items: fruit,
                    value: 'apple',
                    onChanged: (v) => picked = v,
                    label: 'Pick one',
                  ),
                ),
              ),
              child: const Text('Open dialog'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cherry'));
    await tester.pumpAndSettle();

    expect(picked, 'cherry');
    // The dialog underneath is still up; only the sheet closed.
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
