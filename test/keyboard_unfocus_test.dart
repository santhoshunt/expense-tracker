import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/widgets/keyboard_unfocus.dart';

void main() {
  Widget app(Widget home) => MaterialApp(
    builder: (context, child) =>
        UnfocusOnKeyboardDismiss(child: child ?? const SizedBox()),
    home: home,
  );

  Future<void> setKeyboardInset(WidgetTester tester, double bottom) async {
    tester.view.viewInsets = FakeViewPadding(bottom: bottom);
    tester.binding.handleMetricsChanged();
    await tester.pump();
  }

  testWidgets('text field loses focus when the keyboard collapses', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(Scaffold(body: TextField(focusNode: node))));

    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(node.hasFocus, isTrue);

    // Keyboard opens, then the user minimizes it with the system gesture.
    await setKeyboardInset(tester, 600);
    expect(node.hasFocus, isTrue);
    await setKeyboardInset(tester, 0);
    expect(node.hasFocus, isFalse);
  });

  testWidgets('non-text focus is left alone when the keyboard closes', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      app(
        Scaffold(
          body: ElevatedButton(
            focusNode: node,
            onPressed: () {},
            child: const Text('ok'),
          ),
        ),
      ),
    );

    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isTrue);

    await setKeyboardInset(tester, 600);
    await setKeyboardInset(tester, 0);
    expect(node.hasFocus, isTrue);
  });

  group('UnfocusOnScroll', () {
    Widget scrollable(FocusNode node, {ScrollController? controller}) => app(
      Scaffold(
        body: UnfocusOnScroll(
          child: SingleChildScrollView(
            controller: controller,
            child: Column(
              children: [
                TextField(focusNode: node),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      ),
    );

    testWidgets('a user drag on the wrapped scrollable unfocuses the field', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(scrollable(node));

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(node.hasFocus, isTrue);

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -100),
      );
      await tester.pump();
      expect(node.hasFocus, isFalse);
    });

    testWidgets('a programmatic scroll (no drag) keeps the focus', (
      tester,
    ) async {
      final node = FocusNode();
      final controller = ScrollController();
      addTearDown(node.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(scrollable(node, controller: controller));

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(node.hasFocus, isTrue);

      // The autofocus-reveal case: ensureVisible-style scrolls carry no
      // drag details and must not close the keyboard.
      controller.jumpTo(100);
      await tester.pump();
      expect(node.hasFocus, isTrue);
    });

    testWidgets('scrolling INSIDE a multiline field keeps the focus', (
      tester,
    ) async {
      final node = FocusNode();
      final text = TextEditingController(
        text: List.generate(30, (i) => 'line $i').join('\n'),
      );
      addTearDown(node.dispose);
      addTearDown(text.dispose);
      await tester.pumpWidget(
        app(
          Scaffold(
            body: UnfocusOnScroll(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    TextField(focusNode: node, controller: text, maxLines: 3),
                    const SizedBox(height: 1200),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(node.hasFocus, isTrue);

      // Dragging the field's own content scrolls the EditableText — a
      // deeper scrollable than the wrapped one; unfocusing there would
      // blank the field mid-edit.
      await tester.drag(find.byType(EditableText), const Offset(0, -40));
      await tester.pump();
      expect(node.hasFocus, isTrue);
    });
  });
}
