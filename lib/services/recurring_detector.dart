import '../models/subscription_cycle.dart';
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

  /// Median gap between occurrences (an early payment's gaps left out), in
  /// days; for a marked merchant, its cycle's length.
  final int intervalDays;

  /// Predicted next occurrence: [lastDate] + [intervalDays] (two intervals
  /// after the payment before it when the newest was paid early), or one
  /// [cycle] after it for a marked merchant.
  final DateTime nextDue;

  /// Every occurrence the pattern is built from, one per day, oldest first
  /// — what a price rise is read from.
  final List<({DateTime date, double amount})> history;

  /// The cycle when the user marked this merchant as a subscription (it
  /// then counts from its first payment); null when it was spotted.
  final SubscriptionCycle? cycle;

  bool get pinned => cycle != null;

  const RecurringHit({
    required this.key,
    required this.label,
    required this.categoryId,
    required this.type,
    required this.expectedAmount,
    required this.lastDate,
    required this.intervalDays,
    required this.nextDue,
    this.history = const [],
    this.cycle,
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

/// The direction-less half of [recurringKeyOf]: the normalized merchant
/// text, else the payee typed in Paid to, else the user's note; null when the
/// row carries none. Merchant aliases key on this so one rename covers a
/// payee's debits and refunds alike.
String? merchantIdentityOf(Tx t) {
  if (t.suspectedSpam || isTransferCategory(t.categoryId)) return null;
  // Never key on t.sender — it is the bank's DLT channel, so every debit
  // from the same bank would collapse into one "pattern".
  var identity = alertMerchantOf(t).toLowerCase();
  if (identity.isEmpty) {
    identity = _identityText(t.payee);
    // A payee of one or two characters is too short to key on; the note
    // steps in, as it does for no payee.
    if (identity.length < 3) identity = _identityText(t.note);
  }
  if (identity.length < 3) return null;
  // An identity with no letters is a phone number, VPA number or bank
  // reference ("to 9215676766…"), never a payee — surfacing it as a
  // "merchant" is noise.
  if (!identity.contains(RegExp('[a-z]'))) return null;
  return identity;
}

/// The merchant an imported alert names, as the parser reads it; empty for
/// a manual row or an alert that names none. A row whose alert text is gone
/// (restored from a backup) uses the merchant the backup carried
/// ([Tx.smsMerchant]).
String alertMerchantOf(Tx t) {
  if (t.source != TxSource.sms) return '';
  if (t.smsBody.isEmpty && t.smsMerchant.isNotEmpty) return t.smsMerchant;
  return SmsTxnParser.merchantOf(t.smsText);
}

/// Typed text as an identity: lowercased, every run of other characters one
/// space, trimmed. A payee and a note with the same words match.
String _identityText(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Lookup from a merchant identity ([merchantIdentityOf]) to the user's
/// chosen display name; null when the payee has no alias.
typedef MerchantAliasLookup = String? Function(String identity);

/// Scans [confirmed] (any order) for monthly patterns as of [now], limited
/// to those whose predicted date is within 14 days ahead or 7 days past
/// (older misses mean the pattern likely ended), sorted soonest first. The
/// Upcoming card and the reminder monitor read this.
List<RecurringHit> detectRecurring(
  List<Tx> confirmed, {
  required DateTime now,
  MerchantAliasLookup? alias,
  Map<String, SubscriptionCycle> pinned = const {},
}) => [
  for (final h in detectRecurringPatterns(
    confirmed,
    now: now,
    alias: alias,
    pinned: pinned,
  ))
    if (h.daysUntil(now) <= 14 && h.daysUntil(now) >= -7) h,
];

/// Every monthly pattern in [confirmed] as of [now], whatever its predicted
/// date — the Subscriptions list also shows ones that stopped. Sorted by
/// predicted date, soonest first.
///
/// Qualifies a group when, over the last 12 months and after collapsing
/// same-day repeats: ≥3 occurrences, not counting one paid early; every
/// consecutive gap 20–40 days, except one early payment's 16–19 day gap
/// (the latest one, or one whose next gap makes two cycles of 50–70 days);
/// at least two regular gaps, with a median of 25–35 days.
///
/// A key in [pinned] (marked as a subscription by the user) qualifies from
/// one payment in the last 24 months, whatever the gaps, and is due one
/// cycle after its last payment: a yearly plan paid 11 months ago is still
/// active, one paid 14 months ago shows as stopped.
List<RecurringHit> detectRecurringPatterns(
  List<Tx> confirmed, {
  required DateTime now,
  MerchantAliasLookup? alias,
  Map<String, SubscriptionCycle> pinned = const {},
}) {
  final horizon = DateTime(now.year - 1, now.month, now.day);
  final pinnedHorizon = DateTime(now.year - 2, now.month, now.day);

  final groups = <String, List<Tx>>{};
  // Nothing marked: the older rows can only ever be skipped, so skip them
  // before the (regex-heavy) key.
  final oldest = pinned.isEmpty ? horizon : pinnedHorizon;
  for (final t in foldCategorySplits(confirmed)) {
    if (t.date.isAfter(now) || t.date.isBefore(oldest)) continue;
    final key = recurringKeyOf(t);
    if (key == null) continue;
    if (t.date.isBefore(horizon) && !pinned.containsKey(key)) continue;
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
    final days = byDay.keys.toList()..sort();
    final cycle = pinned[key];
    final int interval;
    final DateTime nextDue;
    if (cycle != null) {
      interval = cycle.approxDays;
      nextDue = cycle.nextAfter(days.last);
    } else {
      if (byDay.length < 3) return;
      final gaps = [
        for (var i = 1; i < days.length; i++)
          days[i].difference(days[i - 1]).inDays,
      ];
      // One payment made early (a bill paid when it arrives) shortens one
      // gap and, unless it is the latest, stretches the next: together they
      // still make two cycles. Only the regular gaps set the interval. A
      // gap under 16 days (paid more than about 15 days early, further
      // than a reminder takes) is an extra purchase, not an early payment.
      final regular = <int>[];
      var early = 0;
      var lastEarly = false;
      for (var i = 0; i < gaps.length; i++) {
        final g = gaps[i];
        if (g >= 20 && g <= 40) {
          regular.add(g);
        } else if (g >= 16 && g < 20 && i == gaps.length - 1) {
          early++;
          lastEarly = true;
        } else if (g >= 16 &&
            g < 20 &&
            g + gaps[i + 1] >= 50 &&
            g + gaps[i + 1] <= 70) {
          early++;
          i++;
        } else {
          return;
        }
      }
      if (early > 1 || byDay.length - early < 3 || regular.length < 2) {
        return;
      }
      interval = _median(regular.map((g) => g.toDouble()).toList()).round();
      if (interval < 25 || interval > 35) return;
      // A latest payment made early paid the cycle due one interval after
      // the payment before it; the next one is due one interval after that.
      nextDue = lastEarly
          ? days[days.length - 2].add(Duration(days: interval * 2))
          : days.last.add(Duration(days: interval));
    }

    final ordered = [for (final d in days) byDay[d]!];
    final latest = ordered.last;
    final lastDay = days.last;

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
        history: [
          for (final (i, t) in ordered.indexed)
            (date: days[i], amount: t.amount),
        ],
        cycle: cycle,
      ),
    );
  });

  // Key as tie-break: sorting every pattern (not just the in-window ones)
  // must not reshuffle same-day hits between runs.
  hits.sort((a, b) {
    final byDate = a.nextDue.compareTo(b.nextDue);
    return byDate != 0 ? byDate : a.key.compareTo(b.key);
  });
  return hits;
}

/// [rows] with each category split ([Tx.splitId]) folded into one row at
/// the payment's total: the bank charged once, so a pattern must see one
/// payment, not one per part. The folded row is the anchor
/// ([compareSplitParts]), so the result does not depend on the order of
/// [rows].
Iterable<Tx> foldCategorySplits(Iterable<Tx> rows) {
  final kept = <String, Tx>{};
  final totals = <String, double>{};
  for (final t in rows) {
    final sid = t.splitId;
    if (sid == null) continue;
    totals[sid] = (totals[sid] ?? 0) + t.amount;
    final k = kept[sid];
    if (k == null || compareSplitParts(t, k) < 0) kept[sid] = t;
  }
  if (totals.isEmpty) return rows;
  return [
    for (final t in rows)
      if (t.splitId == null)
        t
      else if (identical(kept[t.splitId], t))
        t.copyWith(amount: (totals[t.splitId]! * 100).round() / 100),
  ];
}

/// The order of one category split's rows, whatever order they are stored
/// in (a CSV export may write parts before the anchor): the row holding the
/// alert (an SMS row) first, then by id, which for rows the app made is the
/// order they were added. The first row is the anchor.
int compareSplitParts(Tx a, Tx b) {
  final aSms = a.source == TxSource.sms;
  if (aSms != (b.source == TxSource.sms)) return aSms ? -1 : 1;
  return a.id.compareTo(b.id);
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
String merchantDisplayLabel(Tx t, {MerchantAliasLookup? alias}) =>
    merchantLabelOrNull(t, alias: alias) ?? 'Payment';

/// [merchantDisplayLabel] without its "Payment" fallback: null when the row
/// names no merchant, so a "category · merchant" title can drop the part
/// rather than compare against the fallback text. The payee is returned as
/// typed; an alert's merchant and the note are title-cased.
String? merchantLabelOrNull(Tx t, {MerchantAliasLookup? alias}) {
  final named = _aliasLabel(t, alias);
  if (named != null) return named;
  // Mirror recurringKeyOf: the alert's merchant, then the payee, then the
  // user's note.
  final merchant = _alertMerchantLabel(t);
  if (merchant != null) return merchant;
  final payee = t.payee.trim();
  final note = t.note.trim();
  // A payee too short to key on gives way to the note, as in
  // merchantIdentityOf.
  if (payee.isNotEmpty && (_identityText(payee).length >= 3 || note.isEmpty)) {
    return payee;
  }
  return note.isEmpty ? null : _titleCase(note);
}

/// What a list row leads with: the user's alias for its merchant, the
/// payee typed in Paid to, the merchant an alert names, or the note's first
/// line as typed; null when the row names none. A typed payee comes before
/// the alert's merchant, since on an imported row the user typed it to
/// correct or fill in the alert.
String? rowTitleOf(Tx t, {MerchantAliasLookup? alias}) {
  final named = _aliasLabel(t, alias);
  if (named != null) return named;
  final payee = t.payee.trim();
  if (payee.isNotEmpty) return payee;
  final merchant = _alertMerchantLabel(t);
  if (merchant != null) return merchant;
  final line = noteFirstLine(t.note);
  return line.isEmpty ? null : line;
}

/// The first line of [note], trimmed: what a row or a payee suggestion
/// shows of a note, which may run to several lines.
String noteFirstLine(String note) => note.split('\n').first.trim();

/// The user's [alias] for [t]'s merchant identity, or null when there is
/// no lookup, no identity or no name for it.
String? _aliasLabel(Tx t, MerchantAliasLookup? alias) {
  if (alias == null) return null;
  final identity = merchantIdentityOf(t);
  final named = identity == null ? null : alias(identity);
  return named == null || named.isEmpty ? null : named;
}

/// The merchant an imported alert names, title-cased; null for a manual
/// row or an alert that names none.
String? _alertMerchantLabel(Tx t) {
  final m = alertMerchantOf(t);
  return m.isEmpty ? null : _titleCase(m);
}

/// Alert bodies shout in ALL CAPS: each word capitalised, the rest lower.
String _titleCase(String raw) => raw
    .split(RegExp(r'\s+'))
    .map(
      (w) => w.length <= 1
          ? w.toUpperCase()
          : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}',
    )
    .join(' ');
