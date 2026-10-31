import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Brightness, ThemeMode;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/spend_budget.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/figma_palette.dart';
import '../utils/format.dart';

/// Snapshot id of the overall monthly cap (which is not a SpendBudget).
const String kOverallBudgetWidgetId = '_overall';

/// Feeds the Android home-screen budget widgets.
///
/// Flutter computes, native displays: [sync] writes a compact per-budget
/// snapshot into SharedPreferences, readable natively as
/// `flutter.budget_widget_data_v1` in the FlutterSharedPreferences file,
/// and pings the platform to re-render every widget instance drawn from it
/// (BudgetWidgetProvider.kt: both budget widgets and Budgets list). There
/// is no background service: like budget alerts, figures refresh whenever
/// the app runs, so a widget always shows "as of last app use" and labels
/// the month and date honestly.
class BudgetWidgetService {
  static const _dataKey = 'budget_widget_data_v1';
  static const _themeKey = 'budget_widget_theme_v1';
  static const _channel = MethodChannel('expense_tracker/sms');

  /// Last JSON written this session — sync rides every provider
  /// notification, and most of them change no budget figure. The updated
  /// label is date-granular (not time), so the comparison actually hits.
  String? _lastWritten;
  String? _lastTheme;

  Future<void> sync(FinanceProvider finance, SettingsProvider settings) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final json = jsonEncode(
      buildWidgetSnapshot(finance, settings, DateTime.now()),
    );
    final theme = jsonEncode(
      buildWidgetTheme(
        settings,
        PlatformDispatcher.instance.platformBrightness,
      ),
    );
    if (json == _lastWritten && theme == _lastTheme) return;
    _lastWritten = json;
    _lastTheme = theme;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dataKey, json);
    await prefs.setString(_themeKey, theme);
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

/// Whether the widgets draw in the light palette: the rule
/// [buildWidgetTheme] uses ([ThemeMode.system] resolves against
/// [platformBrightness]).
bool widgetThemeIsLight(
  SettingsProvider settings,
  Brightness platformBrightness,
) =>
    settings.mode == ThemeMode.light ||
    (settings.mode == ThemeMode.system &&
        platformBrightness == Brightness.light);

/// The widget's colours as ARGB ints, following the app: the chosen dark
/// palette, or the light palette when the app shows light
/// ([ThemeMode.system] resolves against [platformBrightness] at sync time),
/// plus the budget ring's threshold colours.
///
/// The card colours come from the helpers buildAppTheme uses
/// (app_theme.dart, contrast.dart), so a widget looks like the app's cards:
/// `cardFill` is [cardFillFor], `border` the hairline the light theme and
/// the outlined palettes draw (absent when the app draws none), `onAccent`
/// [onAccentFor] and `accentText` [accentTextFor].
Map<String, int> buildWidgetTheme(
  SettingsProvider settings,
  Brightness platformBrightness,
) {
  final light = widgetThemeIsLight(settings, platformBrightness);
  final p = settings.palette.colors;
  final accent = settings.accent;
  final surface = light ? FigmaPaletteLight.surface : p.surface;
  final border = light ? FigmaPaletteLight.border : p.border;
  // The theme's dark ink, as buildAppTheme picks it.
  final ink = light ? FigmaPalette.bg : p.bg;
  final cardFill = cardFillFor(surface, accent, light: light);
  return {
    'surface': surface.toARGB32(),
    'cardFill': cardFill.toARGB32(),
    if (light || p.outlineCards) 'border': border.toARGB32(),
    // The page background, for the budget widget's setup screen.
    'bg': (light ? FigmaPaletteLight.bg : p.bg).toARGB32(),
    'text': (light ? FigmaPaletteLight.textPrimary : p.textPrimary).toARGB32(),
    'textSecondary': (light ? FigmaPaletteLight.textSecondary : p.textSecondary)
        .toARGB32(),
    'track': border.toARGB32(),
    // Ring colours by how much of the budget is used (green below 80%,
    // orange to 95%, red above); `safe` is also money in and `over` money
    // out, as in the app.
    'safe': (light ? FigmaPaletteLight.green : FigmaPalette.green).toARGB32(),
    'warn': (light ? FigmaPaletteLight.orange : FigmaPalette.orange).toARGB32(),
    'over': (light ? FigmaPaletteLight.pink : FigmaPalette.pink).toARGB32(),
    // The pace widget's bar and the Add buttons.
    'accent': accent.toARGB32(),
    'onAccent': onAccentFor(accent, ink).toARGB32(),
    // The accent as small text on a card.
    'accentText': accentTextFor(
      accent,
      light ? Brightness.light : Brightness.dark,
    ).toARGB32(),
  };
}

/// The widget snapshot: the overall monthly cap first (when set), then
/// every custom budget with a limit, the same enumeration BudgetMonitor
/// alerts on. The budget widgets and Budgets list draw from it. Amounts are
/// pre-formatted here so the widget's ₹ symbol and Indian grouping match the
/// app exactly; the raw numbers ride along for the native rings.
List<Map<String, dynamic>> buildWidgetSnapshot(
  FinanceProvider finance,
  SettingsProvider settings,
  DateTime now,
) {
  final month = DateTime(now.year, now.month);
  const tidy = fmtMoneyTidy;

  Map<String, dynamic> entry(
    String id,
    String name,
    double spent,
    double limit,
    String icon, {
    // A dated budget's days, shown where a monthly one names its month.
    String? period,
  }) => {
    'id': id,
    'name': name,
    'spent': spent,
    'limit': limit,
    'spentLabel': tidy(spent),
    'limitLabel': tidy(limit),
    'statusLabel': spent > limit
        ? 'Over by ${tidy(spent - limit)}'
        : '${tidy(limit - spent)} left',
    // The widgets' first line: what is left, or how far over.
    'over': spent > limit,
    'leftLabel': spent > limit
        ? '${tidy(spent - limit)} over'
        : '${tidy(limit - spent)} left',
    'icon': icon,
    'monthLabel': period ?? fmtMonth(month),
    'monthName': period ?? DateFormat('MMMM').format(month),
    'updatedLabel': fmtDate(now),
    'updatedShort': DateFormat('d MMM').format(now),
  };

  return [
    if (settings.monthlyBudget > 0)
      entry(
        kOverallBudgetWidgetId,
        'Monthly budget',
        finance.budgetSpentInMonth(month),
        settings.monthlyBudget,
        kWalletWidgetIcon,
      ),
    for (final b in finance.budgets)
      if (b.limit > 0 && b.range == null)
        entry(
          b.id,
          b.name,
          finance.budgetSpentFor(b, month),
          b.limit,
          budgetWidgetIcon(b),
        ),
    // Trips until their last day: one total for their dates.
    for (final b in finance.budgets)
      if (b.limit > 0 &&
          (b.stageOn(now) == TripStage.upcoming ||
              b.stageOn(now) == TripStage.running))
        entry(
          b.id,
          b.name,
          finance.budgetSpentFor(b, month),
          b.limit,
          budgetWidgetIcon(b),
          period: fmtDayRange(b.range!, now),
        ),
  ];
}

/// The icon key the budget widgets show inside the ring for the overall
/// cap and for budgets that span several categories.
const String kWalletWidgetIcon = 'wallet';

/// [b]'s ring icon: the icon picked for it, else its one category's icon
/// when it counts exactly one category, else the wallet.
String budgetWidgetIcon(SpendBudget b) =>
    budgetIconKey(b, fallback: kWalletWidgetIcon);
