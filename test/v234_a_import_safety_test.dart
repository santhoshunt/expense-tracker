import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/account.dart';
import 'package:expense_tracker/models/saved_filter.dart';
import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/backup_service.dart';
import 'package:expense_tracker/services/import_health.dart';
import 'package:expense_tracker/services/notification_source.dart';
import 'package:expense_tracker/services/review_queue.dart';
import 'package:expense_tracker/services/sms_import_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/sms_source.dart';

// Every name, number, amount and merchant below is invented.

const _lastScanKey = 'sms_last_scan_millis';
const _inbox = 'VM-HDFCBK';
const _notif = 'HDFC Bank';

ParsedTxn _parse(String sender, String body, DateTime at) {
  final p = SmsTxnParser.parse(sender, body, at, relaxedSender: true);
  if (p == null) throw StateError('fixture does not parse: $body');
  return p;
}

/// [p] as v2.3.3's parser handed it over: dated by the old rule, with no
/// arrival time.
ParsedTxn _asV233(ParsedTxn p) => ParsedTxn(
  type: p.type,
  amount: p.amount,
  merchant: p.merchant,
  date: p.legacyDate!,
  ref: p.ref,
  categoryId: p.categoryId,
  sender: p.sender,
  rawBody: p.rawBody,
  spamSuspect: p.spamSuspect,
  acctKey: p.acctKey,
  balanceAfter: p.balanceAfter,
  isCard: p.isCard,
  isDebitCard: p.isDebitCard,
);

/// Inbox and notification alerts, with and without a bank reference, with
/// a body date equal to, earlier than and absent from the arrival day.
final _alerts = <(String, String, DateTime)>[
  // Inbox, reference, body date the arrival day.
  (
    _inbox,
    'Rs.317.45 debited from a/c XX7719 on 14-03-26 to PLUMWOOD CAFE. '
        'Ref 739104628351.',
    DateTime(2026, 3, 14, 19, 42, 17, 381),
  ),
  // Inbox, no reference, body date the day before it arrived.
  (
    _inbox,
    'Rs.86.00 debited from a/c XX7719 on 13-03-26 to KESTREL KIOSK.',
    DateTime(2026, 3, 14, 0, 7, 51, 204),
  ),
  // Inbox, no reference, no body date.
  (
    _inbox,
    'Rs.1,240.00 spent on Card XX5283 at ORBITAL BOOKS. '
        'Avl Lmt Rs.41,760.00',
    DateTime(2026, 3, 15, 11, 3, 9, 877),
  ),
  // Inbox, reference, two body dates: the purchase and the credit.
  (
    _inbox,
    'Refund of Rs.452.00 for your transaction on 02-02-26 at LANTERN MART '
        'is credited to your a/c XX7719 on 15-03-26. Ref 528830174926.',
    DateTime(2026, 3, 15, 16, 20, 44, 512),
  ),
  // Inbox, no reference, a helpline's hours in the footer.
  (
    _inbox,
    'Rs.73.50 debited from a/c XX7719 on 15-03-26 at TEALEAF STALL. '
        'Queries? Ring 18004190372 (9:30 am-6:30 pm)',
    DateTime(2026, 3, 15, 21, 11, 5, 90),
  ),
  // Notification, no reference, no body date.
  (
    _notif,
    'Rs.199.00 debited from a/c XX7719 to FERNHILL MEDS',
    DateTime(2026, 3, 16, 8, 15, 33, 618),
  ),
  // Notification, no reference, body date the day before it arrived.
  (
    _notif,
    'Rs.58.00 debited from a/c XX7719 on 15-03-26 to QUAYSIDE PARKING',
    DateTime(2026, 3, 16, 0, 2, 12, 733),
  ),
  // Notification, reference, body date the arrival day.
  (
    _notif,
    'Rs.2,600.00 credited to a/c XX7719 on 16-03-26 from ARVEN TRUST. '
        'Ref 604215983377',
    DateTime(2026, 3, 16, 10, 45, 2, 155),
  ),
];

List<ParsedTxn> _parsedNow() => [
  for (final (s, b, at) in _alerts) _parse(s, b, at),
];

String _ledgerOf(FinanceProvider p) =>
    jsonEncode(p.exportData()['transactions']);

/// The stored ledger as a phone in another time zone reads it back: every
/// local wall-time field moved by [shift], the epoch field as it was.
String _readInAnotherZone(String raw, Duration shift, {bool dropMs = false}) {
  final rows = jsonDecode(raw) as List;
  for (final r in rows.cast<Map<String, dynamic>>()) {
    for (final k in ['date', 'smsAt']) {
      final v = r[k];
      if (v is String) r[k] = DateTime.parse(v).add(shift).toIso8601String();
    }
    if (dropMs) r.remove('receivedMs');
  }
  return jsonEncode(rows);
}

class _FakeSms implements SmsSource {
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
  }) async => SmsQueryResult(
    messages: [
      for (final m in inbox)
        if (m.date.isAfter(since) && (until == null || m.date.isBefore(until)))
          m,
    ],
    complete: true,
  );
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  group('alert dates', () {
    test('a body date of the day before, arriving just after midnight with no '
        'clock time, is the end of that day; later, or on the day, the '
        'arrival clock', () {
      const body =
          'Rs.640.00 debited from a/c XX3361 on 05-07-26 to NIGHTOWL '
          'DINER.';
      final late = DateTime(2026, 7, 6, 0, 5, 12);
      expect(
        SmsTxnParser.resolveDateTime(body, late),
        DateTime(2026, 7, 5, 23, 59, 59, 999),
      );
      expect(
        SmsTxnParser.isEndOfDayStamp(SmsTxnParser.resolveDateTime(body, late)),
        isTrue,
      );
      // The old rule stamped it before every other row of the 5th.
      expect(
        SmsTxnParser.resolveDateTimeV233(body, late),
        DateTime(2026, 7, 5, 0, 5, 12),
      );
      // Within two hours of the day's end, and no later.
      expect(
        SmsTxnParser.resolveDateTime(body, DateTime(2026, 7, 6, 1, 59, 30)),
        DateTime(2026, 7, 5, 23, 59, 59, 999),
      );
      for (final later in [
        DateTime(2026, 7, 6, 2, 0, 30),
        DateTime(2026, 7, 6, 8, 30),
        DateTime(2026, 7, 8, 9, 30),
      ]) {
        expect(
          SmsTxnParser.resolveDateTime(body, later),
          SmsTxnParser.resolveDateTimeV233(body, later),
        );
      }
      expect(
        SmsTxnParser.resolveDateTime(body, DateTime(2026, 7, 8, 9, 30)),
        DateTime(2026, 7, 5, 9, 30),
      );
      final sameDay = DateTime(2026, 7, 5, 23, 55, 40);
      expect(SmsTxnParser.resolveDateTime(body, sameDay), sameDay);
    });

    test('the body date nearest the arrival wins among several', () {
      const body =
          'Refund of Rs.999.00 for your transaction on 12-05-26 at '
          'BRIGHTLY GOODS is credited to your Card XX4401 on 05-07-26';
      final at = DateTime(2026, 7, 5, 11, 20, 7);
      expect(SmsTxnParser.resolveDateTime(body, at), at);
      expect(
        SmsTxnParser.resolveDateTimeV233(body, at),
        DateTime(2026, 5, 12, 11, 20, 7),
      );
      // None within the window: the first date stands, as before.
      const far =
          'Rs.300.00 debited from a/c XX3361 on 02-06-26 for order dated '
          'on 10-06-26';
      expect(
        SmsTxnParser.resolveDateTime(far, at),
        DateTime(2026, 6, 2, 11, 20, 7),
      );
      // A due date ahead is still never the payment's date.
      const due =
          'Rs.4,100.00 debited from a/c XX3361 on 04-07-26. Next due on '
          '04-08-26';
      expect(
        SmsTxnParser.resolveDateTime(due, at),
        DateTime(2026, 7, 4, 11, 20, 7),
      );
      // A date a day ahead never wins over a near date before it.
      const ahead =
          'Payment of Rs.8,450.00 received on 03-07-26 towards Card XX5517. '
          'Next auto debit on 06-07-26';
      final fifth = DateTime(2026, 7, 5, 10, 4, 51);
      expect(
        SmsTxnParser.resolveDateTime(ahead, fifth),
        DateTime(2026, 7, 3, 10, 4, 51),
      );
      expect(
        SmsTxnParser.resolveDateTime(ahead, fifth),
        SmsTxnParser.resolveDateTimeV233(ahead, fifth),
      );
      // Alone, it stands within the one-day slack, as before.
      const onlyAhead =
          'Rs.8,450.00 debited from Card XX5517 on 06-07-26 at SALTPAN '
          'GROCER';
      expect(
        SmsTxnParser.resolveDateTime(onlyAhead, fifth),
        DateTime(2026, 7, 6, 10, 4, 51),
      );
    });

    test('a clock time counts only next to the date', () {
      const footer =
          'Rs.73.50 debited from a/c XX3361 on 05-07-26 at TEALEAF STALL. '
          'Queries? Ring 18004190372 (9:30 am-6:30 pm)';
      final at = DateTime(2026, 7, 5, 21, 11, 5);
      expect(SmsTxnParser.resolveDateTime(footer, at), at);
      expect(
        SmsTxnParser.resolveDateTimeV233(footer, at),
        DateTime(2026, 7, 5, 9, 30),
      );
      const before = 'Rs.120.00 debited from a/c XX3361 at 14:05 on 05-07-26';
      expect(
        SmsTxnParser.resolveDateTime(before, at),
        DateTime(2026, 7, 5, 14, 5),
      );
      const after = 'Rs.120.00 debited from a/c XX3361 on 05-07-26 at 18:45';
      expect(
        SmsTxnParser.resolveDateTime(after, at),
        DateTime(2026, 7, 5, 18, 45),
      );
      const stamped =
          'Rs.120.00 debited from a/c XX3361 06-07-2026 03:41:52 pm at '
          'PIER CAFE';
      expect(
        SmsTxnParser.resolveDateTime(stamped, DateTime(2026, 7, 6, 16)),
        DateTime(2026, 7, 6, 15, 41, 52),
      );
    });

    test('parse carries the arrival time and the old-rule date', () {
      final at = DateTime(2026, 7, 6, 0, 5, 12, 345);
      final p = _parse(
        _inbox,
        'Rs.640.00 debited from a/c XX3361 on 05-07-26 to NIGHTOWL DINER.',
        at,
      );
      expect(p.arrivedAt, at);
      expect(p.legacyDate, DateTime(2026, 7, 5, 0, 5, 12));
      expect(p.date, DateTime(2026, 7, 5, 23, 59, 59, 999));
    });
  });

  group('rescans', () {
    test('a rescan of alerts v2.3.3 imported imports, holds and changes '
        'nothing', () async {
      final now = _parsedNow();
      // The fixtures exercise the old rule: these dates moved.
      final moved = [
        for (final p in now)
          if (!p.date.isAtSameMomentAs(p.legacyDate!)) p,
      ];
      // The late inbox and notification alerts, the refund, the footer.
      expect(moved.length, 4);

      final old = FinanceProvider();
      await old.load();
      final (added, _, _) = await old.addImported([
        for (final p in now) _asV233(p),
      ]);
      expect(added, now.length);
      expect(
        old.pendingTransactions.every((t) => t.receivedAt == null),
        isTrue,
      );

      // The refund the old rule dated by its purchase (2 Feb), moved by the
      // user to the credit date before the app kept the original
      // ([Tx.smsAt], v1.43.8): six weeks from the date the old rule gives.
      final prefs = await SharedPreferences.getInstance();
      final rows = jsonDecode(prefs.getString('transactions_v1')!) as List;
      for (final r in rows.cast<Map<String, dynamic>>()) {
        if ((r['smsBody'] as String? ?? '').contains('LANTERN')) {
          expect(r['date'], startsWith('2026-02-02'));
          r['date'] = DateTime(2026, 3, 15, 16, 20, 44).toIso8601String();
          r.remove('smsAt');
        }
      }
      await prefs.setString('transactions_v1', jsonEncode(rows));

      final p = FinanceProvider();
      await p.load();
      final ledger = _ledgerOf(p);
      final pending = p.pendingTransactions.length;
      final stored = prefs.getString('transactions_v1');

      // Two of the notification alerts again, as the inbox holds them: its
      // own sender and a few seconds later.
      final inboxCopies = [
        _parse(
          _inbox,
          'Rs.199.00 debited from a/c XX7719 to FERNHILL MEDS',
          DateTime(2026, 3, 16, 8, 15, 36, 4),
        ),
        _parse(
          _inbox,
          'Rs.58.00 debited from a/c XX7719 on 15-03-26 to QUAYSIDE PARKING',
          DateTime(2026, 3, 16, 0, 2, 15, 228),
        ),
      ];
      expect(await p.addImported([..._parsedNow(), ...inboxCopies]), (0, 0, 0));
      expect(_ledgerOf(p), ledger);
      expect(p.pendingTransactions.length, pending);
      expect(prefs.getString('transactions_v1'), stored);

      // A deleted older row stays deleted on the next rescan.
      final late = p.pendingTransactions.firstWhere(
        (t) => t.smsBody.contains('KESTREL'),
      );
      await p.deleteTransaction(late.id);
      expect(await p.addImported(_parsedNow()), (0, 0, 0));
    });

    test('a rescan of alerts this version imported changes nothing, also '
        'after a time-zone change', () async {
      final first = FinanceProvider();
      await first.load();
      await first.addImported(_parsedNow());
      expect(
        first.pendingTransactions.every((t) => t.receivedAt != null),
        isTrue,
      );
      expect(await first.addImported(_parsedNow()), (0, 0, 0));

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('transactions_v1')!;
      for (final shift in const [
        Duration(hours: -5, minutes: -30),
        Duration(hours: 9),
      ]) {
        SharedPreferences.setMockInitialValues({
          'transactions_v1': _readInAnotherZone(raw, shift),
        });
        final p = FinanceProvider();
        await p.load();
        final ledger = _ledgerOf(p);
        expect(await p.addImported(_parsedNow()), (0, 0, 0));
        expect(_ledgerOf(p), ledger);
      }

      // The same rows without the arrival field, as v2.3.3 kept them,
      // would come back after the change.
      SharedPreferences.setMockInitialValues({
        'transactions_v1': _readInAnotherZone(
          raw,
          const Duration(hours: 9),
          dropMs: true,
        ),
      });
      final bare = FinanceProvider();
      await bare.load();
      final (back, _, _) = await bare.addImported(_parsedNow());
      expect(back, greaterThan(0));
    });

    test('older rows dated by their arrival alone are recognised across a '
        'time-zone change', () async {
      final undated = [
        for (final p in _parsedNow())
          if (p.legacyDate!.isAtSameMomentAs(p.arrivedAt!)) p,
      ];
      expect(undated.length, 2);
      final old = FinanceProvider();
      await old.load();
      await old.addImported([for (final p in undated) _asV233(p)]);
      final prefs = await SharedPreferences.getInstance();
      SharedPreferences.setMockInitialValues({
        'transactions_v1': _readInAnotherZone(
          prefs.getString('transactions_v1')!,
          const Duration(hours: -3, minutes: -45),
        ),
      });
      final p = FinanceProvider();
      await p.load();
      expect(await p.addImported(undated), (0, 0, 0));
    });

    test('a row that is edited, split and restored from a backup is still '
        'recognised', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported(_parsedNow());
      final row = p.pendingTransactions.firstWhere(
        (t) => t.smsBody.contains('KESTREL'),
      );
      await p.updateTransaction(
        row.copyWith(date: row.date.subtract(const Duration(days: 2))),
      );
      final shop = p.pendingTransactions.firstWhere(
        (t) => t.smsBody.contains('ORBITAL'),
      );
      await p.confirmTransaction(shop.id);
      await p.splitTransaction(shop.id, [
        (categoryId: 'shopping', amount: 1000),
        (categoryId: 'food', amount: 240),
      ]);
      final anchor = p.transactions.firstWhere((t) => t.id == shop.id);
      expect(anchor.splitId, isNotNull);
      expect(anchor.receivedAt, isNotNull);
      final data = p.exportData();
      final restored = FinanceProvider();
      await restored.load();
      await restored.importData(jsonDecode(jsonEncode(data)), replace: true);
      expect(
        restored.pendingTransactions.every((t) => t.receivedAt != null),
        isTrue,
      );
      expect(
        restored.transactions.firstWhere((t) => t.id == shop.id).receivedAt,
        anchor.receivedAt,
      );
      final ledger = _ledgerOf(restored);
      expect(await restored.addImported(_parsedNow()), (0, 0, 0));
      expect(_ledgerOf(restored), ledger);
    });
  });

  group('a CSV round trip', () {
    Future<(List<Tx>, Map<String, String>, Map<String, DateTime?>)>
    exported() async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported(_parsedNow());
      final arrivals = {
        for (final t in p.pendingTransactions) t.id: t.receivedAt,
      };
      expect(arrivals.values.every((a) => a != null), isTrue);
      final bytes = await BackupService.csvBytes(p);
      final (txs, kinds) = BackupService.csvImportOf(utf8.decode(bytes));
      return (txs, kinds, arrivals);
    }

    for (final replace in [true, false]) {
      test('keeps the arrival time, and a rescan changes nothing '
          '(${replace ? 'replace' : 'merge'})', () async {
        final (txs, kinds, arrivals) = await exported();
        // The late reference-less alert, whose date the new rule moved.
        final late = _parsedNow().firstWhere(
          (p) => p.rawBody.contains('KESTREL'),
        );
        expect(late.ref, isNull);
        expect(late.date.isAtSameMomentAs(late.legacyDate!), isFalse);

        SharedPreferences.setMockInitialValues({});
        final q = FinanceProvider();
        await q.load();
        if (!replace) {
          await q.addTransaction(
            type: TxType.expense,
            categoryId: 'food',
            amount: 95,
            note: 'Samosas at Brindle Corner',
            date: DateTime(2026, 3, 12, 17, 40),
          );
        }
        await q.importTransactions(txs, replace: replace, acctKinds: kinds);
        for (final t in q.pendingTransactions) {
          expect(t.receivedAt, arrivals[t.id], reason: t.id);
        }
        final ledger = _ledgerOf(q);
        final pending = q.pendingTransactions.length;
        expect(await q.addImported(_parsedNow()), (0, 0, 0));
        expect(_ledgerOf(q), ledger);
        expect(q.pendingTransactions.length, pending);
      });
    }

    test('without the column, as exported before it, the late alert comes '
        'back on a rescan', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported(_parsedNow());
      final csv = utf8.decode(await BackupService.csvBytes(p));
      final older = [
        for (final line in csv.split('\r\n'))
          line.substring(0, line.lastIndexOf(',')),
      ].join('\r\n');
      expect(older.split('\r\n').first, endsWith(',rewardPickedAt'));
      final (txs, kinds) = BackupService.csvImportOf(older);
      SharedPreferences.setMockInitialValues({});
      final q = FinanceProvider();
      await q.load();
      await q.importTransactions(txs, replace: true, acctKinds: kinds);
      await q.addImported(_parsedNow());
      expect(q.pendingTransactions.where((t) => t.amount == 86), hasLength(2));
    });

    test('an unreadable or missing value, or a manual row, reads as '
        'absent', () {
      final csv = BackupService.buildCsvOf([
        Tx(
          id: 'm1',
          type: TxType.expense,
          categoryId: 'food',
          amount: 60,
          note: 'Chai',
          date: DateTime(2026, 3, 12, 9),
          receivedAt: DateTime(2026, 3, 12, 9),
        ),
        Tx(
          id: 's1',
          type: TxType.expense,
          categoryId: 'food',
          amount: 60,
          note: '',
          date: DateTime(2026, 3, 12, 9),
          source: TxSource.sms,
          sender: _inbox,
          receivedAt: DateTime(2026, 3, 12, 9, 0, 0, 417),
        ),
      ]);
      final back = {for (final t in BackupService.txsFromCsv(csv)) t.id: t};
      expect(back['m1']!.receivedAt, isNull);
      expect(back['s1']!.receivedAt, DateTime(2026, 3, 12, 9, 0, 0, 417));
      final bad = csv.replaceFirst(RegExp(r',\d+$'), ',soon');
      expect(BackupService.txsFromCsv(bad).last.receivedAt, isNull);
    });
  });

  group('bank references', () {
    const emi =
        'Loan Ref 4455667788: EMI of Rs.5,000.00 debited from a/c XX4402 on '
        '05-07-26';
    const emiNext =
        'Loan Ref 4455667788: EMI of Rs.5,000.00 debited from a/c XX4402 on '
        '05-08-26';

    test('a reference seen a month earlier imports and is held as a '
        'possible duplicate', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        _parse(_inbox, emi, DateTime(2026, 7, 5, 9, 12, 40)),
      ]);
      final (added, _, counted) = await p.addImported([
        _parse(_inbox, emiNext, DateTime(2026, 8, 5, 9, 14, 3)),
      ]);
      expect(added, 1);
      expect(counted, 0);
      final next = p.pendingTransactions.firstWhere((t) => t.date.month == 8);
      expect(
        p.reviewQueue(const {}).held[HoldReason.duplicate]?.map((t) => t.id),
        contains(next.id),
      );
      // Each month's own alert read again drops.
      expect(
        await p.addImported([
          _parse(_inbox, emi, DateTime(2026, 7, 5, 9, 12, 40)),
          _parse(_inbox, emiNext, DateTime(2026, 8, 5, 9, 14, 3)),
        ]),
        (0, 0, 0),
      );
    });

    test('the same reference minutes apart is one alert', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([
        _parse(_inbox, emi, DateTime(2026, 7, 5, 9, 12, 40)),
      ]);
      final (added, _, _) = await p.addImported([
        _parse(_notif, emi, DateTime(2026, 7, 5, 9, 14, 1)),
      ]);
      expect(added, 0);
    });
  });

  test('an incremental scan reads a few minutes back and imports nothing '
      'twice', () async {
    final now = DateTime.now();
    final sms = _FakeSms();
    final service = SmsImportService(
      source: sms,
      notifications: _NoNotifications(),
    );
    SmsMessage m(String body, DateTime at) =>
        SmsMessage(sender: _inbox, body: body, date: at);
    final a = m(
      'Rs.212.00 debited from a/c XX6630 to HAZELNUT BAKERY',
      now.subtract(const Duration(hours: 3)),
    );
    final b = m(
      'Rs.48.00 debited from a/c XX6630 to WILLOW TEA ROOM',
      now.subtract(const Duration(hours: 2)),
    );
    sms.inbox = [a, b];
    final p = FinanceProvider();
    await p.load();
    final first = await service.run(p);
    expect(first!.imported, 2);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(_lastScanKey), b.date.millisecondsSinceEpoch);

    // Written into the inbox after the first scan, dated before its marker.
    final late = m(
      'Rs.365.00 debited from a/c XX6630 to ROWAN HARDWARE',
      b.date.subtract(const Duration(minutes: 4)),
    );
    sms.inbox = [a, b, late];
    final second = await service.run(p);
    expect(second!.imported, 1);
    expect(second.duplicates, 0);
    expect(p.pendingTransactions.length + p.transactions.length, 3);

    final third = await service.run(p);
    expect(third!.imported, 0);
    expect(p.pendingTransactions.length + p.transactions.length, 3);
    expect(prefs.getInt(_lastScanKey), b.date.millisecondsSinceEpoch);
  });

  test('deleting a hand-assigned row takes its key off the account, and '
      'Undo puts it back', () async {
    final p = FinanceProvider();
    await p.load();
    final cash = await p.addAccount(name: 'Pocket', type: AccountType.cash);
    final id = await p.addTransaction(
      type: TxType.expense,
      categoryId: 'food',
      amount: 140,
      note: 'Lunch at Copperleaf',
      date: DateTime(2026, 7, 9, 13, 20),
    );
    await p.assignAccount(id, cash);
    expect(p.accountById(cash)!.keys, contains('manual:$id'));

    final row = p.transactions.firstWhere((t) => t.id == id);
    await p.deleteTransaction(id);
    expect(p.accountById(cash)!.keys, isNot(contains('manual:$id')));
    final reloaded = FinanceProvider();
    await reloaded.load();
    expect(reloaded.accountById(cash)!.keys, isEmpty);

    await p.restoreTransaction(row);
    expect(p.accountById(cash)!.keys, contains('manual:$id'));
    expect(p.accountForKey('manual:$id')?.id, cash);

    final removed = await p.deleteTransactions([id]);
    expect(p.accountById(cash)!.keys, isEmpty);
    await p.restoreTransactions(removed);
    expect(p.accountForKey('manual:$id')?.id, cash);
  });

  test('one unreadable account fails the accounts whole, and every link to '
      'them stays in place', () async {
    final p = FinanceProvider();
    await p.load();
    final spend = await p.addAccount(name: 'Spend', type: AccountType.bank);
    final hidden = await p.addAccount(name: 'Reserve', type: AccountType.bank);
    final card = await p.addAccount(name: 'Tap card', type: AccountType.bank);
    expect(
      await p.setAccountType(
        card,
        AccountType.debitCard,
        linkedAccountId: hidden,
      ),
      isTrue,
    );
    await p.addReminder(
      name: 'Broadband',
      dayOfMonth: 11,
      expectedAmount: 799,
      categoryId: 'bills',
      accountId: hidden,
    );
    await p.saveFilter(
      SavedFilter(id: 'sf_reserve', name: 'Reserve', accountId: hidden),
    );

    final prefs = await SharedPreferences.getInstance();
    final accounts = jsonDecode(prefs.getString('accounts_v1')!) as List;
    for (final a in accounts.cast<Map<String, dynamic>>()) {
      if (a['id'] == hidden) a['name'] = 42;
    }
    final broken = jsonEncode(accounts);
    await prefs.setString('accounts_v1', broken);
    final reminders = prefs.getString('reminders_v1');
    final filters = prefs.getString('saved_filters_v1');

    final q = FinanceProvider();
    await q.load();
    // All or nothing, as in v2.3.3: a partial list would be saved over the
    // stored one by the first write.
    expect(q.loadWarnings, contains('accounts'));
    expect(q.loadWarnings, isNot(contains('some accounts')));
    expect(q.accounts, isEmpty);
    expect(jsonDecode(broken), hasLength(3));
    expect([spend, card], everyElement(isNot(hidden)));
    expect(q.reminders.single.accountId, hidden);
    expect(q.savedFilters.single.accountId, hidden);
    expect(prefs.getString('accounts_v1'), broken);
    expect(prefs.getString('accounts_v1_corrupt'), broken);
    expect(prefs.getString('reminders_v1'), reminders);
    expect(prefs.getString('saved_filters_v1'), filters);
  });

  group('late alerts', () {
    const lateBody =
        'Rs.40.00 spent on Card XX8823 at LINDEN KIOSK on 05-07-26.';
    const nextBody =
        'Rs.40.00 spent on Card XX8823 at LINDEN KIOSK on 06-07-26.';
    // No signal overnight: the 5th's alert and the 6th's arrive together.
    final lateAt = DateTime(2026, 7, 6, 1, 10, 0, 120);
    final nextAt = DateTime(2026, 7, 6, 1, 10, 2, 920);

    for (final lateFirst in [true, false]) {
      test('two payments of one amount on different days both import '
          '(${lateFirst ? 'late one first' : 'late one second'})', () async {
        final late = _parse(_inbox, lateBody, lateAt);
        final next = _parse(_inbox, nextBody, nextAt);
        expect(late.date, DateTime(2026, 7, 5, 23, 59, 59, 999));
        expect(next.date, DateTime(2026, 7, 6, 1, 10, 2));
        final p = FinanceProvider();
        await p.load();
        final (one, _, _) = await p.addImported(
          lateFirst ? [late, next] : [next, late],
        );
        expect(one, 2);
        final q = FinanceProvider();
        await q.load();
        final (a, _, _) = await q.addImported([lateFirst ? late : next]);
        final (b, _, _) = await q.addImported([lateFirst ? next : late]);
        expect((a, b), (0, 0), reason: 'both already on record');
        SharedPreferences.setMockInitialValues({});
        final r = FinanceProvider();
        await r.load();
        expect((await r.addImported([lateFirst ? late : next])).$1, 1);
        expect((await r.addImported([lateFirst ? next : late])).$1, 1);
      });
    }

    test('a deleted copy of the late alert does not block the next day\'s '
        'payment, and still blocks its own copy', () async {
      final p = FinanceProvider();
      await p.load();
      await p.addImported([_parse(_notif, lateBody, lateAt)]);
      await p.deleteTransaction(p.pendingTransactions.single.id);
      final (next, _, _) = await p.addImported([
        _parse(_inbox, nextBody, nextAt),
      ]);
      expect(next, 1);
      final (copy, _, _) = await p.addImported([
        _parse(_inbox, lateBody, lateAt.add(const Duration(seconds: 20))),
      ]);
      expect(copy, 0);
    });

    test('an alert held up past the night keeps its arrival clock, so the '
        'day\'s later figure stays the balance', () async {
      final held = _parse(
        _inbox,
        'Rs.1,000.00 debited from a/c XX2290 on 05-07-26 to OAKFIELD STORES. '
        'Avl Bal Rs.9,000.00',
        DateTime(2026, 7, 6, 8, 30, 11),
      );
      final onTime = _parse(
        _inbox,
        'Rs.500.00 debited from a/c XX2290 on 05-07-26 to MARROW CAFE. '
        'Avl Bal Rs.8,500.00',
        DateTime(2026, 7, 5, 18, 0, 40),
      );
      expect(held.date, DateTime(2026, 7, 5, 8, 30, 11));
      final p = FinanceProvider();
      await p.load();
      await p.addImported([onTime]);
      await p.addImported([held]);
      await p.confirmAllPending();
      expect(p.accountBalance(p.accountForKey(held.acctKey)!), 8500);
    });
  });

  test('one reference on two inbox alerts stating different balances is '
      'two payments', () async {
    const first =
        'Rs.250.00 debited from a/c XX6104 for standing order Ref '
        '7781203345. Avl Bal Rs.4,750.00';
    const second =
        'Rs.250.00 debited from a/c XX6104 for standing order Ref '
        '7781203345. Avl Bal Rs.4,500.00';
    final p = FinanceProvider();
    await p.load();
    await p.addImported([_parse(_inbox, first, DateTime(2026, 7, 1, 6, 0, 9))]);
    final (added, _, _) = await p.addImported([
      _parse(_inbox, second, DateTime(2026, 7, 2, 6, 0, 13)),
    ]);
    expect(added, 1);
    final held = p.reviewQueue(const {}).held[HoldReason.duplicate] ?? [];
    expect(held.map((t) => t.balanceAfter), contains(4500));
    // A notification copy states no balance the check trusts: one alert.
    final (copy, _, _) = await p.addImported([
      _parse(_notif, second, DateTime(2026, 7, 2, 6, 1, 40)),
    ]);
    expect(copy, 0);
  });

  test('a message read again for the overlap is not noted as unreadable '
      'again', () async {
    final now = DateTime.now();
    final sms = _FakeSms();
    final service = SmsImportService(
      source: sms,
      notifications: _NoNotifications(),
    );
    sms.inbox = [
      SmsMessage(
        sender: _inbox,
        body: 'Rs.88.00 debited from a/c XX6630 to SORREL PANTRY',
        date: now.subtract(const Duration(hours: 3)),
      ),
      SmsMessage(
        sender: _inbox,
        body:
            'Your A/c XX6630 has been debited. Avl Bal Rs.7,310.00 as of now.',
        date: now.subtract(const Duration(hours: 2)),
      ),
    ];
    final p = FinanceProvider();
    await p.load();
    await service.run(p);
    expect((await ImportHealth.load()).banks['HDFC']!.unread, hasLength(1));
    // The bank's list trimmed or pruned since: the next scan's overlap
    // re-reads the message and must not put it back.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kImportHealthKey);
    await service.run(p);
    expect((await ImportHealth.load()).banks['HDFC'], isNull);
  });
}
