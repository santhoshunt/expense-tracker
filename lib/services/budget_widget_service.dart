import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/format.dart';

/// Snapshot id of the overall monthly cap (which is not a SpendBudget).
const String kOverallBudgetWidgetId = '_overall';

/// Feeds the Android home-screen budget widgets.
///
/// Flutter computes, native displays: [sync] writes a compact per-budget
/// snapshot into SharedPreferences — readable natively as
/// `flutter.budget_widget_data_v1` in the FlutterSharedPreferences file —
/// and pings the platform to re-render every widget instance
/// (BudgetWidgetProvider.kt). There is no background service: like budget
/// alerts, figures refresh whenever the app runs, so a widget always shows
/// "as of last app use" and labels the month and date honestly.
class BudgetWidgetService {
  static const _dataKey = 'budget_widget_data_v1';
  static const _channel = MethodChannel('expense_tracker/sms');

  /// Last JSON written this session — sync rides every provider
  /// notification, and most of them change no budget figure. The updated
  /// label is date-granular (not time), so the comparison actually hits.
  String? _lastWritten;

  Future<void> sync(FinanceProvider finance, SettingsProvider settings) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final json = jsonEncode(
      buildWidgetSnapshot(finance, settings, DateTime.now()),
    );
    if (json == _lastWritten) return;
    _lastWritten = json;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dataKey, json);
    try {
      await _channel.invokeMethod<void>('updateBudgetWidgets');
    } on PlatformException {
      // A widget-refresh hiccup must never surface into the calling flow;
      // the data is written, the next ping re-renders it.
    } on MissingPluginException {
      // Headless/test environments have no platform handler.
    }
  }
}

/// The widget snapshot: the overall monthly cap first (when set), then
/// every custom budget with a limit — the same enumeration BudgetMonitor
/// alerts on. Amounts are pre-formatted here so the widget's ₹ symbol and
/// Indian grouping match the app exactly; the raw numbers ride along for
/// the native progress bar.
List<Map<String, dynamic>> buildWidgetSnapshot(
  FinanceProvider finance,
  SettingsProvider settings,
  DateTime now,
) {
  final month = DateTime(now.year, now.month);

  // fmtMoney's forced two decimals read as clutter at widget size —
  // "₹60,000.00 of ₹60,000.00" — so whole-rupee figures drop the ".00".
  String tidy(double v) {
    final s = fmtMoney(v);
    return s.endsWith('.00') ? s.substring(0, s.length - 3) : s;
  }

  Map<String, dynamic> entry(
    String id,
    String name,
    double spent,
    double limit,
  ) => {
    'id': id,
    'name': name,
    'spent': spent,
    'limit': limit,
    'spentLabel': tidy(spent),
    'limitLabel': tidy(limit),
    'statusLabel': spent > limit
        ? 'Over by ${tidy(spent - limit)}'
        : '${tidy(limit - spent)} left',
    'monthLabel': fmtMonth(month),
    'updatedLabel': fmtDate(now),
  };

  return [
    if (settings.monthlyBudget > 0)
      entry(
        kOverallBudgetWidgetId,
        'Monthly budget',
        finance.budgetSpentInMonth(month),
        settings.monthlyBudget,
      ),
    for (final b in finance.budgets)
      if (b.limit > 0)
        entry(b.id, b.name, finance.budgetSpentFor(b, month), b.limit),
  ];
}
