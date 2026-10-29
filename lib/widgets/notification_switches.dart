import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/app_nav.dart';
import '../services/import_checks.dart';
import '../services/notification_service.dart';
import '../utils/app_theme.dart';
import 'glossy.dart';
import 'info_tip.dart';

/// The alert switches of Settings, Notifications: Budget alerts with its
/// 80/90/overshoot levels, Unusual spending alerts, Weekly digest and
/// Payment reminders, plus a warning when Android blocks notifications.
/// Turning a switch on requests notification permission.
class NotificationSwitches extends StatefulWidget {
  const NotificationSwitches({super.key});

  @override
  State<NotificationSwitches> createState() => _NotificationSwitchesState();
}

class _NotificationSwitchesState extends State<NotificationSwitches>
    with WidgetsBindingObserver {
  // Survives State re-creation: the "notifications blocked" row must not
  // appear or disappear a beat after the panel rebuilds (a height change
  // mid-scroll jerks the list).
  static NotificationStatus? _lastKnownNotifStatus;

  NotificationStatus? _notifStatus = _lastKnownNotifStatus;

  @override
  void initState() {
    super.initState();
    // Resume re-check: a system-level block is fixed on an Android Settings
    // page, and the row must reflect that on the way back.
    WidgetsBinding.instance.addObserver(this);
    _checkNotifications();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkNotifications();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkNotifications() async {
    final status = await NotificationService.instance.status;
    _lastKnownNotifStatus = status;
    if (mounted) setState(() => _notifStatus = status);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    // Alerts apply to the monthly cap and to custom budgets, so the switch
    // is enabled when either exists.
    final hasCustomBudgets = context.select<FinanceProvider, bool>(
      (f) => f.budgets.any((b) => b.limit > 0),
    );
    final hasCap = settings.monthlyBudget > 0 || hasCustomBudgets;

    return FrostedPanel(
      radius: BorderRadius.circular(AppRadius.card),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          children: [
            _SwitchWithTip(
              tip: const InfoTip(
                title: 'Budget alerts',
                message:
                    'Each alert fires at most once a month per budget, for '
                    'the highest level newly crossed. Changing a limit '
                    're-arms its alerts. Alerts are checked when the app '
                    'opens and about every 6 hours while it is closed.',
                link: InfoLink(
                  prompt: 'No cap set yet?',
                  label: 'Set a monthly cap',
                  onTap: goCockpitBudgets,
                ),
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Budget alerts'),
                subtitle: Text(
                  hasCap
                      ? 'Notify as spending nears the cap or a custom budget'
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
            // Alerts silently go nowhere while notifications cannot be
            // shown. Say WHICH problem it is, since each has a different
            // remedy and only a fresh runtime denial can be fixed from inside
            // the app.
            if (((hasCap && settings.budgetAlerts) ||
                    settings.unusualAlerts ||
                    settings.weeklyDigest ||
                    settings.importChecks ||
                    settings.upcomingReminders) &&
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
                        // and w600 (12px error-on-white was under AA).
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
            // Independent of the cap too: it measures each category against
            // its own usual month.
            _SwitchWithTip(
              tip: const InfoTip(
                title: 'Unusual spending alerts',
                message:
                    'A category alerts once a month when its spending so far '
                    'reaches 1.5 times its usual month and is at least '
                    '₹1,000 more. The usual month is the middle of up to 6 '
                    'whole months, so a category needs 2 whole months since '
                    'its first spend. '
                    'Alerts are checked when the app opens and about every 6 '
                    'hours while it is closed. '
                    "Tapping an alert opens the category's history.",
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Unusual spending alerts'),
                subtitle: Text(
                  'Notify when a category runs well past its usual month',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: settings.unusualAlerts,
                onChanged: (on) async {
                  await context.read<SettingsProvider>().setUnusualAlerts(on);
                  if (on) {
                    await NotificationService.instance.requestPermission();
                  }
                  await _checkNotifications();
                },
              ),
            ),
            // Only the note: the digest itself always opens from the
            // Overview and the ⋮ menu.
            _SwitchWithTip(
              tip: const InfoTip(
                title: 'Weekly digest',
                message:
                    "Every Monday at 9 AM, a note says last week's digest is "
                    'ready. The note shows no amounts. The digest also opens '
                    'any time from This week on the Overview or the ⋮ menu.',
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Weekly digest'),
                subtitle: Text(
                  'A note on Monday morning about last week',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: settings.weeklyDigest,
                onChanged: (on) async {
                  await context.read<SettingsProvider>().setWeeklyDigest(on);
                  if (on) {
                    await NotificationService.instance.requestPermission();
                  }
                  await _checkNotifications();
                },
              ),
            ),
            // Background imports only: one in front reports in its toast.
            _SwitchWithTip(
              tip: const InfoTip(
                title: 'Payments to check',
                message:
                    'When a background import counts a payment with a '
                    'guessed category or as To sort, a note shows it with '
                    'Keep and Change. Keep confirms the guess the next time '
                    "the app opens. The lock screen follows your phone's "
                    'setting for sensitive content.',
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Payments to check'),
                subtitle: Text(
                  'A note for each new payment counted with a guess or as '
                  'To sort',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                value: settings.importChecks,
                onChanged: (on) async {
                  final finance = context.read<FinanceProvider>();
                  await context.read<SettingsProvider>().setImportChecks(on);
                  if (on) {
                    await NotificationService.instance.requestPermission();
                  }
                  await ImportChecks.sync(finance, enabled: on);
                  await _checkNotifications();
                },
              ),
            ),
            // Independent of the cap: card due dates and detected recurring
            // payments exist without any budget.
            _SwitchWithTip(
              tip: const InfoTip(
                title: 'Payment reminders',
                message:
                    'Card bills notify once billed and unpaid, from 5 days '
                    'before the due date. Detected recurring payments and '
                    'your reminders notify from 2 days before. Each notifies '
                    'once per due month. Alerts are checked when the app '
                    'opens and about every 6 hours while it is closed.',
                link: InfoLink(
                  prompt: 'A bill the app cannot detect?',
                  label: 'Add a reminder',
                  onTap: goNewReminder,
                ),
              ),
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Payment reminders'),
                subtitle: Text(
                  'Card bills, your reminders and detected recurring payments',
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
