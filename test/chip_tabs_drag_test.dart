import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/widgets/glossy.dart';

/// v1.42.0: on Transactions, the type tabs follow a page swipe once it
/// passes halfway, before the finger lifts (PageView.onPageChanged fires
/// at the halfway point of a drag).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// The selected tab's filter name ('all', 'income', ...).
  String selectedChip(WidgetTester tester) {
    final tabs =
        tester.widget(find.byWidgetPredicate((w) => w is UnderlineTabs))
            as UnderlineTabs;
    return (tabs.selected as Enum).name;
  }

  testWidgets('the tab changes mid-drag, past halfway', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final finance = FinanceProvider();
    await finance.load();
    await finance.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 120,
      note: 'lunch',
      date: DateTime(2026, 7, 1),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: const MaterialApp(home: Scaffold(body: TransactionsScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(selectedChip(tester), 'all');

    final pager = find.byType(PageView);
    final width = tester.getSize(pager).width;
    final gesture = await tester.startGesture(tester.getCenter(pager));
    // Past the touch slop first, then on in steps to 0.6 of the width.
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(Offset(-width * 0.1, 0));
      await tester.pump();
    }
    expect(selectedChip(tester), 'income', reason: 'before the finger lifts');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(selectedChip(tester), 'income');
  });
}
