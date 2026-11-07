import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/dialog_expander.dart';
import 'package:expense_tracker/widgets/editor_sheet.dart';
import 'package:expense_tracker/widgets/info_tip.dart';
import 'package:expense_tracker/widgets/one_field_dialog.dart';
import 'package:expense_tracker/widgets/picker_sheet.dart';

/// The shared editor sheet: a pinned footer that says what is missing, a
/// first field whose label stays in view, and value folds that build
/// nothing while closed, at a small phone's size and 2x text too.
void main() {
  /// Pumps the app's own theme at [textScale] and opens a sheet with
  /// [body] from a button named 'open'.
  Future<void> openSheet(
    WidgetTester tester,
    Widget Function() body, {
    double textScale = 1,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          brightness: Brightness.dark,
          accent: FigmaPalette.primary,
        ),
        // Above the routes, so the sheet gets the text scale too.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showEditorSheet<void>(context, builder: (_) => body()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void smallPhone(WidgetTester tester, {double keyboard = 0}) {
    tester.view.physicalSize = const Size(320, 568) * 3;
    tester.view.devicePixelRatio = 3;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 3);
    addTearDown(tester.view.reset);
  }

  final save = find.byKey(const ValueKey('editor-save'));

  testWidgets('the footer stays pinned and says what is missing', (
    tester,
  ) async {
    await openSheet(
      tester,
      () => EditorSheetBody(
        title: 'New thing',
        footerLabel: 'Save',
        footerReason: 'Enter a name',
        onSave: null,
        children: [
          for (var i = 0; i < 30; i++) ListTile(title: Text('Row $i')),
        ],
      ),
    );

    expect(find.text('Enter a name'), findsOneWidget);
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getBottomLeft(save).dy, lessThanOrEqualTo(screen.height));
    expect(save.hitTestable(), findsOneWidget);
  });

  testWidgets('Back on an editor sheet calls onBack', (tester) async {
    var backs = 0;
    await openSheet(
      tester,
      () => EditorSheetBody(
        title: 'New trip budget',
        onBack: () => backs++,
        footerLabel: 'Save',
        onSave: null,
        children: const [Text('inside')],
      ),
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(backs, 1);
    // It hands back to the caller; the sheet stays open.
    expect(find.text('New trip budget'), findsOneWidget);
  });

  testWidgets('Back on a form with edits asks Discard changes? first', (
    tester,
  ) async {
    var backs = 0;
    await openSheet(
      tester,
      () => EditorSheetBody(
        title: 'New trip budget',
        onBack: () => backs++,
        footerLabel: 'Save',
        onSave: null,
        dirty: true,
        children: const [Text('inside')],
      ),
    );

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(backs, 0);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(backs, 1);
    expect(find.text('New trip budget'), findsOneWidget);
  });

  testWidgets('a value fold builds nothing while closed', (tester) async {
    var open = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => DialogExpander(
              title: 'Split',
              value: 'Off',
              keepClosed: false,
              open: open,
              onToggle: () => setState(() => open = !open),
              child: const Text('inside'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Off'), findsOneWidget);
    expect(find.text('inside'), findsNothing);
    await tester.tap(find.text('Split'));
    await tester.pumpAndSettle();
    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets('at 320dp and 2x text the header neither overflows nor clips', (
    tester,
  ) async {
    smallPhone(tester);
    var open = false;
    await openSheet(
      tester,
      () => StatefulBuilder(
        builder: (context, setState) => EditorSheetBody(
          title: 'Edit transaction',
          menu: const [PopupMenuItem(value: 'delete', child: Text('Delete'))],
          footerLabel: 'Save changes',
          onSave: () {},
          children: [
            DialogExpander(
              title: 'Tags, subscription, count in',
              value: '# Diwali · Monthly subscription',
              keepClosed: false,
              open: open,
              onToggle: () => setState(() => open = !open),
              child: const Text('inside'),
            ),
          ],
        ),
      ),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Tags, subscription, count in'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('inside'), findsOneWidget);
  });

  testWidgets("the first field's floating label sits inside the scroll view", (
    tester,
  ) async {
    final ctrl = TextEditingController(text: 'Dining');
    addTearDown(ctrl.dispose);
    await openSheet(
      tester,
      () => EditorSheetBody(
        title: 'New thing',
        footerLabel: 'Save',
        onSave: () {},
        children: [
          TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
        ],
      ),
    );

    final scroll = find.descendant(
      of: find.byType(EditorSheetBody),
      matching: find.byType(SingleChildScrollView),
    );
    expect(
      tester.getRect(find.text('Name')).top,
      greaterThanOrEqualTo(tester.getRect(scroll).top),
    );
  });

  testWidgets('the footer stack fits a small phone with the keyboard up', (
    tester,
  ) async {
    smallPhone(tester, keyboard: 280);
    const reason =
        'Enter a minimum above ₹0, or leave it blank, and pick a category '
        'or add a merchant word';
    await openSheet(
      tester,
      () => EditorSheetBody(
        title: 'Edit reward group',
        footerLabel: 'Save',
        footerReason: reason,
        footerExtra: const Text(
          'extra line',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onSave: null,
        children: const [TextField()],
      ),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    // Cut to one line rather than wrapping onto two.
    final paragraph = tester.renderObject<RenderParagraph>(find.text(reason));
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(find.text('extra line'), findsNothing);
    expect(save.hitTestable(), findsOneWidget);
  });

  // The sheet's own drag popped the route directly, past the guard.
  testWidgets('dragging the handle down asks on a dirty sheet and closes a '
      'clean one', (tester) async {
    var dirty = true;
    await openSheet(
      tester,
      () => EditorSheetBody(
        title: 'Edit thing',
        footerLabel: 'Save',
        onSave: () {},
        dirty: dirty,
        children: const [Text('inside')],
      ),
    );
    final handle = find.byKey(const ValueKey('editor-sheet-handle'));

    await tester.drag(handle, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Edit thing'), findsOneWidget);

    // Closed, then opened clean.
    await tester.drag(handle, const Offset(0, 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Edit thing'), findsNothing);
    dirty = false;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.drag(handle, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('Edit thing'), findsNothing);
  });

  // The handle closes a sheet with the keyboard still up, and the dialog
  // overflowed by about 248px there.
  testWidgets('Discard changes? fits a small phone with 2x text and the '
      'keyboard up', (tester) async {
    smallPhone(tester, keyboard: 280);
    await openSheet(
      tester,
      () => const EditorSheetBody(
        title: 'Edit thing',
        footerLabel: 'Save',
        onSave: null,
        dirty: true,
        children: [TextField(autofocus: true)],
      ),
      textScale: 2,
    );

    await tester.drag(
      find.byKey(const ValueKey('editor-sheet-handle')),
      const Offset(0, 100),
    );
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(find.text('Discard').hitTestable(), findsOneWidget);
    expect(find.text('Keep editing').hitTestable(), findsOneWidget);
  });

  /// A button named 'open' that runs [open] with the app's context.
  Future<void> pumpOpener(
    WidgetTester tester,
    void Function(BuildContext context) open,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a short picker has no search and ticks a null value', (
    tester,
  ) async {
    await pumpOpener(
      tester,
      (context) => showPickerSheet<String>(
        context: context,
        title: 'Statement day',
        items: const [
          PickerItem(value: null, label: 'Not set'),
          PickerItem(value: 'a', label: 'A'),
        ],
        selected: null,
        selectedIsSet: true,
      ),
    );

    expect(find.text('Search…'), findsNothing);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(
      find.ancestor(
        of: find.byIcon(Icons.check_circle),
        matching: find.widgetWithText(Row, 'Not set'),
      ),
      findsWidgets,
    );
  });

  testWidgets('a one-field dialog saves only a valid change', (tester) async {
    String? result;
    await pumpOpener(tester, (context) async {
      result = await showOneFieldDialog(
        context,
        title: 'Savings goal',
        label: 'Target amount',
        tip: const InfoTip(title: 'Target amount', message: 'The goal.'),
        initial: '',
        problem: (text) => text == 'x' ? 'Enter a number, e.g. 45000' : null,
      );
    });
    FilledButton save() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

    expect(save().onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    expect(save().onPressed, isNull);
    expect(find.text('Enter a number, e.g. 45000'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '5');
    await tester.pump();
    expect(save().onPressed, isNotNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, '5');
  });
}
