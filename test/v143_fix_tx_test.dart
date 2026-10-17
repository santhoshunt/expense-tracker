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
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/widgets/empty_state.dart';
import 'package:expense_tracker/widgets/info_tip.dart';
import 'package:expense_tracker/widgets/lock_gate.dart';
import 'package:expense_tracker/widgets/review_sheet.dart';
import 'package:expense_tracker/widgets/transaction_tile.dart';
import 'package:expense_tracker/widgets/undo_snackbar.dart';

/// v1.43.0 review fixes on the Transactions side: where the edit sheet's
/// Undo offers land, the review sheet's insets and tap targets, stale
/// filter ids, the Filters label, the selection count and the bottom bar
/// labels. Invented names, senders and amounts only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Widget page(FinanceProvider p, Widget body, {double textScale = 1}) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(body: body),
        ),
      );

  /// A button that opens the review sheet.
  Widget reviewOpener() => Builder(
    builder: (context) => Center(
      child: TextButton(
        onPressed: () => showReviewSheet(context),
        child: const Text('open'),
      ),
    ),
  );

  Tx pendingRow(String id, double amount, String note) => Tx(
    id: id,
    type: TxType.expense,
    categoryId: 'food',
    amount: amount,
    note: note,
    sender: 'VM-SAMPLE',
    date: DateTime(2026, 10, 12, 11),
    pending: true,
  );

  Tx spamRow() => Tx(
    id: 'spam',
    type: TxType.income,
    categoryId: 'other_income',
    amount: 9000,
    note: 'Prize Desk',
    sender: 'AX-PROMOS',
    date: DateTime(2026, 10, 12, 10),
    pending: true,
    suspectedSpam: true,
  );

  Future<FinanceProvider> withRows(List<Tx> rows) async {
    final p = FinanceProvider();
    await p.load();
    await p.restoreTransactions(rows);
    return p;
  }

  Finder sheetList() => find.descendant(
    of: find.byType(BottomSheet),
    matching: find.byType(ListView),
  );

  group('edit sheet Undo routing', () {
    testWidgets('with a host, Unlink keeps its toast on the edit sheet', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final p = await withRows([
        Tx(
          id: 'buy',
          type: TxType.expense,
          categoryId: 'shopping',
          amount: 900,
          note: 'Gadget Hub',
          date: DateTime(2026, 9, 25, 18, 30),
        ),
        Tx(
          id: 'back',
          type: TxType.income,
          categoryId: 'other_income',
          amount: 900,
          note: '',
          date: DateTime(2026, 10, 2, 10),
          refundOf: 'buy',
        ),
      ]);
      final hosted = <(String, AppToastTone)>[];
      await tester.pumpWidget(
        page(
          p,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddTransactionSheet(
                context,
                existing: p.transactions.firstWhere((t) => t.id == 'back'),
                onUndoable: (message, undo, {required icon, required tone}) =>
                    hosted.add((message, tone)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final unlink = find.widgetWithText(TextButton, 'Unlink');
      await tester.ensureVisible(unlink);
      await tester.pumpAndSettle();
      await tester.tap(unlink);
      await tester.pumpAndSettle();

      // The sheet stays open, so the host never sees the offer.
      expect(hosted, isEmpty);
      expect(find.text('Edit transaction'), findsOneWidget);
      final toast = find.text('Unlinked');
      expect(
        find.ancestor(of: toast, matching: find.byType(ToastHost)),
        findsOneWidget,
      );
      expect(toast.hitTestable(), findsOneWidget);

      // Delete closes the sheet: that offer goes to the host. After the
      // toast, whose strip takes taps while it shows.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      final delete = find.text('Delete transaction');
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(hosted, hasLength(1));
      expect(hosted.single.$1, startsWith('Deleted '));
      expect(hosted.single.$2, AppToastTone.removal);
    });

    testWidgets('a confirming save hands the host its success tone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final p = await withRows([pendingRow('r1', 120, 'Demo Kiosk')]);
      final hosted = <(String, AppToastTone)>[];
      await tester.pumpWidget(
        page(
          p,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddTransactionSheet(
                context,
                existing: p.pendingTransactions.single,
                onUndoable: (message, undo, {required icon, required tone}) =>
                    hosted.add((message, tone)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final save = find.widgetWithText(FilledButton, 'Save and confirm');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(hosted, [('Saved and confirmed', AppToastTone.success)]);
    });

    testWidgets('a delete from the review sheet keeps its removal tint', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await withRows([
        pendingRow('r1', 120, 'Demo Kiosk'),
        pendingRow('r2', 80, 'Sample Cafe'),
      ]);
      await tester.pumpWidget(page(p, reviewOpener()));
      await tester.pumpAndSettle();
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Demo Kiosk'));
      await tester.pumpAndSettle();
      final delete = find.text('Delete transaction');
      await tester.ensureVisible(delete);
      await tester.pumpAndSettle();
      await tester.tap(delete);
      await tester.pumpAndSettle();

      // One row left: the review sheet stays and shows the toast itself.
      expect(find.text('Imported from SMS'), findsOneWidget);
      final icon = find.descendant(
        of: find.byType(SnackBar),
        matching: find.byIcon(Icons.delete_outline),
      );
      expect(icon, findsOneWidget);
      final scheme = Theme.of(tester.element(icon)).colorScheme;
      expect(tester.widget<Icon>(icon).color, scheme.error);
      // One thud for the delete: the review sheet gives it, the edit sheet
      // does not add its own.
      expect(
        haptics.where((a) => a == 'HapticFeedbackType.mediumImpact'),
        hasLength(1),
      );
    });
  });

  testWidgets('More details reads as a button with its fold state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final p = await withRows(const []);
    await tester.pumpWidget(
      page(
        p,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddTransactionSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final semantics = tester.ensureSemantics();
    final fold = find.text('More details');
    await tester.ensureVisible(fold);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(fold),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        hasExpandedState: true,
        isExpanded: false,
      ),
    );
    await tester.tap(fold);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(fold),
      isSemantics(isButton: true, hasExpandedState: true, isExpanded: true),
    );
    semantics.dispose();
  });

  group('review sheet', () {
    testWidgets('spam alone: the list clears the nav bar and the fold header '
        'and its "i" are 48dp', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.reset);
      final p = await withRows([spamRow()]);
      await tester.pumpWidget(page(p, reviewOpener()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // No batch bar, so the list pads for the nav bar itself.
      expect(find.text('Confirm all'), findsNothing);
      expect(
        tester.widget<ListView>(sheetList()).padding,
        const EdgeInsets.only(bottom: 16 + 24),
      );

      final header = find.ancestor(
        of: find.text('Suspected spam · 1'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(header.first).height, greaterThanOrEqualTo(48));
      final tip = find.byWidgetPredicate(
        (w) => w is InfoTip && w.title == 'Suspected spam',
      );
      expect(tester.getSize(tip), const Size(48, 48));
    });

    testWidgets('with the batch bar, the list keeps its own 16dp only', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      addTearDown(tester.view.reset);
      final p = await withRows([pendingRow('r1', 120, 'Demo Kiosk')]);
      await tester.pumpWidget(page(p, reviewOpener()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm all'), findsOneWidget);
      expect(
        tester.widget<ListView>(sheetList()).padding,
        const EdgeInsets.only(bottom: 16),
      );
    });

    testWidgets('opened empty, the empty state scrolls', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await withRows(const []);
      await tester.pumpWidget(page(p, reviewOpener()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final empty = find.byType(EmptyState);
      expect(empty, findsOneWidget);
      expect(
        find.ancestor(of: empty, matching: find.byType(SingleChildScrollView)),
        findsOneWidget,
      );
    });

    testWidgets('suggestion buttons keep a 48dp tap target', (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await withRows([
        Tx(
          id: 'q-out',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 5000,
          note: '',
          date: DateTime(2026, 10, 13, 12, 0),
          sender: 'VM-DEMOBK',
          acctKey: 'DEMOBK:1111',
          pending: true,
        ),
        Tx(
          id: 'q-in',
          type: TxType.income,
          categoryId: 'other_income',
          amount: 5000,
          note: '',
          date: DateTime(2026, 10, 13, 12, 2),
          sender: 'VM-DEMOCC',
          acctKey: 'DEMOCC:2222',
          pending: true,
        ),
      ]);
      await tester.pumpWidget(page(p, reviewOpener()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final dismiss = find.widgetWithText(TextButton, 'Not a transfer');
      final accept = find.widgetWithText(FilledButton, 'Pair');
      expect(dismiss, findsOneWidget);
      expect(accept, findsOneWidget);
      expect(tester.getSize(dismiss).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(accept).height, greaterThanOrEqualTo(48));
    });
  });

  group('transactions filters', () {
    Future<FinanceProvider> ledger() async {
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'Demo Kiosk',
        date: DateTime(2026, 7, 3, 9),
        tags: ['Demo trip'],
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 80,
        note: 'Sample Cab',
        date: DateTime(2026, 7, 4, 9),
      );
      return p;
    }

    testWidgets('a deleted group stops filtering and leaves no count', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await ledger();
      final group = await p.addGroup(label: 'Demo group', color: Colors.teal);
      await p.assignCategoryToGroup('food', group);
      await tester.pumpWidget(page(p, const TransactionsScreen()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        page(
          p,
          TransactionsScreen(
            request: TxFilterRequest(groupId: group),
            filterToken: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Group · Demo group'), findsOneWidget);
      expect(find.text('Sample Cab'), findsNothing);

      await p.deleteGroup(group);
      await tester.pumpAndSettle();
      expect(find.textContaining('Group ·'), findsNothing);
      expect(find.byTooltip('Filters'), findsOneWidget);
      expect(find.text('Demo Kiosk'), findsOneWidget);
      expect(find.text('Sample Cab'), findsOneWidget);
    });

    testWidgets('a deleted tag stops filtering and leaves no count', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await ledger();
      await tester.pumpWidget(page(p, const TransactionsScreen()));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        page(
          p,
          const TransactionsScreen(
            request: TxFilterRequest(tag: 'Demo trip'),
            filterToken: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tag · Demo trip'), findsOneWidget);
      expect(find.text('Sample Cab'), findsNothing);

      await p.deleteTag('Demo trip');
      await tester.pumpAndSettle();
      expect(find.textContaining('Tag ·'), findsNothing);
      expect(find.byTooltip('Filters'), findsOneWidget);
      expect(find.text('Sample Cab'), findsOneWidget);
    });
  });

  testWidgets('the selection count menu is at least 48 by 48', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = FinanceProvider();
    await p.load();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 120,
      note: 'Demo Kiosk',
      date: DateTime(2026, 9, 16),
    );
    await tester.pumpWidget(page(p, const TransactionsScreen()));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.longPress(find.byType(TransactionTile));
    await tester.pump(const Duration(milliseconds: 300));

    final count = find.byTooltip('Select all or none');
    expect(count, findsOneWidget);
    final size = tester.getSize(count);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  group('bottom bar labels', () {
    setUp(() => appLocked.value = false);
    tearDown(() => appLocked.value = true);

    Widget home(FinanceProvider p, double textScale) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: p),
        ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
        Provider<DriveBackupService>(create: (_) => DriveBackupService()),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    );

    // v1.43.1: the bar spans the full width again, so every label fits
    // and shows at every scale.
    for (final (scale, behavior) in [
      (1.0, NavigationDestinationLabelBehavior.alwaysShow),
      (1.15, NavigationDestinationLabelBehavior.alwaysShow),
      (1.3, NavigationDestinationLabelBehavior.alwaysShow),
    ]) {
      testWidgets('at ${scale}x text the labels are $behavior', (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final p = FinanceProvider();
        await p.load();
        await tester.pumpWidget(home(p, scale));
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          tester
              .widget<NavigationBar>(find.byType(NavigationBar))
              .labelBehavior,
          behavior,
        );
        // Every tab is still named.
        for (final tab in ['Dashboard', 'Transactions', 'Accounts']) {
          expect(find.byTooltip(tab), findsWidgets, reason: tab);
        }
      });
    }
  });
}
