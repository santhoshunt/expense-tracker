import 'package:flutter/material.dart';

import '../models/transaction.dart';
import '../screens/add_transaction_sheet.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import 'glossy.dart';

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

  @override
  Widget build(BuildContext context) {
    final cat = tx.category;
    final isIncome = tx.type == TxType.income;
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final amountColor = isIncome ? AppColors.of(context).green : scheme.error;

    // The category leads — the SMS sender (bank shortcode) used to headline
    // every imported row and just repeated what the account view already
    // knows. Second line: the user's note (when present) with the date after
    // it; the full sender/SMS detail stays available in the edit sheet.
    final title = cat.label;
    final note = tx.note.isEmpty ? null : tx.note.split('\n').first;
    // Compact (no year): the list already groups under month headers, and
    // the full form crowded the note off the line at large font scales.
    final dateLabel = fmtDateCompact(tx.date);

    // No swipe-to-delete: an accidental horizontal drag while scrolling
    // kept deleting rows. Deleting lives in the edit sheet (with Undo).
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Container(
        // Selection is marked with a border rather than a fill so the
        // amount/category colours stay legible.
        foregroundDecoration: selected
            ? BoxDecoration(
                border: Border.all(color: scheme.primary, width: 1.5),
                borderRadius: BorderRadius.circular(16),
              )
            : null,
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
                    // selected.
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: selected
                            ? scheme.primary
                            : cat.color.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      // categoryGlyphColor: the raw dark-kit hue washed out
                      // to 1.6–2.4:1 over its own tint on light surfaces.
                      child: selected
                          ? Icon(Icons.check, color: scheme.onPrimary, size: 22)
                          : Icon(
                              cat.icon,
                              color: categoryGlyphColor(context, cat.color),
                              size: 22,
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
                          // just trails off — the line is left-aligned.
                          Row(
                            children: [
                              if (note != null) ...[
                                Flexible(
                                  flex: 3,
                                  child: Text(
                                    note,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                                Text(
                                  ' · ',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              Flexible(
                                flex: 2,
                                child: Text(
                                  dateLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
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
                          if (tx.isSplit)
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
