import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/notification_service.dart';
import '../utils/contrast.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import '../widgets/budget_dialog.dart';
import '../widgets/info_tip.dart';
import '../widgets/reminder_editor_dialog.dart';
import '../widgets/glossy.dart';

/// The Budgets and Reminders tabs of the Cockpit screen. The sections moved
/// here from Settings (2026-09) so all recurring money management lives in
/// one place; the editors stay in widgets/ because the dashboard shares them.

class BudgetsTab extends StatelessWidget {
  const BudgetsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        Text('Budget & alerts', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Set a monthly spending cap and get notified as you approach it. '
          'Checks run while the app is open (after imports or edits) — '
          'there is no always-on background monitoring.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        const _BudgetSection(),
        const SizedBox(height: 24),
        Text('Custom budgets', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Extra monthly limits beside the overall cap — e.g. "Personal '
          'spending" that leaves out family categories. Progress shows '
          'on the dashboard.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        const _CustomBudgetsSection(),
      ],
    );
  }
}

class RemindersTab extends StatelessWidget {
  const RemindersTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        InfoLabel(
          label: Text(
            'Reminders',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Reminders',
            message:
                'Reminders notify only when Payment reminders is on, in the '
                'Budgets tab.',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Bills the app cannot detect from SMS: cash, a new payee, '
          'money to send home. They show in Upcoming and notify on open.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        const _RemindersSection(),
      ],
    );
  }
}

/// Monthly cap amount, master alert toggle and the 80/90/overshoot threshold
/// switches. Enabling alerts requests notification permission.
class _BudgetSection extends StatefulWidget {
  const _BudgetSection();

  @override
  State<_BudgetSection> createState() => _BudgetSectionState();
}

class _BudgetSectionState extends State<_BudgetSection>
    with WidgetsBindingObserver {
  // Survives State re-creation: the "notifications blocked" row must not
  // appear/disappear a beat after the section rebuilds (height change
  // mid-scroll jerks the list).
  static NotificationStatus? _lastKnownNotifStatus;

  late final TextEditingController _capCtrl;
  late final FocusNode _capFocus;
  late final SettingsProvider _settings; // captured: dispose can't use context
  NotificationStatus? _notifStatus = _lastKnownNotifStatus;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsProvider>();
    final budget = _settings.monthlyBudget;
    _capCtrl = TextEditingController(
      text: budget <= 0 ? '' : budget.toStringAsFixed(0),
    );
    // Commit on focus loss, NOT per keystroke: notifying listeners on every
    // character rebuilds the whole screen with the keyboard open, and the
    // keep-focused-field-visible logic then fights scroll gestures.
    _capFocus = FocusNode()..addListener(_onCapFocusChange);
    // Resume re-check: a system-level block is fixed on an Android Settings
    // page, and the row must reflect that on the way back.
    WidgetsBinding.instance.addObserver(this);
    _checkNotifications();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkNotifications();
  }

  void _onCapFocusChange() {
    if (!_capFocus.hasFocus) _commitCap();
  }

  /// Set when the cap field holds text that doesn't parse — the old
  /// `parseAmount(...) ?? 0` silently switched the budget off while the
  /// field kept showing whatever was typed.
  String? _capError;

  Future<void> _checkNotifications() async {
    final status = await NotificationService.instance.status;
    _lastKnownNotifStatus = status;
    if (mounted) setState(() => _notifStatus = status);
  }

  @override
  void deactivate() {
    // Commit here rather than in dispose(): committing notifies
    // SettingsProvider, and by dispose() this route (or tab) is already being
    // torn down — marking the still-mounted widgets dirty at that point is a
    // framework error. setMonthlyBudget no-ops when the value is unchanged, so
    // an untouched field costs nothing. Tab switches inside Cockpit land here
    // too, so leaving the tab commits the cap.
    _commitCap(interactive: false);
    super.deactivate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Detach first: disposing a FocusNode fires a final focus-change, which
    // would otherwise re-enter _commitCap during teardown.
    _capFocus.removeListener(_onCapFocusChange);
    _capFocus.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  void _commitCap({bool interactive = true}) {
    // parseAmount, not double.tryParse: "50,000" must not read as null and
    // silently switch the budget off. Blank is the documented off switch;
    // anything else that fails to parse keeps the stored cap and shows an
    // error instead of quietly writing 0 ("50k" used to kill the budget
    // while the field still displayed 50k). During teardown
    // (interactive: false) there is no screen to show the error on, so bad
    // input just keeps the previous cap.
    final text = _capCtrl.text.trim();
    final v = text.isEmpty ? 0.0 : parseAmount(text);
    if (v == null || v < 0) {
      if (interactive && mounted) {
        setState(() => _capError = 'Enter a number, e.g. 45000');
      }
      return;
    }
    if (_capError != null && interactive && mounted) {
      setState(() => _capError = null);
    }
    _settings.setMonthlyBudget(v);
  }

  /// The cap tip's worked line: this month's spend against the cap, with the
  /// same figures and formatting as the dashboard's budget card. Reads the
  /// field first: opening the tip takes focus, which commits the typed cap,
  /// so the line must show that value rather than the one saved before.
  String? _capExample() {
    final typed = _capCtrl.text.trim();
    final cap = typed.isEmpty
        ? 0.0
        : parseAmount(typed) ?? _settings.monthlyBudget;
    if (cap <= 0) return null;
    final now = DateTime.now();
    final spent = context.read<FinanceProvider>().budgetSpentInMonth(
      DateTime(now.year, now.month),
    );
    return 'This month: ${fmtMoneyCompact(spent)} of '
        '${fmtMoneyCompact(cap)} (${(spent / cap * 100).round()}%)';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    // Alerts apply to the monthly cap AND custom budgets — enable the switch
    // when either exists.
    final hasCustomBudgets = context.select<FinanceProvider, bool>(
      (f) => f.budgets.any((b) => b.limit > 0),
    );
    final hasCap = settings.monthlyBudget > 0 || hasCustomBudgets;

    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Padding(
        // Generous top inset: the cap field's floating label must not touch
        // the panel's clipped edge.
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
        child: Column(
          children: [
            TextField(
              controller: _capCtrl,
              focusNode: _capFocus,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Monthly cap',
                prefixText: '₹ ',
                helperText: 'Leave blank to turn the budget off',
                errorText: _capError,
                suffixIcon: InfoTip(
                  title: 'Monthly cap',
                  message:
                      'Counts confirmed spending only. Pending imports, '
                      'transfers and card bill payments are left out, and a '
                      'split bill counts only your share.',
                  example: _capExample,
                ),
              ),
              // Unfocus (not just commit): pressing Done closes the keyboard
              // but leaves the field focused, and a focused field yanks the
              // scroll position back to itself ("keep caret visible") on
              // every later rebuild or inset change — the scroll-glitch bug.
              // Unfocusing also commits, via the focus listener.
              onSubmitted: (_) => _capFocus.unfocus(),
              onTapOutside: (_) => _capFocus.unfocus(),
            ),
            _SwitchWithTip(
              tip: const InfoTip(
                title: 'Budget alerts',
                message:
                    'Checks run only while the app is open. Each alert fires '
                    'at most once a month per budget, for the highest level '
                    'newly crossed. Changing a limit re-arms its alerts.',
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Budget alerts'),
                subtitle: Text(
                  hasCap
                      ? 'Notify as spending approaches the cap or a custom '
                            'budget limit'
                      : 'Set a cap or a custom budget to enable alerts',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: settings.budgetAlerts && hasCap,
                onChanged: hasCap
                    ? (on) async {
                        await context.read<SettingsProvider>().setBudgetAlerts(
                          on,
                        );
                        if (on) {
                          await NotificationService.instance
                              .requestPermission();
                        }
                        await _checkNotifications();
                      }
                    : null,
              ),
            ),
            // Alerts silently go nowhere while notifications cannot be shown —
            // say WHICH problem it is, since each has a different remedy and
            // only a fresh runtime denial can be fixed from inside the app.
            if (hasCap &&
                settings.budgetAlerts &&
                _notifStatus != null &&
                _notifStatus != NotificationStatus.enabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.notifications_off_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        switch (_notifStatus!) {
                          NotificationStatus.appBlocked =>
                            'Notifications are turned off for this app. '
                                'Turn them on in Android Settings → Apps → '
                                'Expense Tracker → Notifications.',
                          NotificationStatus.channelBlocked =>
                            'The "Budget alerts" notification channel is '
                                'muted in Android Settings.',
                          _ =>
                            'Notifications could not be initialised on this '
                                'device, so alerts cannot be shown.',
                        },
                        // The one row here the user must not miss: bodyMedium
                        // + w600 (12px error-on-white was under AA).
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // The system dialog only helps for a runtime denial; a
                    // muted channel or a plugin failure has no in-app fix.
                    if (_notifStatus == NotificationStatus.appBlocked)
                      TextButton(
                        onPressed: () async {
                          await NotificationService.instance
                              .requestPermission();
                          await _checkNotifications();
                        },
                        child: const Text('Request'),
                      ),
                  ],
                ),
              ),
            if (hasCap && settings.budgetAlerts) ...[
              for (final (level, label) in const [
                (80, 'At 80% of budget'),
                (90, 'At 90% of budget'),
                (100, 'When over budget'),
              ])
                _ThresholdSwitch(
                  level: level,
                  label: label,
                  value: switch (level) {
                    80 => settings.alert80,
                    90 => settings.alert90,
                    _ => settings.alertOver,
                  },
                ),
            ],
            // Independent of the cap: card due dates and detected recurring
            // payments exist without any budget.
            _SwitchWithTip(
              tip: const InfoTip(
                title: 'Payment reminders',
                message:
                    'Card bills notify once billed and unpaid, from 5 days '
                    'before the due date. Detected recurring payments and '
                    'your reminders notify from 2 days before. Each notifies '
                    'once per due month, when you open the app.',
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Payment reminders'),
                subtitle: Text(
                  'Card bills, your reminders and detected recurring '
                  'payments, checked when the app opens',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: settings.upcomingReminders,
                onChanged: (on) async {
                  await context.read<SettingsProvider>().setUpcomingReminders(
                    on,
                  );
                  if (on) {
                    await NotificationService.instance.requestPermission();
                  }
                  await _checkNotifications();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A switch row with its [InfoTip] beside the tile rather than inside it:
/// SwitchListTile merges its children's semantics, which would fold the
/// tip into the switch so a screen reader could never open it.
class _SwitchWithTip extends StatelessWidget {
  final Widget child;
  final InfoTip tip;
  const _SwitchWithTip({required this.child, required this.tip});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: child),
      tip,
    ],
  );
}

class _ThresholdSwitch extends StatelessWidget {
  final int level;
  final String label;
  final bool value;
  const _ThresholdSwitch({
    required this.level,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      // Right inset = the info tip beside the switches above, so all the
      // switches in the panel share one column.
      contentPadding: const EdgeInsets.only(left: 8, right: 32),
      title: Text(label),
      value: value,
      onChanged: (on) =>
          context.read<SettingsProvider>().setAlertThreshold(level, on),
    );
  }
}

/// User-defined spend limits: list with edit/delete plus an add flow.
/// The category/group pickers live in the dialog; progress renders on the
/// dashboard.
class _CustomBudgetsSection extends StatelessWidget {
  const _CustomBudgetsSection();

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;

    String subtitle(SpendBudget b) {
      final n = b.categoryIds.length;
      final scope = b.mode == BudgetMode.include
          ? 'Only $n ${n == 1 ? 'category' : 'categories'}'
          : (n == 0
                ? 'All spending'
                : 'All except $n ${n == 1 ? 'category' : 'categories'}');
      return '$scope · ${fmtMoneyCompact(b.limit)}/month';
    }

    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (finance.budgets.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  'No custom budgets yet.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final b in finance.budgets)
              ListTile(
                dense: true,
                onTap: () => showBudgetDialog(context, existing: b),
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.primary.withValues(alpha: 0.15),
                  child: Icon(
                    Icons.track_changes,
                    color: categoryGlyphColor(context, scheme.primary),
                    size: 18,
                  ),
                ),
                title: Text(b.name),
                subtitle: Text(
                  subtitle(b),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  tooltip: 'Delete budget',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _confirmDelete(context, b),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add budget'),
                onPressed: () => showBudgetDialog(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, SpendBudget b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${b.name}"?'),
        content: const Text('Transactions are not affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<FinanceProvider>().deleteBudget(b.id);
    }
  }
}

/// Manual monthly reminders: list with edit/delete plus an add flow. The
/// editor lives in widgets/ so the dashboard's Upcoming card shares it.
class _RemindersSection extends StatelessWidget {
  const _RemindersSection();

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final thisMonth = monthKey(DateTime.now());

    String subtitle(Reminder r) => [
      'Day ${r.dayOfMonth}',
      if (r.expectedAmount != null) fmtMoneyCompact(r.expectedAmount!),
      if (r.lastPaidMonth == thisMonth) 'paid this month',
    ].join(' · ');

    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (finance.reminders.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  'No reminders yet.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final r in finance.reminders)
              ListTile(
                dense: true,
                onTap: () => showReminderEditor(context, existing: r),
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: categoryById(
                    r.categoryId,
                  ).color.withValues(alpha: 0.15),
                  child: Icon(
                    categoryById(r.categoryId).icon,
                    color: categoryGlyphColor(
                      context,
                      categoryById(r.categoryId).color,
                    ),
                    size: 18,
                  ),
                ),
                title: Text(r.name),
                subtitle: Text(
                  subtitle(r),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  tooltip: 'Delete reminder',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _confirmDelete(context, r),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add reminder'),
                onPressed: () => showReminderEditor(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, Reminder r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${r.name}"?'),
        content: const Text('Transactions are not affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<FinanceProvider>().deleteReminder(r.id);
    }
  }
}
