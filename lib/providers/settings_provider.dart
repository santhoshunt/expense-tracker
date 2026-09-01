import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/budget.dart';
import '../utils/figma_palette.dart';

/// How often SMS auto-import runs. Imports happen on app launch when due —
/// "daily" means the first launch of each day catches up on everything since
/// the last scan, so opening the app after EOD covers the whole day.
enum AutoImportFrequency {
  off('Off'),
  everyOpen('Launch'),
  daily('Daily'),
  weekly('Weekly');

  final String label;
  const AutoImportFrequency(this.label);
}

/// App preferences: theme mode + accent colour, SMS auto-import cadence and
/// monthly budget alerts. (The old seed/background/glass customization is
/// gone — the Figma structure is fixed; only mode and accent vary.)
class SettingsProvider extends ChangeNotifier {
  static const _kThemeMode = 'theme_mode_v1';
  static const _kAccent = 'accent_color_v1';
  static const _kAutoImport = 'auto_import_frequency_v1';
  static const _kMonthlyBudget = 'monthly_budget_v1';
  static const _kBudgetAlerts = 'budget_alerts_enabled_v1';
  static const _kAlert80 = 'budget_alert_80_v1';
  static const _kAlert90 = 'budget_alert_90_v1';
  static const _kAlertOver = 'budget_alert_over_v1';

  ThemeMode _mode = ThemeMode.dark; // the app's native look
  Color _accent = FigmaPalette.primary;
  AutoImportFrequency _autoImport = AutoImportFrequency.off;
  double _monthlyBudget = 0; // 0 = no cap set
  bool _budgetAlerts = true;
  bool _alert80 = true;
  bool _alert90 = true;
  bool _alertOver = true;
  bool _loaded = false;

  ThemeMode get mode => _mode;
  Color get accent => _accent;
  AutoImportFrequency get autoImport => _autoImport;

  /// Overall monthly spending cap; 0 means no budget is set.
  double get monthlyBudget => _monthlyBudget;
  bool get budgetAlerts => _budgetAlerts;
  bool get alert80 => _alert80;
  bool get alert90 => _alert90;
  bool get alertOver => _alertOver;

  bool get loaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Every read is individually guarded: a wrongly-typed stored value
    // (e.g. an int where getDouble expects a double) throws, and an
    // unhandled throw here means `_loaded` never flips — a permanent
    // loading spinner. A bad value falls back to its default instead.
    T tryRead<T>(T Function() read, T fallback) {
      try {
        return read();
      } catch (_) {
        return fallback;
      }
    }

    _mode = tryRead(
      () =>
          ThemeMode.values.asNameMap()[prefs.getString(_kThemeMode)] ??
          ThemeMode.dark,
      ThemeMode.dark,
    );
    _accent = tryRead(() {
      final accent = prefs.getInt(_kAccent);
      return accent != null ? Color(accent) : FigmaPalette.primary;
    }, FigmaPalette.primary);
    _autoImport = tryRead(
      () =>
          AutoImportFrequency.values.asNameMap()[prefs.getString(
            _kAutoImport,
          )] ??
          AutoImportFrequency.off,
      AutoImportFrequency.off,
    );
    _monthlyBudget = tryRead(() => prefs.getDouble(_kMonthlyBudget) ?? 0, 0);
    _budgetAlerts = tryRead(() => prefs.getBool(_kBudgetAlerts) ?? true, true);
    _alert80 = tryRead(() => prefs.getBool(_kAlert80) ?? true, true);
    _alert90 = tryRead(() => prefs.getBool(_kAlert90) ?? true, true);
    _alertOver = tryRead(() => prefs.getBool(_kAlertOver) ?? true, true);
    _loaded = true;
    notifyListeners();
  }

  /// Best-effort prefs write. A platform failure must neither crash the
  /// caller (setters aren't awaited by their UI) nor skip a pending
  /// notifyListeners — the in-memory value stands either way, it just won't
  /// survive a restart. Logged only: unlike FinanceProvider there is no
  /// banner surface here, and re-setting a preference recovers it.
  Future<void> _persistPref(
    String what,
    Future<void> Function(SharedPreferences p) write,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await write(prefs);
    } catch (e) {
      debugPrint('Settings persist failed ($what): $e');
    }
  }

  Future<void> setMonthlyBudget(double value) async {
    final v = value < 0 ? 0.0 : value;
    if (v == _monthlyBudget) return;
    _monthlyBudget = v;
    // A new cap means new thresholds — forget what was already notified this
    // month so the monitor re-evaluates against the new cap. This must land
    // BEFORE notifyListeners: the budget monitor is a listener, so
    // notify-first let it check the new cap against the old marker and then
    // have this clear erase what it just recorded (the same race
    // FinanceProvider.updateBudget documents for custom budgets).
    // _persistPref never throws, so the notify below always runs — a failed
    // write no longer left the provider diverged from its listeners.
    await _persistPref(_kMonthlyBudget, (p) async {
      await p.remove(budgetAlertMonthKey(DateTime.now()));
      await p.setDouble(_kMonthlyBudget, v);
    });
    notifyListeners();
  }

  Future<void> setBudgetAlerts(bool enabled) async {
    if (enabled == _budgetAlerts) return;
    _budgetAlerts = enabled;
    notifyListeners();
    await _persistPref(
      _kBudgetAlerts,
      (p) => p.setBool(_kBudgetAlerts, enabled),
    );
  }

  Future<void> setAlertThreshold(int threshold, bool enabled) async {
    switch (threshold) {
      case 80:
        _alert80 = enabled;
      case 90:
        _alert90 = enabled;
      case 100:
        _alertOver = enabled;
      default:
        return;
    }
    notifyListeners();
    await _persistPref('alert thresholds', (p) async {
      await p.setBool(_kAlert80, _alert80);
      await p.setBool(_kAlert90, _alert90);
      await p.setBool(_kAlertOver, _alertOver);
    });
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    await _persistPref(_kThemeMode, (p) => p.setString(_kThemeMode, mode.name));
  }

  Future<void> setAccent(Color color) async {
    if (color == _accent) return;
    _accent = color;
    notifyListeners();
    await _persistPref(_kAccent, (p) => p.setInt(_kAccent, color.toARGB32()));
  }

  Future<void> setAutoImport(AutoImportFrequency frequency) async {
    if (frequency == _autoImport) return;
    _autoImport = frequency;
    notifyListeners();
    await _persistPref(
      _kAutoImport,
      (p) => p.setString(_kAutoImport, frequency.name),
    );
  }

  /// The preference block carried inside JSON backups (the 'settings' key)
  /// — the backup doc used to claim "full snapshot" while every value here
  /// was silently absent, so a fresh-device restore lost the monthly cap,
  /// alert flags, auto-import cadence and theme.
  Map<String, dynamic> toBackupMap() => {
    'themeMode': _mode.name,
    'accent': _accent.toARGB32(),
    'autoImport': _autoImport.name,
    'monthlyBudget': _monthlyBudget,
    'budgetAlerts': _budgetAlerts,
    'alert80': _alert80,
    'alert90': _alert90,
    'alertOver': _alertOver,
  };

  /// Restores [toBackupMap]'s block. Missing or wrongly-typed keys keep the
  /// current values, so backups from before the block existed apply
  /// cleanly. Persists first (including the fired-alert marker clear — see
  /// [setMonthlyBudget] for the ordering race), then notifies once.
  Future<void> applyBackupMap(Map<String, dynamic> map) async {
    _mode = ThemeMode.values.asNameMap()[map['themeMode']] ?? _mode;
    final accent = map['accent'];
    if (accent is int) _accent = Color(accent);
    _autoImport =
        AutoImportFrequency.values.asNameMap()[map['autoImport']] ??
        _autoImport;
    final cap = map['monthlyBudget'];
    if (cap is num && cap.toDouble().isFinite && cap >= 0) {
      _monthlyBudget = cap.toDouble();
    }
    if (map['budgetAlerts'] is bool) {
      _budgetAlerts = map['budgetAlerts'] as bool;
    }
    if (map['alert80'] is bool) _alert80 = map['alert80'] as bool;
    if (map['alert90'] is bool) _alert90 = map['alert90'] as bool;
    if (map['alertOver'] is bool) _alertOver = map['alertOver'] as bool;
    await _persistPref('backup restore', (p) async {
      await p.remove(budgetAlertMonthKey(DateTime.now()));
      await p.setString(_kThemeMode, _mode.name);
      await p.setInt(_kAccent, _accent.toARGB32());
      await p.setString(_kAutoImport, _autoImport.name);
      await p.setDouble(_kMonthlyBudget, _monthlyBudget);
      await p.setBool(_kBudgetAlerts, _budgetAlerts);
      await p.setBool(_kAlert80, _alert80);
      await p.setBool(_kAlert90, _alert90);
      await p.setBool(_kAlertOver, _alertOver);
    });
    notifyListeners();
  }
}
