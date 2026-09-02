import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/budget_monitor.dart';
import '../services/budget_widget_service.dart';
import '../services/drive_backup_service.dart';
import '../services/notification_service.dart';
import '../services/sms_import_service.dart';
import '../services/sms_source.dart';
import '../services/upcoming_monitor.dart';
import '../widgets/glossy.dart';
import 'accounts_screen.dart';
import 'add_transaction_sheet.dart';
import 'classifiers_screen.dart';
import 'dashboard_screen.dart';
import 'settings_screen.dart';
import 'transactions_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _index = 0;
  bool _importing = false;
  final _smsImport = SmsImportService();
  final _budgetMonitor = BudgetMonitor();
  final _upcomingMonitor = UpcomingMonitor();
  final _budgetWidgets = BudgetWidgetService();
  FinanceProvider? _finance;
  SettingsProvider? _settings;

  // Re-entrancy guard + throttle for auto-import: it now runs on every
  // resume as well as cold start, and resumes can arrive in bursts.
  bool _autoImporting = false;
  DateTime? _lastAutoImportAt;

  // Dashboard taps land on the Transactions tab with this filter applied;
  // the token tells the screen a new request arrived.
  TxFilterRequest? _request;
  int _filterToken = 0;

  // Stable tab instances: HomeScreen setStates (import spinner, tab index,
  // badge counts) would otherwise hand the stack three new widgets and
  // rebuild all three subtrees. Identical instances short-circuit at the
  // element level. Transactions is re-created only when a deep-link bumps
  // the token — that's what its didUpdateWidget listens for.
  late final Widget _dashboardTab = DashboardScreen(
    onViewTransactions: _viewTransactions,
    onViewCategory: _viewCategory,
    onViewGroup: _viewGroup,
    onViewBudget: _viewBudget,
    onViewMerchant: _viewMerchant,
  );
  late final Widget _accountsTab = AccountsScreen(onViewAccount: _viewAccount);
  TransactionsScreen? _transactionsTab;

  Widget get _transactionsTabWidget {
    if (_transactionsTab?.filterToken != _filterToken) {
      _transactionsTab = TransactionsScreen(
        request: _request,
        filterToken: _filterToken,
      );
    }
    return _transactionsTab!;
  }

  void _openTransactions(TxFilterRequest req) => setState(() {
    _request = req;
    _filterToken++;
    _index = 1;
  });

  void _viewTransactions(TxType type, DateTime month) =>
      _openTransactions(TxFilterRequest(type: type, month: month));

  // Tapping an account card jumps to Transactions filtered to that account.
  void _viewAccount(String accountId) =>
      _openTransactions(TxFilterRequest(accountId: accountId));

  // Dashboard spending rows: that category's (or group's) expenses in the
  // month the dashboard was showing.
  void _viewCategory(String categoryId, DateTime month) => _openTransactions(
    TxFilterRequest(type: TxType.expense, categoryId: categoryId, month: month),
  );

  // A null group is the dashboard's "Other" bucket → the ungrouped filter.
  // No type filter: group sums include grouped transfer outflows, so an
  // expense-only view wouldn't add up to the tapped figure.
  void _viewGroup(String? groupId, DateTime month) => _openTransactions(
    TxFilterRequest(groupId: groupId ?? kUngroupedFilterKey, month: month),
  );

  // Budget rows: the rows counting toward that budget in that month (budget
  // math is expense-only already — no type filter needed).
  void _viewBudget(String budgetId, DateTime month) =>
      _openTransactions(TxFilterRequest(budgetId: budgetId, month: month));

  // Top-merchant rows: merchants have no structured field, so the deep-link
  // pre-fills the free-text search with the normalized identity.
  void _viewMerchant(String query, DateTime month) => _openTransactions(
    TxFilterRequest(type: TxType.expense, month: month, query: query),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoImport();
      _ensureNotificationPermission();
      // Due reminders must run even on a quiet open — the budget listener
      // below only fires on data CHANGES, and a bill comes due without any.
      _checkUpcoming();
      // Unconditional: the listener-driven syncs only fire on CHANGES, so a
      // quiet open (nothing imported, nothing edited) never wrote the
      // widget snapshot — the widget config screen then claimed "No budgets
      // yet" against a ledger full of them.
      _syncBudgetWidgets();
      // Scheduled Drive backup — fire-and-forget, never blocks startup;
      // failures are recorded and surfaced in Settings.
      if (mounted) {
        unawaited(
          context.read<DriveBackupService>().checkAndRunScheduled(
            context.read<FinanceProvider>(),
            settings: context.read<SettingsProvider>().toBackupMap(),
          ),
        );
      }
    });
    // A single hook for budget checks: any transaction change (import, manual
    // add, confirm) notifies the provider, and we re-evaluate the cap.
    // _checkBudget also refreshes the home-screen budget widgets; the extra
    // settings listener covers cap/alert edits, which don't notify finance.
    _finance = context.read<FinanceProvider>();
    _finance!.addListener(_checkBudget);
    _settings = context.read<SettingsProvider>();
    _settings!.addListener(_syncBudgetWidgets);
  }

  /// "On launch" must include WARM launches: Android keeps the process in
  /// recents, so tapping the icon usually resumes the existing activity —
  /// initState's auto-import never re-ran and the feature looked flaky,
  /// firing only after the OS had actually killed the process. Resuming now
  /// runs the same auto-import (which also drains the ephemeral RCS
  /// notification buffer); a short throttle absorbs the resumed event that
  /// fires right after a cold start and rapid app switches.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final last = _lastAutoImportAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _autoImport();
  }

  /// Budget alerts are on by default, so the Settings toggle (the other
  /// place permission is requested) may never be touched — ask on launch
  /// when a cap is active. No-op once granted or permanently denied.
  Future<void> _ensureNotificationPermission() async {
    if (!mounted) return;
    final settings = context.read<SettingsProvider>();
    if (!settings.budgetAlerts || settings.monthlyBudget <= 0) return;
    await NotificationService.instance.requestPermission();
    // A pending alert may have been waiting on the permission.
    _checkBudget();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _finance?.removeListener(_checkBudget);
    _settings?.removeListener(_syncBudgetWidgets);
    super.dispose();
  }

  void _checkBudget() {
    if (!mounted) return;
    // Fire-and-forget from a ChangeNotifier listener: an escaping platform
    // error would otherwise vanish (or crash) on every data change.
    _budgetMonitor
        .check(
          context.read<FinanceProvider>(),
          context.read<SettingsProvider>(),
        )
        .catchError((Object e) => debugPrint('Budget check failed: $e'));
    // Imports can change what's due (a card payment clears the bill, a new
    // debit completes a recurring pattern) — re-evaluate alongside budgets.
    _checkUpcoming();
    _syncBudgetWidgets();
  }

  void _checkUpcoming() {
    if (!mounted) return;
    _upcomingMonitor
        .check(
          context.read<FinanceProvider>(),
          context.read<SettingsProvider>(),
        )
        .catchError((Object e) => debugPrint('Upcoming check failed: $e'));
  }

  /// Pushes fresh figures to the Android home-screen budget widgets. Cheap
  /// and self-deduplicating (the service skips unchanged snapshots), so it
  /// simply rides every budget check and settings change.
  void _syncBudgetWidgets() {
    if (!mounted) return;
    _budgetWidgets
        .sync(context.read<FinanceProvider>(), context.read<SettingsProvider>())
        .catchError((Object e) => debugPrint('Widget sync failed: $e'));
  }

  /// Scheduled import: runs on launch when the configured cadence is due.
  Future<void> _autoImport() async {
    if (!mounted || _autoImporting) return;
    _autoImporting = true;
    _lastAutoImportAt = DateTime.now();
    final settings = context.read<SettingsProvider>();
    final finance = context.read<FinanceProvider>();
    final messenger = ScaffoldMessenger.of(context);

    try {
      // Always drain the RCS notification buffer on every launch — the
      // buffer is ephemeral and cannot wait for the (optional) SMS
      // auto-import cadence. drainNotifications() is a no-op when access
      // hasn't been granted.
      final notifImported = await _smsImport.drainNotifications(finance);

      final result = await _smsImport.maybeAutoRun(
        finance,
        settings.autoImport,
      );
      if (!mounted) return;

      // Combine notification-only imports with SMS auto-import results.
      final totalImported = (result?.imported ?? 0) + notifImported;
      if (totalImported == 0) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Auto-import: $totalImported new transaction'
            '${totalImported == 1 ? '' : 's'} to review.',
          ),
        ),
      );
    } catch (e) {
      // Fire-and-forget from a post-frame callback — surface instead of
      // vanishing (e.g. READ_SMS revoked between the check and the query).
      debugPrint('Auto-import failed: $e');
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Auto-import failed — will retry on next launch.'),
          ),
        );
      }
    } finally {
      _autoImporting = false;
    }
  }

  static const _titles = ['Dashboard', 'Transactions', 'Accounts'];

  // Sentinels for the scan-window radio group.
  static const Duration _sinceLastScan = Duration.zero;
  static const Duration _customRange = Duration(days: -1);

  Future<void> _importFromSms() async {
    final messenger = ScaffoldMessenger.of(context);
    final finance = context.read<FinanceProvider>();

    var range = _sinceLastScan;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Import from SMS'),
          // Six radio rows + intro text overflow a landscape screen.
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Bank and UPI alert messages are scanned on-device only — '
                'nothing is uploaded. Choose how far back to scan:',
              ),
              const SizedBox(height: 8),
              RadioGroup<Duration>(
                groupValue: range,
                onChanged: (v) => setDialogState(() => range = v!),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (label, d) in [
                      ('New messages since last scan', _sinceLastScan),
                      ('Last 7 days', Duration(days: 7)),
                      ('Last 30 days', Duration(days: 30)),
                      ('Last 90 days', Duration(days: 90)),
                      ('Last year', Duration(days: 365)),
                      ('Custom date range…', _customRange),
                    ])
                      RadioListTile<Duration>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(label),
                        value: d,
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Scan messages'),
            ),
          ],
        ),
      ),
    );
    if (proceed != true) return;

    DateTimeRange? customRange;
    if (range == _customRange) {
      if (!mounted) return;
      customRange = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime.now(),
        initialDateRange: DateTimeRange(
          start: DateTime.now().subtract(const Duration(days: 30)),
          end: DateTime.now(),
        ),
      );
      if (customRange == null) return; // picker cancelled
    }

    setState(() => _importing = true);
    try {
      final result = await _smsImport.run(
        finance,
        lookback: range == _sinceLastScan || range == _customRange
            ? null
            : range,
        range: customRange,
      );
      if (result == null) {
        if (_smsImport.lastPermission == SmsPermission.blocked) {
          // The OS suppressed the permission dialog (READ_SMS is restricted
          // for sideloaded apps) — walk the user through the manual path.
          if (mounted) await _showBlockedHelp();
        } else {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('SMS permission denied — nothing imported.'),
            ),
          );
        }
      } else {
        final parts = <String>[];
        if (result.imported > 0) {
          parts.add('${result.imported} new to review');
        }
        if (result.spamDropped > 0) {
          parts.add('${result.spamDropped} spam dropped by your rules');
        }
        if (result.duplicates > 0) {
          parts.add('${result.duplicates} duplicates skipped');
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              parts.isEmpty
                  ? 'No new transactions found in '
                        '${result.scanned} scanned message${result.scanned == 1 ? '' : 's'}.'
                  : parts.join(' · '),
            ),
          ),
        );
        if (result.imported > 0) setState(() => _index = 1);
      }
    } catch (e) {
      // Without this a mid-scan platform error just cleared the spinner —
      // indistinguishable from "found nothing".
      debugPrint('SMS import failed: $e');
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Import failed — could not read the SMS inbox.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _showBlockedHelp() async {
    final openSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('SMS access is blocked by Android'),
        // Long 4-step instructions — must stay readable in landscape.
        scrollable: true,
        content: const Text(
          'Android restricts SMS access for apps installed outside the '
          'Play Store, so the permission dialog was not shown.\n\n'
          'To enable it manually:\n'
          '1. Open this app\'s settings (button below)\n'
          '2. Tap the ⋮ menu (top right) → "Allow restricted settings" '
          '(Android 13+; skip if not shown)\n'
          '3. Open Permissions → SMS → Allow\n'
          '4. Return here and tap the SMS icon again',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open app settings'),
          ),
        ],
      ),
    );
    if (openSettings == true) await _smsImport.openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    final onAccounts = _index == 2;
    // Counted directly: the selector runs on every provider change, and
    // materialising + sorting the pending list to read its length was pure
    // waste.
    final pendingCount = context.select<FinanceProvider, int>(
      (f) => f.pendingCount,
    );

    return Scaffold(
      appBar: AppBar(
        // Deliberately NOT animated. Two rounds of AnimatedSwitcher tuning
        // (sequential fade-through, then a start-anchored layoutBuilder)
        // still left short titles visibly entering offset and sliding into
        // place on-device — the switcher sizes its box to the widest of the
        // outgoing/incoming titles for the whole transition. A static title
        // cannot shift; the tab body's own fade-through carries the motion.
        title: Text(_titles[_index]),
        actions: [
          IconButton(
            tooltip: 'Classifiers',
            icon: const Icon(Icons.rule),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ClassifiersScreen()),
            ),
          ),
          // Same IconButton in both states (disabled + spinner icon while
          // importing) so the action row doesn't shift and the pending
          // badge doesn't blink out for the duration.
          if (_smsImport.isSupported)
            IconButton(
              tooltip: _importing ? 'Importing…' : 'Import from SMS',
              icon: Badge(
                isLabelVisible: pendingCount > 0,
                label: Text('$pendingCount'),
                child: _importing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sms_outlined),
              ),
              onPressed: _importing ? null : _importFromSms,
            ),
          // Import/Export/Delete-all moved into Settings → Data — the old
          // ⋮ menu's only remaining entry was Settings itself.
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: AmbientBackground(
        child: Column(
          children: [
            const _StorageWarningBanners(),
            Expanded(
              child: _FadeThroughIndexedStack(
                index: _index,
                children: [_dashboardTab, _transactionsTabWidget, _accountsTab],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: GlassButton(
        icon: Icons.add,
        label: onAccounts ? 'New account' : 'Add',
        onPressed: () => onAccounts
            ? showAddAccountDialog(context)
            : showAddTransactionSheet(context),
      ),
      // Solid kit-style bar; the theme paints the coral rounded indicator.
      bottomNavigationBar: NavigationBar(
        // Scales with the font setting — any constant (68, then 76) clips
        // the always-shown labels again at a large enough scale.
        height: MediaQuery.textScalerOf(context).scale(76),
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Transactions',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_balance_wallet_outlined),
            selectedIcon: Icon(Icons.account_balance_wallet),
            label: 'Accounts',
          ),
        ],
      ),
    );
  }
}

/// Storage-health banners: a dismissible one when parts of the stored data
/// couldn't be read at startup (each was skipped rather than bricking the
/// launch), and a persistent one while writes are failing — without it the
/// UI keeps accepting edits that silently evaporate on the next launch.
class _StorageWarningBanners extends StatefulWidget {
  const _StorageWarningBanners();

  @override
  State<_StorageWarningBanners> createState() => _StorageWarningBannersState();
}

class _StorageWarningBannersState extends State<_StorageWarningBanners> {
  bool _loadWarningDismissed = false;

  @override
  Widget build(BuildContext context) {
    final loadWarnings = context.select<FinanceProvider, String>(
      (f) => f.loadWarnings.join(', '),
    );
    final persistFailed = context.select<FinanceProvider, bool>(
      (f) => f.persistFailed,
    );
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        if (loadWarnings.isNotEmpty && !_loadWarningDismissed)
          MaterialBanner(
            backgroundColor: scheme.errorContainer,
            contentTextStyle: TextStyle(color: scheme.onErrorContainer),
            content: Text(
              'Some stored data could not be read and was skipped '
              '($loadWarnings). Restore from a backup if needed.',
            ),
            actions: [
              TextButton(
                onPressed: () => setState(() => _loadWarningDismissed = true),
                child: const Text('Dismiss'),
              ),
            ],
          ),
        if (persistFailed)
          MaterialBanner(
            backgroundColor: scheme.errorContainer,
            contentTextStyle: TextStyle(color: scheme.onErrorContainer),
            content: const Text(
              'Changes are not being saved — storage writes are failing.',
            ),
            actions: [
              TextButton(
                onPressed: () => context.read<FinanceProvider>().retryPersist(),
                child: const Text('Retry'),
              ),
            ],
          ),
      ],
    );
  }
}

/// Like [IndexedStack] (all tabs stay mounted, state preserved) but tab
/// switches fade-and-settle instead of snapping.
///
/// Hidden tabs used to sit in the stack at opacity 0 but fully live: screen
/// readers traversed all three tabs at once and their animations kept
/// ticking. Once a tab's fade-out completes it goes
/// [Offstage] (no paint, no hit-test), [ExcludeSemantics] hides it from
/// assistive tech, and [TickerMode] freezes its animations. The tab that is
/// still fading keeps painting so the cross-fade looks unchanged.
class _FadeThroughIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const _FadeThroughIndexedStack({required this.index, required this.children});

  @override
  State<_FadeThroughIndexedStack> createState() =>
      _FadeThroughIndexedStackState();
}

class _FadeThroughIndexedStackState extends State<_FadeThroughIndexedStack> {
  /// Tabs currently fading out — still painted until their fade ends. A set,
  /// not a single index: switching tabs twice within one fade used to evict
  /// the first tab from the slot and pop it offstage mid-fade.
  final Set<int> _fadingOut = {};

  @override
  void didUpdateWidget(_FadeThroughIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index != oldWidget.index) {
      _fadingOut
        ..add(oldWidget.index)
        ..remove(widget.index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _buildTab(
            i,
            active: i == widget.index,
            fading: _fadingOut.contains(i),
          ),
      ],
    );
  }

  Widget _buildTab(int i, {required bool active, required bool fading}) {
    return Offstage(
      offstage: !active && !fading,
      child: IgnorePointer(
        ignoring: !active,
        child: ExcludeSemantics(
          excluding: !active,
          child: AnimatedOpacity(
            opacity: active ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            // True fade-through (Material spec): the outgoing tab is gone in
            // the first ~90ms, the incoming one only starts appearing after
            // that. Simultaneous cross-fading double-exposed both tabs'
            // text for the whole transition.
            curve: active
                ? const Interval(0.4, 1, curve: Curves.easeOut)
                : const Interval(0, 0.4, curve: Curves.easeIn),
            onEnd: () {
              if (_fadingOut.contains(i) && mounted) {
                setState(() => _fadingOut.remove(i));
              }
            },
            child: AnimatedScale(
              scale: active ? 1 : 0.98,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              // Inside the fade widgets so a settling tab still animates;
              // only the tab's own tickers freeze while it is hidden.
              child: TickerMode(enabled: active, child: widget.children[i]),
            ),
          ),
        ),
      ),
    );
  }
}
