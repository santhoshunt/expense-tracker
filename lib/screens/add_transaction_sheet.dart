import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/format.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/tag_input.dart';
import '../widgets/undo_snackbar.dart';

/// What a new entry starts with, for callers that already know (the People
/// page's "Record repayment"). The kind follows the category.
class TxPrefill {
  final String categoryId;
  final double? amount;

  /// The payer, on a Repaid to me entry.
  final String? person;

  const TxPrefill({required this.categoryId, this.amount, this.person});
}

/// Opens the add sheet, or the edit sheet for [existing]. Completes with the
/// new row's id after an add, and null otherwise (edit, delete, dismiss).
Future<String?> showAddTransactionSheet(
  BuildContext context, {
  Tx? existing,
  TxPrefill? prefill,
}) {
  return showModalBottomSheet<String>(
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
      child: _AddTransactionForm(existing: existing, prefill: prefill),
    ),
  );
}

/// What the type toggle offers. Transfer is not a [TxType]: transfer
/// categories carry their own direction via their type, so the saved
/// transaction's type always comes from the selected category.
enum _EntryKind { expense, income, transfer }

/// One "Who owes what" row: the person, their amount, and whether their
/// share was already settled (kept through the edit).
class _PersonEntry {
  final TextEditingController name;
  final TextEditingController amount;

  _PersonEntry({String name = '', String amount = ''})
    : name = TextEditingController(text: name),
      amount = TextEditingController(text: amount);

  void dispose() {
    name.dispose();
    amount.dispose();
  }
}

class _AddTransactionForm extends StatefulWidget {
  final Tx? existing;
  final TxPrefill? prefill;
  const _AddTransactionForm({this.existing, this.prefill});

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

  /// Who else was in the split and what each owes. With any row here the
  /// share is what they leave of the bill; with none, [_shareCtrl] holds it
  /// and nobody's balance is tracked.
  final List<_PersonEntry> _people = [];

  /// The payer, on a Repaid to me entry.
  late final TextEditingController _fromCtrl;

  /// Tags chosen so far, and the field's not-yet-added text.
  late List<String> _tags;
  final _tagCtrl = TextEditingController();

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
    // Only what a save would keep: rows under an unticked split and a From
    // on another category are ignored by the save, so by the guard too.
    if (_kind == _EntryKind.expense && _isSplit)
      for (final p in _people) '${p.name.text}:${p.amount.text}',
    if (_categoryId == kRepaidToMeCategoryId) _fromCtrl.text,
    pendingTagsOf(_tags, _tagCtrl).join('|'),
    _accountId ?? '',
    _date.toIso8601String(),
  ].join('|');

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final prefill = e == null ? widget.prefill : null;
    final startCategory =
        e?.category ??
        (prefill == null ? null : categoryById(prefill.categoryId));
    if (startCategory == null) {
      _kind = _EntryKind.expense;
    } else if (startCategory.isTransfer) {
      _kind = _EntryKind.transfer;
    } else {
      // The row's own type: a dangling category id falls back to an "Other"
      // of either direction.
      final type = e?.type ?? startCategory.type;
      _kind = type == TxType.income ? _EntryKind.income : _EntryKind.expense;
    }
    _categoryId =
        e?.categoryId ?? prefill?.categoryId ?? _categoriesFor(_kind).first.id;
    _date = e?.date ?? DateTime.now();
    final startAmount = e?.amount ?? prefill?.amount;
    _amountCtrl = TextEditingController(
      text: startAmount == null ? '' : startAmount.toStringAsFixed(2),
    );
    _fromCtrl = TextEditingController(text: e?.repaidBy ?? prefill?.person);
    for (final p in e?.people ?? const <SplitShare>[]) {
      _people.add(
        _PersonEntry(name: p.name, amount: p.amount.toStringAsFixed(2)),
      );
    }
    _noteCtrl = TextEditingController(text: e?.note ?? '');
    _senderCtrl = TextEditingController(text: e?.sender ?? '');
    _isSplit = e?.myShare != null;
    _tags = [...?e?.tags];
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
    _fromCtrl.dispose();
    for (final p in _people) {
      p.dispose();
    }
    _tagCtrl.dispose();
    super.dispose();
  }

  List<TxCategory> _categoriesFor(_EntryKind kind) => _ordered(switch (kind) {
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
  });

  /// Orders the picker per the Settings preference. "Most used" ranks by
  /// gross over the last three months (ties fall back to A to Z), which
  /// also makes `.first` — the default selection — the likeliest category.
  List<TxCategory> _ordered(List<TxCategory> list) {
    CategoryOrder order;
    try {
      order = context.read<SettingsProvider>().categoryOrder;
    } on ProviderNotFoundException {
      // Bare test trees carry no SettingsProvider; the default stands.
      order = CategoryOrder.mostUsed;
    }
    int byName(TxCategory a, TxCategory b) =>
        a.label.toLowerCase().compareTo(b.label.toLowerCase());
    if (order == CategoryOrder.alphabetical) return list..sort(byName);
    final gross = context.read<FinanceProvider>().categoryGrossRecent();
    return list..sort((a, b) {
      final byGross = (gross[b.id] ?? 0).compareTo(gross[a.id] ?? 0);
      return byGross != 0 ? byGross : byName(a, b);
    });
  }

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

  static double _paise(double x) => (x * 100).round() / 100;

  /// What the people rows add up to so far; rows without a number count 0.
  double _peopleTotal() => _paise(
    _people.fold(0.0, (s, p) => s + (parseAmount(p.amount.text) ?? 0)),
  );

  /// Adds a "Who owes what" row, named [name] when a suggestion was
  /// tapped (filling an empty row first). The first row on a split that
  /// only had a share starts with what that share left over.
  void _addPerson([String name = '']) {
    setState(() {
      final blank = name.isEmpty
          ? null
          : _people.where((p) => p.name.text.trim().isEmpty).firstOrNull;
      if (blank != null) {
        blank.name.text = name;
        return;
      }
      if (_people.length >= kMaxSplitPeople) return;
      var amount = '';
      if (_people.isEmpty) {
        final total = parseAmount(_amountCtrl.text);
        final share = parseAmount(_shareCtrl.text);
        if (total != null && share != null && share >= 0 && share < total) {
          amount = _paise(total - share).toStringAsFixed(2);
        }
      }
      _people.add(_PersonEntry(name: name, amount: amount));
    });
  }

  void _removePerson(_PersonEntry p) {
    // A second tap before the next frame must not dispose it twice.
    if (!_people.contains(p)) return;
    setState(() => _people.remove(p));
    // After the frame: the row's fields still hold the controllers.
    WidgetsBinding.instance.addPostFrameCallback((_) => p.dispose());
  }

  /// Everyone gets the same whole-paise part of the bill, you included;
  /// the paise that don't divide stay with your share.
  void _splitEvenly() {
    final total = parseAmount(_amountCtrl.text);
    if (total == null || total <= 0 || _people.isEmpty) return;
    final each = (total * 100).round() ~/ (_people.length + 1);
    setState(() {
      for (final p in _people) {
        p.amount.text = (each / 100).toStringAsFixed(2);
      }
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    final amount = parseAmount(_amountCtrl.text)!;
    // The share is only meaningful on plain expenses; income and transfer
    // kinds hide the checkbox, so saving them always clears it.
    final split = _kind == _EntryKind.expense && _isSplit;
    final tracked = split && _people.isNotEmpty;
    // A share settled by hand stays settled through the edit.
    final wasSettled = {
      for (final p in widget.existing?.people ?? const <SplitShare>[])
        if (p.settled) personKey(p.name),
    };
    final people = [
      if (tracked)
        for (final p in _people)
          SplitShare(
            name: normalizePersonName(p.name.text),
            amount: parseAmount(p.amount.text)!,
            settled: wasSettled.contains(
              personKey(normalizePersonName(p.name.text)),
            ),
          ),
    ];
    final myShare = !split
        ? null
        : tracked
        ? _paise(amount - _peopleTotal())
        : parseAmount(_shareCtrl.text);
    final from = _categoryId == kRepaidToMeCategoryId
        ? normalizePersonName(_fromCtrl.text)
        : '';
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    // Text typed in the tag field but not yet added is saved too.
    final tags = pendingTagsOf(_tags, _tagCtrl);
    setState(() => _busy = true);
    String? newId;

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
            tags: tags,
            people: people,
            repaidBy: from.isEmpty ? null : from,
            clearRepaidBy: from.isEmpty,
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
          tags: tags,
          people: people,
          repaidBy: from.isEmpty ? null : from,
        );
        if (_accountId != null) await finance.assignAccount(id, _accountId!);
        newId = id;
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
    navigator.pop(newId);
  }

  Future<void> _delete() async {
    if (_busy) return;
    setState(() => _busy = true);
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    final tx = widget.existing!;
    // Deleting one leg of a pair unlinks the other; the snapshot lets Undo
    // put both the row and the partner's link back.
    final partner = await finance.deleteTransaction(tx.id);
    if (!mounted) return;
    // Immediate delete + Undo instead of a confirmation dialog — the
    // snackbar rides the app-level messenger, so it outlives this sheet.
    showUndoSnackBar(
      context,
      'Deleted ${tx.category.label} · ${fmtMoney(tx.amount)}',
      () => finance.restoreEditedTransactions([tx, ?partner]),
      icon: Icons.delete_outline,
      tone: AppToastTone.removal,
    );
    navigator.pop();
  }

  /// "Paired transfer" line for a row linked to its other leg, with Unpair.
  Widget _pairedBanner(BuildContext context, Tx tx) {
    final finance = context.read<FinanceProvider>();
    final partner = finance.pairPartnerOf(tx);
    final scheme = Theme.of(context).colorScheme;
    final summary = partner == null
        ? 'other leg missing'
        : '${partner.type == TxType.income ? '+' : '−'}'
              '${fmtMoney(partner.amount)} · ${fmtDateCompact(partner.date)}';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.link, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Paired transfer · $summary',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () async {
              final pairId = tx.pairId!;
              final a = tx.id;
              final b = partner?.id;
              final navigator = Navigator.of(context);
              await finance.unpair(pairId);
              if (!context.mounted) return;
              // Categories stay as they are (transfer); Undo re-links.
              showUndoSnackBar(
                context,
                'Unpaired',
                b == null ? () {} : () => finance.pairTransactions(a, b),
                icon: Icons.link_off,
                tone: AppToastTone.removal,
              );
              navigator.pop();
            },
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }

  /// Names used before, as one-tap chips, leaving out anyone already on
  /// this bill (or already in the From field). [onPick] defaults to adding
  /// a people row.
  List<Widget> _peopleSuggestions(
    BuildContext context, {
    void Function(String name)? onPick,
  }) {
    final taken = {
      for (final p in _people) personKey(p.name.text.trim()),
      if (onPick != null) personKey(_fromCtrl.text.trim()),
    };
    final names = [
      for (final n in context.read<FinanceProvider>().knownPeople)
        if (!taken.contains(personKey(n))) n,
    ].take(6).toList();
    if (names.isEmpty) return const [];
    return [
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final n in names)
            ActionChip(
              avatar: const Icon(Icons.person_outline, size: 16),
              label: Text(n),
              onPressed: () => (onPick ?? _addPerson)(n),
            ),
        ],
      ),
    ];
  }

  /// "Who owes what": a row per person, then Split evenly, the names used
  /// before, and your share as what the rows leave of the bill.
  List<Widget> _peopleRows(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final settled = {
      for (final p in widget.existing?.people ?? const <SplitShare>[])
        if (p.settled) personKey(p.name),
    };
    return [
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(child: Text('Who owes what', style: text.titleSmall)),
          TextButton(
            onPressed: _splitEvenly,
            child: const Text('Split evenly'),
          ),
        ],
      ),
      for (final (i, p) in _people.indexed)
        Padding(
          // Keyed by the entry: removing a row mid-list must not hand its
          // neighbour's field state to the wrong person.
          key: ObjectKey(p),
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextFormField(
                  controller: p.name,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    helperText: settled.contains(personKey(p.name.text.trim()))
                        ? 'Settled'
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final name = normalizePersonName(v ?? '');
                    if (name.isEmpty) return 'Enter a name';
                    final k = personKey(name);
                    final earlier = _people
                        .take(i)
                        .any(
                          (o) =>
                              personKey(normalizePersonName(o.name.text)) == k,
                        );
                    return earlier ? '$name is listed twice' : null;
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: p.amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Owes',
                    prefixText: '₹ ',
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final a = parseAmount(v ?? '');
                    return a == null || a <= 0 ? 'Enter an amount' : null;
                  },
                ),
              ),
              IconButton(
                tooltip:
                    'Remove ${p.name.text.trim().isEmpty ? 'person' : p.name.text.trim()}',
                onPressed: () => _removePerson(p),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      if (_people.length < kMaxSplitPeople)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addPerson,
            icon: const Icon(Icons.person_add_alt_1, size: 18),
            label: const Text('Add person'),
          ),
        ),
      ..._peopleSuggestions(context),
      const SizedBox(height: 8),
      // The share is derived, so the over-total check lives on its line.
      FormField<void>(
        validator: (_) {
          final total = parseAmount(_amountCtrl.text);
          if (total == null) return null;
          return _peopleTotal() > total + 0.005
              ? "People's amounts add up to more than the bill"
              : null;
        },
        builder: (_) {
          final total = parseAmount(_amountCtrl.text);
          // Live, not only on save: a negative "your share" would read as a
          // bug. The validator's same check blocks the save; its stored
          // errorText would linger after the amounts were fixed.
          final over = total != null && _peopleTotal() > total + 0.005;
          final error = over
              ? "People's amounts add up to more than the bill"
              : null;
          return Text(
            error ??
                (total == null
                    ? 'Your share: what the others leave of the bill'
                    : 'Your share ${fmtMoney(_paise(total - _peopleTotal()))}'),
            style: text.bodyMedium?.copyWith(
              color: error != null ? scheme.error : scheme.onSurfaceVariant,
            ),
          );
        },
      ),
    ];
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
                  if (widget.existing!.pairId != null)
                    _pairedBanner(context, widget.existing!),
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
                  if (_isSplit && _people.isNotEmpty) ..._peopleRows(context),
                  if (_isSplit && _people.isEmpty) ...[
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
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _addPerson,
                        icon: const Icon(Icons.person_add_alt_1, size: 18),
                        label: const Text('Add who owes what'),
                      ),
                    ),
                    ..._peopleSuggestions(context),
                  ],
                  // Same 16dp rhythm below the split block as between every
                  // other field.
                  const SizedBox(height: 16),
                ],
                if (_categoryId == kRepaidToMeCategoryId) ...[
                  TextFormField(
                    controller: _fromCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'From',
                      helperText: 'Name them to pay down what they owe',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  ..._peopleSuggestions(
                    context,
                    onPick: (n) => setState(() => _fromCtrl.text = n),
                  ),
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
                TagInput(
                  tags: _tags,
                  controller: _tagCtrl,
                  suggestions: [
                    for (final u in context.read<FinanceProvider>().allTags)
                      u.tag,
                  ],
                  onChanged: (t) => setState(() => _tags = t),
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
