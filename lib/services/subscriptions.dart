import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import 'recurring_detector.dart';

/// Past its predicted date by more than this, a payment counts as stopped.
/// The Upcoming card drops a pattern at the same point.
const int kSubscriptionGraceDays = 7;

/// A price change this small is rounding or tax, not a rise worth flagging.
const double kPriceRiseMinPct = 0.05;
const double kPriceRiseMinAmount = 10;

/// One regular payment on the Subscriptions list.
class SubscriptionItem {
  final RecurringHit hit;

  /// What it costs over a year at its usual amount and interval.
  final double yearly;

  /// Set when the last payment was clearly above the one before it.
  final ({double amount, DateTime since})? priceRise;

  const SubscriptionItem({
    required this.hit,
    required this.yearly,
    required this.priceRise,
  });

  double get monthly => yearly / 12;

  /// The payee identity, for the Transactions search deep link.
  String get identity => hit.key.substring(hit.key.indexOf('|') + 1);
}

/// The Subscriptions list: detected monthly expenses, split by whether they
/// still charge. Hidden ones share the Upcoming card's hide list.
class SubscriptionSummary {
  /// Still charging, soonest next payment first.
  final List<SubscriptionItem> active;

  /// Missed their date by more than [kSubscriptionGraceDays]; most recently
  /// paid first.
  final List<SubscriptionItem> stopped;

  /// Hidden by the user, whether active or stopped.
  final List<SubscriptionItem> hidden;

  const SubscriptionSummary({
    required this.active,
    required this.stopped,
    required this.hidden,
  });

  /// Only the active ones: a stopped payment no longer costs anything.
  double get monthlyTotal => active.fold(0, (s, i) => s + i.monthly);
  double get yearlyTotal => active.fold(0, (s, i) => s + i.yearly);

  bool get isEmpty => active.isEmpty && stopped.isEmpty && hidden.isEmpty;
}

SubscriptionSummary buildSubscriptions(
  List<Tx> confirmed, {
  required DateTime now,
  MerchantAliasLookup? alias,
  Set<String> hidden = const {},
}) {
  final active = <SubscriptionItem>[];
  final stopped = <SubscriptionItem>[];
  final hiddenItems = <SubscriptionItem>[];
  for (final h in detectRecurringPatterns(confirmed, now: now, alias: alias)) {
    if (h.type != TxType.expense) continue;
    final item = SubscriptionItem(
      hit: h,
      yearly: h.expectedAmount * 365 / h.intervalDays,
      priceRise: _priceRise(h),
    );
    if (hidden.contains(h.key)) {
      hiddenItems.add(item);
    } else if (h.daysUntil(now) >= -kSubscriptionGraceDays) {
      active.add(item);
    } else {
      stopped.add(item);
    }
  }
  // Patterns arrive soonest-due first, which suits the active list; the
  // stopped ones read best by when they were last paid.
  stopped.sort((a, b) => b.hit.lastDate.compareTo(a.hit.lastDate));
  return SubscriptionSummary(
    active: active,
    stopped: stopped,
    hidden: hiddenItems,
  );
}

/// [buildSubscriptions] over [finance]'s confirmed rows, computed once per
/// (ledger revision, hide list, day) and shared by every screen that shows
/// it — the Cockpit hub stays mounted under the Subscriptions tab, and the
/// Breakdown line asks too, so each would otherwise rerun detection on the
/// same change.
SubscriptionSummary cachedSubscriptions(
  FinanceProvider finance,
  Set<String> hidden,
) {
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  final hiddenKey = hiddenListKey(hidden);
  final c = _cache;
  if (c != null &&
      identical(c.rev, finance.revision) &&
      c.hidden == hiddenKey &&
      c.day == day) {
    return c.summary;
  }
  final summary = buildSubscriptions(
    finance.transactions,
    now: now,
    alias: finance.merchantAlias,
    hidden: hidden,
  );
  _cache = (
    rev: finance.revision,
    hidden: hiddenKey,
    day: day,
    summary: summary,
  );
  return summary;
}

({Object rev, String hidden, DateTime day, SubscriptionSummary summary})?
_cache;

/// The hide list as a comparable value: the settings getter hands out a
/// fresh set on every call, so screens select on this instead.
String hiddenListKey(Set<String> hidden) =>
    (hidden.toList()..sort()).join('\n');

({double amount, DateTime since})? _priceRise(RecurringHit h) {
  final history = h.history;
  if (history.length < 2) return null;
  final last = history.last.amount;
  final previous = history[history.length - 2];
  final rise = last - previous.amount;
  if (rise < kPriceRiseMinAmount || rise < previous.amount * kPriceRiseMinPct) {
    return null;
  }
  return (amount: rise, since: previous.date);
}
