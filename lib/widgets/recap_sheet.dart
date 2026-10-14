import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/monthly_recap.dart';
import 'monthly_recap_card.dart';

/// A past month's recap as a sheet, opened from the Dashboard's ⋮ menu on
/// any day of the month. The arrows step through [recapMonths] only, so a
/// month with no transactions is skipped. It watches the ledger, so edits
/// made while it is open show at once.
///
/// Each callback closes the sheet first, so the Transactions tab opens
/// with no sheet on top. The sheet passes no Done: it never hides the
/// Overview's recap.
Future<void> showRecapSheet(
  BuildContext context, {
  required DateTime month,
  void Function(String categoryId, DateTime month)? onViewCategory,
  void Function(String query, DateTime month)? onViewMerchant,
  void Function(String budgetId, DateTime month)? onViewBudget,
  void Function(DateTime month)? onViewSpending,
}) {
  // Outside the builder, so a step survives the sheet's rebuilds.
  var shown = DateTime(month.year, month.month);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => StatefulBuilder(
      builder: (ctx, setState) {
        final finance = ctx.watch<FinanceProvider>();
        final settings = ctx.watch<SettingsProvider>();
        final theme = Theme.of(ctx);
        final scheme = theme.colorScheme;
        // Newest first. The neighbours are found by date, not by index, so
        // the arrows still work when an edit empties the shown month.
        final months = recapMonths(finance.monthsWithData, recapClock());
        final earlier = months.where((m) => m.isBefore(shown)).firstOrNull;
        final later = months.where((m) => m.isAfter(shown)).lastOrNull;
        final recap = buildRecapFor(finance, settings, shown);
        final label = DateFormat('MMMM yyyy').format(shown);

        void step(DateTime to) => setState(() => shown = to);

        // Close the sheet, then run the Dashboard's link.
        void Function(A, DateTime)? closing<A>(
          void Function(A, DateTime)? link,
        ) => link == null
            ? null
            : (a, m) {
                Navigator.pop(ctx);
                link(a, m);
              };

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Previous recap',
                      onPressed: earlier == null ? null : () => step(earlier),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    // One line, shrinking if it must: at 320dp
                    // "September 2026 recap" wrapped onto two.
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '$label recap',
                          maxLines: 1,
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next recap',
                      onPressed: later == null ? null : () => step(later),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (recap == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'No transactions in $label',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  MonthlyRecapCard(
                    recap: recap,
                    showTitle: false,
                    onViewCategory: closing(onViewCategory),
                    onViewMerchant: closing(onViewMerchant),
                    onViewBudget: closing(onViewBudget),
                    onViewSpending: onViewSpending == null
                        ? null
                        : (m) {
                            Navigator.pop(ctx);
                            onViewSpending(m);
                          },
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
