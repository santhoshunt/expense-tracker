import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';

/// The dialog helpers own their TextEditingControllers and dispose them in a
/// `finally` after `await showDialog(...)`. That is only safe if the future
/// completes *after* the route's exit transition has finished — otherwise the
/// TextField is still mounted and reads a disposed controller.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(
    WidgetTester tester,
    Future<void> Function(BuildContext) open,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final finance = FinanceProvider();
    await finance.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: finance,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => open(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('credit-limit dialog survives typing then cancelling', (
    tester,
  ) async {
    final account = Account(
      id: 'a1',
      name: 'HDFC ••9012',
      type: AccountType.creditCard,
      keys: {'HDFC:9012'},
    );
    await pumpHost(tester, (ctx) => showCreditLimitDialog(ctx, account));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Credit limit'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '150000');
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    // Runs the exit transition to completion — the window in which a
    // prematurely disposed controller would be read.
    await tester.pumpAndSettle();

    expect(find.text('Credit limit'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('account-key dialog survives being dismissed by barrier tap', (
    tester,
  ) async {
    await pumpHost(tester, (ctx) async => showAccountKeyDialog(ctx));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '1234');
    await tester.pump();

    // Barrier dismiss rather than an explicit button — the same teardown path
    // the system back gesture takes.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
