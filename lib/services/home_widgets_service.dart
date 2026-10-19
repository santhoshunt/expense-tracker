import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/contrast.dart';
import '../utils/figma_palette.dart';
import '../utils/format.dart';
import 'big_bills.dart';
import 'budget_widget_service.dart';
import 'card_bill.dart';
import 'recurring_detector.dart';
import 'safe_to_spend.dart';
import 'spend_comparison.dart';
import 'upcoming_items.dart';
import 'weekly_digest.dart';

/// Upcoming rows the widget carries; it shows the first three still due.
const int kUpcomingWidgetRows = 5;

/// Days since 1970-01-01 for [d]'s local calendar date. Kotlin compares
/// these with `LocalDate.now().toEpochDay()`, so "today" and "in 3 days" are
/// worked out on the day the widget draws, not the day the app last ran.
int epochDay(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// Feeds the Month pace, Upcoming, Today and Add, Spending split, Recent,
/// Big bills and This week widgets (HomeWidgets.kt). Like [BudgetWidgetService], Dart
/// computes and native draws; the snapshot carries dates and a usual-by-day
/// curve so the widgets stay right across midnight without the app running.
class HomeWidgetsService {
  static const _dataKey = 'home_widget_data_v1';
  static const _themeKey = 'budget_widget_theme_v1';
  static const _channel = MethodChannel('expense_tracker/sms');

  String? _lastWritten;

  // Recurring detection scans the whole ledger: once per data change or day.
  Object? _hitsRev;
  int? _hitsDay;
  List<RecurringHit> _hits = const [];
  List<RecurringHit> _patterns = const [];

  List<RecurringHit> _recurring(FinanceProvider finance, DateTime now) {
    final day = epochDay(now);
    if (!identical(_hitsRev, finance.revision) || _hitsDay != day) {
      _hitsRev = finance.revision;
      _hitsDay = day;
      // The whole month's, for safe to spend's bills; Upcoming's window of
      // them is what detectRecurring would keep.
      _patterns = detectRecurringPatterns(
        finance.countedTransactions,
        now: now,
        alias: finance.merchantAlias,
        pinned: finance.subscriptionPins,
      );
      _hits = [
        for (final h in _patterns)
          if (h.daysUntil(now) <= 14 && h.daysUntil(now) >= -7) h,
      ];
    }
    return _hits;
  }

  Future<void> sync(FinanceProvider finance, SettingsProvider settings) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final now = DateTime.now();
    // Read once: the glyph colours and the theme must agree on light.
    final brightness = PlatformDispatcher.instance.platformBrightness;
    final json = jsonEncode(
      buildHomeWidgetSnapshot(
        finance,
        settings,
        now,
        _recurring(finance, now),
        patterns: _patterns,
        light: widgetThemeIsLight(settings, brightness),
      ),
    );
    final theme = jsonEncode(buildWidgetTheme(settings, brightness));
    if ('$json$theme' == _lastWritten) return;
    _lastWritten = '$json$theme';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dataKey, json);
    await prefs.setString(_themeKey, theme);
    try {
      await _channel.invokeMethod<void>('updateHomeWidgets');
    } on PlatformException {
      // The data is written; the next ping or the 30-minute redraw shows it.
    } on MissingPluginException {
      // Headless/test environments have no platform handler.
    }
  }
}

/// The widgets' snapshot for [now]. Amounts are formatted here so the ₹
/// grouping matches the app; the raw figures ride along for the bar.
/// [light] is the widget theme's brightness ([widgetThemeIsLight]), which
/// the category glyph colours are baked for.
Map<String, dynamic> buildHomeWidgetSnapshot(
  FinanceProvider finance,
  SettingsProvider settings,
  DateTime now,
  List<RecurringHit> hits, {
  List<RecurringHit>? patterns,
  bool light = false,
}) {
  final month = DateTime(now.year, now.month);
  final spent = finance.expenseInMonth(month);
  final cap = settings.monthlyBudget;
  final today = finance.spendOnDay(now);
  final allUpcoming = buildUpcomingItems(
    finance,
    hits: hits,
    hidden: settings.hiddenUpcoming,
    now: now,
  );
  // Every live pattern: safe to spend sets aside the whole month's bills,
  // and Big bills spreads the quarterly, half-yearly and yearly ones.
  final allPatterns =
      patterns ??
      detectRecurringPatterns(
        finance.countedTransactions,
        now: now,
        alias: finance.merchantAlias,
        pinned: finance.subscriptionPins,
      );
  final safe = computeSafeToSpend(
    finance,
    cap: cap,
    patterns: allPatterns,
    hidden: settings.hiddenUpcoming,
    now: now,
  );
  final bigBills = buildBigBillsPlan(
    finance,
    patterns: allPatterns,
    hidden: settings.hiddenUpcoming,
    now: now,
  );
  final upcoming = [
    for (final u in allUpcoming)
      // No card cycle that owes nothing yet; income due (a salary) shows
      // too, in green.
      if (!u.muted && u.days >= -7) u,
  ].take(kUpcomingWidgetRows);
  final hideIncome = settings.hideIncome;
  return {
    'computedDay': epochDay(now),
    // year * 12 + month: compared as a number, so no locale can change it.
    'monthKey': month.year * 12 + month.month,
    'monthLabel': DateFormat('MMMM').format(month),
    // Imports waiting in review: Today and Recent name them.
    'pendingCount': finance.pendingCount,
    'pace': {
      'spent': spent,
      'spentLabel': fmtMoneyTidy(spent),
      'cap': cap,
      'capLabel': fmtMoneyTidy(cap),
      'usualByDay': usualCumulativeByDay(finance, month),
    },
    'upcoming': [for (final u in upcoming) _upcomingRow(u, hideIncome, light)],
    'recent': [
      for (final t in finance.transactions.take(kRecentWidgetRows))
        _recentRow(finance, t, hideIncome, light),
    ],
    'split': _split(finance, month),
    'today': {
      'day': epochDay(now),
      'spent': today.spent,
      'spentLabel': fmtMoneyTidy(today.spent),
      'count': today.count,
    },
    // Today's figure plus one per later day of this month (what each would
    // allow if nothing more is spent), so the widget moves on after
    // midnight without the app; past the month's end it hides the row.
    if (safe != null)
      'safe': {
        'day': epochDay(now),
        // Every label is then "Over budget", which the widget prints alone.
        'overCap': safe.overCap,
        'label': _safeLabel(safe, safe.leftToday),
        'next': [
          for (var d = safe.today + 1; d < safe.today + safe.daysLeft; d++)
            _safeLabel(safe, safe.allowanceOn(d) ?? 0),
        ],
      },
    // Left out with no big bills: the widget shows its empty line.
    if (!bigBills.isEmpty) 'bigBills': _bigBills(bigBills, month),
    'week': _week(finance, settings, now),
  };
}

/// The Big bills widgets' block. [month]'s key dates the 12-month strip,
/// so a widget drawn in a later month shifts it without the app.
Map<String, dynamic> _bigBills(BigBillsPlan plan, DateTime month) => {
  'monthKey': month.year * 12 + month.month,
  'monthlyLabel': fmtMoneyTidy(plan.monthly),
  'yearlyLabel': fmtMoneyTidy(plan.yearly),
  'months': [for (final m in plan.months) m.due],
  'next': [
    for (final b in plan.bills.take(2))
      {
        'label': b.label,
        'amountLabel': fmtMoneyTidy(b.amount),
        'dueDay': epochDay(b.nextDue),
        'dueLabel': DateFormat('d MMM').format(b.nextDue),
      },
  ],
};

/// The This week widgets' block: the current week's spend day by day, and
/// the usual week cut to each weekday, so the widget compares against the
/// day it draws. Its `weekStart` tells a widget drawn after Sunday that
/// the figures are last week's. `toReview` is everything the review sheet
/// lists, whatever its date: the app's badge, and where the count's tap
/// lands.
Map<String, dynamic> _week(
  FinanceProvider finance,
  SettingsProvider settings,
  DateTime now,
) {
  final start = weekStartOf(now);
  final d = buildWeekDigest(finance, start, now: now);
  return {
    'weekStart': epochDay(start),
    'spent': d.spent,
    'spentLabel': fmtMoneyTidy(d.spent),
    'byDay': d.byDay,
    'usualByDay': usualWeekByDay(finance, start),
    'toReview': finance.reviewCount(settings.dismissedPairSuggestions),
  };
}

/// Rows the Recent widget shows: the newest confirmed transactions.
const int kRecentWidgetRows = 4;

/// How a widget colours an amount (the snapshot's `kind`): 'in' green,
/// 'out' red, and 'neutral' plain for money that is neither income nor
/// spend: a transfer, a row left out of the totals, or a linked refund.
String _kindOf(TxType type, {required bool neutral}) => neutral
    ? 'neutral'
    : type == TxType.income
    ? 'in'
    : 'out';

/// [amount] with the sign of [type], as the ledger prints it; income is
/// masked when Hide income is on.
String _signedLabel(double amount, TxType type, bool hideIncome) {
  final sign = type == TxType.income ? '+' : '−';
  if (type == TxType.income && hideIncome) return '$sign$kMaskedAmount';
  return '$sign${fmtMoneyTidy(amount)}';
}

/// A category glyph colour as ARGB, by the app's contrast rule for the
/// widget theme's surface ([light]); dark returns the colour as it is.
int _glyph(Color c, bool light) => categoryGlyphColorOn(
  c,
  surface: light ? FigmaPaletteLight.surface : FigmaPalette.surface,
  dark: !light,
).toARGB32();

/// One Upcoming widget row. `kind` colours the amount: a card bill is
/// 'neutral' like a transfer, since paying it moves money between your own
/// accounts. `color` is the category glyph colour; a card bill carries none
/// and the widget colours its card by urgency. `urgentDays` is a threshold,
/// not a flag: the widget marks the row urgent when the days until due, on
/// the day it draws, are at or below it (a card bill within its urgent
/// window, a reminder from its due day, a detected payment only overdue).
Map<String, dynamic> _upcomingRow(UpcomingItem u, bool hideIncome, bool light) {
  final transfer =
      u.kind == UpcomingKind.cardBill ||
      (u.categoryId != null && isTransferCategory(u.categoryId!));
  final kind = _kindOf(u.type, neutral: transfer);
  final amount = u.amount;
  return {
    'label': u.label,
    'dueDay': epochDay(u.due),
    'dueLabel': DateFormat('d MMM').format(u.due),
    // Bills keep a plain amount (nothing has left yet); income due carries
    // its "+" and is masked when Hide income is on.
    'amountLabel': amount == null
        ? null
        : kind == 'in'
        ? _signedLabel(amount, u.type, hideIncome)
        : fmtMoneyTidy(amount),
    'kind': kind,
    'icon': u.kind == UpcomingKind.cardBill
        ? 'card'
        : categoryById(u.categoryId ?? '', fallbackType: u.type).iconKey,
    if (u.kind != UpcomingKind.cardBill)
      'color': _glyph(
        categoryById(u.categoryId ?? '', fallbackType: u.type).color,
        light,
      ),
    'urgentDays': switch (u.kind) {
      UpcomingKind.cardBill => kCardUrgentWindowDays,
      UpcomingKind.reminder => 0,
      UpcomingKind.recurring => -1,
    },
  };
}

/// One Recent widget row: the category, the merchant when there is one,
/// and the day and time, which Kotlin turns into "Today" or "Yesterday" on
/// the day it draws. `color` is the category glyph colour for the icon.
Map<String, dynamic> _recentRow(
  FinanceProvider finance,
  Tx t,
  bool hideIncome,
  bool light,
) {
  // A linked refund is neither income nor spend: it cancels its purchase.
  final neutral =
      isTransferCategory(t.categoryId) ||
      !finance.countsInTotals(t) ||
      finance.isLinkedRefund(t);
  final kind = _kindOf(t.type, neutral: neutral);
  final midnight = t.date.hour == 0 && t.date.minute == 0;
  return {
    'label': t.category.label,
    'merchant': merchantLabelOrNull(t, alias: finance.merchantAlias),
    'day': epochDay(t.date),
    'timeLabel': midnight ? null : fmtTime(t.date),
    'dateLabel': DateFormat('d MMM').format(t.date),
    'amountLabel': _signedLabel(t.amount, t.type, hideIncome),
    'kind': kind,
    'unseen': t.unseen,
    'icon': t.category.iconKey,
    'color': _glyph(t.category.color, light),
  };
}

/// Categories the Spending split widget names; the rest are one "Other".
/// Three plus Other: four rows fit the widget's two-cell height.
const int kSplitWidgetRows = 3;

/// [month]'s spend by category for the Spending split widget: the largest
/// [kSplitWidgetRows], then the rest as Other, each with its colour (ARGB)
/// for the donut. Empty rows and a zero total when nothing is spent.
Map<String, dynamic> _split(FinanceProvider finance, DateTime month) {
  final all = [
    for (final e in finance.expenseByCategory(month))
      if (e.value > 0) e,
  ];
  final total = all.fold(0.0, (s, e) => s + e.value);
  final rest = all.skip(kSplitWidgetRows).fold(0.0, (s, e) => s + e.value);
  return {
    'total': total,
    'totalLabel': fmtMoneyCompact(total),
    'rows': [
      for (final e in all.take(kSplitWidgetRows))
        {
          'label': e.key.label,
          'amount': e.value,
          'amountLabel': fmtMoneyTidy(e.value),
          'color': e.key.color.toARGB32(),
        },
      if (rest > 0)
        {
          'label': 'Other',
          'amount': rest,
          'amountLabel': fmtMoneyTidy(rest),
          'color': 0xFF888780,
        },
    ],
  };
}

String _safeLabel(SafeToSpend safe, double amount) {
  if (safe.overCap) return 'Over budget';
  return amount < 1 ? fmtMoneyTidy(0) : fmtMoneyTidy(amount);
}
