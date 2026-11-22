import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/transactions_screen.dart';
import 'package:expense_tracker/services/import_health.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/utils/app_theme.dart';
import 'package:expense_tracker/utils/contrast.dart';
import 'package:expense_tracker/utils/figma_palette.dart';
import 'package:expense_tracker/widgets/import_health_banner.dart';
import 'package:expense_tracker/widgets/undo_snackbar.dart';

/// v2.3.1 review fixes on the screens: the Transactions pager builds only
/// the tab on screen, the import warning reads storage only when its record
/// can have changed, and accent text buttons read on their surfaces.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  Future<(FinanceProvider, SettingsProvider)> providers() async {
    final p = FinanceProvider();
    await p.load();
    final s = SettingsProvider();
    await s.load();
    return (p, s);
  }

  Widget app(FinanceProvider p, SettingsProvider s, Widget child) =>
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: p),
          ChangeNotifierProvider.value(value: s),
        ],
        child: MaterialApp(home: Scaffold(body: child)),
      );

  group('the Transactions pager', () {
    testWidgets('a data change filters only the tab on screen', (
      tester,
    ) async {
      final (p, s) = await providers();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 140,
        note: 'test tea',
        date: DateTime(2026, 7, 1),
      );
      await p.addTransaction(
        type: TxType.income,
        categoryId: 'salary',
        amount: 3100,
        note: 'test pay',
        date: DateTime(2026, 7, 2),
      );
      await tester.pumpWidget(app(p, s, const TransactionsScreen()));
      await tester.pumpAndSettle();

      transactionsPipelineRuns = 0;
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 260,
        note: 'test dinner',
        date: DateTime(2026, 7, 3),
      );
      await tester.pumpAndSettle();
      expect(find.text('test dinner'), findsOneWidget);
      // All, not All plus Income, Expenses and Transfers.
      expect(transactionsPipelineRuns, 1);

      // The Income tab still lists its rows once it shows.
      await tester.fling(find.text('test tea'), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(find.text('test pay'), findsOneWidget);
      expect(find.text('test tea'), findsNothing);
    });
  });

  group('the import warning', () {
    // An invented bank code; bankLabel shows an unknown code as it is.
    const bank = 'QWZBNK';
    final unreadable = find.text('2 $bank alerts in 14 days could not be read');

    String record() {
      final now = DateTime.now();
      return jsonEncode({
        bank: {
          'unread': [
            now.subtract(const Duration(days: 3)).millisecondsSinceEpoch,
            now.subtract(const Duration(days: 1)).millisecondsSinceEpoch,
          ],
          'samples': const [],
        },
      });
    }

    /// A SharedPreferences instance standing in for the headless import's
    /// isolate: its writes reach storage but not the cached copy the app's
    /// own instance reads from until it reloads.
    Future<SharedPreferences> otherIsolate() async {
      final other = await SharedPreferences.getInstance();
      // A fresh store: the app's providers now get their own instance.
      SharedPreferences.setMockInitialValues({});
      return other;
    }

    testWidgets('a ledger change leaves storage alone; a resume reads it', (
      tester,
    ) async {
      final other = await otherIsolate();
      final (p, s) = await providers();
      await tester.pumpWidget(
        app(p, s, const SingleChildScrollView(child: ImportHealthBanner())),
      );
      await tester.pumpAndSettle();
      expect(unreadable, findsNothing);

      await other.setString(kImportHealthKey, record());
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 180,
        note: 'test snack',
        date: DateTime(2026, 7, 4),
      );
      await tester.pumpAndSettle();
      expect(unreadable, findsNothing, reason: 'storage not read again');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(unreadable, findsOneWidget);
    });

    testWidgets('an import signal reads storage again', (tester) async {
      final other = await otherIsolate();
      final (p, s) = await providers();
      await tester.pumpWidget(
        app(p, s, const SingleChildScrollView(child: ImportHealthBanner())),
      );
      await tester.pumpAndSettle();
      await other.setString(kImportHealthKey, record());
      ImportHealth.changed();
      await tester.pumpAndSettle();
      expect(unreadable, findsOneWidget);
    });

    testWidgets('Delete all data takes the warning down at once', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({kImportHealthKey: record()});
      final (p, s) = await providers();
      await tester.pumpWidget(
        app(p, s, const SingleChildScrollView(child: ImportHealthBanner())),
      );
      await tester.pumpAndSettle();
      expect(unreadable, findsOneWidget);

      // Removes the record without an import signal: the ledger change
      // alone must clear the card.
      await p.clearAll();
      await tester.pumpAndSettle();
      expect(unreadable, findsNothing);
    });

    testWidgets('a quiet bank shows once an import moves the scan marker, '
        'and stays dismissed', (tester) async {
      final (p, s) = await providers();
      final now = DateTime.now();
      // Every 3 days over 33 days, the last one 15 days ago: quiet for 5
      // usual gaps.
      await p.addImported([
        for (var i = 0; i < 12; i++)
          ParsedTxn(
            type: TxType.expense,
            amount: 110.0 + i,
            merchant: 'TEST SHOP',
            date: DateTime(now.year, now.month, now.day - 15 - 3 * i, 10),
            ref: 'QWZ$i',
            categoryId: 'other_expense',
            sender: 'AX-$bank-S',
            rawBody: 'Rs.${110 + i} spent at TEST SHOP',
          ),
      ]);
      // Read SMS granted: the banner asks once a scan marker exists.
      const sms = MethodChannel('expense_tracker/sms');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        sms,
        (call) async => call.method == 'hasPermission' ? true : null,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(sms, null));
      await tester.pumpWidget(
        app(p, s, const SingleChildScrollView(child: ImportHealthBanner())),
      );
      await tester.pumpAndSettle();
      final quiet = find.textContaining('alerts since');
      expect(quiet, findsNothing, reason: 'no scan yet');

      // What an import does once it has read the inbox up to now.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kSmsLastScanKey, now.millisecondsSinceEpoch);
      ImportHealth.changed();
      await tester.pumpAndSettle();
      expect(quiet, findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(quiet, findsNothing);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 90,
        note: 'test juice',
        date: DateTime(2026, 7, 5),
      );
      ImportHealth.changed();
      await tester.pumpAndSettle();
      expect(quiet, findsNothing, reason: 'dismissed stays dismissed');
    });
  });

  group('accent text buttons', () {
    const accent = FigmaPalette.defaultAccent;
    final light = buildAppTheme(brightness: Brightness.light, accent: accent);
    final dark = buildAppTheme(brightness: Brightness.dark, accent: accent);

    Color textButton(ThemeData t) =>
        t.textButtonTheme.style!.foregroundColor!.resolve(const {})!;

    String hex(Color c) =>
        '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

    test('read at 4.5 to 1 on every light surface, the toast fill too', () {
      final button = textButton(light);
      final action = light.snackBarTheme.actionTextColor!;
      for (final surface in [
        Colors.white,
        FigmaPaletteLight.bg,
        light.extension<AppColors>()!.cardFill!,
        FigmaPaletteLight.surface2,
      ]) {
        expect(
          contrastRatio(button, surface),
          greaterThanOrEqualTo(4.5),
          reason: hex(surface),
        );
      }
      expect(light.snackBarTheme.backgroundColor, FigmaPaletteLight.surface2);
      expect(
        contrastRatio(action, light.snackBarTheme.backgroundColor!),
        greaterThanOrEqualTo(4.5),
      );
      // The default accent, deepened once for both.
      expect(hex(button), '#1E67BC');
      expect(action, button);
    });

    test('dark keeps the accent as it was', () {
      expect(textButton(dark), accent);
      expect(dark.snackBarTheme.actionTextColor, accent);
    });

    testWidgets("the toast's Undo uses the corrected colour", (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: light,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUndoSnackBar(
                  context,
                  'Test row deleted',
                  () {},
                  icon: Icons.delete_outline,
                ),
                child: const Text('Go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      final undo = DefaultTextStyle.of(tester.element(find.text('Undo')));
      expect(undo.style.color, light.snackBarTheme.actionTextColor);
      expect(
        contrastRatio(undo.style.color!, FigmaPaletteLight.surface2),
        greaterThanOrEqualTo(4.5),
      );
      final go = DefaultTextStyle.of(tester.element(find.text('Go')));
      expect(go.style.color, textButton(light));
    });
  });
}
