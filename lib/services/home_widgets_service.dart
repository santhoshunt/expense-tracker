import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/format.dart';
import 'budget_widget_service.dart';
import 'recurring_detector.dart';
import 'safe_to_spend.dart';
import 'spend_comparison.dart';
import 'upcoming_items.dart';

/// Upcoming rows the widget carries; it shows the first three still due.
const int kUpcomingWidgetRows = 5;

/// Days since 1970-01-01 for [d]'s local calendar date. Kotlin compares
/// these with `LocalDate.now().toEpochDay()`, so "today" and "in 3 days" are
/// worked out on the day the widget draws, not the day the app last ran.
int epochDay(DateTime d) =>
    DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

/// Feeds the Month pace, Upcoming and Today widgets
/// (HomeWidgets.kt). Like [BudgetWidgetService], Dart computes and native
/// draws; the snapshot carries dates and a usual-by-day curve so the
/// widgets stay right across midnight without the app running.
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
    final json = jsonEncode(
      buildHomeWidgetSnapshot(
        finance,
        settings,
        now,
        _recurring(finance, now),
        patterns: _patterns,
      ),
    );
    final theme = jsonEncode(
      buildWidgetTheme(
        settings,
        PlatformDispatcher.instance.platformBrightness,
      ),
    );
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
Map<String, dynamic> buildHomeWidgetSnapshot(
  FinanceProvider finance,
  SettingsProvider settings,
  DateTime now,
  List<RecurringHit> hits, {
  List<RecurringHit>? patterns,
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
  final safe = computeSafeToSpend(
    finance,
    cap: cap,
    patterns:
        patterns ??
        detectRecurringPatterns(
          finance.countedTransactions,
          now: now,
          alias: finance.merchantAlias,
          pinned: finance.subscriptionPins,
        ),
    hidden: settings.hiddenUpcoming,
    now: now,
  );
  final upcoming = [
    for (final u in allUpcoming)
      // Bills only: no salary or interest, and no card cycle that owes
      // nothing yet.
      if (u.type == TxType.expense && !u.muted && u.days >= -7) u,
  ].take(kUpcomingWidgetRows);
  return {
    'computedDay': epochDay(now),
    // year * 12 + month: compared as a number, so no locale can change it.
    'monthKey': month.year * 12 + month.month,
    'monthLabel': DateFormat('MMMM').format(month),
    'pace': {
      'spent': spent,
      'spentLabel': fmtMoneyTidy(spent),
      'cap': cap,
      'capLabel': fmtMoneyTidy(cap),
      'usualByDay': usualCumulativeByDay(finance, month),
    },
    'upcoming': [
      for (final u in upcoming)
        {
          'label': u.label,
          'dueDay': epochDay(u.due),
          'dueLabel': DateFormat('d MMM').format(u.due),
          'amountLabel': u.amount == null ? null : fmtMoneyTidy(u.amount!),
        },
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
        'label': _safeLabel(safe, safe.leftToday),
        'next': [
          for (var d = safe.today + 1; d < safe.today + safe.daysLeft; d++)
            _safeLabel(safe, safe.allowanceOn(d) ?? 0),
        ],
      },
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
