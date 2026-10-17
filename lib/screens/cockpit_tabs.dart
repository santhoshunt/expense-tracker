import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show NumberFormat;
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/spend_budget.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/big_bills.dart' show reminderIsBigBill;
import '../services/recurring_detector.dart';
import '../services/reminder_schedule.dart';
import '../services/subscriptions.dart';
import '../services/upcoming_items.dart' show hitMarkedPaid;
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../widgets/budget_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/fold_section.dart';
import '../widgets/info_tip.dart';
import '../widgets/rename_merchant_dialog.dart';
import '../widgets/reminder_editor_dialog.dart';
import '../widgets/tag_editor_dialog.dart';
import '../utils/text_scale.dart';
import '../widgets/glossy.dart';
import '../widgets/undo_snackbar.dart';
import 'app_nav.dart';
import 'transactions_screen.dart' show TxFilterRequest;

/// The Budgets and Reminders tabs of the Cockpit screen. The sections moved
/// here from Settings (2026-09) so all recurring money management lives in
/// one place; the editors stay in widgets/ because the dashboard shares them.
/// The alert switches live on Settings, Notifications.

class BudgetsTab extends StatelessWidget {
  const BudgetsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        Text('Monthly cap', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Set a monthly spending cap. Budget alerts for the cap and custom '
          'budgets are on the Notifications page in Settings.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            // Starts on the heading's left edge.
            style: flushTextButtonStyle,
            icon: const Icon(Icons.notifications_outlined),
            label: const Text('Notification settings'),
            onPressed: () => goNotificationSettings(context),
          ),
        ),
        const SizedBox(height: 4),
        const _MonthlyCapSection(),
        const SizedBox(height: 24),
        Text('Custom budgets', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Extra monthly limits beside the overall cap, e.g. "Personal '
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

/// A tab's title that is its own tip. Left-aligned: stretched across the
/// list, the whole row would open the tip.
class _TabHeading extends StatelessWidget {
  final Widget label;
  final InfoTip tip;

  const _TabHeading({required this.label, required this.tip});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: InfoLabel(label: label, tip: tip),
  );
}

class RemindersTab extends StatelessWidget {
  const RemindersTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        _TabHeading(
          label: Text(
            'Reminders',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Reminders',
            message:
                'Reminders notify only when Payment reminders is on, on the '
                'Notifications page in Settings.',
            link: InfoLink(
              prompt: 'Notifications not arriving?',
              label: 'Check Payment reminders',
              onTap: goNotificationSettings,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Bills the app cannot detect from SMS: cash, a new payee, '
          'money to send home. They show in Next 7 days and notify from 2 '
          'days before they are due.',
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

/// Every tag with its all-time spend, transaction count and date span. Tags
/// are added from a transaction's sheet or the bulk Tag action, so there is
/// no add button here; a tap opens the tag editor: rename, merge into an
/// existing tag, colour, delete, or see its transactions.
class TagsTab extends StatelessWidget {
  const TagsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final summaries = finance.tagSummaries;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        _TabHeading(
          label: Text('Tags', style: text.titleMedium),
          tip: const InfoTip(
            title: 'Tags',
            message:
                'Labels that cut across categories, like a trip or '
                '"Reimbursable". A transaction can carry up to 5. Spent '
                'counts money out as the dashboard does: your share of a '
                'split bill, and no transfers. Tap a tag to rename it, give '
                'it a colour, delete it or see its transactions. Renaming to '
                'an existing tag merges the two.',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Totals since the first tagged transaction, across every month.',
          style: text.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (summaries.isEmpty)
                  const EmptyState(
                    compact: true,
                    icon: Icons.label_outline,
                    message: 'Add tags when you add or edit a transaction.',
                  ),
                for (final s in summaries)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      Icons.sell,
                      size: 20,
                      color:
                          finance.tagColor(s.tag) ??
                          Theme.of(context).colorScheme.tertiary,
                    ),
                    title: Text(s.tag),
                    trailing: _rowChevron(context),
                    // Each fact stays whole when the line wraps.
                    subtitle: Text(
                      joinFacts([
                        '${fmtMoneyTidy(s.spent)} spent',
                        '${s.count} '
                            '${s.count == 1 ? 'transaction' : 'transactions'}',
                        fmtDateRange(
                          DateTimeRange(start: s.first, end: s.last),
                        ),
                      ]),
                      style: text.bodySmall,
                    ),
                    // The editor also opens the tag's transactions.
                    onTap: () => showTagEditor(context, s.tag),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Regular payments: the monthly ones the app spotted, plus the merchants
/// the user marked (from a transaction's sheet or the selection bar), with
/// what each costs, price rises, and the ones that stopped; the header
/// totals them a month and a year. Hiding shares the Upcoming card's list,
/// so a hidden income pattern can be unhidden here too.
class SubscriptionsTab extends StatefulWidget {
  const SubscriptionsTab({super.key});

  @override
  State<SubscriptionsTab> createState() => _SubscriptionsTabState();
}

class _SubscriptionsTabState extends State<SubscriptionsTab> {
  /// Folded by default and per visit: they are history, not the list.
  bool _stoppedOpen = false;
  bool _hiddenOpen = false;

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    // Selected by content, so other settings changes don't rebuild this.
    context.select<SettingsProvider, String>(
      (s) => hiddenListKey(s.hiddenUpcoming),
    );
    // Shared with the hub and the dashboard: one detection per change.
    final summary = cachedSubscriptions(
      finance,
      context.read<SettingsProvider>().hiddenUpcoming,
    );
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final count = summary.active.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
      children: [
        _TabHeading(
          label: Text('Subscriptions', style: text.titleMedium),
          tip: const InfoTip(
            title: 'Subscriptions',
            message:
                'Payments the app spotted repeating (3 or more to the same '
                'merchant about a month apart, from SMS or your notes), and '
                'merchants you marked as a subscription in a transaction or '
                'from the selection bar, monthly, quarterly, half-yearly or '
                'yearly. A '
                'yearly cost is the usual amount over a year. "Up" means the '
                'last payment was more than the one before. A payment more '
                'than a week past its date moves to Stopped. Hiding one here '
                'also hides it from Upcoming.',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          count == 0
              ? 'Regular payments show here once the app spots them or you '
                    'mark one.'
              : '$count regular ${count == 1 ? 'payment' : 'payments'} · '
                    '${fmtMoneyTidy(summary.monthlyTotal)} a month · '
                    '${fmtMoneyTidy(summary.yearlyTotal)} a year',
          style: muted,
        ),
        const SizedBox(height: 12),
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (summary.active.isEmpty)
                  const EmptyState(
                    compact: true,
                    icon: Icons.autorenew,
                    message: 'No regular payments spotted yet.',
                  ),
                for (final item in summary.active)
                  _SubscriptionTile(item: item, kind: _SubKind.active),
              ],
            ),
          ),
        ),
        if (summary.stopped.isNotEmpty)
          FoldSection(
            title: 'Stopped (${summary.stopped.length})',
            open: _stoppedOpen,
            onToggle: () => setState(() => _stoppedOpen = !_stoppedOpen),
            children: [
              for (final item in summary.stopped)
                _SubscriptionTile(item: item, kind: _SubKind.stopped),
            ],
          ),
        if (summary.hidden.isNotEmpty)
          FoldSection(
            title: 'Hidden (${summary.hidden.length})',
            open: _hiddenOpen,
            onToggle: () => setState(() => _hiddenOpen = !_hiddenOpen),
            children: [
              for (final item in summary.hidden)
                _SubscriptionTile(item: item, kind: _SubKind.hidden),
            ],
          ),
      ],
    );
  }
}

enum _SubKind { active, stopped, hidden }

class _SubscriptionTile extends StatelessWidget {
  final SubscriptionItem item;
  final _SubKind kind;

  const _SubscriptionTile({required this.item, required this.kind});

  @override
  Widget build(BuildContext context) {
    final hit = item.hit;
    final category = categoryById(hit.categoryId, fallbackType: hit.type);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // No-break spaces: at large text "next 5 Nov" wraps whole rather than
    // leaving "Nov" alone on the next line.
    String keep(String s) => s.replaceAll(' ', ' ');
    final when = kind == _SubKind.active
        ? keep('next ${fmtDateCompact(hit.nextDue)}')
        : hit.type == TxType.expense
        ? 'last paid ${keep(fmtDateCompact(hit.lastDate))}'
        : 'last received ${keep(fmtDateCompact(hit.lastDate))}';
    final rise = item.priceRise;
    final cycle = context.select<FinanceProvider, SubscriptionCycle?>(
      (f) => f.subscriptionPinOf(hit.key),
    );
    // The yearly cost sits in the tab's header line, so a row keeps to its
    // amount and date.
    final details = Text.rich(
      TextSpan(
        text:
            '${fmtMoneyTidy(hit.expectedAmount)} '
            '${(cycle ?? SubscriptionCycle.monthly).label.toLowerCase()} · '
            '$when',
        children: [
          if (cycle != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: 'Marked by you',
                  child: Icon(
                    Icons.push_pin_outlined,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
      style: text.bodySmall,
    );
    final Widget? extra = kind == _SubKind.hidden
        ? TextButton(
            onPressed: () =>
                context.read<SettingsProvider>().unhideUpcoming(hit.key),
            child: const Text('Unhide'),
          )
        : rise == null || kind != _SubKind.active
        ? null
        // Colour on the border and text only, never a filled badge.
        : Tooltip(
            message:
                'Up ${fmtMoneyTidy(rise.amount)} since '
                '${fmtDateCompact(rise.since)}',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: scheme.error),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Up ${fmtMoneyTidy(rise.amount)}',
                style: text.labelSmall?.copyWith(color: scheme.error),
              ),
            ),
          );
    // At large text, Unhide or the badge takes a line under the subtitle
    // so the name keeps its width at 320dp.
    final stacked = isLargeTextScale(context);

    return ListTile(
      dense: true,
      // Tap opens the actions sheet, which also lists its transactions.
      onTap: () => _actions(context),
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: category.color.withValues(alpha: 0.15),
        child: Icon(
          category.icon,
          color: categoryGlyphColor(context, category.color),
          size: 18,
        ),
      ),
      title: Text(hit.label),
      subtitle: stacked && extra != null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [details, const SizedBox(height: 4), extra],
            )
          : details,
      trailing: stacked
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [?extra, ?_rowChevron(context)],
            ),
    );
  }

  /// Tap: see its transactions, rename the payee, turn it into a reminder,
  /// or hide it; one marked paid by hand can be marked unpaid; a merchant
  /// the user marked can also change its cycle or be unmarked.
  Future<void> _actions(BuildContext context) async {
    final hit = item.hit;
    final marked = hit.pinned;
    // Marked paid by hand from Upcoming or the heatmap: the lasting way
    // back once that toast is gone.
    final paidByHand = hitMarkedPaid(context.read<FinanceProvider>(), hit);
    final choice = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      // Scrolls: a marked merchant has six actions, more than the sheet's
      // height holds on a short screen or at large text.
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.list_alt),
                title: const Text('See transactions'),
                onTap: () => Navigator.pop(ctx, 'see'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename'),
                onTap: () => Navigator.pop(ctx, 'rename'),
              ),
              // Reminders are for money going out; a hidden income pattern
              // has no bill to remind of.
              if (hit.type == TxType.expense)
                ListTile(
                  leading: const Icon(Icons.add_alert_outlined),
                  title: const Text('Make a reminder'),
                  subtitle: const Text(
                    'For bills that may stop showing in SMS',
                  ),
                  onTap: () => Navigator.pop(ctx, 'reminder'),
                ),
              if (paidByHand)
                ListTile(
                  leading: const Icon(Icons.undo),
                  title: const Text('Mark unpaid'),
                  subtitle: const Text('Its latest payment is due again'),
                  onTap: () => Navigator.pop(ctx, 'unpaid'),
                ),
              if (marked) ...[
                ListTile(
                  leading: const Icon(Icons.autorenew),
                  title: const Text('Change cycle'),
                  subtitle: const Text(
                    'Monthly, quarterly, half-yearly or yearly',
                  ),
                  onTap: () => Navigator.pop(ctx, 'cycle'),
                ),
                ListTile(
                  leading: const Icon(Icons.remove_circle_outline),
                  title: const Text('Not a subscription'),
                  subtitle: const Text('Removes your mark'),
                  onTap: () => Navigator.pop(ctx, 'unmark'),
                ),
              ],
              if (kind != _SubKind.hidden)
                ListTile(
                  leading: const Icon(Icons.visibility_off_outlined),
                  title: const Text('Hide'),
                  subtitle: const Text('Also hides it from Upcoming'),
                  onTap: () => Navigator.pop(ctx, 'hide'),
                ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'see':
        AppNav.instance.openTransactions(
          context,
          // The subscription's own tab: All would also list uncounted wallet
          // rows that its figures leave out.
          TxFilterRequest(type: hit.type, query: item.identity),
        );
      case 'rename':
        await showRenameMerchantDialog(
          context,
          identity: item.identity,
          currentLabel: hit.label,
        );
      case 'reminder':
        await showReminderEditor(
          context,
          name: hit.label,
          dayOfMonth: hit.nextDue.day,
          amount: hit.expectedAmount,
          categoryId: hit.categoryId,
          // Reminders repeat like the plan, in the month it is next due.
          cycle: hit.cycle ?? SubscriptionCycle.monthly,
          anchorMonth: hit.nextDue.month,
        );
      case 'hide':
        final settings = context.read<SettingsProvider>();
        // The toast first: hiding rebuilds the list, which can unmount this
        // very tile before the preference write returns.
        showUndoSnackBar(
          context,
          'Hid "${hit.label}"',
          () => settings.unhideUpcoming(hit.key),
          icon: Icons.visibility_off_outlined,
          tone: AppToastTone.removal,
        );
        await settings.hideUpcoming(hit.key);
      case 'unpaid':
        final finance = context.read<FinanceProvider>();
        final before = finance.patternPaidThrough(hit.key);
        showUndoSnackBar(
          context,
          'Marked "${hit.label}" unpaid',
          () => finance.restorePatternPaid(hit.key, before),
          icon: Icons.undo,
        );
        await finance.restorePatternPaid(hit.key, null);
      case 'cycle':
        final finance = context.read<FinanceProvider>();
        final current = finance.subscriptionPinOf(hit.key);
        final next = await showModalBottomSheet<SubscriptionCycle>(
          context: context,
          useSafeArea: true,
          showDragHandle: true,
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in SubscriptionCycle.values)
                  ListTile(
                    title: Text(c.label),
                    trailing: c == current ? const Icon(Icons.check) : null,
                    onTap: () => Navigator.pop(ctx, c),
                  ),
              ],
            ),
          ),
        );
        if (next == null || next == current) return;
        await finance.setSubscriptionPins({hit.key: next});
      case 'unmark':
        final finance = context.read<FinanceProvider>();
        final settings = context.read<SettingsProvider>();
        final messenger = ScaffoldMessenger.of(context);
        final before = finance.subscriptionPinsBefore([hit.key]);
        final wasHidden = settings.hiddenUpcoming.contains(hit.key);
        // A merchant the app would still spot on its own is hidden too,
        // or it would stay on the list as a detected subscription.
        final spotted = detectRecurringPatterns(
          finance.countedTransactions,
          now: DateTime.now(),
        ).any((h) => h.key == hit.key);
        // Both writes first, then the toast: an Undo tapped mid-write would
        // otherwise be overtaken by the hide that followed it.
        await finance.setSubscriptionPins({hit.key: null});
        if (spotted) await settings.hideUpcoming(hit.key);
        showAppToastOn(
          messenger,
          '"${hit.label}" is no longer a subscription',
          tone: AppToastTone.removal,
          icon: Icons.remove_circle_outline,
          actionLabel: 'Undo',
          duration: const Duration(seconds: 5),
          onAction: () async {
            await finance.setSubscriptionPins(before);
            if (!wasHidden) await settings.unhideUpcoming(hit.key);
          },
        );
    }
  }
}

/// The trailing mark of a row that opens its editor on tap, dropped at
/// large text so the words get the width.
Widget? _rowChevron(BuildContext context) => isLargeTextScale(context)
    ? null
    : Icon(
        Icons.chevron_right,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );

/// The monthly cap amount. Its alerts are on Settings, Notifications.
class _MonthlyCapSection extends StatefulWidget {
  const _MonthlyCapSection();

  @override
  State<_MonthlyCapSection> createState() => _MonthlyCapSectionState();
}

class _MonthlyCapSectionState extends State<_MonthlyCapSection> {
  late final TextEditingController _capCtrl;
  late final FocusNode _capFocus;
  late final SettingsProvider _settings; // captured: dispose can't use context

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsProvider>();
    final budget = _settings.monthlyBudget;
    _capCtrl = TextEditingController(text: _capText(budget));
    // Commit on focus loss, NOT per keystroke: notifying listeners on every
    // character rebuilds the whole screen with the keyboard open, and the
    // keep-focused-field-visible logic then fights scroll gestures.
    _capFocus = FocusNode()..addListener(_onCapFocusChange);
  }

  void _onCapFocusChange() {
    if (!_capFocus.hasFocus) _commitCap();
  }

  /// Indian grouping, as every amount on screen reads ("40,000",
  /// "1,50,000"); blank for no cap. parseAmount reads the commas back.
  static final NumberFormat _capGrouping = NumberFormat.decimalPattern('en_IN');

  static String _capText(double cap) =>
      cap <= 0 ? '' : _capGrouping.format(cap);

  /// Set when the cap field holds text that doesn't parse — the old
  /// `parseAmount(...) ?? 0` silently switched the budget off while the
  /// field kept showing whatever was typed.
  String? _capError;

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
    // Typed "40000" reads back "40,000" once the field lets go. Not during
    // teardown: the field is going away.
    if (interactive && mounted) {
      final shown = _capText(v);
      if (_capCtrl.text != shown) _capCtrl.text = shown;
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
    return 'This month: ${fmtMoneyTidy(spent)} of '
        '${fmtMoneyTidy(cap)} (${(spent / cap * 100).round()}%)';
  }

  @override
  Widget build(BuildContext context) {
    return FrostedPanel(
      radius: BorderRadius.circular(AppRadius.card),
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
                // The theme's borderless outline floats the label onto the
                // box's top edge, half outside the fill. A borderless
                // underline keeps it inside; focus draws the accent line.
                border: const UnderlineInputBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(AppRadius.control),
                  ),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: const UnderlineInputBorder(
                  borderRadius: BorderRadius.all(
                    Radius.circular(AppRadius.control),
                  ),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: UnderlineInputBorder(
                  borderRadius: const BorderRadius.all(
                    Radius.circular(AppRadius.control),
                  ),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 1.5,
                  ),
                ),
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
                  link: const InfoLink(
                    prompt: 'Where does this show?',
                    label: 'Open the dashboard',
                    onTap: goDashboard,
                  ),
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
          ],
        ),
      ),
    );
  }
}

/// User-defined spend limits: a tap edits, and Delete lives in the editor;
/// adding goes through the Cockpit FAB. The category/group pickers live in
/// the dialog; progress renders on the dashboard.
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
      return '$scope · ${fmtMoneyTidy(b.limit)} a month';
    }

    return FrostedPanel(
      radius: BorderRadius.circular(AppRadius.card),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // No button: the tab's 'New budget' FAB is the add flow.
            if (finance.budgets.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.track_changes,
                message: 'No custom budgets yet.',
              ),
            for (final b in finance.budgets)
              ListTile(
                dense: true,
                onTap: () =>
                    showBudgetDialog(context, existing: b, allowDelete: true),
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
                trailing: _rowChevron(context),
              ),
          ],
        ),
      ),
    );
  }
}

/// Manual monthly reminders: a tap edits, and Delete lives in the editor;
/// adding goes through the Cockpit FAB. The editor lives in widgets/ so the
/// dashboard's Upcoming card shares it.
class _RemindersSection extends StatelessWidget {
  const _RemindersSection();

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final now = DateTime.now();

    String subtitle(Reminder r) => [
      reminderCycleLabel(r),
      if (r.expectedAmount != null) fmtMoneyTidy(r.expectedAmount!),
      if (r.autoAdd) 'adds itself',
      // A one-time reminder past its date or paid needs nothing more; it
      // stays listed so it can be deleted.
      if (reminderFinished(r, now))
        'done'
      else if (reminderPaidThisPeriod(r, now))
        'paid',
    ].join(' · ');

    Widget details(Reminder r) =>
        Text(subtitle(r), style: Theme.of(context).textTheme.bodySmall);

    // The lasting way back from a paid mark once its toast is gone. Only a
    // real mark: Add it for me before its start date reads as paid too.
    Widget? unpaidButton(Reminder r) =>
        r.lastPaidMonth == null || !reminderPaidThisPeriod(r, now)
        ? null
        : TextButton(
            onPressed: () => _markUnpaid(context, r),
            child: const Text('Mark unpaid'),
          );
    // At large text the button takes a line under the subtitle, so the
    // name keeps its width.
    final stacked = isLargeTextScale(context);

    return FrostedPanel(
      radius: BorderRadius.circular(AppRadius.card),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // No button: the tab's 'New reminder' FAB is the add flow.
            if (finance.reminders.isEmpty)
              const EmptyState(
                compact: true,
                icon: Icons.event_repeat_outlined,
                message: 'No reminders yet.',
              ),
            for (final r in finance.reminders)
              ListTile(
                dense: true,
                onTap: () =>
                    showReminderEditor(context, existing: r, allowDelete: true),
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
                subtitle: stacked && unpaidButton(r) != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [details(r), unpaidButton(r)!],
                      )
                    : details(r),
                trailing: stacked
                    ? null
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [?unpaidButton(r), ?_rowChevron(context)],
                      ),
              ),
            if (finance.reminders.any(reminderIsBigBill))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Quarterly, half-yearly and yearly reminders with an amount '
                  'also show in Big bills ahead on the Overview.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Steps the paid mark back one period (a one-time reminder loses it) and
  /// offers Undo, which marks that month paid again.
  Future<void> _markUnpaid(BuildContext context, Reminder r) async {
    final finance = context.read<FinanceProvider>();
    final before = r.lastPaidMonth;
    if (before == null) return;
    // The toast first: the rebuild drops this row's button, and the toast
    // needs a mounted context.
    showUndoSnackBar(
      context,
      'Marked "${r.name}" unpaid',
      () => finance.markReminderPaid(r.id, DateTime.parse('$before-01')),
      icon: Icons.undo,
    );
    await finance.unmarkLatestReminderPaid(r.id);
  }
}
