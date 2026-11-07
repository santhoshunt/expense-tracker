import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
import 'editor_sheet.dart';
import 'picker_sheet.dart';
import 'undo_snackbar.dart';

/// Shows a split's Undo offer: the message and what Undo runs.
typedef SplitUndoOffer = void Function(String message, VoidCallback undo);

/// Opens the editor that divides one payment or credit into category parts
/// ([FinanceProvider.splitTransaction]), or reshapes or merges back the split
/// [row] belongs to. Completes with true when the payment changed.
///
/// [offerUndo] takes the Undo offer of a save or a merge; without it the
/// offer shows on the caller's messenger.
Future<bool> showCategorySplitSheet(
  BuildContext context,
  Tx row, {
  SplitUndoOffer? offerUndo,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final changed = await showEditorSheet<bool>(
    context,
    builder: (ctx) => _CategorySplitForm(
      row: row,
      offerUndo:
          offerUndo ??
          (message, undo) {
            if (messenger == null || !messenger.mounted) return;
            showUndoSnackBarOn(
              messenger,
              message,
              undo,
              icon: Icons.call_split,
            );
          },
    ),
  );
  return changed ?? false;
}

/// One part row: its category (null until picked) and amount.
class _Part {
  String? categoryId;
  final TextEditingController amount;

  _Part(this.categoryId, String amount)
    : amount = TextEditingController(text: amount);
}

class _CategorySplitForm extends StatefulWidget {
  final Tx row;
  final SplitUndoOffer offerUndo;

  const _CategorySplitForm({required this.row, required this.offerUndo});

  @override
  State<_CategorySplitForm> createState() => _CategorySplitFormState();
}

class _CategorySplitFormState extends State<_CategorySplitForm> {
  late final Tx _anchor;
  late final double _total;
  final List<_Part> _parts = [];

  /// Why the last Save could not go through, above the button, when no
  /// part's own field says it.
  String? _error;

  /// A Save was refused: from then on each part shows its own problem on
  /// its Amount, live.
  bool _showRowErrors = false;

  /// On the [_error] line, which a refused Save scrolls to.
  final _errorKey = GlobalKey();

  /// Re-entrancy latch for Save and Merge back.
  bool _busy = false;

  /// The parts as they opened, for the Discard changes? guard.
  late final String _opened;

  String _fingerprint() =>
      [for (final p in _parts) '${p.categoryId}:${p.amount.text}'].join('|');

  bool get _isSplit => _anchor.splitId != null;

  @override
  void initState() {
    super.initState();
    final finance = context.read<FinanceProvider>();
    _anchor = finance.splitAnchorOf(widget.row);
    _total = finance.splitTotalOf(_anchor);
    if (_isSplit) {
      for (final p in finance.splitPartsOf(_anchor)) {
        _parts.add(_Part(p.categoryId, fmtFieldNumber(p.amount)));
      }
    } else {
      // The row's own category holds the whole payment, and an empty row
      // waits for the first part to move out of it.
      final own = isSplitPartCategory(_anchor.category, _anchor.type)
          ? _anchor.categoryId
          : null;
      _parts
        ..add(_Part(own, fmtFieldNumber(_total)))
        ..add(_Part(null, ''));
    }
    _opened = _fingerprint();
  }

  @override
  void dispose() {
    for (final p in _parts) {
      p.amount.dispose();
    }
    super.dispose();
  }

  static double _paise(double x) => (x * 100).round() / 100;

  double get _assigned =>
      _paise(_parts.fold(0.0, (s, p) => s + (parseAmount(p.amount.text) ?? 0)));

  void _addPart() => setState(() => _parts.add(_Part(null, '')));

  void _removePart(_Part p) {
    if (!_parts.contains(p)) return;
    setState(() {
      _parts.remove(p);
      _error = null;
    });
    // After the frame: the row's field still holds the controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => p.amount.dispose());
  }

  /// What keeps [p] from saving, for its Amount's error line; null for a
  /// good part or a wholly empty one, which the save skips.
  String? _rowError(_Part p) {
    final typed = p.amount.text.trim();
    if (p.categoryId == null && typed.isEmpty) return null;
    if (p.categoryId == null) return 'Pick a category';
    final amount = parseAmount(typed);
    return amount == null || amount <= 0 ? 'Enter an amount' : null;
  }

  /// The parts as [FinanceProvider.splitTransaction] takes them, or the
  /// reason they can't be saved yet (null when a part's own error line
  /// says it). Rows left wholly empty are skipped.
  ({List<({String categoryId, double amount})> parts, String? error})
  _validated() {
    final parts = <({String categoryId, double amount})>[];
    for (final p in _parts) {
      if (_rowError(p) != null) return (parts: parts, error: null);
      final typed = p.amount.text.trim();
      if (p.categoryId == null && typed.isEmpty) continue;
      parts.add((
        categoryId: p.categoryId!,
        amount: _paise(parseAmount(typed)!),
      ));
    }
    if (parts.length < 2) {
      return (parts: parts, error: 'Add at least two parts');
    }
    final left = _paise(_total - _assigned);
    if (left.abs() >= 0.005) {
      return (
        parts: parts,
        error:
            'Parts add up to ${fmtMoney(_assigned)}; the payment is '
            '${fmtMoney(_total)}',
      );
    }
    return (parts: parts, error: null);
  }

  /// The refused Save's line sits under the parts: with the keyboard up it
  /// lands out of sight, so the keyboard goes and the line scrolls in.
  void _revealError() {
    FocusScope.of(context).unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final at = _errorKey.currentContext;
      if (at != null && at.mounted) {
        Scrollable.ensureVisible(
          at,
          duration: const Duration(milliseconds: 200),
          alignment: 1,
        );
      }
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    final check = _validated();
    if (check.error != null || _parts.any((p) => _rowError(p) != null)) {
      setState(() {
        _error = check.error;
        _showRowErrors = true;
      });
      _revealError();
      return;
    }
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() => _busy = true);
    final SplitChange change;
    try {
      change = await finance.splitTransaction(_anchor.id, check.parts);
    } on ArgumentError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message?.toString() ?? 'These parts cannot be saved';
        });
        _revealError();
      }
      return;
    }
    // A back or scrim tap during the write already closed this sheet; a
    // pop now would close the add sheet under it.
    if (route?.isCurrent == true) navigator.pop(true);
    widget.offerUndo(
      'Split into ${check.parts.length} parts',
      () => finance.undoSplitChange(change),
    );
  }

  Future<void> _merge() async {
    if (_busy) return;
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() => _busy = true);
    final change = await finance.mergeSplit(_anchor.splitId!);
    if (route?.isCurrent == true) navigator.pop(true);
    widget.offerUndo(
      'Merged back into one payment',
      () => finance.undoSplitChange(change),
    );
  }

  List<PickerItem<String>> _categoryItems() {
    final type = _anchor.type;
    final dir = type == TxType.income ? 'in' : 'out';
    return [
      PickerItem.header(type == TxType.income ? 'Income' : 'Expenses'),
      for (final c in allCategories)
        if (isSplitPartCategory(c, type) && !c.isTransfer)
          PickerItem(
            value: c.id,
            label: c.label,
            leading: Icon(c.icon, color: c.color, size: 20),
          ),
      const PickerItem.header('Transfers'),
      for (final c in allCategories)
        if (isSplitPartCategory(c, type) && c.isTransfer)
          PickerItem(
            value: c.id,
            label: '${c.label} · money $dir',
            leading: Icon(c.icon, color: c.color, size: 20),
          ),
    ];
  }

  /// The credit a money-in split divides: a green left bar, the account
  /// and merchant, and the amount in green over its date.
  Widget _creditHeader(BuildContext context, String merchant) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final green = AppColors.of(context).green;
    final account = context.read<FinanceProvider>().accountForKey(
      _anchor.acctKey,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          // No radius here: a one-sided border with a radius asserts, so the
          // ClipRRect rounds the corners instead.
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            border: Border(left: BorderSide(color: green, width: 3)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account == null
                          ? 'Money in'
                          : 'Money in · ${account.displayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      merchant,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '+${fmtMoney(_total)}',
                    style: text.bodyLarge?.copyWith(
                      color: green,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    fmtDateCompact(_anchor.date),
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// [left] is what no part holds yet; a positive one offers itself on the
  /// first empty part's Amount.
  Widget _partRow(_Part p, List<PickerItem<String>> items, double left) {
    final offerLeft =
        left > 0.005 &&
        p.amount.text.trim().isEmpty &&
        identical(p, _parts.firstWhere((o) => o.amount.text.trim().isEmpty));
    return Padding(
      // Keyed by the part: removing a row mid-list must not hand its
      // neighbour's field state to the wrong part.
      key: ObjectKey(p),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _partFields(p, items),
          if (offerLeft)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: ActionChip(
                key: const ValueKey('split-use-left'),
                label: Text('Use ${fmtMoney(left)} left'),
                onPressed: () => setState(() {
                  p.amount.text = fmtFieldNumber(left);
                  _error = null;
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _partFields(_Part p, List<PickerItem<String>> items) {
    final category = AppDropdownField<String>(
      label: 'Category',
      value: p.categoryId,
      items: items,
      onChanged: (v) => setState(() {
        p.categoryId = v;
        _error = null;
      }),
    );
    final amount = TextFormField(
      controller: p.amount,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: 'Amount',
        prefixText: '₹ ',
        // This part's own problem, under its own field.
        errorText: _showRowErrors ? _rowError(p) : null,
        errorMaxLines: 2,
      ),
      onChanged: (_) => setState(() => _error = null),
    );
    final remove = IconButton(
      tooltip: 'Remove part',
      onPressed: _parts.length > 1 ? () => _removePart(p) : null,
      icon: const Icon(Icons.close),
    );
    return LayoutBuilder(
      builder: (context, box) {
        // Side by side only on a row of 360dp or more at about normal
        // text: in less, Category got "Food & …" (a 360dp phone at 1x)
        // or a letter or two. Otherwise Category takes its own line, with
        // Amount and the remove button under it.
        if (box.maxWidth >= 360 &&
            MediaQuery.textScalerOf(context).scale(1) <= 1.15) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: category),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: amount),
              remove,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            category,
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: amount),
                remove,
              ],
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final items = _categoryItems();
    final merchant =
        finance.merchantLabelFor(_anchor) ?? _anchor.category.label;
    final left = _paise(_total - _assigned);
    final balanced = left.abs() < 0.005;
    final leftLine = left < 0
        ? 'Over by ${fmtMoney(-left)}'
        : 'Left to assign ${fmtMoney(balanced ? 0 : left)}';
    final leftColor = left < 0
        ? scheme.error
        : balanced
        ? AppColors.of(context).green
        : scheme.onSurfaceVariant;
    return EditorSheetBody(
      title: _isSplit ? 'Edit split' : 'Split by category',
      menu: _isSplit
          ? const [
              PopupMenuItem(
                value: 'merge',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.call_merge),
                  title: Text('Merge back'),
                ),
              ),
            ]
          : null,
      menuTooltip: 'Split actions',
      onMenu: (_) => _merge(),
      footerLabel: _isSplit ? 'Save split' : 'Split payment',
      onSave: _busy ? null : _save,
      // Not while writing: a Discard changes? asked then would stay over
      // a sheet the write is about to close.
      dirty: _fingerprint() != _opened && !_busy,
      children: [
        if (_anchor.type == TxType.income)
          _creditHeader(context, merchant)
        else
          Text(
            '$merchant · ${fmtMoney(_total)} · '
            '${fmtDateCompact(_anchor.date)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        for (final p in _parts) _partRow(p, items, left),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: _addPart,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a part'),
          ),
        ),
        // In the body, not the footer: the footer's extra line hides while
        // the keyboard is up, which is when the amounts are typed.
        Text(
          leftLine,
          key: const ValueKey('split-left'),
          style: text.bodyMedium?.copyWith(
            color: leftColor,
            fontWeight: FontWeight.w600,
          ),
        ),
        // Wrapping and in the error colour: the footer's one grey line cut
        // "Parts add up to ...; the payment is ..." at 320dp.
        if (_error != null) ...[
          const SizedBox(height: 8),
          KeyedSubtree(
            key: _errorKey,
            child: Text(
              _error!,
              key: const ValueKey('split-error'),
              style: text.bodyMedium?.copyWith(color: scheme.error),
            ),
          ),
        ],
      ],
    );
  }
}
