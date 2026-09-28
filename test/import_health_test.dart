import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:expense_tracker/models/transaction.dart';
import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/services/import_health.dart';
import 'package:expense_tracker/services/notification_source.dart';
import 'package:expense_tracker/services/sms_import_service.dart';
import 'package:expense_tracker/services/sms_parser.dart';
import 'package:expense_tracker/services/sms_source.dart';

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

/// Alerts that look like bank transactions but cannot be read, and banks
/// that went quiet: what the Overview's import warning is built from.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    setCustomCategories(const []);
    setBuiltinOverrides(const {});
  });

  // The only rupee figure is the balance: the parser refuses to guess.
  const unreadable =
      'Your A/c XX1234 has been debited. Avl Bal Rs.5,000.00 as of today.';
  const readable = 'Rs.450.00 debited from A/c XX1234 on 20-09-26 to ZOMATO.';

  group('looksUnreadable', () {
    test('a bank alert the parser cannot read', () {
      expect(
        SmsTxnParser.parse('VM-HDFCBK', unreadable, DateTime(2026, 9, 20)),
        isNull,
      );
      expect(SmsTxnParser.looksUnreadable('VM-HDFCBK', unreadable), isTrue);
    });

    test('not a message the parser reads', () {
      expect(
        SmsTxnParser.parse('VM-HDFCBK', readable, DateTime(2026, 9, 20)),
        isNotNull,
      );
      expect(SmsTxnParser.looksUnreadable('VM-HDFCBK', readable), isFalse);
    });

    test('not an OTP, a promotion or a personal number', () {
      expect(
        SmsTxnParser.looksUnreadable(
          'VM-HDFCBK',
          '123456 is your OTP for a txn of Rs.450 debited. Do not share.',
        ),
        isFalse,
      );
      expect(
        SmsTxnParser.looksUnreadable('+919876543210', unreadable),
        isFalse,
      );
    });

    test('a notification brand sender only when relaxed', () {
      expect(SmsTxnParser.looksUnreadable('HDFC Bank', unreadable), isFalse);
      expect(
        SmsTxnParser.looksUnreadable(
          'HDFC Bank',
          unreadable,
          relaxedSender: true,
        ),
        isTrue,
      );
    });
  });

  group('recordUnreadable', () {
    test('counts one alert once, and caps what it keeps', () async {
      final t0 = DateTime(2026, 9, 20, 10);
      await ImportHealth.recordUnreadable([
        (sender: 'VM-HDFCBK', body: unreadable, date: t0),
      ], now: t0);
      // A re-scan of the same window, and the alert's notification copy a
      // minute later from the messaging app.
      await ImportHealth.recordUnreadable([
        (sender: 'VM-HDFCBK', body: unreadable, date: t0),
        (
          sender: 'HDFC Bank',
          body: unreadable,
          date: t0.add(const Duration(minutes: 1)),
        ),
      ], now: t0);
      var state = await ImportHealth.load(now: t0);
      expect(state.banks['HDFC']!.unread.map((u) => u.at), [t0]);
      await ImportHealth.recordUnreadable([
        for (var i = 1; i <= 40; i++)
          (
            sender: 'AD-HDFCBK',
            body: '$unreadable $i',
            date: t0.add(Duration(minutes: 10 * i)),
          ),
      ], now: t0);
      state = await ImportHealth.load(now: t0);
      final h = state.banks['HDFC']!;
      expect(h.unread, hasLength(kMaxUnreadTimes));
      expect(h.samples, hasLength(kMaxUnreadSamples));
      // The newest are kept.
      expect(h.samples.last.body, endsWith(' 40'));
    });

    test('long texts are cut to the sample length', () async {
      final t0 = DateTime(2026, 9, 20);
      await ImportHealth.recordUnreadable([
        (sender: 'VM-HDFCBK', body: 'x' * 1000, date: t0),
      ], now: t0);
      final h = (await ImportHealth.load(now: t0)).banks['HDFC']!;
      expect(h.samples.single.body.length, kMaxSampleChars);
    });

    test('alerts older than the cutoff are not kept', () async {
      final now = DateTime(2026, 9, 28);
      await ImportHealth.recordUnreadable([
        (sender: 'VM-HDFCBK', body: unreadable, date: DateTime(2026, 6, 1)),
      ], now: now);
      expect((await ImportHealth.load()).banks, isEmpty);
    });

    test('Delete all data removes the stored texts', () async {
      final t0 = DateTime.now();
      await ImportHealth.recordUnreadable([
        (sender: 'VM-HDFCBK', body: unreadable, date: t0),
      ]);
      final finance = FinanceProvider();
      await finance.load();
      await finance.clearAll();
      expect((await ImportHealth.load()).banks, isEmpty);
    });
  });

  group('warnings', () {
    final now = DateTime(2026, 9, 28, 12);

    ImportHealthState state(
      List<DateTime> unread, {
      DateTime? dismissed,
      DateTime? seen,
    }) => ImportHealthState({
      'HDFC': BankHealth(
        bank: 'HDFC',
        unread: [for (final d in unread) (at: d, seen: seen ?? d)],
        dismissedAt: dismissed,
      ),
    });

    test('two unreadable alerts in 14 days warn, one does not', () {
      final one = buildImportWarnings(
        state([DateTime(2026, 9, 25)]),
        const [],
        now,
      );
      expect(one, isEmpty);
      final two = buildImportWarnings(
        state([
          DateTime(2026, 9, 1),
          DateTime(2026, 9, 20),
          DateTime(2026, 9, 25),
        ]),
        const [],
        now,
      );
      expect(two.single.kind, ImportWarningKind.unreadable);
      expect(two.single.count, 2);
      expect(two.single.since, DateTime(2026, 9, 20));
    });

    test('a dismissal holds until an alert seen after it', () {
      final unread = [DateTime(2026, 9, 20), DateTime(2026, 9, 25)];
      expect(
        buildImportWarnings(
          state(unread, dismissed: DateTime(2026, 9, 26)),
          const [],
          now,
        ),
        isEmpty,
      );
      // Sent before the dismissal, but a Weekly import saw them after it.
      expect(
        buildImportWarnings(
          state(
            unread,
            dismissed: DateTime(2026, 9, 26),
            seen: DateTime(2026, 9, 27),
          ),
          const [],
          now,
        ),
        hasLength(1),
      );
    });

    test(
      'a silent bank warns until dismissed, and again after a new alert',
      () {
        final quiet = BankSilence(
          bank: 'ICICI',
          lastAlert: DateTime(2026, 9, 10),
          usualGapDays: 3,
        );
        expect(
          buildImportWarnings(ImportHealthState.empty, [
            quiet,
          ], now).single.kind,
          ImportWarningKind.silent,
        );
        final dismissed = ImportHealthState({
          'ICICI': BankHealth(
            bank: 'ICICI',
            dismissedAt: DateTime(2026, 9, 26),
          ),
        });
        expect(buildImportWarnings(dismissed, [quiet], now), isEmpty);
        final later = BankSilence(
          bank: 'ICICI',
          lastAlert: DateTime(2026, 9, 27),
          usualGapDays: 3,
        );
        expect(buildImportWarnings(dismissed, [later], now), hasLength(1));
      },
    );

    test('a bank with both shows once, as unreadable', () {
      final both = buildImportWarnings(
        state([DateTime(2026, 9, 20), DateTime(2026, 9, 25)]),
        [
          BankSilence(
            bank: 'HDFC',
            lastAlert: DateTime(2026, 9, 10),
            usualGapDays: 3,
          ),
        ],
        now,
      );
      expect(both.single.kind, ImportWarningKind.unreadable);
    });
  });
  group('detectSilentBanks', () {
    Tx sms(String sender, DateTime date, [TxSource source = TxSource.sms]) =>
        Tx(
          id: 'id$sender${date.millisecondsSinceEpoch}',
          type: TxType.expense,
          categoryId: 'other_expense',
          amount: 100,
          note: '',
          date: date,
          source: source,
          sender: sender,
        );

    List<Tx> every(String sender, int gap, DateTime last, int count) => [
      for (var i = 0; i < count; i++)
        sms(sender, last.subtract(Duration(days: gap * i))),
    ];

    test('regular alerts, then 12 quiet days', () {
      final rows = every('VM-HDFCBK', 3, DateTime(2026, 9, 16), 15);
      final silent = detectSilentBanks(
        rows,
        DateTime(2026, 9, 28),
        scannedUntil: DateTime(2026, 9, 28),
      );
      expect(silent.single.bank, 'HDFC');
      expect(silent.single.usualGapDays, 3);
    });

    test('not while within three usual gaps', () {
      final rows = every('VM-HDFCBK', 3, DateTime(2026, 9, 20), 15);
      expect(
        detectSilentBanks(
          rows,
          DateTime(2026, 9, 28),
          scannedUntil: DateTime(2026, 9, 28),
        ),
        isEmpty,
      );
    });

    test('not for a bank with only a few alerts', () {
      final rows = every('VM-HDFCBK', 10, DateTime(2026, 9, 1), 4);
      expect(
        detectSilentBanks(
          rows,
          DateTime(2026, 9, 28),
          scannedUntil: DateTime(2026, 9, 28),
        ),
        isEmpty,
      );
    });

    test('not for an account quiet for over 60 days', () {
      final rows = every('VM-HDFCBK', 3, DateTime(2026, 7, 20), 15);
      expect(
        detectSilentBanks(
          rows,
          DateTime(2026, 9, 28),
          scannedUntil: DateTime(2026, 9, 28),
        ),
        isEmpty,
      );
    });

    test('SMS and notification senders of one bank count together', () {
      final rows = [
        // Each alone alerts every 6 days and is not yet 3 gaps quiet;
        // together they alert every 3 days, now 15 days quiet.
        ...every('VM-HDFCBK', 6, DateTime(2026, 9, 10), 6),
        ...every('HDFC Bank', 6, DateTime(2026, 9, 13), 6),
      ];
      expect(
        detectSilentBanks(
          rows,
          DateTime(2026, 9, 28),
          scannedUntil: DateTime(2026, 9, 28),
        ).map((s) => s.bank),
        ['HDFC'],
      );
    });

    test('rows typed in by hand never count', () {
      final rows = [
        for (final t in every('VM-HDFCBK', 3, DateTime(2026, 9, 16), 15))
          sms(t.sender, t.date, TxSource.manual),
      ];
      expect(
        detectSilentBanks(
          rows,
          DateTime(2026, 9, 28),
          scannedUntil: DateTime(2026, 9, 28),
        ),
        isEmpty,
      );
    });
  });

  test('silence counts only up to the last inbox scan', () {
    Tx sms(DateTime d) => Tx(
      id: 'x${d.millisecondsSinceEpoch}',
      type: TxType.expense,
      categoryId: 'other_expense',
      amount: 1,
      note: '',
      date: d,
      source: TxSource.sms,
      sender: 'VM-HDFCBK',
    );
    final rows = [
      for (var i = 0; i < 15; i++)
        sms(DateTime(2026, 9, 16).subtract(Duration(days: 3 * i))),
    ];
    // Auto-import off: nothing read since the 18th.
    expect(
      detectSilentBanks(
        rows,
        DateTime(2026, 9, 28),
        scannedUntil: DateTime(2026, 9, 18),
      ),
      isEmpty,
    );
    // Never scanned: nothing to say.
    expect(
      detectSilentBanks(rows, DateTime(2026, 9, 28), scannedUntil: null),
      isEmpty,
    );
  });

  test('a promotion quoting a limit is not an unreadable alert', () {
    const promo =
        'Congratulations! Your credit card has an available limit of '
        'Rs.1,50,000 that can be used on EMI. Apply now.';
    expect(SmsTxnParser.looksUnreadable('VM-HDFCBK', promo), isFalse);
  });

  test('loading drops entries past the cutoff', () async {
    final t0 = DateTime(2026, 9, 20);
    await ImportHealth.recordUnreadable([
      (sender: 'VM-HDFCBK', body: unreadable, date: t0),
    ], now: t0);
    final later = t0.add(const Duration(days: kSilenceGiveUpDays + 1));
    final h = (await ImportHealth.load(now: later)).banks['HDFC']!;
    expect(h.unread, isEmpty);
    expect(h.samples, isEmpty);
  });

  test('a link footer does not hide an unreadable alert', () {
    expect(
      SmsTxnParser.looksUnreadable(
        'VM-KOTAKB',
        '$unreadable Not you? https://kotak.com/fraud',
      ),
      isTrue,
    );
  });

  test('an import records the alerts it could not read', () async {
    final inbox = _Inbox();
    final service = SmsImportService(
      source: inbox,
      notifications: _NoNotifications(),
    );
    final now = DateTime.now();
    inbox.inbox = [
      SmsMessage(
        sender: 'VM-HDFCBK',
        body: readable,
        date: now.subtract(const Duration(hours: 3)),
      ),
      SmsMessage(
        sender: 'VM-HDFCBK',
        body: unreadable,
        date: now.subtract(const Duration(hours: 2)),
      ),
      SmsMessage(
        sender: 'AD-HDFCBK',
        body: '$unreadable Ref 2',
        date: now.subtract(const Duration(hours: 1)),
      ),
    ];
    final finance = FinanceProvider();
    await finance.load();
    final result = await service.run(
      finance,
      lookback: const Duration(days: 1),
    );
    expect(result!.imported, 1);
    var h = (await ImportHealth.load()).banks['HDFC']!;
    expect(h.unread, hasLength(2));
    // The same window again adds nothing.
    await service.run(finance, lookback: const Duration(days: 1));
    h = (await ImportHealth.load()).banks['HDFC']!;
    expect(h.unread, hasLength(2));
  });
}
