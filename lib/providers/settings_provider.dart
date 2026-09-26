import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/budget.dart';
import '../utils/app_palettes.dart';
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

/// How the category picker in the add/edit sheet orders its options.
enum CategoryOrder {
  /// Highest gross amount over the last three months first.
  mostUsed('Most used'),
  alphabetical('A to Z');

  final String label;
  const CategoryOrder(this.label);
}

/// How the dashboard's "Categories vs usual" rows are ordered. The service
/// hands them biggest absolute change first; the other two orders are
/// recomputed in the card.
enum CategorySort {
  biggestChange(
    'Biggest change',
    'Where this month differs most from a normal one.',
  ),
  mostUnusual(
    'Most unusual',
    'The furthest from its own usual, so a small category that doubled '
        'outranks a big one that wobbled.',
  ),
  highestSpend('Highest spend', 'The most spent this month first.');

  final String label;
  final String subtitle;
  const CategorySort(this.label, this.subtitle);
}

/// App preferences: theme mode, dark palette + accent colour, SMS
/// auto-import cadence and monthly budget alerts.
class SettingsProvider extends ChangeNotifier {
  static const _kThemeMode = 'theme_mode_v1';
  static const _kAccent = 'accent_color_v1';
  static const _kAutoImport = 'auto_import_frequency_v1';
  static const _kMonthlyBudget = 'monthly_budget_v1';
  static const _kBudgetAlerts = 'budget_alerts_enabled_v1';
  static const _kAlert80 = 'budget_alert_80_v1';
  static const _kAlert90 = 'budget_alert_90_v1';
  static const _kAlertOver = 'budget_alert_over_v1';
  static const _kUpcomingReminders = 'upcoming_reminders_v1';
  static const _kUpcomingHidden = 'upcoming_hidden_v1';
  static const _kCollapsedSections = 'collapsed_sections_v1';

  /// Pre-1.1.1 key: a single bool for the dashboard Upcoming card, folded
  /// into [_kCollapsedSections] on load.
  static const _kLegacyUpcomingCollapsed = 'upcoming_collapsed_v1';
  static const _kAppLock = 'app_lock_enabled_v1';
  static const _kHideIncome = 'hide_income_v1';
  static const _kTiltGlow = 'tilt_glow_v1';
  static const _kDismissedPairs = 'pair_dismissed_v1';
  static const _kCategoryOrder = 'category_order_v1';
  static const _kCategorySort = 'category_sort_v1';
  static const _kPalette = 'palette_v1';
  static const _kUpdateOnLaunch = 'update_check_on_launch_v1';
  static const _kUpdateLastCheck = 'update_last_check_v1';
  static const _kUpdateDismissed = 'update_dismissed_tag_v1';
  static const _kUpdateInstalling = 'update_installing_tag_v1';

  ThemeMode _mode = ThemeMode.dark; // the app's native look
  Color _accent = FigmaPalette.primary;
  AppPalette _palette = AppPalette.standard;
  AutoImportFrequency _autoImport = AutoImportFrequency.off;
  double _monthlyBudget = 0; // 0 = no cap set
  bool _budgetAlerts = true;
  bool _alert80 = true;
  bool _alert90 = true;
  bool _alertOver = true;
  bool _upcomingReminders = true;
  Set<String> _upcomingHidden = {};
  Set<String> _collapsedSections = {};
  Set<String> _dismissedPairs = {};
  bool _appLock = false;
  bool _hideIncome = false;
  bool _tiltGlow = true;
  CategoryOrder _categoryOrder = CategoryOrder.mostUsed;
  CategorySort _categorySort = CategorySort.biggestChange;
  bool _updateOnLaunch = true;
  DateTime? _updateLastCheck;
  String? _updateDismissedTag;
  String? _updateInstallingTag;
  bool _loaded = false;

  ThemeMode get mode => _mode;
  Color get accent => _accent;

  /// The dark theme's structural palette (light mode ignores it).
  AppPalette get palette => _palette;
  AutoImportFrequency get autoImport => _autoImport;

  /// Overall monthly spending cap; 0 means no budget is set.
  double get monthlyBudget => _monthlyBudget;
  bool get budgetAlerts => _budgetAlerts;
  bool get alert80 => _alert80;
  bool get alert90 => _alert90;
  bool get alertOver => _alertOver;

  /// Notify on open when a card bill or detected recurring payment is due.
  bool get upcomingReminders => _upcomingReminders;

  /// Recurring-detection keys the user hid from the Upcoming card.
  Set<String> get hiddenUpcoming => Set.unmodifiable(_upcomingHidden);

  /// Collapsible sections folded to their headers ('upcoming',
  /// 'pending_review', 'spam_review'). Per-device UI state — deliberately
  /// not in the backup block.
  bool isSectionCollapsed(String id) => _collapsedSections.contains(id);

  /// Biometric/device-credential gate on the whole app.
  bool get appLock => _appLock;

  /// Hide income TOTALS: the dashboard Income tile and chart bars disappear,
  /// month-header and breakdown totals show a mask. Individual transaction
  /// rows keep their amounts.
  bool get hideIncome => _hideIncome;

  /// The screen glow drifts with the phone's tilt. Per device, like the app
  /// lock: backups leave it out.
  bool get tiltGlow => _tiltGlow;

  /// Transfer-pair suggestions the user rejected ("Not a transfer"), keyed
  /// by pairSuggestionKey (two row ids). Backed up: the judgement is about
  /// the data, not the device.
  Set<String> get dismissedPairSuggestions => Set.unmodifiable(_dismissedPairs);

  /// Ordering of the add/edit sheet's category picker.
  CategoryOrder get categoryOrder => _categoryOrder;

  /// Ordering of the "Categories vs usual" card's rows.
  CategorySort get categorySort => _categorySort;

  /// Look for a newer release once a day on launch. Per device, like the
  /// rest of the update state: backups leave it out.
  bool get updateOnLaunch => _updateOnLaunch;
  DateTime? get updateLastCheck => _updateLastCheck;

  /// The newest release the user answered "Not now" to; the banner stays
  /// away until a newer one appears.
  String? get updateDismissedTag => _updateDismissedTag;

  /// The release an install was started for, so the next launch on that
  /// version can say it worked.
  String? get updateInstallingTag => _updateInstallingTag;

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
    _upcomingReminders = tryRead(
      () => prefs.getBool(_kUpcomingReminders) ?? true,
      true,
    );
    _upcomingHidden = tryRead(
      () => (prefs.getStringList(_kUpcomingHidden) ?? const []).toSet(),
      <String>{},
    );
    _collapsedSections = tryRead(
      () => (prefs.getStringList(_kCollapsedSections) ?? const []).toSet(),
      <String>{},
    );
    // One-shot legacy fold-in; best-effort like every other write here.
    if (prefs.getBool(_kLegacyUpcomingCollapsed) == true) {
      _collapsedSections.add('upcoming');
      await _persistPref(_kCollapsedSections, (p) async {
        await p.setStringList(_kCollapsedSections, _collapsedSections.toList());
        await p.remove(_kLegacyUpcomingCollapsed);
      });
    }
    _appLock = tryRead(() => prefs.getBool(_kAppLock) ?? false, false);
    _hideIncome = tryRead(() => prefs.getBool(_kHideIncome) ?? false, false);
    _tiltGlow = tryRead(() => prefs.getBool(_kTiltGlow) ?? true, true);
    _dismissedPairs = tryRead(
      () => (prefs.getStringList(_kDismissedPairs) ?? const []).toSet(),
      <String>{},
    );
    _categoryOrder = tryRead(
      () =>
          CategoryOrder.values.asNameMap()[prefs.getString(_kCategoryOrder)] ??
          CategoryOrder.mostUsed,
      CategoryOrder.mostUsed,
    );
    _categorySort = tryRead(
      () =>
          CategorySort.values.asNameMap()[prefs.getString(_kCategorySort)] ??
          CategorySort.biggestChange,
      CategorySort.biggestChange,
    );
    _palette = tryRead(
      () =>
          AppPalette.values.asNameMap()[prefs.getString(_kPalette)] ??
          AppPalette.standard,
      AppPalette.standard,
    );
    _updateOnLaunch = tryRead(
      () => prefs.getBool(_kUpdateOnLaunch) ?? true,
      true,
    );
    _updateLastCheck = tryRead(() {
      final ms = prefs.getInt(_kUpdateLastCheck);
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    }, null);
    _updateDismissedTag = tryRead(
      () => prefs.getString(_kUpdateDismissed),
      null,
    );
    _updateInstallingTag = tryRead(
      () => prefs.getString(_kUpdateInstalling),
      null,
    );
    _loaded = true;
    notifyListeners();
  }

  Future<void> setUpdateOnLaunch(bool value) async {
    if (value == _updateOnLaunch) return;
    _updateOnLaunch = value;
    notifyListeners();
    await _persistPref(
      _kUpdateOnLaunch,
      (p) => p.setBool(_kUpdateOnLaunch, value),
    );
  }

  /// Not a listened-for change: only the launch throttle reads it.
  Future<void> markUpdateChecked(DateTime when) async {
    _updateLastCheck = when;
    await _persistPref(
      _kUpdateLastCheck,
      (p) => p.setInt(_kUpdateLastCheck, when.millisecondsSinceEpoch),
    );
  }

  Future<void> dismissUpdate(String tag) async {
    if (tag == _updateDismissedTag) return;
    _updateDismissedTag = tag;
    notifyListeners();
    await _persistPref(
      _kUpdateDismissed,
      (p) => p.setString(_kUpdateDismissed, tag),
    );
  }

  /// [tag] null clears it.
  Future<void> setUpdateInstallingTag(String? tag) async {
    _updateInstallingTag = tag;
    await _persistPref(
      _kUpdateInstalling,
      (p) => tag == null
          ? p.remove(_kUpdateInstalling)
          : p.setString(_kUpdateInstalling, tag),
    );
  }

  Future<void> dismissPairSuggestion(String key) async {
    if (!_dismissedPairs.add(key)) return;
    notifyListeners();
    await _persistPref(
      _kDismissedPairs,
      (p) => p.setStringList(_kDismissedPairs, _dismissedPairs.toList()),
    );
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

  /// Switches the dark theme and adopts its accent in the same notify, so
  /// the app cross-fades once. The accent swatches can change it after.
  Future<void> setPalette(AppPalette palette) async {
    if (palette == _palette) return;
    _palette = palette;
    _accent = palette.colors.accent;
    notifyListeners();
    await _persistPref(_kPalette, (p) async {
      await p.setString(_kPalette, palette.name);
      await p.setInt(_kAccent, _accent.toARGB32());
    });
  }

  Future<void> setUpcomingReminders(bool enabled) async {
    if (enabled == _upcomingReminders) return;
    _upcomingReminders = enabled;
    notifyListeners();
    await _persistPref(
      _kUpcomingReminders,
      (p) => p.setBool(_kUpcomingReminders, enabled),
    );
  }

  /// Hides one detected recurring payment from the Upcoming card (and the
  /// reminder monitor). Keys come from RecurringHit.key.
  Future<void> hideUpcoming(String key) async {
    if (!_upcomingHidden.add(key)) return;
    notifyListeners();
    await _persistPref(
      _kUpcomingHidden,
      (p) => p.setStringList(_kUpcomingHidden, _upcomingHidden.toList()),
    );
  }

  /// Brings back one payment hidden via [hideUpcoming] (the Subscriptions
  /// list's Unhide, and Undo after a hide).
  Future<void> unhideUpcoming(String key) async {
    if (!_upcomingHidden.remove(key)) return;
    notifyListeners();
    await _persistPref(
      _kUpcomingHidden,
      (p) => p.setStringList(_kUpcomingHidden, _upcomingHidden.toList()),
    );
  }

  Future<void> toggleSection(String id) async {
    if (!_collapsedSections.add(id)) _collapsedSections.remove(id);
    notifyListeners();
    await _persistPref(
      _kCollapsedSections,
      (p) => p.setStringList(_kCollapsedSections, _collapsedSections.toList()),
    );
  }

  /// Un-hides everything hidden via [hideUpcoming].
  Future<void> resetHiddenUpcoming() async {
    if (_upcomingHidden.isEmpty) return;
    _upcomingHidden = {};
    notifyListeners();
    await _persistPref(
      _kUpcomingHidden,
      (p) => p.setStringList(_kUpcomingHidden, const []),
    );
  }

  /// App lock is deliberately NOT part of the backup block: it is a property
  /// of this device's enrollment. Restoring "locked" onto a device without
  /// biometrics/PIN set up would gate the app behind a prompt that can never
  /// succeed.
  Future<void> setAppLock(bool enabled) async {
    if (enabled == _appLock) return;
    _appLock = enabled;
    notifyListeners();
    await _persistPref(_kAppLock, (p) => p.setBool(_kAppLock, enabled));
  }

  Future<void> setHideIncome(bool enabled) async {
    if (enabled == _hideIncome) return;
    _hideIncome = enabled;
    notifyListeners();
    await _persistPref(_kHideIncome, (p) => p.setBool(_kHideIncome, enabled));
  }

  Future<void> setTiltGlow(bool enabled) async {
    if (enabled == _tiltGlow) return;
    _tiltGlow = enabled;
    notifyListeners();
    await _persistPref(_kTiltGlow, (p) => p.setBool(_kTiltGlow, enabled));
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

  Future<void> setCategoryOrder(CategoryOrder order) async {
    if (order == _categoryOrder) return;
    _categoryOrder = order;
    notifyListeners();
    await _persistPref(
      _kCategoryOrder,
      (p) => p.setString(_kCategoryOrder, order.name),
    );
  }

  Future<void> setCategorySort(CategorySort sort) async {
    if (sort == _categorySort) return;
    _categorySort = sort;
    notifyListeners();
    await _persistPref(
      _kCategorySort,
      (p) => p.setString(_kCategorySort, sort.name),
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
    'upcomingReminders': _upcomingReminders,
    'upcomingHidden': _upcomingHidden.toList(),
    'hideIncome': _hideIncome,
    'dismissedPairs': _dismissedPairs.toList(),
    'categoryOrder': _categoryOrder.name,
    'categorySort': _categorySort.name,
    'palette': _palette.name,
    // appLock is intentionally absent — see setAppLock.
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
    if (map['upcomingReminders'] is bool) {
      _upcomingReminders = map['upcomingReminders'] as bool;
    }
    if (map['upcomingHidden'] is List) {
      _upcomingHidden = {
        for (final k in map['upcomingHidden'] as List)
          if (k is String) k,
      };
    }
    if (map['hideIncome'] is bool) {
      _hideIncome = map['hideIncome'] as bool;
    }
    if (map['dismissedPairs'] is List) {
      _dismissedPairs = {
        for (final k in map['dismissedPairs'] as List)
          if (k is String) k,
      };
    }
    _categoryOrder =
        CategoryOrder.values.asNameMap()[map['categoryOrder']] ??
        _categoryOrder;
    _categorySort =
        CategorySort.values.asNameMap()[map['categorySort']] ?? _categorySort;
    _palette = AppPalette.values.asNameMap()[map['palette']] ?? _palette;
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
      await p.setBool(_kUpcomingReminders, _upcomingReminders);
      await p.setStringList(_kUpcomingHidden, _upcomingHidden.toList());
      await p.setBool(_kHideIncome, _hideIncome);
      await p.setStringList(_kDismissedPairs, _dismissedPairs.toList());
      await p.setString(_kCategoryOrder, _categoryOrder.name);
      await p.setString(_kCategorySort, _categorySort.name);
      await p.setString(_kPalette, _palette.name);
    });
    notifyListeners();
  }
}
