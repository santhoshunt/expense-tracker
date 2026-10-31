import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/format.dart';
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
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _CategorySplitForm(
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

  /// Shown under the parts after a Save that could not go through.
  String? _error;

  /// Re-entrancy latch for Save and Merge back.
  bool _busy = false;

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

  /// The parts as [FinanceProvider.splitTransaction] takes them, or the
  /// reason they can't be saved yet. Rows left wholly empty are skipped.
  ({List<({String categoryId, double amount})> parts, String? error})
  _validated() {
    final parts = <({String categoryId, double amount})>[];
    for (final p in _parts) {
      final typed = p.amount.text.trim();
      if (p.categoryId == null && typed.isEmpty) continue;
      final amount = parseAmount(typed);
      if (p.categoryId == null) {
        return (parts: parts, error: 'Pick a category for each part');
      }
      if (amount == null || amount <= 0) {
        return (parts: parts, error: 'Enter an amount for each part');
      }
      parts.add((categoryId: p.categoryId!, amount: _paise(amount)));
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

  Future<void> _save() async {
    if (_busy) return;
    final check = _validated();
    if (check.error != null) {
      setState(() => _error = check.error);
      return;
    }
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
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
      }
      return;
    }
    if (navigator.mounted) navigator.pop(true);
    widget.offerUndo(
      'Split into ${check.parts.length} parts',
      () => finance.undoSplitChange(change),
    );
  }

  Future<void> _merge() async {
    if (_busy) return;
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    final change = await finance.mergeSplit(_anchor.splitId!);
    if (navigator.mounted) navigator.pop(true);
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

  Widget _partRow(_Part p, List<PickerItem<String>> items) => Padding(
    // Keyed by the part: removing a row mid-list must not hand its
    // neighbour's field state to the wrong part.
    key: ObjectKey(p),
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: AppDropdownField<String>(
            label: 'Category',
            value: p.categoryId,
            items: items,
            onChanged: (v) => setState(() {
              p.categoryId = v;
              _error = null;
            }),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: p.amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount',
              prefixText: '₹ ',
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
        ),
        IconButton(
          tooltip: 'Remove part',
          onPressed: _parts.length > 1 ? () => _removePart(p) : null,
          icon: const Icon(Icons.close),
        ),
      ],
    ),
  );

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
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isSplit ? 'Edit split' : 'Split by category',
              style: text.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            if (_anchor.type == TxType.income)
              _creditHeader(context, merchant)
            else
              Text(
                '$merchant · ${fmtMoney(_total)} · '
                '${fmtDateCompact(_anchor.date)}',
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            for (final p in _parts) _partRow(p, items),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _addPart,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add a category'),
              ),
            ),
            Text(
              leftLine,
              style: text.bodyMedium?.copyWith(
                color: leftColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: text.bodyMedium?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(_isSplit ? 'Save split' : 'Split payment'),
            ),
            if (_isSplit) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _busy ? null : _merge,
                icon: const Icon(Icons.call_merge),
                label: const Text('Merge back'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
