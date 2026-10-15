import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/update_downloader.dart';
import 'package:expense_tracker/services/update_installer.dart';
import 'package:expense_tracker/services/update_service.dart';
import 'package:expense_tracker/services/weekly_digest.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/figure_tile.dart';
import 'package:expense_tracker/widgets/link_pill.dart';
import 'package:expense_tracker/widgets/update_sheet.dart';

/// v1.40.0 leftover fixes: CSV unseen, the update sheet's link failure,
/// emptied accounts out of net balance, distinct ids and shared helpers.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<FinanceProvider> loaded() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  group('CSV unseen', () {
    Tx row(String id, {bool pending = false, bool unseen = false}) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: 'food',
      amount: 250,
      note: 'groceries',
      date: DateTime(2026, 9, 5, 12),
      pending: pending,
      unseen: unseen,
    );

    test('round trip keeps unseen; a pending row reads false', () {
      final csv = BackupService.buildCsvOf([
        row('a', unseen: true),
        row('b'),
        row('c', pending: true, unseen: true),
      ]);
      expect(csv.split('\r\n').first, endsWith(',walletCounted,unseen'));
      final back = {for (final t in BackupService.txsFromCsv(csv)) t.id: t};
      expect(back['a']!.unseen, isTrue);
      expect(back['b']!.unseen, isFalse);
      expect(back['c']!.pending, isTrue);
      expect(back['c']!.unseen, isFalse, reason: 'never set on a pending row');
    });

    test('an older file without the column reads false', () {
      final csv = BackupService.buildCsvOf([row('a', unseen: true)]);
      // The same file as an older build wrote it: no trailing unseen cell.
      final old = [
        for (final line in csv.split('\r\n'))
          line.substring(0, line.lastIndexOf(',')),
      ].join('\r\n');
      expect(old.split('\r\n').first, endsWith(',walletCounted'));
      expect(BackupService.txsFromCsv(old).single.unseen, isFalse);
    });
  });

  group('link failure', () {
    // Answers every launch with "not opened", whichever way the plugin
    // would otherwise fail in a test.
    void failLaunches(WidgetTester tester) {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }

    Future<void> pumpButton(WidgetTester tester, {VoidCallback? onFail}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openWebLink(
                    context,
                    'https://example.com/x',
                    onFail: onFail,
                  ),
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        );

    testWidgets('onFail is called instead of the toast', (tester) async {
      failLaunches(tester);
      var failed = 0;
      await pumpButton(tester, onFail: () => failed++);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(failed, 1);
      expect(find.text("Couldn't open the link."), findsNothing);
    });

    testWidgets('without onFail the toast still shows', (tester) async {
      failLaunches(tester);
      await pumpButton(tester);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't open the link."), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      // Let the toast time out, so no timer outlives the test.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('the update sheet says so on the sheet, once', (tester) async {
      failLaunches(tester);
      final settings = SettingsProvider();
      await settings.load();
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showUpdateSheet(
                    context,
                    UpdateList('1.39.1', [
                      ReleaseOption(
                        tag: 'v1.40.0',
                        publishedAt: DateTime(2026, 10, 15),
                        sizeBytes: 62 * 1024 * 1024,
                        notes: 'What changed',
                        downloadUrl: UpdateService.assetUrlFor('v1.40.0'),
                      ),
                    ]),
                    installer: _Installer(),
                    downloader: _Downloader(),
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
      expect(find.text("Couldn't open the link."), findsNothing);
      await tester.ensureVisible(find.text('Release page'));
      await tester.tap(find.text('Release page'));
      await tester.pumpAndSettle();
      // One: the line on the sheet, and no toast under it.
      expect(find.text("Couldn't open the link."), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(UpdateSheet),
          matching: find.text("Couldn't open the link."),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('emptied accounts', () {
    test('net balance drops an emptied SMS account\'s set balance but keeps '
        'a hand-made one\'s', () async {
      final p = await loaded();
      final old = await p.addAccount(name: 'Old HDFC', type: AccountType.bank);
      // An SMS-made number: one typed in by hand is waiting, not emptied.
      await p.addAccountKey(old, 'HDFC:4321', byHand: false);
      await p.setManualBalance(old, 5000);
      final cash = await p.addAccount(name: 'Cash', type: AccountType.bank);
      await p.setManualBalance(cash, 800);
      final card = await p.addAccount(
        name: 'Old card',
        type: AccountType.creditCard,
      );
      await p.addAccountKey(card, 'ICICI:9876', byHand: false);
      await p.setManualBalance(card, 1200);
      final rd = await p.addAccount(name: 'Old RD', type: AccountType.savings);
      await p.addAccountKey(rd, 'SBI:1111', byHand: false);
      await p.setManualBalance(rd, 3000);

      expect(p.isOrphanedAccount(p.accountById(old)!), isTrue);
      expect(p.isOrphanedAccount(p.accountById(cash)!), isFalse);
      expect(p.bankBalanceTotal, 800);
      expect(p.cardOutstandingTotal, 0);
      expect(p.savingsBalanceTotal, 0);
      expect(p.netWorth, 800);
      // Its own tile still shows the set balance.
      expect(p.accountBalance(p.accountById(old)!), 5000);
    });
  });

  test('categories, groups and budgets added back to back get distinct '
      'ids', () async {
    final p = await loaded();
    // Not awaited one by one: each id is minted before the method's first
    // await, so these run in one tight loop where timestamps repeat.
    final cats = await Future.wait([
      for (var i = 0; i < 20; i++)
        p.addCategory(
          label: 'Cat $i',
          type: TxType.expense,
          icon: Icons.star,
          color: Colors.teal,
        ),
    ]);
    final groups = await Future.wait([
      for (var i = 0; i < 20; i++)
        p.addGroup(label: 'Group $i', color: Colors.teal),
    ]);
    final budgets = await Future.wait([
      for (var i = 0; i < 20; i++)
        p.addBudget(
          name: 'Budget $i',
          limit: 1000,
          mode: BudgetMode.include,
          categoryIds: {'food'},
        ),
    ]);
    expect(cats.toSet(), hasLength(20));
    expect(groups.toSet(), hasLength(20));
    expect(budgets.toSet(), hasLength(20));
  });

  test('fmtInDays', () {
    expect(fmtInDays(0), 'today');
    expect(fmtInDays(1), 'tomorrow');
    expect(fmtInDays(5), 'in 5 days');
  });

  test('weekRangeLabel names the weekdays when asked', () {
    expect(
      weekRangeLabel(DateTime(2026, 10, 12), withWeekday: true),
      'Mon 12 to Sun 18 Oct',
    );
    expect(
      weekRangeLabel(DateTime(2026, 9, 28), withWeekday: true),
      'Mon 28 Sep to Sun 4 Oct',
    );
    // A mid-week day reads as its week.
    expect(
      weekRangeLabel(DateTime(2026, 10, 15), withWeekday: true),
      'Mon 12 to Sun 18 Oct',
    );
    // The default stays as the Monday note words it.
    expect(weekRangeLabel(DateTime(2026, 10, 12)), '12 to 18 Oct');
    expect(weekRangeLabel(DateTime(2026, 9, 28)), '28 Sep to 4 Oct');
  });

  group('FigureTile', () {
    Future<void> pump(WidgetTester tester, Widget tile) =>
        tester.pumpWidget(MaterialApp(home: Scaffold(body: tile)));

    testWidgets('no value shows the none text', (tester) async {
      await pump(
        tester,
        const FigureTile(title: 'Usual month', none: 'Not enough months yet'),
      );
      expect(find.text('Usual month'), findsOneWidget);
      expect(find.text('Not enough months yet'), findsOneWidget);
    });

    testWidgets('a value shows instead, with its note and colour', (
      tester,
    ) async {
      await pump(
        tester,
        const FigureTile(
          title: 'In',
          value: '₹500',
          color: Colors.green,
          none: 'None yet',
          note: 'Oct 2026',
        ),
      );
      expect(find.text('None yet'), findsNothing);
      expect(find.text('Oct 2026'), findsOneWidget);
      expect(tester.widget<Text>(find.text('₹500')).style?.color, Colors.green);
    });
  });
}

class _Installer implements UpdateInstaller {
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<void> openInstallSettings() async {}
  @override
  Future<String?> install(File apk) async => null;
}

class _Downloader extends UpdateDownloader {
  @override
  Future<File> download(
    ReleaseOption option, {
    void Function(int received, int total)? onProgress,
    DownloadCancel? cancel,
  }) async => File('${option.tag}.apk');

  @override
  Future<void> cleanup() async {}
}
