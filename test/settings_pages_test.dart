import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/settings_screen.dart';
import 'package:expense_tracker/services/drive_backup_service.dart';
import 'package:expense_tracker/utils/app_palettes.dart';
import 'package:expense_tracker/widgets/grouped_surface.dart';

/// The Settings root lists its groups, and each group opens its own page.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Bounded pumps: the Drive section on Backup and data keeps an
  /// indeterminate progress bar up while the sign-in state loads (never
  /// resolves under tests), so pumpAndSettle would time out, also while
  /// that page pops.
  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> pumpSettings(WidgetTester tester) async {
    final finance = FinanceProvider();
    await finance.load();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: finance),
          ChangeNotifierProvider(create: (_) => SettingsProvider()..load()),
          Provider<DriveBackupService>(create: (_) => DriveBackupService()),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await pumpThrough(tester);
  }

  testWidgets('root lists the groups and each opens its page', (tester) async {
    await pumpSettings(tester);

    // Group title to a heading near the top of its page. Widget tests run as
    // Android, so the SMS group is offered.
    const pages = {
      'Appearance': 'Dark theme',
      'SMS import': 'Automatic SMS import',
      'Backup and data': 'Cloud backup',
      'Notifications': 'Budget alerts',
      'Privacy': 'App lock',
      'About': 'Check for updates',
    };
    expect(find.text('Category order'), findsNothing, reason: 'moved');
    for (final title in pages.keys) {
      expect(find.text(title), findsOneWidget, reason: title);
    }

    for (final MapEntry(key: title, value: heading) in pages.entries) {
      await tester.tap(find.text(title));
      await pumpThrough(tester);
      expect(find.widgetWithText(AppBar, title), findsOneWidget);
      expect(find.text(heading), findsOneWidget, reason: title);

      await tester.pageBack();
      await pumpThrough(tester);
      expect(find.widgetWithText(AppBar, 'Settings'), findsOneWidget);
    }
  });

  testWidgets('root rows show the current values and follow changes', (
    tester,
  ) async {
    await pumpSettings(tester);
    final settings = tester
        .element(find.byType(SettingsScreen))
        .read<SettingsProvider>();

    // A new install: dark, the default theme's own accent, no automatic
    // import, no lock. Budget alerts count only with a cap or a custom
    // budget to watch, so three of the four alerts are on.
    expect(find.text('Dark · Default accent'), findsOneWidget);
    expect(find.text('Automatic import off'), findsOneWidget);
    expect(find.text('Lock off'), findsOneWidget);
    expect(find.text('3 of 4 on'), findsOneWidget);
    // The Cockpit card, then the rows of one grouped card.
    expect(find.byType(GroupedSurface), findsNWidgets(7));
    expect(find.text('Rules, categories, budgets, dashboard layout'), findsOne);

    await settings.setMode(ThemeMode.light);
    await settings.setPalette(AppPalette.ocean);
    await settings.setAutoImport(AutoImportFrequency.daily);
    await settings.setAppLock(true);
    await settings.setHideIncome(true);
    await settings.setMonthlyBudget(40000);
    await pumpThrough(tester);
    expect(find.text('Light · Ocean accent'), findsOneWidget);
    expect(find.text('Daily'), findsOneWidget);
    expect(find.text('Lock on · Income hidden'), findsOneWidget);
    expect(find.text('4 of 4 on'), findsOneWidget);

    // Every mode but Off shows its own label, On open included.
    await settings.setAutoImport(AutoImportFrequency.everyOpen);
    await settings.setBudgetAlerts(false);
    await settings.setUnusualAlerts(false);
    await settings.setWeeklyDigest(false);
    await settings.setUpcomingReminders(false);
    await pumpThrough(tester);
    expect(find.text('On open'), findsOneWidget);
    expect(find.text('All off'), findsOneWidget);
  });

  testWidgets('radio options carry a short line each, and the paragraphs '
      'that repeated a tip are gone', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('SMS import'));
    await pumpThrough(tester);
    expect(find.text('First open each day'), findsOneWidget);
    expect(find.textContaining('Scans new bank messages'), findsNothing);
    await tester.pageBack();
    await pumpThrough(tester);

    await tester.tap(find.text('Appearance'));
    await pumpThrough(tester);
    expect(find.textContaining('Used in dark mode'), findsNothing);
    expect(find.textContaining('Used for buttons, highlights'), findsNothing);
  });

  testWidgets('SMS import: On open, an SMS filters row, and RCS capture as a '
      'plain row', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('SMS import'));
    await pumpThrough(tester);

    expect(find.text('On open'), findsOneWidget);
    expect(find.text('Launch'), findsNothing);
    expect(find.text('SMS filters'), findsOneWidget);
    final finance = tester
        .element(find.byType(SettingsGroupPage))
        .read<FinanceProvider>();
    final n = finance.importRules.length;
    expect(
      find.text(
        'What gets ignored or flagged · $n ${n == 1 ? 'rule' : 'rules'}',
      ),
      findsOneWidget,
    );
    // No access under tests: Off, with the explanation in its tip.
    expect(find.text('Capture RCS alerts'), findsOneWidget);
    expect(find.text('Off · tap to allow notification access'), findsOneWidget);
    expect(find.text('Enable'), findsNothing);
    expect(find.bySemanticsLabel('About Capture RCS alerts'), findsOneWidget);
  });

  testWidgets('Move glow with tilt switch toggles the setting', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('Appearance'));
    await pumpThrough(tester);

    const label = 'Move glow with tilt';
    await tester.scrollUntilVisible(
      find.text(label),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    final toggle = find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
      matching: find.byType(Switch),
    );
    final settings = tester
        .element(find.byType(SettingsGroupPage))
        .read<SettingsProvider>();
    expect(settings.tiltGlow, isTrue, reason: 'on by default');
    expect(tester.widget<Switch>(toggle).value, isTrue);

    await tester.tap(toggle);
    await pumpThrough(tester);
    expect(settings.tiltGlow, isFalse);
    // The pushed page watches the provider itself, so the switch follows.
    expect(tester.widget<Switch>(toggle).value, isFalse);

    await tester.tap(toggle);
    await pumpThrough(tester);
    expect(settings.tiltGlow, isTrue);
  });
}
