import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
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
        expect(data['version'], 32);
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
        endsWith(',acctKind,smsAt,splitId,guessed,noCashback'),
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
    final waits = p.addImported([alert(ref: 'W1', date: daysAgo(4))]);
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
}
