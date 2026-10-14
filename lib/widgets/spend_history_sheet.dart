import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../providers/finance_provider.dart';
import '../services/recurring_detector.dart'
    show merchantDisplayLabel, recurringKeyOf;
import '../services/spend_comparison.dart' show kUsualWindowMonths;
import '../services/spend_history.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import 'monthly_bar_chart.dart';
import 'rename_merchant_dialog.dart';

/// One category's or merchant's spend across [months]: a bar per month,
/// its usual month, its biggest month and the shown month's (or year's)
/// total, with the jump into its transactions. Opened by tapping a
/// category or merchant on the dashboard. It watches the ledger, so edits
/// made while it is open show at once.
Future<void> showSpendHistorySheet(
  BuildContext context, {
  required HistorySubject subject,
  required List<DateTime> months,
  required String windowLabel,
  required bool yearView,
  IconData? icon,
  Color? color,
  VoidCallback? onViewTransactions,
}) {
  // A merchant's identity (the key after "kind|"), for its Rename button.
  final key = subject.merchantKey;
  final identity = key?.substring(key.indexOf('|') + 1);
  // The name it had on opening, when that was the user's own: a Reset in
  // Rename then falls back to the detected identity, not that old name.
  final openAlias = identity == null
      ? null
      : context.read<FinanceProvider>().merchantAlias(identity);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => Builder(
      builder: (ctx) {
        final finance = ctx.watch<FinanceProvider>();
        final h = buildSpendHistory(
          finance,
          subject: subject,
          months: months,
          now: DateTime.now(),
        );
        final theme = Theme.of(ctx);
        final scheme = theme.colorScheme;
        final muted = theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        );
        final mmmYyyy = DateFormat('MMM yyyy');
        final usual = h.usual;
        final biggestMonth = h.biggestMonth;
        // The button opens the tapped period's rows, so it only shows when
        // that period has rows: never an empty list. Rows, not spend: a
        // split the user paid none of is ₹0 here but still a row to open.
        final periodRows = yearView ? h.totalCount : h.anchorCount;
        // A rename made from here shows at once.
        final alias = identity == null ? null : finance.merchantAlias(identity);
        final title =
            alias ??
            (openAlias != null
                ? _detectedLabel(finance, key!, identity!)
                : subject.label);

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: color == null
                          ? scheme.surfaceContainerHigh
                          : color.withValues(alpha: 0.15),
                      child: Icon(
                        icon ?? Icons.bar_chart_outlined,
                        size: 22,
                        color: color == null
                            ? scheme.onSurfaceVariant
                            : categoryGlyphColor(ctx, color),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: theme.textTheme.titleLarge,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(windowLabel, style: muted),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (h.empty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      'Nothing spent on $title in these months.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  MonthlyBarChart(
                    months: months,
                    seriesOf: (m) {
                      final i = h.months.indexOf(m);
                      return i < 0 ? 0.0 : h.amounts[i];
                    },
                    seriesLabel: 'Spent',
                    barColor: color,
                  ),
                const SizedBox(height: 16),
                _TileRow(
                  tiles: [
                    _Tile(
                      title: 'Usual month',
                      value: usual == null ? null : fmtMoney(usual),
                      none: 'Not enough months yet',
                      // The Categories vs usual card counts a running month
                      // to today's date, so its figure can differ.
                      note: 'Middle of up to $kUsualWindowMonths whole months',
                    ),
                    _Tile(
                      title: 'Biggest',
                      value: biggestMonth == null ? null : fmtMoney(h.biggest),
                      none: 'None yet',
                      note: biggestMonth == null
                          ? null
                          : mmmYyyy.format(biggestMonth),
                    ),
                    if (yearView)
                      _Tile(title: 'Year total', value: fmtMoney(h.total))
                    else
                      // The shown month, which is not always this one.
                      _Tile(
                        title: h.anchorRunning
                            ? 'This month so far'
                            : 'In ${DateFormat('MMMM').format(h.anchor)}',
                        value: fmtMoney(h.anchorAmount),
                        note: mmmYyyy.format(h.anchor),
                      ),
                  ],
                ),
                if (onViewTransactions != null && periodRows > 0) ...[
                  const SizedBox(height: 20),
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.receipt_long_outlined, size: 18),
                    label: const Text('View transactions'),
                    onPressed: () {
                      Navigator.pop(ctx);
                      onViewTransactions();
                    },
                  ),
                ],
                // The same rename as a long-press on a Top merchants row,
                // in sight here.
                if (identity != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('Rename'),
                    onPressed: () => showRenameMerchantDialog(
                      ctx,
                      identity: identity,
                      currentLabel: title,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// A merchant's name without the user's own: what Top merchants shows for
/// its rows ([merchantDisplayLabel]), or [identity] when it has none.
String _detectedLabel(FinanceProvider finance, String key, String identity) {
  for (final t in finance.countedTransactions) {
    if (recurringKeyOf(t) == key) return merchantDisplayLabel(t);
  }
  return identity;
}

/// The figure tiles: three across, equal in width and height, when each
/// gets at least [_minWidth] at the current text scale; otherwise one per
/// row, full width.
class _TileRow extends StatelessWidget {
  final List<Widget> tiles;

  const _TileRow({required this.tiles});

  /// Three fit on a 360dp phone at normal text (320dp inside the sheet's
  /// padding), and stack at 320dp or with larger text.
  static const _minWidth = 96.0;
  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) {
    final minTile = MediaQuery.textScalerOf(context).scale(_minWidth);
    // LayoutBuilder stays outside IntrinsicHeight: it cannot report
    // intrinsic sizes.
    return LayoutBuilder(
      builder: (context, constraints) {
        final across =
            constraints.maxWidth >=
            tiles.length * minTile + (tiles.length - 1) * _gap;
        if (across) {
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, t) in tiles.indexed) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  Expanded(child: t),
                ],
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, t) in tiles.indexed) ...[
              if (i > 0) const SizedBox(height: _gap),
              t,
            ],
          ],
        );
      },
    );
  }
}

/// One figure on a plain surface card, in the default text colours.
class _Tile extends StatelessWidget {
  final String title;

  /// The figure; null shows [none] instead.
  final String? value;
  final String? none;
  final String? note;

  const _Tile({required this.title, this.value, this.none, this.note});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final value = this.value;
    final note = this.note;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: muted),
            const SizedBox(height: 4),
            if (value != null)
              // FittedBox, not Flexible: a long figure shrinks rather than
              // breaking mid-number (transaction-tile pattern).
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else
              Text(none ?? '', style: text.bodyMedium),
            if (note != null) ...[
              const SizedBox(height: 2),
              Text(note, style: muted),
            ],
          ],
        ),
      ),
    );
  }
}
