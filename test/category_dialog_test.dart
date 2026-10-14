import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/category_management.dart';
import 'package:expense_tracker/widgets/animated_fold.dart';

/// The category dialog: the icon circle beside Name opens one sheet with
/// the icons and colours, and the Transfer switch waits behind Transfer
/// options.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// Opens the dialog for a new category, or with [editTransfer] for a
  /// transfer category made here.
  Future<FinanceProvider> open(
    WidgetTester tester, {
    bool editTransfer = false,
    double textScale = 1,
  }) async {
    final finance = FinanceProvider();
    await finance.load();
    String? id;
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

  AnimatedFold transferFold(WidgetTester tester) => tester.widget<AnimatedFold>(
    find.ancestor(
      of: find.text('Transfer'),
      matching: find.byType(AnimatedFold),
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
    await tester.tap(find.bySemanticsLabel('pets'));
    await tester.pump();
    // The sheet scrolls on a short screen: bring each target into view.
    await tester.ensureVisible(find.bySemanticsLabel('Teal'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('Teal'));
    await tester.pump();
    expect(find.text('Colour · Teal'), findsOneWidget);
    await tester.ensureVisible(find.text('Done'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The circle beside Name shows the pick.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
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

    final pets = tester.getSemantics(find.bySemanticsLabel('pets'));
    expect(pets.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    pets.owner!.performAction(pets.id, SemanticsAction.tap);
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsLabel('pets')),
      isSemantics(isSelected: true),
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
    await tester.ensureVisible(find.text('Transfer options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer options'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Transfer options opens onto the Transfer switch', (
    tester,
  ) async {
    await open(tester);
    expect(transferFold(tester).collapsed, isTrue);
    // The long subtitle that repeated the tip is gone.
    expect(find.textContaining('Affects account balance only'), findsNothing);

    await tester.tap(find.text('Transfer options'));
    await tester.pumpAndSettle();
    expect(transferFold(tester).collapsed, isFalse);
    expect(find.text('Moves money, not income or spending'), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Lent');
    // Create enables on the rebuild that follows the typed name.
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(customCategories.single.isTransfer, isTrue);
  });

  testWidgets('editing a transfer opens with Transfer options open', (
    tester,
  ) async {
    await open(tester, editTransfer: true);
    expect(find.text('Edit category'), findsOneWidget);
    // Editing: the circle already shows the category, so no hint.
    expect(
      find.text('Tap the circle to pick an icon and colour'),
      findsNothing,
    );
    expect(transferFold(tester).collapsed, isFalse);
  });
}
