import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../screens/add_transaction_sheet.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import 'glossy.dart';
import 'motion.dart';

/// Width of [text] laid out on one line the way a `Text` with [style] would
/// render it here: same default style, bold-text setting and text scale.
double _textWidth(BuildContext context, String text, TextStyle? style) {
  var effective = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) {
    effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  final painter = TextPainter(
    text: TextSpan(text: text, style: effective),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

class TransactionTile extends StatelessWidget {
  final Tx tx;

  /// Multi-select support. While [selectionMode] is on, taps toggle
  /// selection instead of opening the editor.
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onToggleSelect;

  const TransactionTile({
    super.key,
    required this.tx,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
  });

  /// "₹2,200 to get back · Arun, Priya" (or "Settled · …") on a split that
  /// names its people; "from Arun" on a repayment; null otherwise.
  String? _peopleLine(BuildContext context) {
    if (tx.categoryId == kRepaidToMeCategoryId && tx.repaidBy != null) {
      return 'from ${tx.repaidBy}';
    }
    // Only a bill's people count: a row moved to income or a transfer by a
    // path that hasn't cleaned it yet shows nothing.
    if (!tx.tracksPeople ||
        tx.type != TxType.expense ||
        isTransferCategory(tx.categoryId)) {
      return null;
    }
    // The figure leads, so a long list of names cuts off first.
    final names = tx.people.map((p) => p.name).join(', ');
    // Balances cover confirmed rows only; a pending bill shows its full
    // friends' part until it is confirmed.
    if (tx.pending) return '${fmtMoney(tx.frontedAmount)} to get back · $names';
    final owed = context.select<FinanceProvider, double>(
      (f) => f.billOwed(tx.id),
    );
    return owed > 0
        ? '${fmtMoney(owed)} to get back · $names'
        : 'Settled · $names';
  }

  @override
  Widget build(BuildContext context) {
    final cat = tx.category;
    final isIncome = tx.type == TxType.income;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // A wallet row left out of spending reads muted, like a note.
    final counted = context.select<FinanceProvider, bool>(
      (f) => f.countsInTotals(tx),
    );
    final amountColor = !counted
        ? scheme.onSurfaceVariant
        : isIncome
        ? AppColors.of(context).green
        : scheme.error;

    // The category leads — the SMS sender (bank shortcode) used to headline
    // every imported row and just repeated what the account view already
    // knows. Second line: the user's note (when present) with the date after
    // it; the full sender/SMS detail stays available in the edit sheet.
    final title = cat.label;
    final note = tx.note.isEmpty ? null : tx.note.split('\n').first;
    // Compact (no year): the list already groups under month headers, and
    // the full form crowded the note off the line at large font scales.
    final dateLabel = fmtDateCompact(tx.date);
    final lineStyle = textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    // One timing for every selection change on the row, so the border, the
    // fill and the icon swap move together.
    final selectMotion = motionDuration(
      context,
      const Duration(milliseconds: 160),
    );

    // No swipe-to-delete: an accidental horizontal drag while scrolling
    // kept deleting rows. Deleting lives in the edit sheet (with Undo).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: AnimatedContainer(
        duration: selectMotion,
        curve: Curves.easeOutCubic,
        // Selection is marked with a border rather than a fill so the
        // amount/category colours stay legible. The border is always there,
        // transparent when unselected, so it fades rather than popping in.
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.primary.withValues(alpha: 0),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: FrostedPanel(
          radius: BorderRadius.circular(16),
          // Selection is otherwise only a border + icon swap — invisible to
          // assistive tech. `selected` is exposed only in selection mode so
          // ordinary browsing isn't narrated as "not selected" per row.
          child: Semantics(
            selected: selectionMode ? selected : null,
            onLongPressHint: 'select',
            child: InkWell(
              onTap: selectionMode
                  ? onToggleSelect
                  : () => showAddTransactionSheet(context, existing: tx),
              onLongPress: onToggleSelect,
              borderRadius: BorderRadius.circular(16),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    // Rounded-square category icon; flips to a check while
                    // selected, the fill easing over and the glyphs
                    // swapping with a small pop.
                    AnimatedContainer(
                      duration: selectMotion,
                      curve: Curves.easeOutCubic,
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: selected
                            ? scheme.primary
                            : cat.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: AnimatedSwitcher(
                        duration: selectMotion,
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween(
                              begin: 0.6,
                              end: 1.0,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        // categoryGlyphColor: the raw dark-kit hue washed
                        // out to 1.6–2.4:1 over its own tint on light
                        // surfaces.
                        child: selected
                            ? Icon(
                                Icons.check,
                                key: const ValueKey(true),
                                color: scheme.onPrimary,
                                size: 22,
                              )
                            : Icon(
                                cat.icon,
                                key: const ValueKey(false),
                                color: categoryGlyphColor(context, cat.color),
                                size: 22,
                              ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Category title over "note · date". The note shrinks and
                    // ellipsizes first so the date is always visible, however
                    // long the note.
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              // One leg of a paired transfer.
                              if (tx.pairId != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Icon(
                                    Icons.link,
                                    size: 14,
                                    color: scheme.onSurfaceVariant,
                                    semanticLabel: 'paired transfer',
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          // Both flexible so neither can push the other off
                          // the line entirely: a rigid date used to leave a
                          // squeezed note zero width (an orphan "·" before
                          // the date) at large font scales. Unused flex space
                          // just trails off, since the line is left-aligned.
                          // The " · " is rigid and can alone be wider than
                          // the line (73px of 52 at 320dp and 2x in tests).
                          // So the note and it drop out, leaving the date the
                          // whole line, once the date's 2/5 share of what is
                          // left after the " · " can't hold even a "…".
                          LayoutBuilder(
                            builder: (context, constraints) {
                              String? shownNote;
                              if (note != null) {
                                final left =
                                    constraints.maxWidth -
                                    _textWidth(context, ' · ', lineStyle);
                                final ellipsis = _textWidth(
                                  context,
                                  '…',
                                  lineStyle,
                                );
                                if (left * 2 / 5 >= ellipsis) shownNote = note;
                              }
                              return Row(
                                children: [
                                  if (shownNote != null) ...[
                                    Flexible(
                                      flex: 3,
                                      child: Text(
                                        shownNote,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: lineStyle,
                                      ),
                                    ),
                                    Text(' · ', style: lineStyle),
                                  ],
                                  Flexible(
                                    flex: 2,
                                    child: Text(
                                      dateLabel,
                                      // TalkBack still reads a note left out.
                                      semanticsLabel:
                                          note != null && shownNote == null
                                          ? '$note · $dateLabel'
                                          : null,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: lineStyle,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                          // Why a wallet purchase isn't in the totals; its
                          // own line, like Counts in below.
                          if (!counted)
                            Text(
                              'Not counted',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: lineStyle,
                            ),
                          // Why a row listed on the 30th shows up in next
                          // month's totals. Its own line, so the note and
                          // date above never get squeezed for it. Moot on
                          // a row that counts nowhere.
                          if (tx.countIn != null && counted)
                            Text(
                              'Counts in ${fmtDateCompact(tx.countIn!)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          // Rows with tags grow a line for them.
                          if (tx.tags.isNotEmpty)
                            Text(
                              tx.tags.map((t) => '# $t').join('  '),
                              // TalkBack would read each "#" as "number".
                              semanticsLabel: 'tags ${tx.tags.join(', ')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: accentTextColor(context),
                              ),
                            ),
                          // Who owes what on a split, or who paid back on a
                          // repayment.
                          if (_peopleLine(context) case final line?)
                            Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Amount — prominent, color-coded. Width-capped so a
                    // crore-range figure at a large text scale shrinks to fit
                    // instead of overflowing; below the cap it renders at its
                    // natural size, keeping the usual right alignment.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${isIncome ? '+' : '−'}${fmtMoney(tx.amount)}',
                              style: TextStyle(
                                color: amountColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          // Group split: the full amount above mirrors the
                          // bank debit; this line shows what actually counts
                          // as the user's own spend.
                          // Expense rows outside the transfers only, the
                          // one place a share means anything.
                          // Not on an uncounted wallet row: no share of it
                          // counts.
                          if (tx.isSplit &&
                              counted &&
                              tx.type == TxType.expense &&
                              !isTransferCategory(tx.categoryId))
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'your share ${fmtMoney(tx.myShare!)}',
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
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
        ),
      ),
    );
  }
}
