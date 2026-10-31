import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/app_nav.dart';
import 'package:expense_tracker/screens/dashboard_screen.dart';
import 'package:expense_tracker/services/monthly_recap.dart';
import 'package:expense_tracker/utils/dates.dart';
import 'package:expense_tracker/widgets/info_tip.dart';
import 'package:expense_tracker/widgets/reminder_editor_dialog.dart';

import 'dashboard_test_utils.dart';

/// The v1.43.0 review's gaps: the first-run card offers only the import,
/// the By group tip links to the category editor, and one reminder delete
/// whose Undo puts back the stored reminder where it was. Names and
/// amounts are made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final now = DateTime.now();
    // Past the recap week, so the Overview opens on the same cards each run.
    recapClock = () => DateTime(now.year, now.month, 20, 10);
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  tearDown(() => recapClock = DateTime.now);

  Future<void> pumpDashboard(
    WidgetTester tester,
    FinanceProvider p, {
    Size size = const Size(400, 1600),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = SettingsProvider();
    await s.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: dashboardShell(const DashboardScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<FinanceProvider> empty() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  group('the first-run card', () {
    final getStarted = find.byKey(const ValueKey('get-started'));

    testWidgets('offers Import SMS, leaves adding to the Add button', (
      tester,
    ) async {
      var imports = 0;
      final owner = Object();
      AppNav.instance.attachHome(
        owner,
        setTab: (_) {},
        openTransactions: (_) {},
        importSms: () => imports++,
      );
      addTearDown(() => AppNav.instance.detachHome(owner));
      await pumpDashboard(tester, await empty());

      expect(find.text('Get started'), findsOneWidget);
      expect(
        find.text(
          'No transactions yet. Import your bank SMS, or tap Add to enter '
          'one.',
        ),
        findsOneWidget,
      );
      expect(find.text('Add transaction'), findsNothing);
      final import = find.widgetWithText(FilledButton, 'Import SMS');
      expect(import, findsOneWidget);
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(imports, 1);
    });

    testWidgets('without SMS import it points at Add, with no button', (
      tester,
    ) async {
      await pumpDashboard(tester, await empty());
      expect(
        find.text('No transactions yet. Tap Add to enter one.'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: getStarted,
          matching: find.byType(ButtonStyleButton),
        ),
        findsNothing,
      );
    });

    testWidgets('is as wide as the balance card below it', (tester) async {
      await pumpDashboard(tester, await empty());
      final card = tester.getRect(getStarted);
      final balance = tester.getRect(find.byKey(const ValueKey('balance')));
      expect(card.left, balance.left);
      expect(card.right, balance.right);
    });

    testWidgets('fits 320dp at 1.3x text', (tester) async {
      final owner = Object();
      AppNav.instance.attachHome(
        owner,
        setTab: (_) {},
        openTransactions: (_) {},
        importSms: () {},
      );
      addTearDown(() => AppNav.instance.detachHome(owner));
      await pumpDashboard(
        tester,
        await empty(),
        size: const Size(320, 1400),
        textScale: 1.3,
      );
      final e = tester.takeException();
      expect(e, isNull, reason: e is FlutterError ? e.toStringDeep() : '$e');
      expect(find.text('Import SMS'), findsOneWidget);
    });
  });

  testWidgets("the By group tip links to the categories, where a category's "
      'group is set', (tester) async {
    final p = await empty();
    final group = await p.addGroup(label: 'Test needs', color: Colors.teal);
    await p.assignCategoryToGroup('food', group);
    final now = DateTime.now();
    await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 300,
      note: 'Test lunch',
      date: DateTime(now.year, now.month, 1),
    );
    await pumpDashboard(tester, p);
    await openDashboardView(tester, 'Breakdown');
    // The tip shows beside an open heading.
    await openDashboardSection(tester, 'groups');
    final tip = tester.widget<InfoTip>(
      find.byWidgetPredicate((w) => w is InfoTip && w.title == 'By group'),
    );
    expect(tip.link?.label, 'Edit categories');
    expect(tip.link?.prompt, contains("A category's group is set in its"));
    expect(tip.link?.onTap, goCockpitCategories);
  });

  group('deleting a reminder', () {
    Future<FinanceProvider> three() async {
      final p = await empty();
      final now = DateTime.now();
      // Due today, so all three are on the Next 7 days card.
      for (final name in ['Test rent', 'Test internet', 'Test gym']) {
        await p.addReminder(
          name: name,
          dayOfMonth: now.day,
          expectedAmount: 500,
          categoryId: 'bills',
        );
      }
      return p;
    }

    testWidgets('from Next 7 days, Undo puts it back where it was', (
      tester,
    ) async {
      final p = await three();
      final ids = [for (final r in p.reminders) r.id];
      await pumpDashboard(tester, p);
      await openDashboardView(tester, 'Ahead');
      await openDashboardSection(tester, 'upcoming');

      await tester.tap(find.text('Test internet'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('Delete'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Deleted reminder "Test internet"'), findsOneWidget);
      expect([for (final r in p.reminders) r.id], [ids[0], ids[2]]);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(
        [for (final r in p.reminders) r.id],
        ids,
        reason: 'back in the middle, not appended',
      );
    });

    testWidgets('from its editor, Undo keeps a paid mark made meanwhile', (
      tester,
    ) async {
      final p = await three();
      final ids = [for (final r in p.reminders) r.id];
      final id = ids[1];
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showReminderEditor(
                    context,
                    existing: p.reminders[1],
                    allowDelete: true,
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

      // Paid while the editor is open, as an import can mark it.
      final now = DateTime.now();
      final due = DateTime(now.year, now.month, now.day);
      await p.markReminderPaid(id, due);
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect([for (final r in p.reminders) r.id], [ids[0], ids[2]]);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect([for (final r in p.reminders) r.id], ids);
      expect(p.reminders[1].lastPaidMonth, monthKey(due));
    });

    testWidgets('an id no longer stored does nothing', (tester) async {
      final p = await three();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: p,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => deleteReminderWithUndo(context, 'gone'),
                  child: const Text('delete'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('delete'));
      await tester.pumpAndSettle();
      expect(p.reminders, hasLength(3));
      expect(find.text('Undo'), findsNothing);
    });
  });
}
