import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/add_transaction_sheet.dart';
import 'package:expense_tracker/screens/home_screen.dart';
import 'package:expense_tracker/screens/search_screen.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';
import 'package:expense_tracker/widgets/undo_snackbar.dart';

/// An in-app link closes an add or edit sheet with nothing typed, as it
/// closes any page, and keeps one with typed input; an SMS import's result
/// toast shows above a sheet left open. Names and amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sms = MethodChannel('expense_tracker/sms');
  final binary =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    LaunchActions.instance.resetForTest();
    appLocked.value = false;
  });

  tearDown(() {
    binary.setMockMethodCallHandler(sms, null);
    LaunchActions.instance.resetForTest();
    appLocked.value = true;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<FinanceProvider> pumpHome(
    WidgetTester tester, {
    Future<void> Function(FinanceProvider)? seed,
  }) async {
    final finance = FinanceProvider();
    await finance.load();
    await seed?.call(finance);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await settle(tester);
    return finance;
  }

  final addSheet = find.widgetWithText(TextFormField, 'Amount');
  final transactionsShown = find.byType(TransactionsScreen).hitTestable();

  /// Search over the sheet, then a results page, then its Open in
  /// Transactions link, which goes through AppNav and its page guard.
  Future<void> openTransactionsFromSearch(WidgetTester tester) async {
    LaunchActions.instance.pending.value = LaunchAction.openSearch;
    await settle(tester);
    expect(find.byType(SearchScreen), findsOneWidget);
    Navigator.of(tester.element(find.byType(SearchScreen))).push(
      MaterialPageRoute<void>(
        builder: (_) => SearchPaymentsPage(
          title: 'Test results',
          rowsOf: (f) => f.transactions,
          transactionsRequest: const TxFilterRequest(),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byTooltip('Open in Transactions'));
    await settle(tester);
    expect(find.byType(SearchScreen, skipOffstage: false), findsNothing);
  }

  group('the page guard', () {
    testWidgets('closes an add sheet with nothing typed and shows the tab', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(transactionsShown, findsNothing, reason: 'starts on Dashboard');
      LaunchActions.instance.pending.value = LaunchAction.addExpense;
      await settle(tester);
      expect(addSheet, findsOneWidget);

      await openTransactionsFromSearch(tester);
      expect(addSheet, findsNothing, reason: 'nothing typed, so it closes');
      expect(transactionsShown, findsOneWidget);
    });

    testWidgets('keeps an add sheet with typed input', (tester) async {
      await pumpHome(tester);
      LaunchActions.instance.pending.value = LaunchAction.addExpense;
      await settle(tester);
      await tester.enterText(addSheet, '361');

      await openTransactionsFromSearch(tester);
      expect(addSheet, findsOneWidget, reason: 'the sheet is on top again');
      expect(
        find.byWidgetPredicate(
          (w) => w is EditableText && w.controller.text == '361',
        ),
        findsOneWidget,
      );
    });

    testWidgets('treats an unchanged edit sheet as clean', (tester) async {
      final finance = await pumpHome(
        tester,
        seed: (p) => p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 274,
          note: 'test lunch',
          date: DateTime(2026, 9, 14, 13),
        ),
      );
      showAddTransactionSheet(
        tester.element(find.byType(HomeScreen)),
        existing: finance.transactions.single,
      );
      await settle(tester);
      expect(find.text('Edit transaction'), findsOneWidget);

      await openTransactionsFromSearch(tester);
      expect(find.text('Edit transaction'), findsNothing);
      expect(transactionsShown, findsOneWidget);
    });

    testWidgets('keeps an edit sheet with a changed field', (tester) async {
      final finance = await pumpHome(
        tester,
        seed: (p) => p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 274,
          note: 'test lunch',
          date: DateTime(2026, 9, 14, 13),
        ),
      );
      showAddTransactionSheet(
        tester.element(find.byType(HomeScreen)),
        existing: finance.transactions.single,
      );
      await settle(tester);
      await tester.enterText(addSheet, '285');

      await openTransactionsFromSearch(tester);
      expect(find.text('Edit transaction'), findsOneWidget);
    });
  });

  group('the SMS import result toast', () {
    const denied = 'SMS permission denied. Nothing imported.';

    void denySms() => binary.setMockMethodCallHandler(sms, (call) async {
      switch (call.method) {
        case 'requestPermission':
          return 'denied';
        case 'hasPermission':
        case 'notifHasAccess':
          return false;
      }
      return null;
    });

    /// The import's own range sheet: Scan messages, the topmost one.
    Future<void> scan(WidgetTester tester) async {
      expect(find.text('Import from SMS'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('editor-save')).last);
      await settle(tester);
    }

    testWidgets('shows above a typed add sheet the import left open', (
      tester,
    ) async {
      await pumpHome(tester);
      denySms();
      LaunchActions.instance.pending.value = LaunchAction.addExpense;
      await settle(tester);
      await tester.enterText(addSheet, '432');
      // The review sheet over it, empty, offers Import from SMS.
      LaunchActions.instance.pending.value = LaunchAction.openReview;
      await settle(tester);
      await tester.tap(find.text('Import from SMS'));
      await settle(tester);
      await scan(tester);

      expect(addSheet, findsOneWidget, reason: 'typed, so it stayed');
      expect(
        find.descendant(of: find.byType(ToastHost), matching: find.text(denied)),
        findsOneWidget,
        reason: "on the sheet's own messenger",
      );
      expect(find.text(denied).hitTestable(), findsOneWidget);
    });

    testWidgets('with no sheet open shows on Home as before', (tester) async {
      await pumpHome(tester);
      denySms();
      LaunchActions.instance.pending.value = LaunchAction.importSms;
      await settle(tester);
      await scan(tester);

      expect(find.byType(ToastHost), findsNothing);
      expect(
        find.descendant(
          of: find.byType(HomeScreen),
          matching: find.text(denied),
        ),
        findsOneWidget,
      );
      expect(find.text(denied).hitTestable(), findsOneWidget);
    });
  });
}
