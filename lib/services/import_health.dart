import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transaction.dart';
import 'sms_parser.dart';

/// Whether bank alerts are still importing, per bank: alerts that looked
/// like transactions but could not be read (often a changed SMS format),
/// and banks that sent alerts regularly and then went quiet. The Overview
/// banner reads [buildImportWarnings].
///
/// Only the unreadable alerts are stored (prefs key `import_health_v1`,
/// device only, never in backups, removed by Delete all data); silence is
/// read from the ledger itself.

const String kImportHealthKey = 'import_health_v1';

/// When the SMS inbox was last read up to (SmsImportService's marker).
/// Silence counts only up to it: a bank is not quiet because nothing was
/// imported.
const String kSmsLastScanKey = 'sms_last_scan_millis';

/// Timestamps kept per bank; samples kept per bank; sample length.
const int kMaxUnreadTimes = 30;
const int kMaxUnreadSamples = 3;
const int kMaxSampleChars = 300;

/// Unreadable alerts warn from this many within [kUnreadWindowDays].
const int kUnreadThreshold = 2;
const int kUnreadWindowDays = 14;

/// A bank silent this long is taken as closed, and no longer warned about.
const int kSilenceGiveUpDays = 60;

/// One bank alert reaches the inbox and, as a notification copy, the
/// capture buffer, a moment apart: within this they count as one. The
/// ledger's duplicate check uses the same window.
const Duration kSameAlertWindow = Duration(minutes: 3);

/// Bumped whenever this isolate writes the record or the SMS scan marker,
/// so the Overview banner reads them again even when an import added no
/// rows (the ledger then does not change).
final ValueNotifier<int> importHealthChanged = ValueNotifier<int>(0);

typedef UnreadSample = ({DateTime at, String sender, String body});

/// An unreadable alert: when it was sent, and when this app first saw it
/// (a Weekly import or a range scan can see it days later).
typedef UnreadHit = ({DateTime at, DateTime seen});

/// An alert the parser could not read, as the import hands it over.
typedef ImportMiss = ({String sender, String body, DateTime date});

class BankHealth {
  final String bank;

  /// Each unreadable alert, oldest first.
  final List<UnreadHit> unread;

  /// The newest few unreadable texts, oldest first.
  final List<UnreadSample> samples;
  final DateTime? dismissedAt;

  const BankHealth({
    required this.bank,
    this.unread = const [],
    this.samples = const [],
    this.dismissedAt,
  });

  BankHealth copyWith({
    List<UnreadHit>? unread,
    List<UnreadSample>? samples,
    DateTime? dismissedAt,
  }) => BankHealth(
    bank: bank,
    unread: unread ?? this.unread,
    samples: samples ?? this.samples,
    dismissedAt: dismissedAt ?? this.dismissedAt,
  );

  Map<String, dynamic> toJson() => {
    'unread': [
      for (final u in unread)
        [u.at.millisecondsSinceEpoch, u.seen.millisecondsSinceEpoch],
    ],
    'samples': [
      for (final s in samples)
        {'at': s.at.millisecondsSinceEpoch, 'sender': s.sender, 'body': s.body},
    ],
    if (dismissedAt != null) 'dismissedAt': dismissedAt!.millisecondsSinceEpoch,
  };

  factory BankHealth.fromJson(String bank, Map<String, dynamic> json) {
    DateTime? at(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    final unread = <UnreadHit>[];
    for (final v in json['unread'] as List? ?? const []) {
      // [sent, seen], or a bare send time (seen then).
      final sent = at(v is List && v.isNotEmpty ? v[0] : v);
      if (sent == null) continue;
      final seen = v is List && v.length > 1 ? at(v[1]) : null;
      unread.add((at: sent, seen: seen ?? sent));
    }
    unread.sort((a, b) => a.at.compareTo(b.at));
    return BankHealth(
      bank: bank,
      unread: unread,
      samples: [
        for (final s in json['samples'] as List? ?? const [])
          if (s is Map && at(s['at']) != null)
            (
              at: at(s['at'])!,
              sender: '${s['sender'] ?? ''}',
              body: '${s['body'] ?? ''}',
            ),
      ],
      dismissedAt: at(json['dismissedAt']),
    );
  }
}

class ImportHealthState {
  final Map<String, BankHealth> banks;
  const ImportHealthState(this.banks);
  static const empty = ImportHealthState({});
}

/// Reads and writes [kImportHealthKey]. Every call reloads from prefs, so a
/// background engine's writes are seen the next time the app asks.
class ImportHealth {
  /// The record, without anything older than [kSilenceGiveUpDays]: a bank
  /// with no new misses would otherwise keep its sample texts for good.
  static Future<ImportHealthState> load({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final cutoff = (now ?? DateTime.now()).subtract(
      const Duration(days: kSilenceGiveUpDays),
    );
    final state = _decode(prefs.getString(kImportHealthKey));
    var pruned = false;
    final banks = <String, BankHealth>{};
    for (final e in state.banks.entries) {
      final h = e.value;
      final unread = [
        for (final u in h.unread)
          if (!u.at.isBefore(cutoff)) u,
      ];
      final samples = [
        for (final s in h.samples)
          if (!s.at.isBefore(cutoff)) s,
      ];
      if (unread.length != h.unread.length ||
          samples.length != h.samples.length) {
        pruned = true;
      }
      banks[e.key] = h.copyWith(unread: unread, samples: samples);
    }
    if (!pruned) return state;
    final kept = ImportHealthState(banks);
    await prefs.setString(
      kImportHealthKey,
      jsonEncode({for (final e in banks.entries) e.key: e.value.toJson()}),
    );
    return kept;
  }

  /// When the SMS inbox was last read up to, or null before the first scan.
  static Future<DateTime?> lastScan() async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(kSmsLastScanKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  static ImportHealthState _decode(String? raw) {
    if (raw == null) return ImportHealthState.empty;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return ImportHealthState({
        for (final e in map.entries)
          if (e.value is Map)
            e.key: BankHealth.fromJson(
              e.key,
              Map<String, dynamic>.from(e.value as Map),
            ),
      });
    } catch (e) {
      // A damaged record only costs the warning history.
      debugPrint('Import health unreadable: $e');
      return ImportHealthState.empty;
    }
  }

  static Future<void> _save(ImportHealthState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      kImportHealthKey,
      jsonEncode({
        for (final e in state.banks.entries) e.key: e.value.toJson(),
      }),
    );
    changed();
  }

  /// Tells the banner to read the record and the scan marker again.
  static void changed() => importHealthChanged.value++;

  /// Adds alerts the parser could not read. An alert already held (a
  /// re-scan of a date range, or the same alert's notification copy) is
  /// counted once: one per bank within [kSameAlertWindow].
  static Future<void> recordUnreadable(
    List<ImportMiss> misses, {
    DateTime? now,
  }) async {
    if (misses.isEmpty) return;
    final seenAt = now ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final banks = {..._decode(prefs.getString(kImportHealthKey)).banks};
    final cutoff = seenAt.subtract(const Duration(days: kSilenceGiveUpDays));
    var changed = false;
    for (final m in misses) {
      final bank = SmsTxnParser.dedupBankOf(m.sender);
      if (bank.isEmpty || m.date.isBefore(cutoff)) continue;
      final was = banks[bank] ?? BankHealth(bank: bank);
      // Stored to the millisecond.
      final at = DateTime.fromMillisecondsSinceEpoch(
        m.date.millisecondsSinceEpoch,
      );
      if (was.unread.any(
        (u) => u.at.difference(at).abs() <= kSameAlertWindow,
      )) {
        continue;
      }
      final unread = [...was.unread, (at: at, seen: seenAt)]
        ..sort((a, b) => a.at.compareTo(b.at));
      final body = m.body.length > kMaxSampleChars
          ? m.body.substring(0, kMaxSampleChars)
          : m.body;
      final samples = [
        for (final s in was.samples)
          if (!s.at.isBefore(cutoff)) s,
        (at: at, sender: m.sender, body: body),
      ]..sort((a, b) => a.at.compareTo(b.at));
      final kept = [
        for (final u in unread)
          if (!u.at.isBefore(cutoff)) u,
      ];
      banks[bank] = was.copyWith(
        unread: kept.length > kMaxUnreadTimes
            ? kept.sublist(kept.length - kMaxUnreadTimes)
            : kept,
        samples: samples.length > kMaxUnreadSamples
            ? samples.sublist(samples.length - kMaxUnreadSamples)
            : samples,
      );
      changed = true;
    }
    if (changed) await _save(ImportHealthState(banks));
  }

  /// Hides [bank]'s current warning; an unreadable alert seen after this,
  /// or for a silent bank a new alert and a fresh silence, brings it back.
  static Future<void> dismiss(String bank, DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final banks = {..._decode(prefs.getString(kImportHealthKey)).banks};
    banks[bank] = (banks[bank] ?? BankHealth(bank: bank)).copyWith(
      dismissedAt: now,
    );
    await _save(ImportHealthState(banks));
  }
}

/// A bank that alerted regularly and then stopped.
class BankSilence {
  final String bank;
  final DateTime lastAlert;
  final int usualGapDays;
  const BankSilence({
    required this.bank,
    required this.lastAlert,
    required this.usualGapDays,
  });
}

/// Banks with at least 5 alerts in the 120 days before their latest one,
/// spread over 30 days or more, whose latest alert is older than 3 times
/// their usual (median) gap, and at least 10 days, but within the last
/// [kSilenceGiveUpDays]. [rows] should hold imported rows, confirmed and
/// waiting for review; others are ignored.
///
/// Quiet days count up to [scannedUntil], the last inbox scan: with
/// Auto-import off, or Weekly and the app unopened, nothing arrived because
/// nothing was read, not because the bank stopped. None before a first
/// scan.
List<BankSilence> detectSilentBanks(
  Iterable<Tx> rows,
  DateTime now, {
  required DateTime? scannedUntil,
}) {
  if (scannedUntil == null) return const [];
  final until = scannedUntil.isAfter(now) ? now : scannedUntil;
  final today = DateTime(until.year, until.month, until.day);
  final byBank = <String, List<DateTime>>{};
  for (final t in rows) {
    if (t.source != TxSource.sms || t.sender.trim().isEmpty) continue;
    final bank = SmsTxnParser.dedupBankOf(t.sender);
    if (bank.isEmpty) continue;
    (byBank[bank] ??= []).add(t.date);
  }
  final out = <BankSilence>[];
  for (final e in byBank.entries) {
    final dates = e.value..sort();
    final last = dates.last;
    final from = last.subtract(const Duration(days: 120));
    final recent = [
      for (final d in dates)
        if (!d.isBefore(from)) d,
    ];
    if (recent.length < 5) continue;
    if (recent.last.difference(recent.first).inDays < 30) continue;
    final days = <DateTime>{
      for (final d in recent) DateTime(d.year, d.month, d.day),
    }.toList()..sort();
    final gaps = [
      for (var i = 1; i < days.length; i++)
        days[i].difference(days[i - 1]).inDays,
    ]..sort();
    if (gaps.isEmpty) continue;
    final median = gaps[gaps.length ~/ 2] < 1 ? 1 : gaps[gaps.length ~/ 2];
    final quiet = today
        .difference(DateTime(last.year, last.month, last.day))
        .inDays;
    final threshold = median * 3 < 10 ? 10 : median * 3;
    if (quiet <= threshold || quiet > kSilenceGiveUpDays) continue;
    out.add(BankSilence(bank: e.key, lastAlert: last, usualGapDays: median));
  }
  return out;
}

enum ImportWarningKind { unreadable, silent }

class ImportWarning {
  final String bank;
  final ImportWarningKind kind;

  /// Unreadable alerts in the window; 0 for silence.
  final int count;

  /// The first unreadable alert in the window, or the last alert read.
  final DateTime since;
  final int usualGapDays;
  final BankHealth? health;

  const ImportWarning({
    required this.bank,
    required this.kind,
    required this.count,
    required this.since,
    this.usualGapDays = 0,
    this.health,
  });
}

/// What the Overview banner should say, most urgent first: unreadable
/// alerts (2 or more sent in 14 days and seen after a dismissal), then silent
/// banks (unless dismissed since their last alert). A bank with both shows
/// once, as unreadable.
List<ImportWarning> buildImportWarnings(
  ImportHealthState health,
  List<BankSilence> silent,
  DateTime now,
) {
  final windowStart = now.subtract(const Duration(days: kUnreadWindowDays));
  final out = <ImportWarning>[];
  final seen = <String>{};
  for (final h in health.banks.values) {
    final dismissed = h.dismissedAt;
    // Seen, not sent, after the dismissal: an alert sent before it but
    // imported later is still news.
    final hits = [
      for (final u in h.unread)
        if (!u.at.isBefore(windowStart) &&
            (dismissed == null || u.seen.isAfter(dismissed)))
          u.at,
    ];
    if (hits.length < kUnreadThreshold) continue;
    out.add(
      ImportWarning(
        bank: h.bank,
        kind: ImportWarningKind.unreadable,
        count: hits.length,
        since: hits.first,
        health: h,
      ),
    );
    seen.add(h.bank);
  }
  out.sort((a, b) => b.count.compareTo(a.count));
  for (final s in silent) {
    if (seen.contains(s.bank)) continue;
    final dismissed = health.banks[s.bank]?.dismissedAt;
    if (dismissed != null && !s.lastAlert.isAfter(dismissed)) continue;
    out.add(
      ImportWarning(
        bank: s.bank,
        kind: ImportWarningKind.silent,
        count: 0,
        since: s.lastAlert,
        usualGapDays: s.usualGapDays,
        health: health.banks[s.bank],
      ),
    );
  }
  return out;
}

const _bankNames = {
  'HDFC': 'HDFC',
  'ICICI': 'ICICI',
  'SBI': 'SBI',
  'SBIUPI': 'SBI',
  'SBIINB': 'SBI',
  'AXIS': 'Axis',
  'AXISBK': 'Axis',
  'KOTAK': 'Kotak',
  'IDFC': 'IDFC First',
  'IDFCFB': 'IDFC First',
  'YESBNK': 'Yes Bank',
  'INDUS': 'IndusInd',
  'INDBNK': 'Indian Bank',
  'IDBI': 'IDBI',
  'CENTBK': 'Central Bank',
  'MAHABK': 'Bank of Maharashtra',
  'PNB': 'PNB',
  'BOB': 'Bank of Baroda',
  'BOI': 'Bank of India',
  'CANBNK': 'Canara',
  'UNION': 'Union Bank',
  'UCO': 'UCO',
  'IOB': 'IOB',
  'FEDBNK': 'Federal Bank',
  'RBL': 'RBL',
  'AUBANK': 'AU Bank',
  'DBS': 'DBS',
  'HSBC': 'HSBC',
  'CITI': 'Citi',
  'SCB': 'Standard Chartered',
  'PAYTM': 'Paytm',
  'PHONPE': 'PhonePe',
  'GPAY': 'Google Pay',
  'AMAZONP': 'Amazon Pay',
  'MOBIKW': 'MobiKwik',
  'SLICEIT': 'slice',
  'ONECRD': 'OneCard',
};

/// A display name for a [SmsTxnParser.dedupBankOf] code.
String bankLabel(String code) => _bankNames[code.toUpperCase()] ?? code;
