import '../models/transaction.dart';
import 'sms_parser.dart';

/// Detects roughly-monthly payment patterns (rent, SIPs, EMIs, OTT,
/// utilities) from confirmed history — pure functions, no storage of its
/// own. The dashboard's Upcoming card and the reminder monitor both consume
/// [detectRecurring] output.

/// A detected monthly pattern and its predicted next occurrence.
class RecurringHit {
  /// Stable identity (`"<type>|<merchant>"`) — the hide list and the
  /// reminder dedup markers key on this.
  final String key;

  /// Display name, from the newest row's merchant/note.
  final String label;

  final String categoryId;
  final TxType type;

  /// Median of the last (up to) 3 amounts — utility bills vary, so the
  /// median tracks the current level without chasing one odd month.
  final double expectedAmount;

  /// Date of the newest occurrence.
  final DateTime lastDate;

  /// Median gap between occurrences, in days.
  final int intervalDays;

  /// Predicted next occurrence: [lastDate] + [intervalDays].
  final DateTime nextDue;

  const RecurringHit({
    required this.key,
    required this.label,
    required this.categoryId,
    required this.type,
    required this.expectedAmount,
    required this.lastDate,
    required this.intervalDays,
    required this.nextDue,
  });

  /// Calendar days from [now] to [nextDue]; negative = overdue.
  int daysUntil(DateTime now) =>
      nextDue.difference(DateTime(now.year, now.month, now.day)).inDays;
}

/// Identity key for grouping, or null when the row carries none: transfers
/// (incl. card-bill legs), suspected spam, and rows with neither an
/// extractable merchant nor a usable note.
///
/// The extracted merchant wins for SMS rows; when the body yields none, the
/// user's note steps in — so a consistent note ("EB bill") turns otherwise
/// anonymous imported payments into a detectable pattern.
String? recurringKeyOf(Tx t) {
  final identity = merchantIdentityOf(t);
  return identity == null ? null : '${t.type.name}|$identity';
}

/// The direction-less half of [recurringKeyOf]: the normalized merchant (or
/// note) text, or null when the row carries none. Merchant aliases key on
/// this so one rename covers a payee's debits and refunds alike.
String? merchantIdentityOf(Tx t) {
  if (t.suspectedSpam || isTransferCategory(t.categoryId)) return null;
  // Never key on t.sender — it is the bank's DLT channel, so every debit
  // from the same bank would collapse into one "pattern".
  var identity = t.source == TxSource.sms
      ? SmsTxnParser.merchantOf(t.smsText).toLowerCase()
      : '';
  if (identity.isEmpty) {
    identity = t.note
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }
  if (identity.length < 3) return null;
  // An identity with no letters is a phone number, VPA number or bank
  // reference ("to 9215676766…"), never a payee — surfacing it as a
  // "merchant" is noise.
  if (!identity.contains(RegExp('[a-z]'))) return null;
  return identity;
}

/// Lookup from a merchant identity ([merchantIdentityOf]) to the user's
/// chosen display name; null when the payee has no alias.
typedef MerchantAliasLookup = String? Function(String identity);

/// Scans [confirmed] (any order) for monthly patterns as of [now].
///
/// Qualifies a group when, over the last 12 months and after collapsing
/// same-day repeats: ≥3 occurrences, every consecutive gap 20–40 days, and
/// the median gap 25–35 days. Returned hits are limited to those whose
/// predicted date is within 14 days ahead or 7 days past (older misses mean
/// the pattern likely ended), sorted soonest first.
List<RecurringHit> detectRecurring(
  List<Tx> confirmed, {
  required DateTime now,
  MerchantAliasLookup? alias,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final horizon = DateTime(now.year - 1, now.month, now.day);

  final groups = <String, List<Tx>>{};
  for (final t in confirmed) {
    if (t.date.isBefore(horizon) || t.date.isAfter(now)) continue;
    final key = recurringKeyOf(t);
    if (key == null) continue;
    (groups[key] ??= []).add(t);
  }

  final hits = <RecurringHit>[];
  groups.forEach((key, rows) {
    rows.sort((a, b) => a.date.compareTo(b.date));
    // One occurrence per calendar day: a retried payment or a duplicate
    // alert would otherwise inject a 0-day gap and kill the pattern.
    final byDay = <DateTime, Tx>{};
    for (final t in rows) {
      byDay[DateTime(t.date.year, t.date.month, t.date.day)] = t;
    }
    if (byDay.length < 3) return;
    final days = byDay.keys.toList()..sort();
    final gaps = [
      for (var i = 1; i < days.length; i++)
        days[i].difference(days[i - 1]).inDays,
    ];
    if (gaps.any((g) => g < 20 || g > 40)) return;
    final interval = _median(gaps.map((g) => g.toDouble()).toList()).round();
    if (interval < 25 || interval > 35) return;

    final ordered = [for (final d in days) byDay[d]!];
    final latest = ordered.last;
    final lastDay = days.last;
    final nextDue = lastDay.add(Duration(days: interval));
    final daysUntil = nextDue.difference(today).inDays;
    if (daysUntil > 14 || daysUntil < -7) return;

    final recentAmounts = [
      for (final t in ordered.skip(
        ordered.length <= 3 ? 0 : ordered.length - 3,
      ))
        t.amount,
    ];
    hits.add(
      RecurringHit(
        key: key,
        label: merchantDisplayLabel(latest, alias: alias),
        categoryId: latest.categoryId,
        type: latest.type,
        expectedAmount: _median(recentAmounts),
        lastDate: lastDay,
        intervalDays: interval,
        nextDue: nextDue,
      ),
    );
  });

  hits.sort((a, b) => a.nextDue.compareTo(b.nextDue));
  return hits;
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

/// Human label from a row: the extracted merchant for SMS rows (title-cased
/// — alert bodies shout in ALL CAPS), the note for manual ones. Shared by
/// recurring detection and the merchant spend breakdown. A user [alias] for
/// the row's identity wins over the derived text.
String merchantDisplayLabel(Tx t, {MerchantAliasLookup? alias}) {
  if (alias != null) {
    final identity = merchantIdentityOf(t);
    final named = identity == null ? null : alias(identity);
    if (named != null && named.isNotEmpty) return named;
  }
  var raw = t.source == TxSource.sms
      ? SmsTxnParser.merchantOf(t.smsText)
      : t.note.trim();
  // Mirror recurringKeyOf: an SMS row without an extractable merchant is
  // identified (and therefore labeled) by the user's note.
  if (raw.isEmpty) raw = t.note.trim();
  if (raw.isEmpty) return 'Payment';
  return raw
      .split(RegExp(r'\s+'))
      .map(
        (w) => w.length <= 1
            ? w.toUpperCase()
            : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}',
      )
      .join(' ');
}
