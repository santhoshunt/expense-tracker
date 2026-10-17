import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/subscription_cycle.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/category_management.dart';
import 'package:expense_tracker/services/update_downloader.dart';
import 'package:expense_tracker/services/update_installer.dart';
import 'package:expense_tracker/services/update_service.dart';
import 'package:expense_tracker/services/weekly_digest.dart';
import 'package:expense_tracker/utils/format.dart';
import 'package:expense_tracker/widgets/delta_note.dart';
import 'package:expense_tracker/widgets/update_sheet.dart';
import 'package:expense_tracker/widgets/weekly_digest_sheet.dart';

/// v1.41.0 leftover fixes: a link that opens takes back the failure line,
/// the category dialog's inline save error, the digest's own Undo bar, the
/// cycle's yearly cost and the shared change note. Names and amounts are
/// made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });
  tearDown(() => weekClock = DateTime.now);

  Finder inSheet(Finder f) =>
      find.descendant(of: find.byType(BottomSheet), matching: f);

  testWidgets('a link that opens takes back the failure line', (tester) async {
    // Every launch answers with [opens], whichever methods launchUrl calls.
    var opens = false;
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => opens);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

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
                  UpdateList('1.40.0', [
                    ReleaseOption(
                      tag: 'v1.41.0',
                      publishedAt: DateTime(2026, 10, 15),
                      sizeBytes: 62 * 1024 * 1024,
                      notes: 'What changed',
                      downloadUrl: UpdateService.assetUrlFor('v1.41.0'),
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
    await tester.ensureVisible(find.text('Release page'));
    await tester.tap(find.text('Release page'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't open the link."), findsOneWidget);

    opens = true;
    await tester.tap(find.text('Release page'));
    await tester.pumpAndSettle();
    expect(find.text("Couldn't open the link."), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failed category save says so inside the dialog', (
    tester,
  ) async {
    final p = _FailingFinance();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<FinanceProvider>.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showCategoryDialog(context),
                child: const Text('new'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('new'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'Test pets');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    final error = find.text("Couldn't save the category. Try again.");
    expect(
      find.descendant(of: find.byType(AlertDialog), matching: error),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    expect(find.textContaining('disk full'), findsNothing);
    // Still open, and Create can be tapped again.
    expect(find.text('New category'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'))
          .onPressed,
      isNotNull,
    );
  });

  group('digest Undo', () {
    /// The digest on the 1st's week, opened straight from a button. The rows
    /// sit on the 1st at midnight: never in the future.
    Future<FinanceProvider> pumpDigest(WidgetTester tester) async {
      final now = DateTime.now();
      final first = DateTime(now.year, now.month, 1);
      weekClock = () => DateTime(now.year, now.month, 1, 10);
      final p = FinanceProvider();
      await p.load();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 2400,
        note: 'test groceries',
        date: first,
      );
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'transport',
        amount: 600,
        note: 'test fares',
        date: first,
      );
      final s = SettingsProvider();
      await s.load();
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider.value(value: s),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showWeeklyDigestSheet(
                    context,
                    week: weekClock(),
                    hits: const [],
                  ),
                  child: const Text('digest'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('digest'));
      await tester.pumpAndSettle();
      return p;
    }

    /// Opens the biggest payment from the digest and deletes it.
    Future<void> deleteBiggest(WidgetTester tester) async {
      // The category shows under Top categories and Biggest payments; the
      // payment is the lower one.
      await tester.tap(inSheet(find.text(categoryById('food').label)).last);
      await tester.pumpAndSettle();
      expect(find.text('Delete transaction'), findsOneWidget);
      await tester.ensureVisible(find.text('Delete transaction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete transaction'));
      await tester.pumpAndSettle();
    }

    testWidgets('the bar shows on the digest, survives a drag and undoes', (
      tester,
    ) async {
      final p = await pumpDigest(tester);
      await deleteBiggest(tester);

      expect(p.transactions, hasLength(1));
      expect(find.byType(BottomSheet), findsOneWidget, reason: 'digest open');
      expect(inSheet(find.text('Undo')), findsOneWidget);
      expect(
        inSheet(find.textContaining('Deleted ${categoryById('food').label}')),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing, reason: 'no toast under it');
      // The Undo button is a 48dp target.
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Undo')).height,
        greaterThanOrEqualTo(48),
      );

      // A short drag on the handle: the sheet moves and its builder runs
      // again, and the bar stays; let go and the sheet springs back.
      final top = tester.getTopLeft(find.byType(BottomSheet));
      final drag = await tester.startGesture(top + const Offset(200, 12));
      for (var i = 0; i < 4; i++) {
        await drag.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester.getTopLeft(find.byType(BottomSheet)).dy,
        greaterThan(top.dy),
      );
      expect(inSheet(find.text('Undo')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await drag.up();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(inSheet(find.text('Undo')), findsOneWidget);

      await tester.tap(inSheet(find.text('Undo')));
      await tester.pumpAndSettle();
      expect(p.transactions, hasLength(2));
      expect(inSheet(find.text('Undo')), findsNothing);
      expect(inSheet(find.text(fmtMoneyWhole(3000))), findsOneWidget);
    });

    testWidgets('the bar goes after 5 seconds', (tester) async {
      final p = await pumpDigest(tester);
      await deleteBiggest(tester);
      expect(inSheet(find.text('Undo')), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Undo')), findsNothing);
      expect(p.transactions, hasLength(1));
    });
  });

  test('a cycle\'s payments a year and yearly cost', () {
    expect(
      [for (final c in SubscriptionCycle.values) c.paymentsPerYear],
      [12, 4, 2, 1],
    );
    expect(SubscriptionCycle.quarterly.yearlyCost(2500), 10000);
    expect(SubscriptionCycle.yearly.yearlyCost(12000), 12000);
  });

  group('DeltaNote', () {
    Future<Icon> iconFor(WidgetTester tester, double delta) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeltaNote(text: 'change', delta: delta),
          ),
        ),
      );
      return tester.widget<Icon>(find.byType(Icon));
    }

    testWidgets('under a rupee is the = mark; more and less get arrows', (
      tester,
    ) async {
      expect((await iconFor(tester, 0.6)).icon, Icons.drag_handle);
      expect((await iconFor(tester, -0.9)).icon, Icons.drag_handle);
      expect((await iconFor(tester, 1)).icon, Icons.trending_up);
      expect((await iconFor(tester, -40)).icon, Icons.trending_down);
      expect((await iconFor(tester, 5)).size, 14);
    });
  });
}

/// Every new category fails to save.
class _FailingFinance extends FinanceProvider {
  @override
  Future<String> addCategory({
    required String label,
    required TxType type,
    required IconData icon,
    required Color color,
    bool isTransfer = false,
  }) async => throw StateError('disk full');
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
