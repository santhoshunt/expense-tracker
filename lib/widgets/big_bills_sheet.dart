import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../screens/app_nav.dart';
import '../services/big_bills.dart';
import '../services/recurring_detector.dart' show RecurringHit;
import '../services/reminder_schedule.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';
import 'reminder_editor_dialog.dart';

/// Every big bill with its share a month, under the monthly figure and the
/// 12-month strip. Opened from the Overview's Big bills ahead card. It
/// watches the ledger and the hide list and rebuilds the plan from
/// [patterns] (the Dashboard's detected repeats), so an edit shows at once.
/// A row opens its reminder's editor, or Cockpit's Subscriptions for a
/// marked merchant, after closing the sheet.
Future<void> showBigBillsSheet(
  BuildContext context, {
  required List<RecurringHit> patterns,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => Builder(
      builder: (ctx) {
        final finance = ctx.watch<FinanceProvider>();
        final hidden = ctx.watch<SettingsProvider>().hiddenUpcoming;
        final plan = buildBigBillsPlan(
          finance,
          patterns: patterns,
          hidden: hidden,
          now: DateTime.now(),
        );
        final theme = Theme.of(ctx);
        final text = theme.textTheme;
        final scheme = theme.colorScheme;
        final muted = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
        final out = moneyColor(ctx, type: TxType.expense);

        // The reminder a bill came from; null for a marked subscription, or
        // when the reminder has gone.
        Reminder? reminderFor(BigBill b) {
          final id = b.reminderId;
          if (id == null) return null;
          for (final r in finance.reminders) {
            if (r.id == id) return r;
          }
          return null;
        }

        // Closes the sheet first; the next screen opens on the context that
        // opened it, which is still mounted.
        void open(BigBill b) {
          Navigator.pop(ctx);
          if (b.reminderId == null) {
            goCockpitSubscriptions(context);
            return;
          }
          if (reminderFor(b) case final r?) {
            showReminderEditor(context, existing: r);
          }
        }

        String detail(BigBill b) {
          if (reminderFor(b) case final r?) return reminderCycleLabel(r);
          return '${b.cycle.label} · next ${fmtDate(b.nextDue)}';
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Big bills ahead', style: text.titleLarge),
                const SizedBox(height: 12),
                BigBillsHeadline(plan: plan),
                Text('${fmtMoneyTidy(plan.yearly)} a year', style: muted),
                const SizedBox(height: 16),
                BigBillsStrip(plan: plan, height: 96),
                const SizedBox(height: 16),
                if (plan.bills.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No quarterly, half-yearly or yearly bills.',
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                for (final b in plan.bills)
                  InkWell(
                    onTap: () => open(b),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 56),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            _CategoryIcon(categoryId: b.categoryId),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Two lines: at large text one cut
                                  // "Health insurance" to "Health insur…".
                                  Text(
                                    b.label,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(detail(b), style: muted),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // Up to half the row; a long figure shrinks
                            // rather than pushing the name off.
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      fmtMoneyTidy(b.amount),
                                      maxLines: 1,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: out,
                                      ),
                                    ),
                                  ),
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '${fmtMoneyTidy(b.monthly)} a month',
                                      maxLines: 1,
                                      style: muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// The monthly figure, plain (a target, not money spent), then "a month to
/// set aside". Shared by the Overview card and the sheet.
class BigBillsHeadline extends StatelessWidget {
  final BigBillsPlan plan;

  const BigBillsHeadline({super.key, required this.plan});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.end,
      spacing: 8,
      children: [
        Text(
          fmtMoneyTidy(plan.monthly),
          style: text.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(
            'a month to set aside',
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// One bar per month for the 12 months from this one, scaled to the
/// largest, in the money-out red; a month with nothing due is a 2dp grey
/// stub. Each month's initial sits under its bar, this month's in bold.
class BigBillsStrip extends StatelessWidget {
  final BigBillsPlan plan;
  final double height;

  const BigBillsStrip({super.key, required this.plan, this.height = 40});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final red = moneyColor(context, type: TxType.expense);
    final initial = DateFormat('MMMMM');
    final name = DateFormat('MMM yyyy');
    final largest = plan.months.fold(0.0, (m, e) => e.due > m ? e.due : m);
    final label = [
      for (final e in plan.months)
        if (e.due > 0) '${name.format(e.month)} ${fmtMoneyTidy(e.due)}',
    ];
    return Semantics(
      label: label.isEmpty
          ? 'Nothing due in the next 12 months'
          : 'Due by month: ${label.join(', ')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final (i, e) in plan.months.indexed) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: e.due > 0 && largest > 0
                        ? FractionallySizedBox(
                            alignment: Alignment.bottomCenter,
                            // A small bill stays visible beside a big one.
                            heightFactor: (e.due / largest).clamp(0.06, 1.0),
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: red,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                          )
                        : Container(height: 2, color: scheme.outlineVariant),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final (i, e) in plan.months.indexed) ...[
                if (i > 0) const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    initial.format(e.month),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.clip,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: i == 0 ? FontWeight.w700 : null,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A bill's category icon on its own tint, as the Cockpit lists draw it.
class _CategoryIcon extends StatelessWidget {
  final String categoryId;

  const _CategoryIcon({required this.categoryId});

  @override
  Widget build(BuildContext context) {
    final c = categoryById(categoryId, fallbackType: TxType.expense);
    return CircleAvatar(
      radius: 16,
      backgroundColor: c.color.withValues(alpha: 0.15),
      child: Icon(
        c.icon,
        size: 18,
        color: categoryGlyphColor(context, c.color),
      ),
    );
  }
}
