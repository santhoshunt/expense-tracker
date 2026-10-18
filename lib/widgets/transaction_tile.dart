import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../screens/add_transaction_sheet.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import '../utils/money_colors.dart';
import '../utils/text_scale.dart';
import 'category_tile_icon.dart';
import 'glossy.dart';
import 'grouped_surface.dart';
import 'motion.dart';
import 'status_dot.dart';

// Kept importable from here: other screens take isLargeTextScale from this
// file.
export '../utils/text_scale.dart';

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

  /// Drawn as one row of a [GroupedSurface] (the rows of a day share one
  /// card) instead of a card of its own. [groupedFirst] rounds the top
  /// corners and [groupedLast] the bottom ones.
  final bool grouped;
  final bool groupedFirst;
  final bool groupedLast;

  /// False under a day header, which already names the date: the line under
  /// the amount then shows the time ("4:12 PM"), or no time for a midnight
  /// row (the app's "no time known").
  final bool showDate;

  const TransactionTile({
    super.key,
    required this.tx,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
    this.grouped = false,
    this.groupedFirst = false,
    this.groupedLast = false,
    this.showDate = true,
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

  /// Line two of an unseen row: [text] (the category and any note the title
  /// did not use) ending in " · new", or "new" alone when [text] is null.
  ///
  /// " · new" is its own rigid text, so [text] ellipsizes before "new"
  /// does. Where even that is wider than the line, "new" alone takes the
  /// line (TalkBack still reads [text]); where "new" itself can't fit, the
  /// line is [text] alone. The dot before the line carries "New" for
  /// TalkBack, so the text leaves it out.
  Widget _secondLine(String? text, TextStyle? lineStyle) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final read = text ?? '';
      final full = read.isEmpty ? 'new' : ' · new';
      final withNew = _textWidth(context, full, lineStyle) <= width;
      if (!withNew && _textWidth(context, 'new', lineStyle) <= width) {
        return Semantics(
          label: read,
          child: ExcludeSemantics(
            child: Text('new', maxLines: 1, style: lineStyle),
          ),
        );
      }
      final suffix = withNew
          ? ExcludeSemantics(child: Text(full, maxLines: 1, style: lineStyle))
          : null;
      return Row(
        children: [
          if (text != null)
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: lineStyle,
              ),
            ),
          ?suffix,
        ],
      );
    },
  );

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
    // A refund linked to its purchase: the purchase's date, merchant and
    // category label. Null otherwise, a refund whose link no longer holds
    // included.
    final refundFor = context
        .select<
          FinanceProvider,
          ({DateTime date, String? merchant, String category})?
        >((f) {
          if (!f.isLinkedRefund(tx)) return null;
          final p = f.refundPurchaseOf(tx);
          return p == null
              ? null
              : (
                  date: p.date,
                  merchant: f.merchantLabelFor(p),
                  category: p.category.label,
                );
        });
    // A purchase with refunds linked to it: how much came back and when
    // the latest did.
    final refunded = tx.type == TxType.expense
        ? context.select<FinanceProvider, ({double sum, DateTime last})?>((f) {
            final refunds = f.refundsOf(tx);
            if (refunds.isEmpty) return null;
            return (
              sum: f.refundedFor(tx),
              last: refunds
                  .map((r) => r.date)
                  .reduce((a, b) => a.isAfter(b) ? a : b),
            );
          })
        : null;
    // Refunded in full: the purchase no longer counts, so its amount is
    // muted and struck through, as is every linked refund: the pair is
    // money that went out and came back, neither income nor spend.
    final refundedInFull =
        refunded != null && refunded.sum >= tx.amount - 0.005;
    final struck = refundedInFull || refundFor != null;
    // Money in green, money out red; a transfer plain, as it is neither,
    // and an uncounted row muted.
    final amountColor = struck
        ? scheme.onSurfaceVariant
        : moneyColor(
            context,
            type: tx.type,
            transfer: isTransferCategory(tx.categoryId) || refundFor != null,
            counted: counted,
          );

    // Merchant first: the alias, the alert's merchant, Paid to or the note;
    // the category when the row names none. Line two carries the category
    // and any note the title did not use. A linked refund leads with what it
    // refunds instead: the merchant of either row, else the purchase's
    // category, always after "Refund · ".
    final refundMerchant =
        refundFor?.merchant ??
        (refundFor == null
            ? null
            : context.select<FinanceProvider, String?>(
                (f) => f.merchantLabelFor(tx),
              ));
    final rowTitle = refundFor == null
        ? context.select<FinanceProvider, String?>((f) => f.rowTitleFor(tx))
        : null;
    final title = refundFor != null
        ? 'Refund · ${refundMerchant ?? refundFor.category}'
        : rowTitle ?? cat.label;
    final noteText = tx.note.split('\n').first.trim();
    final extraNote = noteText.isNotEmpty && noteText != rowTitle
        ? noteText
        : null;
    final String? second = refundFor != null
        ? extraNote
        : rowTitle == null
        ? null
        : [cat.label, ?extraNote].join(' · ');
    // The refund line under line two: "₹500 refunded · 4 Oct" on the
    // purchase, "For 25 Sep purchase" on the refund. Days only: the time
    // would crowd the line.
    String day(DateTime d) => fmtDateCompact(DateTime(d.year, d.month, d.day));
    final String? refundLine = refundFor != null
        ? 'For ${day(refundFor.date)} purchase'
        : refunded == null
        ? null
        : refundedInFull
        ? 'Refunded in full · ${day(refunded.last)}'
        : '${fmtMoney(refunded.sum)} refunded · ${day(refunded.last)}';
    // The line under the amount: the date, compact (no year) as the list
    // already groups under month headers. Under a day header only the time
    // is new, and a midnight row has none.
    final midnight = tx.date.hour == 0 && tx.date.minute == 0;
    final String? timeLabel = showDate
        ? fmtDateCompact(tx.date)
        : midnight
        ? null
        : fmtTime(tx.date);
    final lineStyle = textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    // An import that counted at once without review: a dot leads the line
    // and "new" ends it, until the row is opened or marked seen.
    final isNew = tx.unseen;
    final Widget? line = isNew
        ? _secondLine(second, lineStyle)
        : second == null
        ? null
        : Text(
            second,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: lineStyle,
          );
    final Widget? noteLine = line == null || !isNew
        ? line
        : Row(
            children: [
              Semantics(
                label: 'New',
                child: StatusDot(color: accentTextColor(context)),
              ),
              const SizedBox(width: 6),
              Expanded(child: line),
            ],
          );
    // Large text stacks the amount under the title instead of beside it,
    // so the merchant keeps the row's width.
    final stacked = isLargeTextScale(context);

    Widget amountBlock(CrossAxisAlignment align) => Column(
      crossAxisAlignment: align,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${isIncome ? '+' : '−'}${fmtMoney(tx.amount)}',
            style: TextStyle(
              color: amountColor,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              decoration: struck ? TextDecoration.lineThrough : null,
              decorationColor: amountColor,
            ),
          ),
        ),
        // Group split: the full amount above mirrors the bank debit; this
        // line shows what actually counts as the user's own spend.
        // Expense rows outside the transfers only, the one place a share
        // means anything. Not on an uncounted wallet row: no share of it
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
        // The time under a day header, the date on an amount sort: under
        // the amount, so line two belongs to the merchant and category.
        if (timeLabel != null)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(timeLabel, maxLines: 1, style: lineStyle),
          ),
      ],
    );

    // One timing for every selection change on the row, so the border, the
    // fill and the icon swap move together.
    final selectMotion = motionDuration(
      context,
      const Duration(milliseconds: 160),
    );

    // A grouped row rounds only the corners its place in the card has, so
    // the selection border and the ink follow the card's outline.
    const corner = Radius.circular(AppRadius.card);
    final radius = grouped
        ? BorderRadius.vertical(
            top: groupedFirst ? corner : Radius.zero,
            bottom: groupedLast ? corner : Radius.zero,
          )
        : BorderRadius.circular(16);
    // A grouped row is a little tighter: the shared card already sets the
    // rows apart.
    // CategoryTileIcon draws the glyph at half the tile: 20 or 22.
    final iconSize = grouped ? 40.0 : 44.0;

    // Selection is otherwise only a border + icon swap, invisible to
    // assistive tech. `selected` is exposed only in selection mode so
    // ordinary browsing isn't narrated as "not selected" per row.
    final row = Semantics(
      selected: selectionMode ? selected : null,
      onLongPressHint: 'select',
      child: InkWell(
        onTap: selectionMode
            ? onToggleSelect
            : () => showAddTransactionSheet(context, existing: tx),
        onLongPress: onToggleSelect,
        borderRadius: radius,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: grouped ? 10 : 12,
          ),
          child: Row(
            children: [
              // Rounded-square category icon; flips to a check while
              // selected. A linked refund shows the undo glyph its review
              // card used, not its income category's.
              CategoryTileIcon(
                category: cat,
                size: iconSize,
                selected: selected,
                icon: refundFor != null ? Icons.undo : null,
              ),
              const SizedBox(width: 12),
              // Merchant over category; the time sits under the amount.
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
                    // Large text: the amount on its own line, right
                    // under the title.
                    if (stacked) ...[
                      const SizedBox(height: 2),
                      amountBlock(CrossAxisAlignment.start),
                    ],
                    if (noteLine != null) ...[
                      const SizedBox(height: 2),
                      noteLine,
                    ],
                    // A refund and its purchase name each other, on a
                    // line of their own like Counts in below.
                    if (refundLine != null)
                      Text(
                        refundLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: lineStyle,
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
                    // month's totals. Its own line, so line two above
                    // never gets squeezed for it. Moot on a row that
                    // counts nowhere.
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
              if (!stacked) ...[
                const SizedBox(width: 12),
                // Amount: prominent, signed. Width-capped so a
                // crore-range figure at a large text scale shrinks to fit
                // instead of overflowing; below the cap it renders at its
                // natural size, keeping the usual right alignment.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: amountBlock(CrossAxisAlignment.end),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // No swipe-to-delete: an accidental horizontal drag while scrolling
    // kept deleting rows. Deleting lives in the edit sheet (with Undo).
    return Padding(
      // Grouped rows touch: the card they share is the separation.
      padding: grouped
          ? const EdgeInsets.symmetric(horizontal: 16)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: AnimatedContainer(
        duration: selectMotion,
        curve: Curves.easeOutCubic,
        // Selection is marked with a border rather than a fill so the
        // category colours stay legible. The border is always there,
        // transparent when unselected, so it fades rather than popping in.
        foregroundDecoration: BoxDecoration(
          border: Border.all(
            color: selected
                ? scheme.primary
                : scheme.primary.withValues(alpha: 0),
            width: 1.5,
          ),
          borderRadius: radius,
        ),
        child: grouped
            ? GroupedSurface(first: groupedFirst, last: groupedLast, child: row)
            : FrostedPanel(radius: radius, child: row),
      ),
    );
  }
}
