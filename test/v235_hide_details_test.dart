import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/spend_budget.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/background_import.dart';
import 'package:expense_tracker/services/budget_monitor.dart';
import 'package:expense_tracker/services/import_checks.dart';
import 'package:expense_tracker/services/launch_actions.dart';
import 'package:expense_tracker/services/notification_ids.dart';
import 'package:expense_tracker/services/notification_service.dart';
import 'package:expense_tracker/services/price_rise_monitor.dart';
import 'package:expense_tracker/services/sms_import_service.dart';
import 'package:expense_tracker/services/unusual_spend_monitor.dart';
import 'package:expense_tracker/services/upcoming_monitor.dart';
import 'package:expense_tracker/widgets/notification_switches.dart';

/// One posted note, every text field it carries included.
typedef _Note = ({
  int id,
  String title,
  String body,
  String? payload,
  String? keepLabel,
  bool buttons,
});

/// The plugin, faked: records every note with all its text, and keeps
/// payment-to-check notes in the shade until cancelled.
class _Notes implements NotificationService {
  final notes = <_Note>[];
  final active = <int>[];
  final cancelled = <int>[];
  int? summary;

  @override
  Future<void> init() async {}

  @override
  Future<bool> get areEnabled async => true;

  @override
  Future<NotificationStatus> get status async => NotificationStatus.enabled;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async => notes.add((
    id: id,
    title: title,
    body: body,
    payload: payload,
    keepLabel: null,
    buttons: false,
  ));

  @override
  Future<String?> launchPayload() async => null;

  @override
  Future<void> scheduleRecap(DateTime when, String monthName) async {}

  @override
  Future<void> cancelRecap() async {}

  @override
  Future<void> scheduleWeeklyDigest(
    DateTime when,
    DateTime week,
    String weekLabel,
  ) async {}

  @override
  Future<void> cancelWeeklyDigest() async {}

  @override
  Future<void> showReview(int count) async {}

  @override
  Future<void> cancelReview() async {}

  @override
  Future<void> showImportCheck({
    required int id,
    required String title,
    required String body,
    required String payload,
    String? keepLabel,
    bool buttons = true,
  }) async {
    notes.add((
      id: id,
      title: title,
      body: body,
      payload: payload,
      keepLabel: keepLabel,
      buttons: buttons,
    ));
    if (!active.contains(id)) active.add(id);
  }

  @override
  Future<void> showImportCheckSummary(int count) async => summary = count;

  @override
  Future<List<int>> activeImportChecks() async => List.of(active);

  @override
  Future<void> cancelId(int id) async {
    cancelled.add(id);
    active.remove(id);
  }
}

/// Adds one guessed, unopened row, as an SMS import would.
class _GuessingImport extends SmsImportService {
  _GuessingImport(this.row);
  final Tx row;

  @override
  Future<int> drainNotifications(FinanceProvider finance) async => 0;

  @override
  Future<SmsImportResult?> maybeAutoRun(
    FinanceProvider finance,
    AutoImportFrequency frequency,
  ) async {
    await finance.importTransactions([row], replace: false);
    return null;
  }
}

const _hiddenBody = 'Open the app to see it';

/// [note] shows [kind]'s plain pair and none of [secrets] in any text it
/// carries. The payload is left out: it is checked against today's value.
void _expectHidden(_Note note, NoteKind kind, List<String> secrets) {
  expect(note.title, kind.hiddenTitle);
  expect(note.body, _hiddenBody);
  for (final text in [note.title, note.body, note.keepLabel ?? '']) {
    for (final s in secrets) {
      expect(text, isNot(contains(s)), reason: '"$s" must not show');
    }
  }
}

/// Hide details in notifications. Every name, digit and amount is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
    LaunchActions.instance.resetForTest();
  });

  tearDown(() {
    NotificationService.statusOverride = null;
    NotificationSwitches.resetRememberedStatus();
  });

  Future<SettingsProvider> settingsWith({required bool hide}) async {
    final s = SettingsProvider();
    await s.load();
    await s.setHideNotificationDetails(hide);
    return s;
  }

  test('every kind has its plain title and the one body line', () {
    expect(
      {for (final k in NoteKind.values) k: k.hiddenTitle},
      {
        NoteKind.cardBill: 'A card bill needs paying',
        NoteKind.payment: 'A payment is expected',
        NoteKind.reminder: 'A reminder is due',
        NoteKind.budget: 'A budget alert',
        NoteKind.unusual: 'Unusual spending',
        NoteKind.priceRise: 'A price went up',
        NoteKind.importCheck: 'A payment needs a check',
      },
    );
    const built = (title: 'Kestrel Card 4821 bill due', body: '₹7,340.00');
    expect(notificationText(NoteKind.cardBill, built, hide: false), built);
    expect(notificationText(NoteKind.cardBill, built, hide: true), (
      title: 'A card bill needs paying',
      body: _hiddenBody,
    ));
  });

  group('payment reminders', () {
    // Card bill due, a reminder due and a repeat expected, all on 30 Sep.
    final now = DateTime(2026, 9, 30, 10);

    Future<(FinanceProvider, String)> ledger() async {
      final finance = FinanceProvider();
      await finance.load();
      final card = await finance.addAccount(
        name: 'Kestrel Card 4821',
        type: AccountType.creditCard,
      );
      await finance.setManualBalance(card, 7340);
      await finance.setCardCycle(card, dueDay: 30);
      await finance.restoreReminder(
        const Reminder(
          id: 'rem_quillon',
          name: 'Quillon rent',
          dayOfMonth: 30,
          categoryId: 'bills',
          expectedAmount: 2150,
        ),
      );
      for (final d in [
        DateTime(2026, 7, 2),
        DateTime(2026, 8, 1),
        DateTime(2026, 8, 31),
      ]) {
        await finance.addTransaction(
          type: TxType.expense,
          categoryId: 'entertainment',
          amount: 873,
          note: 'Larkvane gym',
          date: d,
        );
      }
      return (finance, card);
    }

    test('off: each note names its item, as before', () async {
      final (finance, _) = await ledger();
      final notes = _Notes();
      await UpcomingMonitor(
        notifications: notes,
      ).check(finance, await settingsWith(hide: false), now: now);
      expect(notes.notes, hasLength(3));
      expect(notes.notes[0].title, 'Kestrel Card 4821 bill due today');
      expect(notes.notes[0].body, contains('7,340'));
      expect(notes.notes[1].title.toLowerCase(), contains('larkvane'));
      expect(notes.notes[2].title, 'Reminder: Quillon rent');
      expect(notes.notes[2].body, contains('2,150'));
    });

    test(
      'on: plain pairs, no detail, the same ids, payloads and markers',
      () async {
        final (finance, card) = await ledger();
        final notes = _Notes();
        final settings = await settingsWith(hide: true);
        final monitor = UpcomingMonitor(notifications: notes);
        await monitor.check(finance, settings, now: now);
        expect(notes.notes, hasLength(3));
        final secrets = [
          'Kestrel', '4821', '7,340', '7340', 'Larkvane', '873', //
          'Quillon', '2,150', '2150', '30 Sep', 'Sep', 'today',
        ];
        _expectHidden(notes.notes[0], NoteKind.cardBill, secrets);
        _expectHidden(notes.notes[1], NoteKind.payment, secrets);
        _expectHidden(notes.notes[2], NoteKind.reminder, secrets);
        expect(notes.notes[0].id, NotificationIds.cardBill(card));
        expect(notes.notes[2].id, NotificationIds.reminder('rem_quillon'));
        expect([
          for (final n in notes.notes) n.payload,
        ], List.filled(3, kUpcomingPayload));

        // The markers hold it as they hold a detailed one.
        final prefs = await SharedPreferences.getInstance();
        final due = DateTime(2026, 9, 30);
        expect(prefs.getBool(UpcomingMonitor.cardDueKey(card, due)), isTrue);
        await monitor.check(finance, settings, now: now);
        expect(notes.notes, hasLength(3), reason: 'announced once');

        // Paid: the hidden alert is withdrawn the same way.
        await finance.markCardBillPaid(card, due);
        await monitor.check(finance, settings, now: now);
        expect(notes.cancelled, [NotificationIds.cardBill(card)]);
        expect(prefs.getBool(UpcomingMonitor.cardDueKey(card, due)), isFalse);
      },
    );
  });

  group('budget alerts', () {
    final now = DateTime(2026, 9, 15, 10);

    Future<FinanceProvider> spent850() async {
      final finance = FinanceProvider();
      await finance.load();
      await finance.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 850,
        note: 'Brindle Market',
        date: now,
      );
      return finance;
    }

    test('the cap: plain pair on, amounts off', () async {
      for (final hide in [false, true]) {
        SharedPreferences.setMockInitialValues({});
        final finance = await spent850();
        final settings = await settingsWith(hide: hide);
        await settings.setMonthlyBudget(1000);
        final notes = _Notes();
        await BudgetMonitor(
          notifications: notes,
          clock: () => now,
        ).check(finance, settings);
        final note = notes.notes.single;
        expect(note.payload, kBudgetPayload);
        expect(note.id, NotificationIds.cap(9));
        if (hide) {
          _expectHidden(note, NoteKind.budget, ['850', '1,000', '80']);
        } else {
          expect('${note.title} ${note.body}', contains('850'));
        }
      }
    });

    test('a named budget: no name, no amounts', () async {
      final finance = await spent850();
      final id = await finance.addBudget(
        name: 'Pinecrest fund',
        limit: 1000,
        mode: BudgetMode.exclude,
        categoryIds: const {},
      );
      final notes = _Notes();
      await BudgetMonitor(
        notifications: notes,
        clock: () => now,
      ).check(finance, await settingsWith(hide: true));
      final note = notes.notes.single;
      _expectHidden(note, NoteKind.budget, ['Pinecrest', '850', '1,000']);
      expect(note.id, NotificationIds.customBudget(id));
      expect(note.payload, kBudgetsPayload);
    });
  });

  test('unusual spending: no category, amount or month', () async {
    final now = DateTime(2025, 12, 20, 10);
    final finance = FinanceProvider();
    await finance.load();
    for (var m = 7; m <= 11; m++) {
      await finance.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 4000,
        note: 'Brindle Market',
        date: DateTime(2025, m, 5),
      );
    }
    await finance.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 6300,
      note: 'Brindle Market',
      date: DateTime(2025, 12, 3),
    );
    final notes = _Notes();
    await UnusualSpendMonitor(
      notifications: notes,
      clock: () => now,
    ).check(finance, await settingsWith(hide: true));
    final note = notes.notes.single;
    _expectHidden(note, NoteKind.unusual, [
      'Food', '6,300', '4,000', 'December', //
    ]);
    expect(note.id, UnusualSpendMonitor.notificationId('food'));
    expect(note.payload, unusualPayload('food', DateTime(2025, 12)));
  });

  test('price rise: no name or prices', () async {
    // No clock seam in the monitor: one read, payments a month apart.
    final now = DateTime.now();
    final finance = FinanceProvider();
    await finance.load();
    await finance.importTransactions([
      for (final (i, amount) in [499.0, 499.0, 649.0].indexed)
        Tx(
          id: 'glimmer_$i',
          type: TxType.expense,
          categoryId: 'bills',
          amount: amount,
          note: 'Glimmerbox',
          date: DateTime(now.year, now.month, now.day - 10 - 30 * (2 - i), 12),
        ),
    ], replace: true);
    final notes = _Notes();
    await PriceRiseMonitor(
      notifications: notes,
    ).check(finance, await settingsWith(hide: true));
    final note = notes.notes.single;
    _expectHidden(note, NoteKind.priceRise, ['Glimmerbox', '649', '499']);
    expect(note.id, NotificationIds.priceRise('expense|glimmerbox'));
    expect(note.payload, kSubscriptionsPayload);
  });

  group('payments to check', () {
    final now = DateTime(2026, 9, 15, 10);

    Tx row(String id, {String category = 'food', bool guessed = true}) => Tx(
      id: id,
      type: TxType.expense,
      categoryId: category,
      amount: 1265,
      note: 'Brindle Market',
      date: now,
      source: TxSource.sms,
      sender: 'VM-QXBANK',
      categoryGuessed: guessed,
      unseen: true,
    );

    Future<FinanceProvider> ledger(List<Tx> rows) async {
      final p = FinanceProvider();
      await p.load();
      await p.importTransactions(rows, replace: true);
      return p;
    }

    test('off: details and Keep and Change, as before', () async {
      final p = await ledger([row('guess')]);
      final notes = _Notes();
      await ImportChecks.post(
        p,
        const {},
        hideDetails: false,
        notifications: notes,
      );
      final note = notes.notes.single;
      expect(note.title, contains('Brindle Market'));
      expect(note.keepLabel, 'Keep ${categoryById('food').label}');
      expect(note.buttons, isTrue);
    });

    test('on: plain pair, no buttons, the same payload and summary', () async {
      final p = await ledger([
        row('guess'),
        row('sort', category: 'to_sort_expense', guessed: false),
      ]);
      final notes = _Notes();
      await ImportChecks.post(
        p,
        const {},
        hideDetails: true,
        notifications: notes,
      );
      expect(notes.notes, hasLength(2));
      final food = categoryById('food').label;
      for (final note in notes.notes) {
        _expectHidden(note, NoteKind.importCheck, [
          'Brindle', '1,265', '1265', food, 'To sort', 'Guessed', //
        ]);
        expect(note.keepLabel, isNull);
        expect(note.buttons, isFalse);
      }
      expect(
        {for (final n in notes.notes) n.payload},
        {
          importCheckPayload('guess', 'food'),
          importCheckPayload('sort', 'to_sort_expense'),
        },
      );
      // The summary the Keep handler re-posts carries a count and nothing
      // else, so it reads the same either way.
      expect(notes.summary, 2);

      // Settled rows withdraw hidden notes as they do detailed ones.
      await p.confirmGuesses([(txId: 'guess', categoryId: 'food')]);
      await ImportChecks.sync(p, enabled: true, notifications: notes);
      expect(notes.cancelled, contains(NotificationIds.importCheck('guess')));
    });

    test('a background run reads the switch from a freshly loaded '
        'SettingsProvider, as the headless engine does', () async {
      await (await settingsWith(
        hide: true,
      )).setAutoImport(AutoImportFrequency.daily);
      // backgroundImportMain loads its own SettingsProvider from prefs.
      final headless = SettingsProvider();
      await headless.load();
      expect(headless.hideNotificationDetails, isTrue);
      final finance = FinanceProvider();
      await finance.load();
      final notes = _Notes();
      ReviewNotifier.resetForTest();
      await runBackgroundImport(
        finance,
        headless,
        BackgroundTrigger.periodic,
        import: _GuessingImport(row('fresh')),
        checkAlerts: false,
        notifications: notes,
        now: now,
      );
      ReviewNotifier.resetForTest();
      final note = notes.notes.single;
      _expectHidden(note, NoteKind.importCheck, ['Brindle', '1,265']);
      expect(note.buttons, isFalse);
      expect(note.payload, importCheckPayload('fresh', 'food'));
    });
  });

  test('a background alert check reads the switch the same way', () async {
    // One clock read: the monitors behind runAlertChecks use the clock.
    final today = DateTime.now();
    await settingsWith(hide: true);
    final headless = SettingsProvider();
    await headless.load();
    final finance = FinanceProvider();
    await finance.load();
    final card = await finance.addAccount(
      name: 'Kestrel Card 4821',
      type: AccountType.creditCard,
    );
    await finance.setManualBalance(card, 7340);
    await finance.setCardCycle(card, dueDay: today.day);
    final notes = _Notes();
    await runAlertChecks(finance, headless, notifications: notes);
    final note = notes.notes.single;
    _expectHidden(note, NoteKind.cardBill, ['Kestrel', '4821', '7,340']);
    expect(note.payload, kUpcomingPayload);
  });

  group('the switch', () {
    Future<SettingsProvider> pumpSwitches(
      WidgetTester tester, {
      double width = 412,
      double textScale = 1,
    }) async {
      NotificationService.statusOverride = () async =>
          NotificationStatus.enabled;
      tester.view.physicalSize = Size(width, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final finance = FinanceProvider();
      await finance.load();
      final settings = SettingsProvider();
      await settings.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: finance),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: NotificationSwitches(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return settings;
    }

    final title = find.text('Hide details in notifications');

    testWidgets('is the first row, off by default, and toggles and persists', (
      tester,
    ) async {
      final settings = await pumpSwitches(tester);
      expect(title, findsOneWidget);
      expect(
        find.text(
          'No amounts, names or account digits. Open the app to see them.',
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(title).dy,
        lessThan(tester.getTopLeft(find.text('Budget alerts')).dy),
      );
      final row = find.ancestor(
        of: title,
        matching: find.byType(SwitchListTile),
      );
      expect(tester.widget<SwitchListTile>(row).value, isFalse);

      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(settings.hideNotificationDetails, isTrue);
      expect(tester.widget<SwitchListTile>(row).value, isTrue);

      final again = SettingsProvider();
      await again.load();
      expect(again.hideNotificationDetails, isTrue);

      await tester.tap(title);
      await tester.pumpAndSettle();
      expect(settings.hideNotificationDetails, isFalse);
    });

    testWidgets('fits a 360 wide screen at 1.3 times text', (tester) async {
      await pumpSwitches(tester, width: 360, textScale: 1.3);
      expect(title, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  test('travels in a backup like its neighbours', () async {
    final s = await settingsWith(hide: true);
    final backup = s.toBackupMap();
    expect(backup['hideNotificationDetails'], isTrue);

    SharedPreferences.setMockInitialValues({});
    final fresh = SettingsProvider();
    await fresh.load();
    expect(fresh.hideNotificationDetails, isFalse, reason: 'off by default');
    await fresh.applyBackupMap(backup);
    expect(fresh.hideNotificationDetails, isTrue);
    final reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.hideNotificationDetails, isTrue, reason: 'persisted');

    // A backup from before the switch keeps the current value.
    await fresh.applyBackupMap({'priceRiseAlerts': true});
    expect(fresh.hideNotificationDetails, isTrue);
  });
}
