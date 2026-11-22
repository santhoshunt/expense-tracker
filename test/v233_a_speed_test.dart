import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The stores below extend the plugin's in-memory store, which only the
// platform interface exports. shared_preferences brings it in.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/card_rewards.dart';
import 'package:expense_tracker/models/reminder.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/services/background_import.dart';
import 'package:expense_tracker/services/card_rewards.dart'
    show CardSpendWindow;
import 'package:expense_tracker/services/category_guess.dart';
import 'package:expense_tracker/services/recurring_detector.dart';
import 'package:expense_tracker/services/refund_matching.dart';
import 'package:expense_tracker/services/sms_import_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/spend_comparison.dart';
import 'package:expense_tracker/services/upcoming_monitor.dart';
import 'package:expense_tracker/services/weekly_digest.dart';

import 'background_import_test.dart' show CountingImport;
import 'upcoming_monitor_test.dart' show FakeNotifications;

/// The in-memory store, counting writes of the ledger.
class _CountingStore extends InMemorySharedPreferencesStore {
  _CountingStore() : super.empty();

  int txWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) {
    if (key == 'flutter.transactions_v1') txWrites++;
    return super.setValue(valueType, key, value);
  }
}

/// The in-memory store, except that the first write of the ledger reports
/// false, as Android's commit() does when it cannot write.
class _FailOnceStore extends InMemorySharedPreferencesStore {
  _FailOnceStore() : super.empty();

  bool _failed = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!_failed && key == 'flutter.transactions_v1') {
      _failed = true;
      return false;
    }
    return super.setValue(valueType, key, value);
  }
}

/// The in-memory store, except that writing the home-screen widgets'
/// snapshot throws while [failing], so a widget sync fails.
class _WidgetFailStore extends InMemorySharedPreferencesStore {
  _WidgetFailStore() : super.empty();

  bool failing = true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (failing && key == 'flutter.home_widget_data_v1') {
      throw StateError('made-up widget failure');
    }
    return super.setValue(valueType, key, value);
  }
}

/// The notification stand-in, except that showing one throws while
/// [failing], as the plugin can.
class _ThrowingNotifications extends FakeNotifications {
  bool failing = true;

  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (failing) throw StateError('made-up plugin failure');
    await super.show(id: id, title: title, body: body, payload: payload);
  }
}

/// An SMS run that finds nothing: a one-time password or a promotion.
class _QuietImport extends SmsImportService {
  @override
  Future<int> drainNotifications(FinanceProvider finance) async => 0;

  @override
  Future<SmsImportResult?> maybeAutoRun(
    FinanceProvider finance,
    AutoImportFrequency frequency,
  ) async => null;
}

/// Load steps that would rewrite a seeded ledger, marked done.
const Map<String, Object> _doneFlags = {
  'builtin_rules_seeded_v1': true,
  'import_rules_seeded_v1': true,
  'import_rules_pruned_v1': true,
  'import_rules_seeded_v2': true,
  'import_rules_seeded_v3': true,
  'category_groups_seeded_v1': true,
  'accounts_migrated_v1': true,
  'accounts_migrated_v2': true,
  'accounts_migrated_v3': true,
  'accounts_migrated_v4': true,
  'accounts_migrated_v5': true,
  'sms_body_migrated_v1': true,
  'reminders_early_rescan_v1': true,
  'imports_count_first_v1': true,
  'debit_cards_detected_v1': true,
  'refunds_linked_v1': true,
};

Map<String, Object> _seed(List<Tx> rows, List<Account> accounts) => {
  ..._doneFlags,
  'transactions_v1': jsonEncode([for (final t in rows) t.toJson()]),
  'accounts_v1': jsonEncode([for (final a in accounts) a.toJson()]),
};

Future<FinanceProvider> _load(Map<String, Object> seed) async {
  SharedPreferences.setMockInitialValues(seed);
  final p = FinanceProvider();
  await p.load();
  return p;
}

Tx _sms(
  String id,
  String body, {
  required DateTime date,
  TxType type = TxType.expense,
  String categoryId = 'food',
  double amount = 100,
  String? acctKey,
  bool pending = false,
}) => Tx(
  id: id,
  type: type,
  categoryId: categoryId,
  amount: amount,
  note: '',
  smsBody: body,
  date: date,
  source: TxSource.sms,
  sender: 'AD-TESTBK',
  externalRef: 'REF-$id',
  acctKey: acctKey,
  pending: pending,
);

String _dmy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}'
    '-${(d.year % 100).toString().padLeft(2, '0')}';

/// Every row as the ledger holds it, with the parts that are made fresh on
/// each run (ids, pair ids, by-hand account keys) replaced by what they
/// stand for, in a stable order.
List<String> _rowsOf(FinanceProvider p) {
  final rows = [
    for (final t in [...p.transactions, ...p.pendingTransactions])
      jsonEncode({
        ...t.toJson()
          ..remove('id')
          ..remove('pairId')
          ..remove('acctKey'),
        'paired': t.pairId != null,
        'account': p.accountForKey(t.acctKey)?.id,
      }),
  ];
  return rows..sort();
}

List<String> _accountsOf(FinanceProvider p) => [
  for (final a in p.accounts) jsonEncode(a.toJson()..remove('keys')),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  // Item 1: the merchant an alert names is read once per row.
  group('merchant per row', () {
    final day = DateTime(2026, 7, 2, 9);
    const alerts = [
      'Rs.317.50 spent using Testa card XX4401 at LANTERN NOODLES. ',
      'Rs.1,204.75 debited from a/c XX4402 on 03-07-26 at QUILLMART STORE. '
          'Avl Bal Rs.3,815.20',
      'Dear UPI user A/C X4403 debited by Rs.462.00 on date 04Jul26 trf to '
          'zenfresh.foods@oktest Refno 900001',
      'INR 911.00 debited from your a/c and credited to BRIMDOVA LABS',
      'Rs.87.00 debited from a/c XX4402 on 04-07-26 17:35 at TOLA RECHARGE.',
      'Rs.13.00 debited from a/c XX4402 on 04-07-26 11:15:00 pm.',
    ];
    List<Tx> rows() => [
      for (final (i, body) in alerts.indexed) _sms('m$i', body, date: day),
    ];

    test('the parser runs once per row and gives what it gave before', () {
      final list = rows();
      final start = alertMerchantParses;
      final first = [for (final t in list) alertMerchantOf(t)];
      expect(first, [for (final t in list) SmsTxnParser.merchantOf(t.smsText)]);
      expect(first, contains('LANTERN NOODLES'));
      expect(alertMerchantParses - start, list.length);
      expect([for (final t in list) alertMerchantOf(t)], first);
      expect(alertMerchantParses - start, list.length);
      // An edit makes a new row, which is read afresh.
      final edited = list[1].copyWith(note: 'a note');
      expect(alertMerchantOf(edited), first[1]);
      expect(alertMerchantParses - start, list.length + 1);
    });

    test('rows with no alert to read never reach the parser', () {
      final start = alertMerchantParses;
      final manual = Tx(
        id: 'h1',
        type: TxType.expense,
        categoryId: 'food',
        amount: 50,
        note: 'tea at the corner',
        date: day,
      );
      final restored = Tx(
        id: 'h2',
        type: TxType.expense,
        categoryId: 'food',
        amount: 50,
        note: '',
        date: day,
        source: TxSource.sms,
        smsMerchant: 'PELLRONK CAFE',
      );
      expect(alertMerchantOf(manual), '');
      expect(alertMerchantOf(restored), 'PELLRONK CAFE');
      expect(alertMerchantParses, start);
      // A row from before smsBody existed keeps its alert in the note.
      final legacy = Tx(
        id: 'h3',
        type: TxType.expense,
        categoryId: 'food',
        amount: 50,
        note: alerts.first,
        date: day,
        source: TxSource.sms,
      );
      expect(alertMerchantOf(legacy), 'LANTERN NOODLES');
    });

    test('the guesser and recurring detection read through the kept answer',
        () {
      final list = [
        for (var m = 0; m < 6; m++)
          _sms(
            'r$m',
            'Rs.199.00 debited from a/c XX1234 on 05-0${m + 1}-26 towards '
                'PLANWAVE TV. Ref 77$m',
            date: DateTime(2026, m + 1, 5, 10),
            categoryId: 'bills',
          ),
        ...rows(),
      ];
      CategoryGuesser.from(list);
      final start = alertMerchantParses;
      CategoryGuesser.from(list);
      final hits = detectRecurringPatterns(list, now: DateTime(2026, 6, 20));
      for (final t in list) {
        recurringKeyOf(t);
        merchantDisplayLabel(t);
        CategoryGuesser.wordsOf(t);
      }
      expect(alertMerchantParses, start);
      expect(hits.single.key, 'expense|planwave tv');
      expect(hits.single.label, 'Planwave Tv');
      // The same patterns as a first run over fresh copies of the rows.
      final again = detectRecurringPatterns(
        [for (final t in list) t.copyWith()],
        now: DateTime(2026, 6, 20),
      );
      expect(again.single.key, hits.single.key);
      expect(again.single.nextDue, hits.single.nextDue);
      expect(again.single.expectedAmount, hits.single.expectedAmount);
    });

    test('the transfer and spam guards still read the row each time', () {
      final transfer = _sms(
        't1',
        'Rs.5,000.00 debited from a/c XX1234 at FENTWUNA SAVINGS.',
        date: day,
        categoryId: kTransferOutCategoryId,
      );
      // The guard-free identity first, so it is kept before the guards ask.
      expect(rewardMerchantOf(transfer), 'fentwuna savings');
      expect(merchantIdentityOf(transfer), isNull);
      expect(recurringKeyOf(transfer), isNull);
      expect(subscriptionKeyOf(transfer), 'transfer|fentwuna savings');
      final food = transfer.copyWith(categoryId: 'food');
      expect(recurringKeyOf(food), 'expense|fentwuna savings');
    });
  });

  // Item 2: the upcoming monitor detects once per change and day.
  group('upcoming monitor', () {
    List<Tx> pattern() => [
      for (final m in [6, 7, 8, 9])
        _sms(
          'p$m',
          'Rs.199.00 debited from a/c XX1234 on 05-0$m-26 towards '
              'PLANWAVE TV. Ref 77$m',
          date: DateTime(2026, m, 5, 10),
          categoryId: 'bills',
          amount: 199,
        ),
    ];

    test('runs detection once per change and day, and still alerts the day '
        'a payment comes due', () async {
      final p = await _load(_seed(pattern(), const []));
      final settings = SettingsProvider();
      await settings.load();
      final notes = FakeNotifications();
      final m = UpcomingMonitor(notifications: notes);
      // Due on 6 October, five days ahead: no alert yet.
      await m.check(p, settings, now: DateTime(2026, 10, 1, 9));
      await m.check(p, settings, now: DateTime(2026, 10, 1, 11));
      expect(m.detections, 1);
      expect(notes.shown, isEmpty);
      // The same data on a later day: two days ahead now, so it alerts.
      await m.check(p, settings, now: DateTime(2026, 10, 4, 9));
      expect(m.detections, 2);
      expect(notes.shown.single.$2, 'Upcoming payment: Planwave Tv');
      // A change runs it again; the alert is not repeated.
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 40,
        note: 'tea',
        date: DateTime(2026, 10, 3, 8),
      );
      await m.check(p, settings, now: DateTime(2026, 10, 4, 10));
      expect(m.detections, 3);
      expect(notes.shown, hasLength(1));
    });

    test('a row dated later today joins once the clock passes it', () async {
      final p = await _load(
        _seed([
          ...pattern(),
          _sms(
            'later',
            'Rs.50.00 debited from a/c XX1234 at TOLA KIOSK.',
            date: DateTime(2026, 10, 1, 18),
          ),
        ], const []),
      );
      final settings = SettingsProvider();
      await settings.load();
      final m = UpcomingMonitor(notifications: FakeNotifications());
      await m.check(p, settings, now: DateTime(2026, 10, 1, 9));
      await m.check(p, settings, now: DateTime(2026, 10, 1, 12));
      expect(m.detections, 1);
      await m.check(p, settings, now: DateTime(2026, 10, 1, 19));
      expect(m.detections, 2);
      // Back before it: the row is ahead again.
      await m.check(p, settings, now: DateTime(2026, 10, 1, 10));
      expect(m.detections, 3);
    });
  });

  // Item 3: one action, one notification and one ledger write.
  group('one change per action', () {
    const bankKey = 'TESTBK:1111';
    final bank = Account(
      id: 'acct_bank',
      name: 'Test Bank',
      type: AccountType.bank,
      keys: {bankKey},
    );
    final card = Account(
      id: 'acct_card',
      name: 'Test Card',
      type: AccountType.creditCard,
      keys: {'TESTBK:2222'},
      statementDay: 10,
      dueDay: 28,
      creditLimit: 50000,
    );
    final cash = Account(
      id: 'acct_cash',
      name: 'Cash',
      type: AccountType.cash,
      keys: {},
      cashDefault: true,
    );

    /// A bank with history, a card bill's bank leg from yesterday and an
    /// ATM withdrawal, all dated from one clock reading.
    Map<String, Object> seed(DateTime now) => _seed([
      for (var i = 1; i <= 5; i++)
        _sms(
          'old$i',
          'Rs.${i * 100}.00 debited from a/c XX1111 at KESHBRIM MART.',
          date: now.subtract(Duration(days: 20 + i)),
          amount: i * 100.0,
          acctKey: bankKey,
        ),
      _sms(
        'bankleg',
        'Rs.2,500.00 debited from a/c XX1111 towards card dues.',
        date: now.subtract(const Duration(days: 1, hours: 1)),
        amount: 2500,
        categoryId: 'other_expense',
        acctKey: bankKey,
      ),
      _sms(
        'atm1',
        'Rs.2,000.00 withdrawn at ATM HILL GATE from a/c XX1111 on '
            '${_dmy(now)}.',
        date: now.subtract(const Duration(days: 3)),
        amount: 2000,
        categoryId: 'other_expense',
        acctKey: bankKey,
      ),
    ], [bank, card, cash]);

    /// Runs [action] on a provider loaded from [seedValues], counting what
    /// listeners hear and how often the ledger is written; checks the
    /// ledger is saved, as the provider holds it, when the action returns.
    Future<({FinanceProvider p, int notes, int writes})> counted(
      Map<String, Object> seedValues,
      Future<void> Function(FinanceProvider p) action, {
      Future<void> Function(FinanceProvider p)? before,
    }) async {
      final p = await _load(seedValues);
      if (before != null) await before(p);
      final store = _CountingStore();
      SharedPreferencesStorePlatform.instance = store;
      var notes = 0;
      p.addListener(() => notes++);
      await action(p);
      final stored = (await store.getAll())['flutter.transactions_v1'];
      final saved = jsonDecode(stored! as String) as List;
      expect(saved, hasLength(p.transactionCount));
      return (p: p, notes: notes, writes: store.txWrites);
    }

    test('recordCardPayment: once, ending as its steps one by one did',
        () async {
      final now = DateTime.now();
      final paidOn = now.subtract(const Duration(days: 1));
      final due = DateTime(now.year, now.month, 28);
      CardPaymentResult? result;
      final a = await counted(seed(now), (p) async {
        result = await p.recordCardPayment(
          accountId: 'acct_card',
          amount: 2500,
          paidOn: paidOn,
          due: due,
        );
      });
      // Before: four notifications and three ledger writes.
      expect(a.notes, 1);
      expect(a.writes, 1);
      expect(result!.pairId, isNotNull);
      expect(result!.bankLegBefore!.id, 'bankleg');

      // The same steps as separate calls, as the action made them before.
      final b = await _load(seed(now));
      final txId = await b.addTransaction(
        type: TxType.income,
        categoryId: kCardPaymentCategoryId,
        amount: 2500,
        note: 'Card bill payment',
        date: paidOn,
      );
      await b.assignAccount(txId, 'acct_card');
      await b.markCardBillPaid('acct_card', due);
      await b.pairTransactions('bankleg', txId);
      expect(_rowsOf(a.p), _rowsOf(b));
      expect(_accountsOf(a.p), _accountsOf(b));
    });

    test('moveToCash: once, ending as its steps one by one did', () async {
      final now = DateTime.now();
      CashMove? move;
      final a = await counted(seed(now), (p) async {
        move = await p.moveToCash('atm1');
      });
      // Before: three notifications and three ledger writes.
      expect(a.notes, 1);
      expect(a.writes, 1);
      expect(move!.cashAccountId, 'acct_cash');

      final b = await _load(seed(now));
      final before = b.transactions.firstWhere((t) => t.id == 'atm1');
      final txId = await b.addTransaction(
        type: TxType.income,
        categoryId: kTransferInCategoryId,
        amount: before.amount,
        note: 'ATM withdrawal',
        date: before.date,
      );
      await b.assignAccount(txId, 'acct_cash');
      await b.pairTransactions('atm1', txId);
      expect(_rowsOf(a.p), _rowsOf(b));
      expect(_accountsOf(a.p), _accountsOf(b));
    });

    test('addImported with ATM moves on: once for the import and its moves',
        () async {
      final now = DateTime.now();
      ParsedTxn atm(int k, double amount) => ParsedTxn(
        type: TxType.expense,
        amount: amount,
        merchant: '',
        date: now.subtract(Duration(minutes: 40 - k)),
        ref: 'NEWATM$k',
        categoryId: 'other_expense',
        sender: 'AD-TESTBK',
        rawBody:
            'Rs.${amount.toStringAsFixed(2)} withdrawn at ATM HILL GATE '
            'from a/c XX1111 on ${_dmy(now)}.',
        acctKey: bankKey,
      );
      final batch = [
        atm(1, 1500),
        ParsedTxn(
          type: TxType.expense,
          amount: 333,
          merchant: '',
          date: now.subtract(const Duration(minutes: 20)),
          ref: 'NEWBUY1',
          categoryId: 'food',
          sender: 'AD-TESTBK',
          rawBody: 'Rs.333.00 debited from a/c XX1111 at KESHBRIM MART.',
          acctKey: bankKey,
        ),
        atm(2, 3500),
      ];
      late (int, int, int) result;
      final a = await counted(
        seed(now),
        (p) async => result = await p.addImported(batch),
        before: (p) => p.setAtmAutoMove(true),
      );
      // Before: the import's own, then three for each of the two moves.
      expect(a.notes, 1);
      expect(a.writes, 1);
      expect(a.p.takeAtmMoves(), hasLength(2));

      // The import without moves, then each move on its own.
      final b = await _load(seed(now));
      final (added, spam, countedB) = await b.addImported(batch);
      var moved = 0;
      for (final t in [...b.pendingTransactions].reversed) {
        if (!t.externalRef!.startsWith('NEWATM')) continue;
        if (await b.moveToCash(t.id) != null) moved++;
      }
      expect(moved, 2);
      expect(result, (added, spam, countedB + moved));
      expect(_rowsOf(a.p), _rowsOf(b));
      expect(_accountsOf(a.p), _accountsOf(b));
    });

    test('nested batches tell listeners and save once, at the outer end; '
        'figures read inside are fresh', () async {
      final now = DateTime.now();
      final r = await counted(seed(now), (p) async {
        var inside = -1;
        await p.batchForTest(() async {
          await p.addTransaction(
            type: TxType.expense,
            categoryId: 'food',
            amount: 10,
            note: 'one',
            date: now.subtract(const Duration(minutes: 5)),
          );
          await p.batchForTest(() async {
            await p.addTransaction(
              type: TxType.expense,
              categoryId: 'food',
              amount: 20,
              note: 'two',
              date: now.subtract(const Duration(minutes: 4)),
            );
          });
          inside = p.transactions.length;
        });
        expect(inside, 9);
      });
      expect(r.notes, 1);
      expect(r.writes, 1);
    });

    test('an action that throws still ends its batch', () async {
      final now = DateTime.now();
      final p = await _load(seed(now));
      final store = _CountingStore();
      SharedPreferencesStorePlatform.instance = store;
      var notes = 0;
      p.addListener(() => notes++);
      await expectLater(
        p.batchForTest(() async {
          await p.addTransaction(
            type: TxType.expense,
            categoryId: 'food',
            amount: 10,
            note: 'kept',
            date: now.subtract(const Duration(minutes: 5)),
          );
          throw StateError('made-up failure');
        }),
        throwsStateError,
      );
      expect(notes, 1);
      expect(store.txWrites, 1);
      // Closed: the next change tells and saves at once.
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 20,
        note: 'after',
        date: now.subtract(const Duration(minutes: 4)),
      );
      expect(notes, 2);
      expect(store.txWrites, 2);
    });

    test('a change made outside the action, while it waits, notifies and '
        'saves at once', () async {
      final now = DateTime.now();
      final p = await _load(seed(now));
      final store = _CountingStore();
      SharedPreferencesStorePlatform.instance = store;
      var notes = 0;
      p.addListener(() => notes++);
      final gate = Completer<void>();
      final action = p.batchForTest(() async {
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 10,
          note: 'inside one',
          date: now.subtract(const Duration(minutes: 5)),
        );
        await gate.future;
        await p.addTransaction(
          type: TxType.expense,
          categoryId: 'food',
          amount: 20,
          note: 'inside two',
          date: now.subtract(const Duration(minutes: 4)),
        );
      });
      await pumpEventQueue();
      expect(notes, 0);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 30,
        note: 'outside',
        date: now.subtract(const Duration(minutes: 3)),
      );
      expect(notes, 1);
      expect(store.txWrites, 1);
      gate.complete();
      await action;
      expect(notes, 2);
      expect(store.txWrites, 2);
      expect(p.transactions.where((t) => t.note.startsWith('inside')), hasLength(2));
    });

    test('a save that fails at the end shows, and the next save clears it',
        () async {
      final now = DateTime.now();
      final p = await _load(seed(now));
      SharedPreferencesStorePlatform.instance = _FailOnceStore();
      await p.recordCardPayment(
        accountId: 'acct_card',
        amount: 2500,
        paidOn: now.subtract(const Duration(days: 1)),
        due: DateTime(now.year, now.month, 28),
      );
      expect(p.persistFailed, isTrue);
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 20,
        note: 'later',
        date: now.subtract(const Duration(minutes: 5)),
      );
      expect(p.persistFailed, isFalse);
    });
  });

  // Item 4: refund candidates come from the window only.
  group('refund window', () {
    const bankKey = 'TESTBK:1111';
    final bank = Account(
      id: 'acct_bank',
      name: 'Test Bank',
      type: AccountType.bank,
      keys: {bankKey},
    );

    List<(String, String)> asPairs(Iterable<RefundSuggestion> s) => [
      for (final x in s) (x.refund.id, x.purchase.id),
    ];

    /// What [FinanceProvider.refundSuggestions] gave before the window: the
    /// candidates over every confirmed row.
    List<(String, String)> overAllRows(
      FinanceProvider p,
      Iterable<Tx> refunds,
      Set<String> dismissed,
    ) {
      final out = <(String, String)>[];
      for (final r in refunds) {
        if (r.type != TxType.income || r.refundOf != null) continue;
        for (final c in refundCandidatesFor(
          r,
          p.transactions,
          remainingOf: p.refundableLeftOf,
          counts: p.countsInTotals,
        )) {
          final s = RefundSuggestion(refund: r, purchase: c.purchase);
          if (dismissed.contains(s.key)) continue;
          out.add((r.id, c.purchase.id));
          break;
        }
      }
      return out;
    }

    test('suggestions match a pass over every row, with refunds at the '
        "window's edges", () async {
      final rand = Random(11);
      const names = [
        'ZANDOVA FOODS',
        'QUIPELL MART',
        'LORRONK STORE',
        'VEXSILO CAFE',
        'MIRATREM LABS',
        'TOLAWUNA TRAVELS',
      ];
      final end = DateTime(2026, 9, 15, 12);
      final rows = <Tx>[];
      var n = 0;
      Tx purchase(DateTime date, String m, double amount, {bool utc = false}) {
        final d = utc
            ? DateTime.utc(date.year, date.month, date.day, date.hour)
            : date;
        return _sms(
          'p${n++}',
          'Rs.${amount.toStringAsFixed(2)} debited from a/c XX1111 on '
              '${_dmy(d)} at $m.',
          date: d,
          amount: amount,
          categoryId: 'shopping',
          acctKey: bankKey,
        );
      }

      Tx refund(DateTime date, String m, double amount, {bool utc = false}) {
        final d = utc
            ? DateTime.utc(date.year, date.month, date.day, date.hour)
            : date;
        return _sms(
          'f${n++}',
          'Rs.${amount.toStringAsFixed(2)} refund from $m on ${_dmy(d)} '
              'credited to a/c XX1111.',
          date: d,
          amount: amount,
          type: TxType.income,
          categoryId: 'other_income',
          acctKey: bankKey,
          pending: rand.nextBool(),
        );
      }

      for (var i = 0; i < 3000; i++) {
        final date = end.subtract(
          Duration(minutes: i * 190 + rand.nextInt(120)),
        );
        rows.add(
          purchase(
            date,
            names[rand.nextInt(names.length)],
            (rand.nextInt(5000) + 100).toDouble(),
            utc: i % 37 == 0,
          ),
        );
      }
      // Refunds a set number of calendar days after a purchase: on its day
      // (before and after it in the day), and at 59, 60, 61 and 62 days, at
      // the first and last minute of the day.
      for (var k = 0; k < 40; k++) {
        final buy = rows[rand.nextInt(3000)];
        final m = alertMerchantOf(buy);
        expect(m, isNotEmpty);
        for (final days in [0, 59, 60, 61, 62]) {
          for (final (h, min) in [(0, 0), (23, 59)]) {
            final d = DateTime(
              buy.date.year,
              buy.date.month,
              buy.date.day + days,
              h,
              min,
            );
            rows.add(refund(d, m, buy.amount, utc: k % 5 == 0 && h == 23));
          }
        }
        // Part refunds that name no merchant, matched on the account.
        rows.add(
          _sms(
            'f${n++}',
            'Rs.50.00 credited to a/c XX1111 as refund of an order.',
            date: buy.date.add(const Duration(days: 30)),
            amount: 50,
            type: TxType.income,
            categoryId: 'other_income',
            acctKey: bankKey,
          ),
        );
      }
      final p = await _load(_seed(rows, [bank]));
      final refunds = [
        for (final t in [...p.transactions, ...p.pendingTransactions])
          if (t.type == TxType.income) t,
      ];
      var dismissed = <String>{};
      for (var round = 0; round < 3; round++) {
        final expected = overAllRows(p, refunds, dismissed);
        expect(expected, isNotEmpty);
        expect(asPairs(p.refundSuggestions(refunds, dismissed)), expected);
        dismissed = {
          ...dismissed,
          for (final (r, x) in expected) 'refund|$r|$x',
        };
      }
      // The edges themselves: 60 days back is in, 61 is out.
      final edge = rows[0];
      final in60 = refund(
        DateTime(edge.date.year, edge.date.month, edge.date.day + 60, 23, 59),
        alertMerchantOf(edge),
        edge.amount,
      );
      final out61 = refund(
        DateTime(edge.date.year, edge.date.month, edge.date.day + 61),
        alertMerchantOf(edge),
        edge.amount,
      );
      expect(
        p.refundSuggestions([in60], const {}).map((s) => s.purchase.id),
        contains(edge.id),
      );
      expect(
        p.refundSuggestions([out61], const {}).map((s) => s.purchase.id),
        isNot(contains(edge.id)),
      );
    });

    test('a possible other leg holds an import up to the pair window and no '
        'further', () async {
      final now = DateTime(2026, 9, 10, 12);
      final other = Account(
        id: 'acct_other',
        name: 'Other Bank',
        type: AccountType.bank,
        keys: {'OTHRBK:2222'},
      );
      final seed = _seed([
        _sms(
          'h1',
          'Rs.120.00 debited from a/c XX1111 at KESHBRIM MART.',
          date: now.subtract(const Duration(days: 30)),
          amount: 120,
          acctKey: bankKey,
        ),
        _sms(
          'h2',
          'Rs.130.00 debited from a/c XX2222 at KESHBRIM MART.',
          date: now.subtract(const Duration(days: 30)),
          amount: 130,
          acctKey: 'OTHRBK:2222',
        ),
        _sms(
          'out1',
          'Rs.7,770.00 debited from a/c XX1111 to own account.',
          date: now,
          amount: 7770,
          categoryId: 'other_expense',
          acctKey: bankKey,
        ),
      ], [bank, other]);
      Future<bool> waits(Duration after) async {
        final p = await _load(seed);
        await p.addImported([
          ParsedTxn(
            type: TxType.income,
            amount: 7770,
            merchant: '',
            date: now.add(after),
            ref: 'IN1',
            categoryId: 'other_income',
            sender: 'AD-OTHRBK',
            rawBody: 'Rs.7,770.00 credited to a/c XX2222 by transfer.',
            acctKey: 'OTHRBK:2222',
          ),
        ]);
        return p.pendingTransactions.any((t) => t.externalRef == 'IN1');
      }

      expect(await waits(const Duration(days: 2)), isTrue);
      expect(await waits(const Duration(days: 2, minutes: 1)), isFalse);
    });
  });

  // Item 5: a card tile's window and rewards are kept until a change.
  group('card window', () {
    const cardKey = 'TESTBK:4404';
    final card = Account(
      id: 'acct_card',
      name: 'Test Card',
      type: AccountType.creditCard,
      keys: {cardKey},
      statementDay: 10,
      dueDay: 28,
      creditLimit: 90000,
      rewards: const CardRewards(
        groups: [
          RewardGroup(
            id: 'g1',
            name: 'Dining',
            categoryIds: {'food'},
            rate: 5,
          ),
        ],
        baseRate: 1,
      ),
    );
    final plain = Account(
      id: 'acct_plain',
      name: 'Plain Card',
      type: AccountType.creditCard,
      keys: {'TESTBK:7000'},
    );
    final clock = DateTime(2026, 9, 20, 12);
    Map<String, Object> seed() => _seed([
      for (var i = 0; i < 240; i++)
        _sms(
          'c$i',
          'INR 410.00 spent on Testa Card XX4404 at LANTERN NOODLES.',
          date: clock.subtract(Duration(hours: 20 * i + 3)),
          amount: 410.0 + i,
          categoryId: i.isEven ? 'food' : 'shopping',
          acctKey: cardKey,
        ),
    ], [card, plain]);

    setUp(() => FinanceProvider.figuresClock = () => clock);
    tearDown(() => FinanceProvider.figuresClock = DateTime.now);

    List<double> spentOf(CardSpendWindow w) => [for (final b in w.bars) b.spent];

    test('the same window until a change, the day or the basis moves',
        () async {
      final p = await _load(seed());
      final first = p.cardSpendWindow(card);
      expect(identical(p.cardSpendWindow(card), first), isTrue);
      expect(identical(p.cardRewardsFor(card), first.current.rewards), isTrue);
      // A fresh provider works it out to the same figures.
      final q = await _load(seed());
      final fresh = q.cardSpendWindow(card);
      expect(spentOf(first), spentOf(fresh));
      expect(first.current.rewards!.earned, fresh.current.rewards!.earned);
      expect((first.day, first.days, first.hasOlder),
          (fresh.day, fresh.days, fresh.hasOlder));
      // The Month view's copy and an older page are their own windows.
      final month = p.cardSpendWindow(card.copyWith(clearStatementDay: true));
      expect(month.current.cycle.start, DateTime(2026, 9, 1));
      expect(first.current.cycle.start, DateTime(2026, 9, 11));
      expect(identical(p.cardSpendWindow(card, skip: 1), first), isFalse);
      expect(p.cardSpendWindow(card, skip: 1).bars.last.back, 1);
      // The next day.
      FinanceProvider.figuresClock = () => clock.add(const Duration(days: 1));
      expect(p.cardSpendWindow(card).day, first.day + 1);
      FinanceProvider.figuresClock = () => clock;
      // A change.
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 1000,
        note: 'dinner',
        date: clock.subtract(const Duration(hours: 1)),
      );
      await p.assignAccount(p.transactions.first.id, 'acct_card');
      expect(p.cardSpendWindow(card).current.spent,
          closeTo(first.current.spent + 1000, 0.001));
      // No rewards set up: none, every time.
      expect(p.cardRewardsFor(plain), isNull);
      expect(p.cardRewardsFor(plain), isNull);
    });
  });

  // Item 6: a quiet SMS run skips the full pass for a few hours.
  group('quiet SMS runs', () {
    Future<(FinanceProvider, SettingsProvider)> setUpRun() async {
      final finance = FinanceProvider();
      await finance.load();
      final settings = SettingsProvider();
      await settings.load();
      await settings.setAutoImport(AutoImportFrequency.everySms);
      return (finance, settings);
    }

    /// A card billed and due on [today], the day the monitors' clock reads.
    Future<void> addDueCard(
      FinanceProvider finance,
      String name,
      DateTime today,
    ) async {
      final id = await finance.addAccount(
        name: name,
        type: AccountType.creditCard,
      );
      await finance.setManualBalance(id, 5000);
      await finance.setCardCycle(id, dueDay: today.day);
    }

    Future<void> run(
      FinanceProvider finance,
      SettingsProvider settings,
      FakeNotifications notes,
      DateTime at, {
      BackgroundTrigger trigger = BackgroundTrigger.sms,
      SmsImportService? import,
      bool syncWidgets = false,
    }) => runBackgroundImport(
      finance,
      settings,
      trigger,
      import: import ?? _QuietImport(),
      syncWidgets: syncWidgets,
      notify: false,
      notifications: notes,
      now: at,
    );

    test('skips the alert checks after a full run until the interval passes',
        () async {
      final (finance, settings) = await setUpRun();
      final notes = FakeNotifications();
      final today = DateTime.now();
      final t0 = DateTime(today.year, today.month, today.day, 0, 30);
      await addDueCard(finance, 'First Card', today);
      await run(finance, settings, notes, t0);
      expect(notes.shown, hasLength(1), reason: 'no full run on record');
      // A second card comes due between messages.
      await addDueCard(finance, 'Second Card', today);
      await run(finance, settings, notes, t0.add(const Duration(hours: 1)));
      expect(notes.shown, hasLength(1), reason: 'a quiet run skips');
      await run(finance, settings, notes, t0.add(kQuietSmsFullCheckEvery));
      expect(notes.shown, hasLength(2));
      expect(notes.shown.last.$2, contains('Second Card'));
    });

    test('a new day, an import or a periodic run always checks', () async {
      final (finance, settings) = await setUpRun();
      final notes = FakeNotifications();
      final today = DateTime.now();
      final t0 = DateTime(today.year, today.month, today.day, 0, 30);
      final prefs = await SharedPreferences.getInstance();
      // The last full run was late yesterday.
      await prefs.setInt(
        kLastFullCheckKey,
        t0.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
      await addDueCard(finance, 'First Card', today);
      await run(finance, settings, notes, t0);
      expect(notes.shown, hasLength(1));
      await addDueCard(finance, 'Second Card', today);
      await run(
        finance,
        settings,
        notes,
        t0.add(const Duration(minutes: 1)),
        import: CountingImport(),
      );
      expect(notes.shown, hasLength(2));
      await addDueCard(finance, 'Third Card', today);
      await run(
        finance,
        settings,
        notes,
        t0.add(const Duration(minutes: 2)),
        trigger: BackgroundTrigger.periodic,
      );
      expect(notes.shown, hasLength(3));
    });

    test('a pass whose widget sync fails is not recorded, so the next quiet '
        'run does the full pass again', () async {
      final (finance, settings) = await setUpRun();
      final store = _WidgetFailStore();
      SharedPreferencesStorePlatform.instance = store;
      final prefs = await SharedPreferences.getInstance();
      final notes = FakeNotifications();
      final today = DateTime.now();
      final t0 = DateTime(today.year, today.month, today.day, 0, 30);
      await addDueCard(finance, 'First Card', today);
      await run(finance, settings, notes, t0, syncWidgets: true);
      expect(notes.shown, hasLength(1), reason: 'the checks still ran');
      expect(prefs.getInt(kLastFullCheckKey), isNull);
      // The next quiet run does it all again, and this time it works.
      store.failing = false;
      await addDueCard(finance, 'Second Card', today);
      final t1 = t0.add(const Duration(hours: 1));
      await run(finance, settings, notes, t1, syncWidgets: true);
      expect(notes.shown, hasLength(2));
      expect(prefs.getInt(kLastFullCheckKey), t1.millisecondsSinceEpoch);
      // Recorded: the quiet run after it skips.
      await addDueCard(finance, 'Third Card', today);
      await run(
        finance,
        settings,
        notes,
        t1.add(const Duration(minutes: 10)),
        syncWidgets: true,
      );
      expect(notes.shown, hasLength(2));
    });

    test('a pass whose alert check fails is not recorded, so the next quiet '
        'run checks again', () async {
      final (finance, settings) = await setUpRun();
      final prefs = await SharedPreferences.getInstance();
      final notes = _ThrowingNotifications();
      final today = DateTime.now();
      final t0 = DateTime(today.year, today.month, today.day, 0, 30);
      await addDueCard(finance, 'First Card', today);
      await run(finance, settings, notes, t0, syncWidgets: true);
      expect(notes.shown, isEmpty);
      expect(prefs.getInt(kLastFullCheckKey), isNull);
      notes.failing = false;
      final t1 = t0.add(const Duration(hours: 1));
      await run(finance, settings, notes, t1, syncWidgets: true);
      expect(notes.shown, hasLength(1), reason: 'the unsent alert goes now');
      expect(prefs.getInt(kLastFullCheckKey), t1.millisecondsSinceEpoch);
    });

    test('a check whose setting is off counts as done', () async {
      final (finance, settings) = await setUpRun();
      await settings.setUpcomingReminders(false);
      final prefs = await SharedPreferences.getInstance();
      final today = DateTime.now();
      final t0 = DateTime(today.year, today.month, today.day, 0, 30);
      await addDueCard(finance, 'First Card', today);
      await run(finance, settings, _ThrowingNotifications(), t0);
      expect(prefs.getInt(kLastFullCheckKey), t0.millisecondsSinceEpoch);
    });

    test('a run whose reminder entry adds a row checks', () async {
      final (finance, settings) = await setUpRun();
      final notes = FakeNotifications();
      final today = DateTime.now();
      final t0 = DateTime(today.year, today.month, today.day, 0, 30);
      await run(finance, settings, notes, t0);
      await addDueCard(finance, 'First Card', today);
      await run(finance, settings, notes, t0.add(const Duration(minutes: 5)));
      expect(notes.shown, isEmpty, reason: 'nothing changed in the run');
      // An Add it for me reminder whose entries the next run adds.
      await finance.restoreReminder(
        Reminder(
          id: 'rem',
          name: 'Made-up rent',
          dayOfMonth: 1,
          categoryId: 'other_expense',
          expectedAmount: 100,
          autoAdd: true,
          autoSince: '2020-01-01',
          lastPaidMonth: '2020-01',
        ),
      );
      await run(finance, settings, notes, t0.add(const Duration(minutes: 6)));
      expect(finance.transactions, isNotEmpty);
      expect(notes.shown, hasLength(1));
    });
  });

  // Item 7: the week digest and the per-category usual give what the
  // per-row date passes gave.
  group('date keys', () {
    final now = DateTime(2026, 9, 17, 15);

    List<Tx> ledger() {
      final rand = Random(5);
      final out = <Tx>[];
      for (var i = 0; i < 1500; i++) {
        var d = now.subtract(Duration(minutes: i * 263 + rand.nextInt(200)));
        // Some at the very edges of a day, some held in UTC.
        if (i % 11 == 0) d = DateTime(d.year, d.month, d.day);
        if (i % 13 == 0) d = DateTime(d.year, d.month, d.day, 23, 59, 59);
        if (i % 17 == 0) {
          d = DateTime.utc(d.year, d.month, d.day, i.isEven ? 0 : 23, 30);
        }
        final income = i % 9 == 0;
        out.add(
          Tx(
            id: 'w$i',
            type: income ? TxType.income : TxType.expense,
            categoryId: income
                ? 'salary'
                : const ['food', 'transport', 'shopping', 'bills'][i % 4],
            amount: (rand.nextInt(90000) + 100) / 100,
            note: 'row $i',
            date: d,
            countIn: i % 29 == 0 ? d.add(const Duration(days: 3)) : null,
          ),
        );
      }
      return out;
    }

    /// [buildWeekDigest]'s pass as it was, with a date per row.
    ({List<double> byDay, int count, double income, Map<String, double> cats})
    weekAsBefore(FinanceProvider finance, DateTime start, int daysShown) {
      final byDay = List<double>.filled(7, 0);
      final cats = <String, double>{};
      var income = 0.0;
      var count = 0;
      for (final t in finance.countedTransactions) {
        final d = t.effectiveDate;
        final day = d.weekday - 1;
        if (day >= daysShown || weekStartOf(d) != start) continue;
        final money = !isTransferCategory(t.categoryId);
        count++;
        if (money && t.type == TxType.expense) {
          final net = finance.netSpendOf(t);
          if (net > 0) {
            byDay[day] += net;
            cats[t.categoryId] = (cats[t.categoryId] ?? 0) + net;
          }
        } else if (money &&
            t.type == TxType.income &&
            !finance.isLinkedRefund(t)) {
          income += t.amount;
        }
      }
      return (byDay: byDay, count: count, income: income, cats: cats);
    }

    /// [usualWeekByDay] as it was.
    List<double?> usualAsBefore(FinanceProvider finance, DateTime weekStart) {
      final start = weekStartOf(weekStart);
      final earliest = DateTime(start.year, start.month, start.day - 7 * 8);
      final earlier = <DateTime, List<double>>{};
      for (final t in finance.countedTransactions) {
        if (isTransferCategory(t.categoryId) || t.type != TxType.expense) {
          continue;
        }
        final d = t.effectiveDate;
        final week = weekStartOf(d);
        if (week.isBefore(earliest) || !week.isBefore(start)) continue;
        final days = earlier.putIfAbsent(week, () => List<double>.filled(7, 0));
        days[d.weekday - 1] += finance.netSpendOf(t);
      }
      final weeks = <List<double>>[];
      final first = finance.firstTransactionDate;
      if (first != null) {
        final firstWeek = weekStartOf(first);
        for (var k = 1; k <= 8; k++) {
          final w = DateTime(start.year, start.month, start.day - 7 * k);
          if (w.isBefore(firstWeek)) break;
          weeks.add(earlier[w] ?? List<double>.filled(7, 0));
        }
      }
      if (weeks.length < 2) return List<double?>.filled(7, null);
      return [
        for (var shown = 1; shown <= 7; shown++)
          median([
            for (final days in weeks)
              days.take(shown).fold(0.0, (s, v) => s + v),
          ]),
      ];
    }

    test('weeks come out as the per-row pass made them', () async {
      final p = await _load(_seed(ledger(), const []));
      for (var back = 0; back < 30; back++) {
        final start = weekStartOf(
          DateTime(now.year, now.month, now.day - 7 * back),
        );
        final d = buildWeekDigest(p, start, now: now);
        final ref = weekAsBefore(p, start, d.daysShown);
        expect(d.byDay, ref.byDay, reason: 'week $start');
        expect(d.count, ref.count, reason: 'week $start');
        expect(d.income, ref.income, reason: 'week $start');
        final top = ref.cats.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        expect(
          [for (final e in d.topCategories) (e.key.id, e.value)],
          [for (final e in top.take(3)) (e.key, e.value)],
          reason: 'week $start',
        );
        expect(usualWeekByDay(p, start), usualAsBefore(p, start));
      }
      expect(weekRangeLabel(DateTime(2026, 9, 28)), '28 Sep to 4 Oct');
      expect(
        weekRangeLabel(DateTime(2026, 10, 12), withWeekday: true),
        'Mon 12 to Sun 18 Oct',
      );
    });

    test("each category's usual starts at its first month, as before",
        () async {
      final rows = [
        ...ledger(),
        // A category first spent mid-window, by a UTC row at a month's
        // first minute.
        Tx(
          id: 'late',
          type: TxType.expense,
          categoryId: 'health',
          amount: 700,
          note: 'clinic',
          date: DateTime.utc(2026, 6, 1, 0, 1),
        ),
        Tx(
          id: 'late2',
          type: TxType.expense,
          categoryId: 'health',
          amount: 300,
          note: 'clinic',
          date: DateTime(2026, 8, 31, 23, 59),
        ),
      ];
      final p = await _load(_seed(rows, const []));
      for (final month in [
        DateTime(2026, 9),
        DateTime(2026, 8),
        DateTime(2026, 7),
      ]) {
        final got = buildMonthComparison(p, month, now: now).categories;
        // The first month per category, worked out with a date per row.
        final firstSpend = <String, DateTime>{};
        for (final t in p.countedTransactions) {
          if (t.type != TxType.expense) continue;
          final m = DateTime(t.effectiveDate.year, t.effectiveDate.month);
          final seen = firstSpend[t.categoryId];
          if (seen == null || m.isBefore(seen)) firstSpend[t.categoryId] = m;
        }
        final window = usualWindow(p, month);
        for (final c in got) {
          final start = firstSpend[c.category.id];
          final running = month.year == now.year && month.month == now.month;
          final usual = median([
            for (final m in window)
              if (start != null && !m.isBefore(start))
                running
                    ? p
                          .expenseByCategoryThrough(m, now.day)
                          .where((e) => e.key.id == c.category.id)
                          .fold(0.0, (s, e) => s + e.value)
                    : p
                          .expenseByCategory(m)
                          .where((e) => e.key.id == c.category.id)
                          .fold(0.0, (s, e) => s + e.value),
          ]);
          expect(c.usual, usual, reason: '${c.category.id} in $month');
        }
      }
    });
  });
}
