import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/saved_filter.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/card_rewards_page.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/import_health.dart';
import 'package:expense_tracker/services/notification_source.dart';
import 'package:expense_tracker/services/sms_import_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/sms_source.dart';
import 'package:expense_tracker/services/stable_hash.dart';
import 'package:expense_tracker/widgets/import_health_banner.dart';

class _Inbox implements SmsSource {
  List<SmsMessage> inbox = [];

  @override
  bool get isSupported => true;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<SmsPermission> requestPermission() async => SmsPermission.granted;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<SmsQueryResult> query({
    required DateTime since,
    DateTime? until,
  }) async => SmsQueryResult(messages: inbox, complete: true);
}

class _NoNotifications implements NotificationSource {
  @override
  bool get isSupported => true;

  @override
  Future<bool> hasAccess() async => false;

  @override
  Future<void> openAccessSettings() async {}

  @override
  Future<Map<String, dynamic>> diagnostics() async => const {};

  @override
  Future<DateTime?> lastCapture() async => null;

  @override
  Future<NotificationBatch> peek() async => NotificationBatch.empty;

  @override
  Future<void> ack(NotificationBatch batch) async {}
}

/// v1.43.8: deleted and discarded imports stay gone after a rescan or a
/// restore, re-dated imports are still recognised, a CSV Replace keeps
/// account kinds, each import reports its own counted figure, and one
/// skipped completed payment warns. Every name, number and text is made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
    FinanceProvider.useIsolateCodec = false;
  });

  Future<FinanceProvider> fresh() async {
    final p = FinanceProvider();
    await p.load();
    return p;
  }

  final now = DateTime.now();
  DateTime daysAgo(int days, [int minute = 0]) =>
      DateTime(now.year, now.month, now.day - days, 10, minute);

  const body = 'Rs.640.00 debited from A/c XX3141 at QUILLFERN TEAS.';

  ParsedTxn alert({
    DateTime? date,
    String? ref,
    String rawBody = body,
    String sender = 'VM-TESTBK',
    String acctKey = 'TESTBK:3141',
    bool isCard = false,
  }) => ParsedTxn(
    type: TxType.expense,
    amount: 640,
    merchant: 'QUILLFERN TEAS',
    date: date ?? daysAgo(5),
    ref: ref,
    categoryId: 'other_expense',
    sender: sender,
    rawBody: rawBody,
    acctKey: acctKey,
    isCard: isCard,
  );

  List<Tx> allRows(FinanceProvider p) => [
    ...p.transactions,
    ...p.pendingTransactions,
  ];

  test('stableHash is fixed, 16 hex characters', () {
    // FNV-1a 64-bit of "a" is af63dc4c8601ec8c.
    expect(stableHash('a'), 'af63dc4c8601ec8c');
    expect(stableHash(''), 'cbf29ce484222325');
    expect(stableHash(body), matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  group('deleted and discarded imports stay gone', () {
    test('Discard all, then a rescan imports nothing', () async {
      final p = await fresh();
      await p.addImported([alert()]);
      expect(p.pendingCount, 1);
      await p.discardAllPending();
      final (added, _, _) = await p.addImported([alert()]);
      expect(added, 0);
      expect(allRows(p), isEmpty);
    });

    test(
      'a deleted confirmed import stays gone, after a restart too',
      () async {
        final p = await fresh();
        await p.addImported([alert(ref: 'QF001')]);
        await p.confirmAllPending();
        await p.deleteTransaction(p.transactions.single.id);
        final reloaded = await fresh();
        final (added, _, _) = await reloaded.addImported([alert(ref: 'QF001')]);
        expect(added, 0);
      },
    );

    test('the bank\'s second copy of a discarded alert drops too', () async {
      final p = await fresh();
      final copy = alert(date: daysAgo(5, 1));
      final (first, _, _) = await p.addImported([alert(), copy]);
      expect(first, 1, reason: 'the copy is a duplicate');
      await p.discardAllPending();
      final (added, _, _) = await p.addImported([copy, alert()]);
      expect(added, 0);
    });

    test('a discarded notification copy keeps its inbox twin out', () async {
      final p = await fresh();
      // The notification copy lost its ref; the inbox alert has one and
      // arrived a minute later, so it drops as the copy's twin.
      final copy = alert(sender: 'HDFC Bank', acctKey: 'HDFC:3141');
      final inbox = alert(
        sender: 'VM-HDFCBK',
        acctKey: 'HDFC:3141',
        ref: 'QF003',
        date: daysAgo(5, 1),
      );
      var (added, _, _) = await p.addImported([copy]);
      expect(added, 1);
      (added, _, _) = await p.addImported([inbox]);
      expect(added, 0, reason: 'the twin of the copy');
      await p.discardAllPending();
      (added, _, _) = await p.addImported([inbox]);
      expect(added, 0);
    });

    test('Undo forgets the discard', () async {
      final p = await fresh();
      await p.addImported([alert()]);
      final removed = await p.discardAllPending();
      expect(p.discardedImportCount, 1);
      await p.restoreTransactions(removed);
      expect(p.discardedImportCount, 0);
      final row = p.pendingTransactions.single;
      await p.deleteTransaction(row.id);
      expect(p.discardedImportCount, 1);
      await p.restoreTransaction(row);
      expect(p.discardedImportCount, 0);
    });

    test(
      'a backup carries hashes, no text, and a restore honours them',
      () async {
        final p = await fresh();
        await p.addImported([alert()]);
        await p.discardAllPending();
        final json = jsonEncode(p.exportData());
        expect(json, isNot(contains('QUILLFERN')));
        expect(json, isNot(contains('XX3141')));
        final data = jsonDecode(json) as Map<String, dynamic>;
        expect(data['version'], 36);
        expect(data['discardedImports'], hasLength(1));

        SharedPreferences.setMockInitialValues({});
        final phone = await fresh();
        await phone.importData(data, replace: true);
        final (added, _, _) = await phone.addImported([alert()]);
        expect(added, 0);
      },
    );

    test('a restored row deleted on the new phone stays gone', () async {
      final p = await fresh();
      await p.addImported([alert(ref: 'QF002')]);
      await p.confirmAllPending();
      final data =
          jsonDecode(jsonEncode(p.exportData())) as Map<String, dynamic>;

      SharedPreferences.setMockInitialValues({});
      final phone = await fresh();
      await phone.importData(data, replace: true);
      final restored = phone.transactions.single;
      expect(restored.smsBody, isEmpty);
      await phone.deleteTransaction(restored.id);
      final (added, _, _) = await phone.addImported([alert(ref: 'QF002')]);
      expect(added, 0);
    });

    test('Delete all data forgets every discard', () async {
      final p = await fresh();
      await p.addImported([alert()]);
      await p.discardAllPending();
      await p.clearAll();
      final (added, _, _) = await p.addImported([alert()]);
      expect(added, 1);
    });
  });

  group('a re-dated import is still recognised', () {
    test('on a rescan, and after a backup round trip', () async {
      final p = await fresh();
      final arrived = daysAgo(5);
      await p.addImported([alert(date: arrived)]);
      await p.confirmAllPending();
      final row = p.transactions.single;
      await p.updateTransaction(row.copyWith(date: daysAgo(2)));
      final moved = p.transactions.single;
      expect(moved.smsAt, arrived);
      expect(moved.smsArrivedAt, arrived);
      var (added, _, _) = await p.addImported([alert(date: arrived)]);
      expect(added, 0);

      // Moving it back drops the field.
      expect(moved.copyWith(date: arrived).smsAt, isNull);

      final data =
          jsonDecode(jsonEncode(p.exportData())) as Map<String, dynamic>;
      SharedPreferences.setMockInitialValues({});
      final phone = await fresh();
      await phone.importData(data, replace: true);
      expect(phone.transactions.single.smsAt, arrived);
      (added, _, _) = await phone.addImported([alert(date: arrived)]);
      expect(added, 0);
    });
  });

  group('CSV Replace keeps account kinds', () {
    Future<FinanceProvider> withCardAndHandAssigned() async {
      final p = await fresh();
      await p.addImported([
        alert(
          sender: 'VM-HDFCBK',
          acctKey: 'HDFC:4412',
          isCard: true,
          rawBody: 'Rs.640.00 spent on HDFC Bank Card XX4412 at QUILLFERN.',
        ),
      ]);
      await p.confirmAllPending();
      await p.addTransaction(
        type: TxType.expense,
        categoryId: 'food',
        amount: 120,
        note: 'Tea stall',
        date: daysAgo(3),
      );
      final boxId = await p.addAccount(name: 'Tin box', type: AccountType.bank);
      final cash = p.transactions.firstWhere((t) => t.note == 'Tea stall');
      await p.assignAccount(cash.id, boxId);
      expect(p.accountForKey('HDFC:4412')?.type, AccountType.creditCard);
      return p;
    }

    test('on the same device, cards and hand-assigned rows stay', () async {
      final p = await withCardAndHandAssigned();
      final (txs, kinds) = BackupService.csvImportOf(BackupService.buildCsv(p));
      await p.importTransactions(txs, replace: true, acctKinds: kinds);
      expect(p.accountForKey('HDFC:4412')?.type, AccountType.creditCard);
      final cash = p.transactions.firstWhere((t) => t.note == 'Tea stall');
      expect(p.accountForKey(cash.acctKey)?.name, 'Tin box');
    });

    test('on a new device, the acctKind column rebuilds a card', () async {
      final p = await withCardAndHandAssigned();
      final csv = BackupService.buildCsv(p);
      expect(
        csv.split('\r\n').first,
        endsWith(
          ',acctKind,smsAt,splitId,guessed,noCashback,smsMerchant,'
          'rewardGroup,rewardPickedAt,receivedMs',
        ),
      );
      final (txs, kinds) = BackupService.csvImportOf(csv);
      expect(kinds, {'HDFC:4412': 'card'});

      SharedPreferences.setMockInitialValues({});
      final phone = await fresh();
      await phone.importTransactions(txs, replace: true, acctKinds: kinds);
      expect(phone.accountForKey('HDFC:4412')?.type, AccountType.creditCard);
    });
  });

  test('each import returns its own counted figure', () async {
    final p = await fresh();
    // A confirmed row on the account makes a rule-matched alert sure.
    await p.addImported([
      alert(
        ref: 'SEED',
        date: daysAgo(30),
        rawBody: 'Rs.450 debited from A/c XX3141 at KETTLE NOOK',
      ),
    ]);
    await p.confirmAllPending();
    final sure = p.addImported([
      alert(ref: 'S1', rawBody: 'Rs.640 debited from A/c XX3141 at SWIGGY'),
    ]);
    // Started while the first awaits its save: it resets the shared figure.
    // With no bank reference it may be the first alert again, so it waits
    // (v2.3.0: two different references would be two payments).
    final waits = p.addImported([alert(date: daysAgo(4))]);
    final (_, _, counted) = await sure;
    final (_, _, waitsCounted) = await waits;
    expect(counted, 1);
    expect(waitsCounted, 0);
    expect(p.lastImportCounted, 0, reason: 'the old read saw the other call');
  });

  group('one skipped completed payment warns', () {
    const emi =
        'EMI of Rs.6,215.00 debited from A/c XX4410 on 03-10-26. Next EMI '
        'of Rs.6,215.00 will be debited on 03-11-26.';

    test('a lone EMI alert the import skips warns at once', () async {
      final inbox = _Inbox()
        ..inbox = [
          SmsMessage(sender: 'VM-HDFCBK', body: emi, date: daysAgo(2)),
        ];
      final service = SmsImportService(
        source: inbox,
        notifications: _NoNotifications(),
      );
      final p = await fresh();
      await service.run(p, lookback: const Duration(days: 10));
      final health = await ImportHealth.load();
      final hit = health.banks['HDFC']!.unread.single;
      expect(hit.droppedButDone, isTrue);
      final warnings = buildImportWarnings(health, const [], DateTime.now());
      expect(warnings.single.count, 1);
      expect(warnings.single.droppedButDone, isTrue);
    });

    test('a lone format change still waits for a second', () {
      final state = ImportHealthState({
        'HDFC': BankHealth(
          bank: 'HDFC',
          unread: [(at: daysAgo(2), seen: daysAgo(2), droppedButDone: false)],
        ),
      });
      expect(buildImportWarnings(state, const [], now), isEmpty);
    });

    testWidgets('the banner names the skipped payment', (tester) async {
      final at = DateTime.now()
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        kImportHealthKey: jsonEncode({
          'HDFC': {
            'unread': [
              [at, at, 1],
            ],
            'samples': [
              {'at': at, 'sender': 'VM-HDFCBK', 'body': emi},
            ],
          },
        }),
      });
      final p = await fresh();
      final s = SettingsProvider();
      await s.load();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: p),
            ChangeNotifierProvider.value(value: s),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: ImportHealthBanner()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('1 HDFC alert in 14 days could not be read'),
        findsOneWidget,
      );
      expect(
        find.textContaining('It states a completed payment'),
        findsOneWidget,
      );
      await tester.tap(find.text('See alerts'));
      await tester.pumpAndSettle();
      expect(find.textContaining('An alert on '), findsOneWidget);
    });
  });

  group('a version 32 backup restores into v2.1.0', () {
    Map<String, dynamic> row(String id, int day, {String? rewardGroup}) => {
      'id': id,
      'type': 'expense',
      'categoryId': 'food',
      'amount': 400.0 + day,
      'note': '',
      'date': daysAgo(day).toIso8601String(),
      'source': 'sms',
      'acctKey': 'TESTBK:1111',
      'externalRef': 'REF$id',
      'rewardGroup': ?rewardGroup,
    };

    Map<String, dynamic> card(List<Map<String, dynamic>> groups) => {
      'id': 'card1',
      'name': 'Test card',
      'type': 'creditCard',
      'keys': ['TESTBK:1111'],
      'rewards': {'unit': 'cashback', 'groups': groups, 'baseRate': 1.0},
    };

    // Two unnamed groups with no ids, as v2.0.1 saved them; no
    // 'rewardGroup' on any row and no 'tagNames'.
    Map<String, dynamic> v32({List<Map<String, dynamic>>? rows}) => {
      'app': 'expense_tracker',
      'version': 32,
      'transactions': rows ?? [row('tx1', 3), row('tx2', 4), row('tx3', 5)],
      'accounts': [
        card([
          {
            'categoryIds': ['food', 'shopping'],
            'rate': 5.0,
          },
          {
            'categoryIds': ['transport'],
            'rate': 2.0,
          },
        ]),
      ],
    };

    List<String> groupIds(FinanceProvider p) => [
      for (final g in p.accountById('card1')!.rewards!.groups) g.id,
    ];

    test('replace', () async {
      final p = await fresh();
      expect(await p.addSavedTag('Diwali', null), isTrue);
      await p.importData(v32(), replace: true);
      expect(groupIds(p), ['card1-g0', 'card1-g1']);
      expect(
        rewardGroupName(p.accountById('card1')!.rewards!.groups.first),
        'Food & Dining, Shopping',
      );
      expect(
        [for (final t in p.transactions) t.rewardGroup],
        [null, null, null],
      );
      // Absent 'tagNames' keeps the device's saved tags.
      expect(p.savedTags, ['Diwali']);
      expect(p.loadWarnings, isEmpty);

      final again =
          jsonDecode(jsonEncode(p.exportData())) as Map<String, dynamic>;
      await p.importData(again, replace: true);
      expect(groupIds(p), ['card1-g0', 'card1-g1']);
    });

    test('merge', () async {
      final p = await fresh();
      final device = v32(rows: [row('tx1', 3, rewardGroup: 'card1-g1')])
        ..['version'] = 33;
      await p.importData(device, replace: true);
      expect(p.transactions.single.rewardGroup, 'card1-g1');

      await p.importData(v32(), replace: false);
      final byId = {for (final t in p.transactions) t.id: t};
      expect(byId.keys.toSet(), {'tx1', 'tx2', 'tx3'});
      // The device's row wins on merge, pick included.
      expect(byId['tx1']!.rewardGroup, 'card1-g1');
      expect(byId['tx2']!.rewardGroup, isNull);
      expect(byId['tx3']!.rewardGroup, isNull);
    });

    test('a version 33 export round-trips every new key', () async {
      final p = await fresh();
      final named = v32(rows: [row('tx1', 3, rewardGroup: 'gdine')])
        ..['version'] = 33
        ..['accounts'] = [
          card([
            {
              'id': 'gdine',
              'name': 'Dining',
              'categoryIds': ['food'],
              'merchantWords': ['quillfern teas'],
              'rate': 10.0,
              'cap': 500.0,
              'minimum': 250.0,
            },
          ]),
        ];
      await p.importData(named, replace: true);
      expect(await p.addSavedTag('Diwali', null), isTrue);
      final data =
          jsonDecode(jsonEncode(p.exportData())) as Map<String, dynamic>;
      expect(data['version'], 36);

      SharedPreferences.setMockInitialValues({});
      final phone = await fresh();
      await phone.importData(data, replace: true);
      final g = phone.accountById('card1')!.rewards!.groups.single;
      expect(g.id, 'gdine');
      expect(g.name, 'Dining');
      expect(g.merchantWords, {'quillfern teas'});
      expect(g.minimum, 250);
      expect(g.cap, 500);
      expect(phone.transactions.single.rewardGroup, 'gdine');
      expect(phone.savedTags, ['Diwali']);
    });
  });

  group('saved filters', () {
    SavedFilter trip(String id, String name) => SavedFilter(
      id: id,
      name: name,
      tab: 'expense',
      categories: const ['food', 'transport'],
      tags: const ['hill trip'],
      accountId: 'acct_1',
      thisMonth: true,
      min: 99.5,
    );

    List<String> names(FinanceProvider p) => [
      for (final f in p.savedFilters) f.name,
    ];

    test('the model keeps every part through JSON, and leaves unset parts '
        'out', () {
      final ranged = SavedFilter(
        id: 'flt_1_0',
        name: 'Last year',
        tab: 'income',
        groups: const ['grp_1', '_ungrouped'],
        budgets: const ['bud_1'],
        rangeStart: DateTime(2025, 4, 1),
        rangeEnd: DateTime(2026, 3, 31),
        rangeCounted: true,
        rangeLabel: 'FY 2025-26',
        max: 2000,
      );
      final back = SavedFilter.fromJson(jsonDecode(jsonEncode(ranged)))!;
      expect(back.toJson(), ranged.toJson());
      expect(back.tab, 'income');
      expect(back.groups, ['grp_1', '_ungrouped']);
      expect(back.budgets, ['bud_1']);
      expect(back.rangeStart, DateTime(2025, 4, 1));
      expect(back.rangeEnd, DateTime(2026, 3, 31));
      expect(back.rangeCounted, isTrue);
      expect(back.rangeLabel, 'FY 2025-26');
      expect(back.min, isNull);
      expect(back.max, 2000);
      expect(back.thisMonth, isFalse);
      expect(back.month, isNull);

      final moving = SavedFilter.fromJson(
        jsonDecode(jsonEncode(trip('flt_2_0', 'Hill trip'))),
      )!;
      expect(moving.thisMonth, isTrue);
      expect(moving.month, isNull);
      expect(moving.categories, ['food', 'transport']);
      expect(moving.tags, ['hill trip']);
      expect(moving.accountId, 'acct_1');
      expect(moving.min, 99.5);

      final fixed = SavedFilter.fromJson(
        jsonDecode(
          jsonEncode(
            SavedFilter(id: 'flt_3_0', name: 'July', month: DateTime(2026, 7)),
          ),
        ),
      )!;
      expect(fixed.month, DateTime(2026, 7));
      expect(fixed.thisMonth, isFalse);

      // Only what narrows is stored.
      expect(const SavedFilter(id: 'flt_4_0', name: 'Bare').toJson(), {
        'id': 'flt_4_0',
        'name': 'Bare',
        'tab': 'all',
      });
      final renamed = ranged.copyWith(name: 'Year before');
      expect(renamed.name, 'Year before');
      expect(renamed.toJson()..remove('name'), ranged.toJson()..remove('name'));
    });

    test('the model reads a damaged entry tolerantly', () {
      expect(SavedFilter.fromJson('nope'), isNull);
      expect(SavedFilter.fromJson({'name': 'No id'}), isNull);
      expect(SavedFilter.fromJson({'id': 'flt_1_0'}), isNull);
      expect(SavedFilter.fromJson({'id': 'flt_1_0', 'name': '  '}), isNull);
      expect(SavedFilter.fromJson({'id': 7, 'name': 'Odd id'}), isNull);

      final f = SavedFilter.fromJson({
        'id': 'flt_1_0',
        'name': ' Odd parts ',
        'tab': 4,
        'categories': ['food', 9, ''],
        'groups': 'grp_1',
        'tags': null,
        'accountId': 12,
        'thisMonth': 'yes',
        'month': 'July',
        'from': '2026-07-10',
        'to': '2026-07-01',
        'rangeCounted': true,
        'rangeLabel': 'Backwards',
        'min': '50',
        'max': 80,
      })!;
      expect(f.name, 'Odd parts');
      expect(f.tab, 'all');
      expect(f.categories, ['food']);
      expect(f.groups, isEmpty);
      expect(f.tags, isEmpty);
      expect(f.accountId, isNull);
      expect(f.thisMonth, isFalse);
      expect(f.month, isNull);
      // A range that runs backwards is no range, and takes its flavour
      // with it.
      expect(f.rangeStart, isNull);
      expect(f.rangeEnd, isNull);
      expect(f.rangeCounted, isFalse);
      expect(f.rangeLabel, isNull);
      expect(f.min, isNull);
      expect(f.max, 80);

      // A range wins over a month, and a fixed month over This month.
      final both = SavedFilter.fromJson({
        'id': 'flt_2_0',
        'name': 'Both',
        'thisMonth': true,
        'month': '2026-07',
        'from': '2026-07-01',
        'to': '2026-07-10',
      })!;
      expect(both.rangeStart, DateTime(2026, 7, 1));
      expect(both.month, isNull);
      expect(both.thisMonth, isFalse);
      final monthAndMoving = SavedFilter.fromJson({
        'id': 'flt_3_0',
        'name': 'Month',
        'thisMonth': true,
        'month': '2026-07',
      })!;
      expect(monthAndMoving.month, DateTime(2026, 7));
      expect(monthAndMoving.thisMonth, isFalse);
    });

    test('a saved filter persists, is replaced by id and deleted', () async {
      final p = await fresh();
      final first = p.newSavedFilterId();
      final second = p.newSavedFilterId();
      expect(first, startsWith('flt_'));
      expect(second, isNot(first));
      await p.saveFilter(trip(first, 'Hill trip'));
      await p.saveFilter(trip(second, 'Groceries'));

      final again = await fresh();
      expect(names(again), ['Hill trip', 'Groceries']);
      expect(
        again.savedFilters.first.toJson(),
        trip(first, 'Hill trip').toJson(),
      );

      // The same id replaces in place; the order holds.
      await again.saveFilter(again.savedFilters.first.copyWith(name: 'Hills'));
      expect(names(again), ['Hills', 'Groceries']);
      await again.deleteSavedFilter(second);
      await again.deleteSavedFilter('flt_none');
      expect(names(again), ['Hills']);

      final third = await fresh();
      expect(names(third), ['Hills']);
      expect(third.loadWarnings, isEmpty);
    });

    test('a stored entry with no id or name is skipped, and a second one '
        'with a seen id', () async {
      SharedPreferences.setMockInitialValues({
        'saved_filters_v1': jsonEncode([
          {'name': 'No id'},
          trip('flt_1_0', 'Hill trip').toJson(),
          {'id': 'flt_2_0'},
          'not a filter',
          trip('flt_1_0', 'Twin').toJson(),
        ]),
      });
      final p = await fresh();
      expect(names(p), ['Hill trip']);
      expect(p.loadWarnings, isEmpty);
    });

    test('an unreadable stored list warns, stays as stored, and a replacing '
        'restore that carries the key clears the warning', () async {
      SharedPreferences.setMockInitialValues({'saved_filters_v1': '{broken'});
      final p = await fresh();
      expect(p.savedFilters, isEmpty);
      expect(p.loadWarnings, ['saved filters']);
      // Another marks save leaves the stored text alone.
      await p.addSavedTag('Diwali', null);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('saved_filters_v1'), '{broken');

      await p.importData({
        ...p.exportData(),
        'savedFilters': [trip('flt_1_0', 'Hill trip').toJson()],
      }, replace: true);
      expect(p.loadWarnings, isEmpty);
      expect(names(p), ['Hill trip']);
      expect(prefs.getString('saved_filters_v1'), contains('Hill trip'));
    });

    test('the backup carries saved filters: replace takes them, merge adds '
        'the missing ids, an older backup keeps the device\'s, a factory '
        'reset clears them', () async {
      final p = await fresh();
      await p.saveFilter(trip('flt_1_0', 'Hill trip'));
      final data =
          jsonDecode(jsonEncode(p.exportData())) as Map<String, dynamic>;
      expect(data['version'], 36);
      expect(data['savedFilters'], [trip('flt_1_0', 'Hill trip').toJson()]);

      SharedPreferences.setMockInitialValues({});
      final other = await fresh();
      await other.saveFilter(trip('flt_9_0', 'Groceries'));
      await other.importData(data, replace: true);
      expect(names(other), ['Hill trip']);

      // A merge keeps the device's copy of an id both sides hold, adds the
      // rest, and skips a broken entry.
      await other.saveFilter(trip('flt_9_0', 'Groceries'));
      await other.importData({
        ...data,
        'savedFilters': [
          trip('flt_1_0', 'Renamed elsewhere').toJson(),
          {'id': 'flt_5_0'},
          trip('flt_6_0', 'Rent').toJson(),
        ],
      }, replace: false);
      expect(names(other), ['Hill trip', 'Groceries', 'Rent']);

      // A backup from before saved filters keeps the device's, in both
      // modes.
      final older = {...data}..remove('savedFilters');
      await other.importData(older, replace: true);
      expect(names(other), ['Hill trip', 'Groceries', 'Rent']);
      await other.importData(older, replace: false);
      expect(names(other), ['Hill trip', 'Groceries', 'Rent']);

      final reloaded = await fresh();
      expect(names(reloaded), ['Hill trip', 'Groceries', 'Rent']);

      await other.clearAll();
      expect(other.savedFilters, hasLength(3));
      await other.clearAll(includeConfig: true);
      expect(other.savedFilters, isEmpty);
      expect((await fresh()).savedFilters, isEmpty);
    });

    // v2.3.0 review: an account the backup holds under another id folds
    // into the device's, and a filter on it follows, as reminders do.
    test('a merging restore points a saved filter at the device account its '
        'own folded into', () async {
      final p = await fresh();
      final device = await p.addAccount(
        name: 'Lantern Bank',
        type: AccountType.bank,
      );
      expect(await p.addAccountKey(device, 'LANTERN:4321'), isTrue);
      SavedFilter on(String id, String name, String accountId) =>
          SavedFilter(id: id, name: name, accountId: accountId);

      await p.importData({
        ...p.exportData(),
        'accounts': [
          ...p.accounts.map((a) => a.toJson()),
          Account(
            id: 'acct_elsewhere',
            name: 'Lantern 4321',
            type: AccountType.bank,
            keys: {'LANTERN:4321'},
          ).toJson(),
          Account(
            id: 'acct_new',
            name: 'Pebble Card',
            type: AccountType.creditCard,
            keys: {'PEBBLE:7788'},
          ).toJson(),
        ],
        'savedFilters': [
          on('flt_1_0', 'Lantern rows', 'acct_elsewhere').toJson(),
          on('flt_2_0', 'Card rows', 'acct_new').toJson(),
        ],
      }, replace: false);

      expect(p.accountById('acct_elsewhere'), isNull);
      SavedFilter saved(FinanceProvider f, String id) =>
          f.savedFilters.firstWhere((x) => x.id == id);
      expect(saved(p, 'flt_1_0').accountId, device);
      // An account that came in as its own keeps its id.
      expect(saved(p, 'flt_2_0').accountId, 'acct_new');
      expect(saved(await fresh(), 'flt_1_0').accountId, device);
    });

    // v2.3.0 review: merging two accounts removes the source's id.
    test('merging accounts moves a saved filter from the source to the '
        'target', () async {
      final p = await fresh();
      final a = await p.addAccount(name: 'First', type: AccountType.bank);
      final b = await p.addAccount(name: 'Second', type: AccountType.bank);
      final c = await p.addAccount(name: 'Third', type: AccountType.bank);
      await p.saveFilter(
        SavedFilter(id: 'flt_1_0', name: 'On B', accountId: b),
      );
      await p.saveFilter(
        SavedFilter(id: 'flt_2_0', name: 'On C', accountId: c),
      );
      final onC = p.savedFilters.last;

      await p.mergeAccounts(b, a);
      expect(p.savedFilters.first.accountId, a);
      expect(p.savedFilters.first.name, 'On B');
      expect(identical(p.savedFilters.last, onC), isTrue);
      final again = await fresh();
      expect(again.savedFilters.first.accountId, a);
      expect(again.savedFilters.last.accountId, c);
    });
  });
}
