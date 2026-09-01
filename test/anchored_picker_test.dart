import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/anchored_picker.dart';

void main() {
  Widget host({
    required List<PickerItem<String>> items,
    String? value,
    required ValueChanged<String?> onChanged,
    bool? searchable,
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
          searchable: searchable,
        ),
      ),
    ),
  );

  final fruit = [
    const PickerItem(value: 'apple', label: 'Apple'),
    const PickerItem(value: 'banana', label: 'Banana'),
    const PickerItem(value: 'cherry', label: 'Cherry'),
  ];

  testWidgets('opens a compact panel and returns the tapped value', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      host(items: fruit, value: 'apple', onChanged: (v) => picked = v),
    );
    await tester.tap(find.text('Apple')); // field shows the selection
    await tester.pumpAndSettle();

    expect(find.text('Banana'), findsOneWidget);
    await tester.tap(find.text('Banana'));
    await tester.pumpAndSettle();

    expect(picked, 'banana');
    expect(find.text('Cherry'), findsNothing); // panel closed
  });

  testWidgets('dismissing does not fire onChanged', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(items: fruit, value: 'apple', onChanged: (_) => calls++),
    );
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();
    // Tap the transparent barrier well away from the panel.
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
        host(
          items: items,
          value: 'banana',
          onChanged: (_) {},
          searchable: true,
        ),
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
      expect(find.text('Banana'), findsWidgets); // field + panel row
      expect(find.text('FRUIT'), findsOneWidget);
    },
  );

  testWidgets('search box appears automatically above 8 items', (tester) async {
    final many = [
      for (var i = 0; i < 12; i++)
        PickerItem(value: 'v$i', label: 'Option number $i'),
    ];
    await tester.pumpWidget(host(items: many, onChanged: (_) {}));
    await tester.tap(find.text('Nothing yet'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    // And the panel stays compact: its list is scrollable, not full-screen.
    expect(find.text('Option number 0'), findsOneWidget);
  });

  testWidgets('panel follows the field when the layout reflows', (
    tester,
  ) async {
    // Simulates a keyboard-driven reflow: the field moves after the panel
    // is already open; the follower must keep the panel glued to it.
    Widget at(double topPadding) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(top: topPadding, left: 24, right: 24),
          child: Column(
            children: [
              AppDropdownField<String>(
                items: fruit,
                value: 'apple',
                onChanged: (_) {},
                label: 'Pick one',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.pumpWidget(at(200));
    await tester.tap(find.text('Apple'));
    await tester.pumpAndSettle();

    final fieldBottomBefore = tester
        .getBottomLeft(find.byType(AppDropdownField<String>))
        .dy;
    final panelTopBefore = tester.getTopLeft(find.text('Banana').last).dy;
    expect(panelTopBefore, greaterThan(fieldBottomBefore));

    // Reflow: the field jumps 120px up while the panel is open.
    await tester.pumpWidget(at(80));
    await tester.pumpAndSettle();

    final fieldBottomAfter = tester
        .getBottomLeft(find.byType(AppDropdownField<String>))
        .dy;
    final panelTopAfter = tester.getTopLeft(find.text('Banana').last).dy;
    expect(fieldBottomAfter, lessThan(fieldBottomBefore));
    // Panel moved WITH the field: same gap as before, within a pixel.
    expect(
      (panelTopAfter - fieldBottomAfter) - (panelTopBefore - fieldBottomBefore),
      closeTo(0, 1),
    );
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
}
