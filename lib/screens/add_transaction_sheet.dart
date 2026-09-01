import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/format.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/undo_snackbar.dart';

Future<void> showAddTransactionSheet(BuildContext context, {Tx? existing}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    // Keeps the sheet (and its drag handle) below the status bar / notch —
    // a full-height sheet otherwise pushes the handle under the cutout.
    useSafeArea: true,
    showDragHandle: true,
    // The builder's context, not the caller's: keyboard insets are delivered
    // to the sheet's own MediaQuery.
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _AddTransactionForm(existing: existing),
    ),
  );
}

/// What the type toggle offers. Transfer is not a [TxType]: transfer
/// categories carry their own direction via their type, so the saved
/// transaction's type always comes from the selected category.
enum _EntryKind { expense, income, transfer }

class _AddTransactionForm extends StatefulWidget {
  final Tx? existing;
  const _AddTransactionForm({this.existing});

  @override
  State<_AddTransactionForm> createState() => _AddTransactionFormState();
}

class _AddTransactionFormState extends State<_AddTransactionForm> {
  final _formKey = GlobalKey<FormState>();
  late _EntryKind _kind;
  late String _categoryId;
  late DateTime _date;
  String? _accountId;

  /// What the account dropdown started as, so saving an edit only reassigns
  /// when the user actually changed it — assignAccount is not a harmless
  /// re-affirmation, it rewrites the transaction's account key.
  String? _initialAccountId;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;
  late final TextEditingController _senderCtrl;

  /// Group split: whether the user fronted this bill for a group. Only the
  /// share in [_shareCtrl] counts as their spend; the remainder is tracked
  /// as Paid for Others. Expense entries only.
  bool _isSplit = false;
  late final TextEditingController _shareCtrl;

  bool get isEditing => widget.existing != null;

  /// Re-entrancy latch: a save on a large ledger runs a multi-MB encode on
  /// an isolate before the sheet pops, and the buttons stayed live that
  /// whole time — a double-tap (or Done on the Sender field plus a tap on
  /// Add) minted two rows. Stays true on success; the sheet is closing.
  bool _busy = false;

  /// The form's state as one comparable string, captured once after
  /// initState fills the fields — pop guards compare against it to know
  /// whether closing the sheet would discard anything the user typed.
  late final String _initialFingerprint;

  String _fingerprint() => [
    _kind.name,
    _categoryId,
    _amountCtrl.text,
    _noteCtrl.text,
    _senderCtrl.text,
    _isSplit.toString(),
    _shareCtrl.text,
    _accountId ?? '',
    _date.toIso8601String(),
  ].join('|');

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e == null) {
      _kind = _EntryKind.expense;
    } else if (e.category.isTransfer) {
      _kind = _EntryKind.transfer;
    } else {
      _kind = e.type == TxType.income ? _EntryKind.income : _EntryKind.expense;
    }
    _categoryId = e?.categoryId ?? _categoriesFor(_kind).first.id;
    _date = e?.date ?? DateTime.now();
    _amountCtrl = TextEditingController(
      text: e == null ? '' : e.amount.toStringAsFixed(2),
    );
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    _senderCtrl = TextEditingController(text: e?.sender ?? '');
    _isSplit = e?.myShare != null;
    _shareCtrl = TextEditingController(
      text: e?.myShare == null ? '' : e!.myShare!.toStringAsFixed(2),
    );
    // Preselect the account this transaction already resolves to.
    if (e?.acctKey != null) {
      _accountId = context
          .read<FinanceProvider>()
          .accountForKey(e!.acctKey)
          ?.id;
    }
    _initialAccountId = _accountId;
    _initialFingerprint = _fingerprint();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _senderCtrl.dispose();
    _shareCtrl.dispose();
    super.dispose();
  }

  List<TxCategory> _categoriesFor(_EntryKind kind) => switch (kind) {
    _EntryKind.expense => [
      for (final c in allCategories)
        if (c.type == TxType.expense && !c.isTransfer) c,
    ],
    _EntryKind.income => [
      for (final c in allCategories)
        if (c.type == TxType.income && !c.isTransfer) c,
    ],
    _EntryKind.transfer => [
      for (final c in allCategories)
        if (c.isTransfer) c,
    ],
  };

  /// The saved type always mirrors the chosen category — the app-wide
  /// invariant `tx.type == category.type` must hold for transfer categories
  /// of either direction too.
  TxType get _type => categoryById(_categoryId).type;

  /// Live preview under the "Your share" field: where the fronted remainder
  /// will go. Null (no helper) until both amounts parse and make sense.
  String? _splitHelperText() {
    final total = parseAmount(_amountCtrl.text);
    final share = parseAmount(_shareCtrl.text);
    if (total == null || share == null || share < 0 || share >= total) {
      return null;
    }
    final label = categoryById(kPaidForOthersCategoryId).label;
    return '${fmtMoney(total - share)} tracked as $label';
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    final amount = parseAmount(_amountCtrl.text)!;
    // The share is only meaningful on plain expenses; income and transfer
    // kinds hide the checkbox, so saving them always clears it.
    final myShare = _kind == _EntryKind.expense && _isSplit
        ? parseAmount(_shareCtrl.text)
        : null;
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    setState(() => _busy = true);

    try {
      if (isEditing) {
        await finance.updateTransaction(
          widget.existing!.copyWith(
            type: _type,
            categoryId: _categoryId,
            amount: amount,
            note: _noteCtrl.text.trim(),
            date: _date,
            sender: _senderCtrl.text.trim(),
            myShare: myShare,
            clearMyShare: myShare == null,
          ),
        );
        if (_accountId != null && _accountId != _initialAccountId) {
          await finance.assignAccount(widget.existing!.id, _accountId!);
        }
      } else {
        final id = await finance.addTransaction(
          type: _type,
          categoryId: _categoryId,
          amount: amount,
          note: _noteCtrl.text.trim(),
          date: _date,
          sender: _senderCtrl.text.trim(),
          myShare: myShare,
        );
        if (_accountId != null) await finance.assignAccount(id, _accountId!);
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
    navigator.pop();
  }

  Future<void> _delete() async {
    if (_busy) return;
    setState(() => _busy = true);
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    final tx = widget.existing!;
    // Immediate delete + Undo instead of a confirmation dialog — the
    // snackbar rides the app-level messenger, so it outlives this sheet.
    showUndoSnackBar(
      context,
      'Deleted ${tx.category.label} · ${fmtMoney(tx.amount)}',
      () => finance.restoreTransaction(tx),
    );
    await finance.deleteTransaction(tx.id);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final categories = _categoriesFor(_kind);

    // canPop stays false so every dismissal — barrier tap, swipe-down,
    // system back — routes through the callback, which lets clean sheets
    // close silently and dirty ones ask first. Typing in a controller
    // doesn't rebuild this widget, so a build-time `canPop: !dirty` would
    // go stale; the imperative pops in _save/_delete bypass PopScope.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (_busy || _fingerprint() == _initialFingerprint) {
          navigator.pop();
          return;
        }
        final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Discard changes?'),
            content: const Text('What you typed here will be lost.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true && mounted) navigator.pop();
      },
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isEditing ? 'Edit transaction' : 'Add transaction',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                // Save lives at the top when editing: at the bottom it sat 8px
                // above Delete — a mis-tap hazard when confirming SMS imports.
                if (isEditing) ...[
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Save changes'),
                  ),
                  const SizedBox(height: 16),
                ],
                // No per-segment icons and no selected checkmark: three
                // segments wide, icon + label + check made "Expense" wrap onto
                // two lines on narrow phones. The fill colour already marks the
                // selection; FittedBox shrinks rather than wraps at large font
                // scales.
                SegmentedButton<_EntryKind>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: _EntryKind.expense,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Expense', maxLines: 1),
                      ),
                    ),
                    ButtonSegment(
                      value: _EntryKind.income,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Income', maxLines: 1),
                      ),
                    ),
                    ButtonSegment(
                      value: _EntryKind.transfer,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Transfer', maxLines: 1),
                      ),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() {
                    _kind = s.first;
                    _categoryId = _categoriesFor(_kind).first.id;
                    // Splits are an expense-only concept.
                    if (_kind != _EntryKind.expense) _isSplit = false;
                  }),
                ),
                const SizedBox(height: 16),
                // Category sits right under the kind toggle: picking what the
                // money was for flows straight from picking its direction.
                AppDropdownField<String>(
                  label: 'Category',
                  value: _categoryId,
                  items: [
                    for (final c in categories)
                      PickerItem(
                        value: c.id,
                        // Transfers carry their direction in the type — surface
                        // it, or "Refund" vs "To savings" reads as a coin flip.
                        label: c.isTransfer
                            ? '${c.label} · money '
                                  '${c.type == TxType.income ? 'in' : 'out'}'
                            : c.label,
                        leading: Icon(c.icon, color: c.color, size: 20),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _categoryId = v);
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _amountCtrl,
                  autofocus: !isEditing,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: '₹ ',
                  ),
                  validator: (v) {
                    // parseAmount, not double.tryParse: people type "1,500".
                    final parsed = parseAmount(v ?? '');
                    if (parsed == null || parsed <= 0) {
                      return 'Enter an amount greater than 0';
                    }
                    return null;
                  },
                  // Keeps the split field's helper text (the live remainder)
                  // in step while the total is being typed.
                  onChanged: _isSplit ? (_) => setState(() {}) : null,
                ),
                const SizedBox(height: 16),
                if (_kind == _EntryKind.expense) ...[
                  CheckboxListTile(
                    value: _isSplit,
                    onChanged: (v) => setState(() => _isSplit = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Group split payment'),
                    subtitle: Text(
                      'You paid the full bill for the group — only your own '
                      'share counts as spending.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (_isSplit) ...[
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _shareCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: 'Your share',
                        prefixText: '₹ ',
                        helperText: _splitHelperText(),
                      ),
                      validator: (v) {
                        final share = parseAmount(v ?? '');
                        if (share == null || share < 0) {
                          return 'Enter your share of the bill';
                        }
                        final total = parseAmount(_amountCtrl.text);
                        if (total != null && share >= total) {
                          return 'Must be less than the total amount';
                        }
                        return null;
                      },
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                  // Same 16dp rhythm below the split block as between every
                  // other field.
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _noteCtrl,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                  ),
                ),
                const SizedBox(height: 16),
                // The raw alert an SMS row was imported from — read-only so the
                // review flow can still see the full message, while the Note
                // field above stays purely the user's own text.
                if (widget.existing != null &&
                    widget.existing!.source == TxSource.sms &&
                    widget.existing!.smsBody.isNotEmpty) ...[
                  TextFormField(
                    initialValue: widget.existing!.smsBody,
                    readOnly: true,
                    minLines: 1,
                    maxLines: 4,
                    style: Theme.of(context).textTheme.bodySmall,
                    decoration: const InputDecoration(
                      labelText: 'Original SMS',
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _senderCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Sender (optional)',
                    helperText:
                        'Who the money moved to/from — filled automatically for SMS imports',
                  ),
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 16),
                Builder(
                  builder: (context) {
                    // watch, not read: an account created while the sheet is
                    // open must appear in the dropdown.
                    final finance = context.watch<FinanceProvider>();
                    // Open accounts only — but keep the row's own account
                    // even when closed, so editing an old transaction shows
                    // (and preserves) its real assignment.
                    final accounts = [
                      ...finance.openAccounts,
                      if (_accountId != null &&
                          (finance.accountById(_accountId!)?.isClosed ?? false))
                        finance.accountById(_accountId!)!,
                    ];
                    if (accounts.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: AppDropdownField<String>(
                        label: 'Account (optional)',
                        value: _accountId,
                        items: [
                          const PickerItem(value: null, label: 'Unassigned'),
                          for (final a in accounts)
                            PickerItem(
                              value: a.id,
                              label: a.name,
                              leading: Icon(a.icon, size: 18),
                            ),
                        ],
                        onChanged: (v) => setState(() => _accountId = v),
                      ),
                    );
                  },
                ),
                // Date and time are edited separately but stored in one
                // DateTime. Each picker only replaces its own half — the date
                // picker returns midnight, so merging rather than assigning is
                // what keeps a time the user already set.
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.calendar_today, size: 18),
                        label: Text(fmtDate(_date)),
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _date,
                            firstDate: DateTime(2000),
                            lastDate: DateTime.now().add(
                              const Duration(days: 1),
                            ),
                          );
                          if (picked == null) return;
                          setState(
                            () => _date = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              _date.hour,
                              _date.minute,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.schedule, size: 18),
                        label: Text(fmtTime(_date)),
                        onPressed: () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(_date),
                          );
                          if (picked == null) return;
                          setState(
                            () => _date = DateTime(
                              _date.year,
                              _date.month,
                              _date.day,
                              picked.hour,
                              picked.minute,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                if (!isEditing)
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Add'),
                  ),
                // When editing, Save sits at the top of the sheet — Delete
                // stays alone down here, well away from it.
                if (isEditing) ...[
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete transaction'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
