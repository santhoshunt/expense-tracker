import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/category_management.dart';
import 'package:expense_tracker/widgets/editor_sheet.dart';

/// The category editor: the icon circle beside Name opens one sheet with
/// the icons and colours, and the Transfer row's switch sits in plain
/// sight under the direction.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// Opens the editor for a new category, with [editTransfer] for a
  /// transfer category made here, or for the category [seed] makes.
  Future<FinanceProvider> open(
    WidgetTester tester, {
    bool editTransfer = false,
    double textScale = 1,
    Future<String> Function(FinanceProvider finance)? seed,
  }) async {
    final finance = FinanceProvider();
    await finance.load();
    String? id = await seed?.call(finance);
    if (editTransfer) {
      id = await finance.addCategory(
        label: 'Loan',
        type: TxType.expense,
        icon: Icons.home,
        color: kNoCategoryColor,
        isTransfer: true,
      );
    }
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: finance,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCategoryDialog(
                  context,
                  existing: id == null ? null : categoryById(id),
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
    return finance;
  }

  Switch transferSwitch(WidgetTester tester) => tester.widget<Switch>(
    find.descendant(
      of: find.widgetWithText(ListTile, 'Transfer'),
      matching: find.byType(Switch),
    ),
  );

  testWidgets('the icon circle opens one sheet; picks reach the category', (
    tester,
  ) async {
    final finance = await open(tester);
    expect(find.text('Tap the circle to pick an icon and colour'), findsOne);
    // The grid and colours left the dialog for the sheet.
    expect(find.text('Colour · None'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Icon and colour'));
    await tester.pumpAndSettle();
    expect(find.text('Colour · None'), findsOneWidget);
    // Colours first, then the icons; the sheet scrolls on a short screen:
    // bring each target into view.
    await tester.ensureVisible(find.bySemanticsLabel('Teal'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Teal'));
    await tester.pump();
    expect(find.text('Colour · Teal'), findsOneWidget);
    await tester.ensureVisible(find.bySemanticsLabel('Pets'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Pets'));
    await tester.pump();
    // Done is pinned under the scroll.
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The circle beside Name shows the pick.
    expect(
      find.descendant(
        of: find.byType(EditorSheetBody),
        matching: find.byIcon(Icons.pets),
      ),
      findsOneWidget,
    );

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Plants');
    // Create enables on the rebuild that follows the typed name.
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    final made = customCategories.single;
    expect(made.label, 'Plants');
    expect(made.icon, Icons.pets);
    expect(made.color, const Color(0xFF2EC4B6));
    expect(made.isTransfer, isFalse);
    expect(finance.isBuiltinCategory(made.id), isFalse);
  });

  testWidgets('a screen reader can open the sheet and pick an icon', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    final circle = tester.getSemantics(
      find.bySemanticsLabel('Icon and colour'),
    );
    expect(circle.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    circle.owner!.performAction(circle.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(find.text('Colour · None'), findsOneWidget);

    final pets = tester.getSemantics(find.bySemanticsLabel('Pets'));
    expect(pets.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    pets.owner!.performAction(pets.id, SemanticsAction.tap);
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Pets')),
      isSemantics(isSelected: true),
    );
    handle.dispose();
  });

  testWidgets('a screen reader hears the Transfer switch by name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    expect(
      tester.getSemantics(
        find.descendant(
          of: find.widgetWithText(ListTile, 'Transfer'),
          matching: find.byType(Switch),
        ),
      ),
      isSemantics(label: 'Transfer', hasToggledState: true),
    );
    handle.dispose();
  });

  testWidgets('a 2x font at 320dp lays the dialog out without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester, textScale: 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Transfer row turns the switch', (tester) async {
    await open(tester);
    expect(transferSwitch(tester).value, isFalse);
    // The long subtitle that repeated the tip is gone.
    expect(find.textContaining('Affects account balance only'), findsNothing);
    expect(find.text('Moves money, not income or spending'), findsOneWidget);

    await tester.tap(find.widgetWithText(ListTile, 'Transfer'));
    await tester.pump();
    expect(transferSwitch(tester).value, isTrue);

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Lent');
    // Create enables on the rebuild that follows the typed name.
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(customCategories.single.isTransfer, isTrue);
  });

  testWidgets('editing a transfer shows Transfer on', (tester) async {
    await open(tester, editTransfer: true);
    expect(find.text('Edit category'), findsOneWidget);
    // Editing: the circle already shows the category, so no hint.
    expect(
      find.text('Tap the circle to pick an icon and colour'),
      findsNothing,
    );
    expect(transferSwitch(tester).value, isTrue);
  });

  testWidgets('New group from the editor makes a group and picks it', (
    tester,
  ) async {
    final finance = await open(tester);
    await tester.tap(find.byKey(const ValueKey('category-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New group…'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      'Leisure',
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: dialog,
        matching: find.widgetWithText(FilledButton, 'Create'),
      ),
    );
    await tester.pumpAndSettle();

    expect(finance.groups.where((g) => g.label == 'Leisure'), hasLength(1));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('category-group')),
        matching: find.text('Leisure'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Delete shows what moves', (tester) async {
    await open(
      tester,
      seed: (finance) async {
        final id = await finance.addCategory(
          label: 'Birds',
          type: TxType.expense,
          icon: Icons.home,
          color: kNoCategoryColor,
        );
        for (final amount in [120.0, 340.0]) {
          await finance.addTransaction(
            type: TxType.expense,
            categoryId: id,
            amount: amount,
            note: 'Seed mix',
            date: DateTime.now().subtract(const Duration(days: 1)),
          );
        }
        await finance.addRule('featherworks', id);
        return id;
      },
    );
    await tester.tap(find.byTooltip('Category actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete category'));
    await tester.pumpAndSettle();
    expect(
      find.text('2 transactions move to Other. 1 rule loses it.'),
      findsOneWidget,
    );

    // Cancel goes back to the editor, still open.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Edit category'), findsOneWidget);
  });

  testWidgets('creating a unique name never flashes the duplicate error', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Garden');
    await tester.pump();
    await tester.tap(find.text('Create'));
    // Every frame of the save and the closing animation: the new category
    // is in the list before the dialog is gone, and must not match itself.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        find.text('A category with this name already exists'),
        findsNothing,
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('New category'), findsNothing);
    expect(customCategories.where((c) => c.label == 'Garden'), hasLength(1));
  });

  testWidgets('back during the save closes the editor and leaves the page '
      'under it', (tester) async {
    final finance = _SlowFinance();
    await finance.load();
    await tester.pumpWidget(
      ChangeNotifierProvider<FinanceProvider>.value(
        value: finance,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: Builder(
                      builder: (context) => TextButton(
                        onPressed: () => showCategoryDialog(context),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('page'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Garden');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pump();

    // Mid-write: back closes the editor at once, with no Discard question.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('Discard changes?'), findsNothing);
    expect(find.text('New category'), findsNothing);

    // The write finishing pops nothing more: the page stays.
    finance.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(customCategories.where((c) => c.label == 'Garden'), hasLength(1));
  });

  testWidgets('a name taken by another category still shows the error', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(find.byType(TextField), 'food & dining');
    await tester.pump();
    expect(
      find.text('A category with this name already exists'),
      findsOneWidget,
    );
  });
}

/// A provider whose category write waits for [gate], so a test can act
/// while it is in flight.
class _SlowFinance extends FinanceProvider {
  final gate = Completer<void>();

  @override
  Future<String> addCategory({
    required String label,
    required TxType type,
    required IconData icon,
    required Color color,
    bool isTransfer = false,
  }) async {
    await gate.future;
    return super.addCategory(
      label: label,
      type: type,
      icon: icon,
      color: color,
      isTransfer: isTransfer,
    );
  }
}
