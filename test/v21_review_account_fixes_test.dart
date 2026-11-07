import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';
import 'package:expense_tracker/screens/category_management.dart';
import 'package:expense_tracker/utils/format.dart';

/// Review fixes in the account and category editors: Unlink's Undo, the
/// savings icon picker for a screen reader, and a long category name.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  /// A button that opens a sheet through [open].
  Future<void> pumpOpener(
    WidgetTester tester,
    FinanceProvider p,
    Future<void> Function(BuildContext) open,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: p,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => open(context),
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

  testWidgets('Undo of Unlink keeps a hand-linked number Added by hand', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    final id = await p.addAccount(name: 'Zeta', type: AccountType.bank);
    const key = 'DEMOBK:4321';
    await p.addAccountKey(id, key);
    // Alerts for the number arrive after it was typed in.
    await p.restoreTransactions([
      Tx(
        id: 's1',
        type: TxType.expense,
        categoryId: 'other_expense',
        amount: 120,
        note: '',
        date: DateTime(2026, 9, 12, 13),
        source: TxSource.sms,
        smsBody: 'Rs 120 debited from a/c XX4321 at SAMPLE STORE',
        sender: 'AD-DEMOBK',
        acctKey: key,
      ),
    ]);
    expect(p.accountById(id)!.linkedByHand, contains(key));

    await pumpOpener(
      tester,
      p,
      (c) => showLinkedNumbersSheet(c, p.accountById(id)!),
    );
    expect(find.text('Added by hand'), findsOneWidget);
    await tester.tap(find.byTooltip('Unlink'));
    await tester.pumpAndSettle();
    expect(p.accountById(id)!.keys, isNot(contains(key)));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(p.accountById(id)!.keys, contains(key));
    expect(p.accountById(id)!.linkedByHand, contains(key));
    expect(find.text('Added by hand'), findsOneWidget);
    expect(find.text('From an SMS'), findsNothing);
  });

  testWidgets('a savings icon is a button a screen reader can press', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final p = FinanceProvider();
    await p.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: SettingsProvider()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddAccountDialog(
                  context,
                  initialType: AccountType.savings,
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

    // Not Gold: a Kind suggestion chip has that label too.
    final gold = find.bySemanticsLabel(iconLabelOf('property'));
    expect(gold, findsOneWidget);
    expect(
      tester.getSemantics(gold),
      isSemantics(
        label: iconLabelOf('property'),
        isButton: true,
        hasTapAction: true,
      ),
    );
    semantics.dispose();
  });

  testWidgets('editing a category keeps an older name past 30 letters', (
    tester,
  ) async {
    final p = FinanceProvider();
    await p.load();
    const long = 'Weekend trips with the cousins ok';
    expect(long.length, greaterThan(30));
    final id = await p.addCategory(
      label: long,
      type: TxType.expense,
      icon: Icons.flight,
      color: Colors.teal,
    );
    await pumpOpener(
      tester,
      p,
      (c) => showCategoryDialog(c, existing: categoryById(id)),
    );

    // One letter changed, the length kept.
    final edited = '${long.substring(0, long.length - 1)}K';
    await tester.enterText(find.byKey(const ValueKey('category-name')), edited);
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('category-name')),
    );
    expect(field.controller!.text, edited);
  });
}
