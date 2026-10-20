import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/account.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/recurring_detector.dart';
import '../services/refund_matching.dart';
import '../services/subscriptions.dart';
import '../utils/format.dart';
import '../widgets/date_time_picker.dart';
import '../widgets/info_tip.dart';
import '../widgets/motion.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/tag_input.dart';
import '../widgets/undo_snackbar.dart';
import 'classifiers_screen.dart' show showRuleDialog;

/// What a new entry starts with, for callers that already know (the People
/// page's "Record repayment"). The kind follows the category.
class TxPrefill {
  final String categoryId;
  final double? amount;

  /// The payer, on a Repaid to me entry.
  final String? person;

  const TxPrefill({required this.categoryId, this.amount, this.person});
}

/// A host sheet's way to show the edit sheet's Undo offer itself, with the
/// arguments [showUndoSnackBarOn] takes. The host gives a removal its thud.
typedef UndoableHost =
    void Function(
      String message,
      VoidCallback undo, {
      required IconData icon,
      required AppToastTone tone,
    });

/// Opens the add sheet, or the edit sheet for [existing]. Completes with the
/// new row's id after an add, and null otherwise (edit, delete, dismiss).
/// [income] starts a new entry on Income with that side's usual first
/// category (the Quick actions widget's "+ Income").
///
/// [onUndoable] takes the Undo offer of an action that closes the sheet (a
/// delete, Unpair, an add or a confirming save) in place of the app-level
/// toast: a host sheet that stays open (the weekly digest, the review
/// sheet) shows it on itself, where the toast would draw underneath.
///
/// [announceAdd] shows "Added ..." with Undo after a new entry saves; a
/// caller with its own toast for the add (the People page's repayment)
/// turns it off.
Future<String?> showAddTransactionSheet(
  BuildContext context, {
  Tx? existing,
  TxPrefill? prefill,
  bool income = false,
  bool announceAdd = true,
  UndoableHost? onUndoable,
}) {
  // Opening a row that counted at once clears its "new" marker.
  if (existing != null && existing.unseen) {
    context.read<FinanceProvider>().markSeen(existing.id);
  }
  // Toasts fired as the sheet closes go to the caller's messenger: the
  // sheet's own goes with it.
  final outer = ScaffoldMessenger.maybeOf(context);
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    // Keeps the sheet (and its drag handle) below the status bar / notch —
    // a full-height sheet otherwise pushes the handle under the cutout.
    useSafeArea: true,
    showDragHandle: true,
    // The builder's context, not the caller's: keyboard insets are delivered
    // to the sheet's own MediaQuery.
    // ToastHost inside the inset padding, so its strip sits above the
    // keyboard: in-sheet toasts (link results, Make rule) draw on top.
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: ToastHost(
        child: _AddTransactionForm(
          existing: existing,
          prefill: prefill,
          income: income,
          announceAdd: announceAdd,
          outerMessenger: outer,
          onUndoable: onUndoable,
        ),
      ),
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
  final bool income;

  /// See [showAddTransactionSheet].
  final UndoableHost? onUndoable;

  /// See [showAddTransactionSheet].
  final bool announceAdd;

  /// The caller's messenger, for toasts fired as the sheet closes.
  final ScaffoldMessengerState? outerMessenger;

  const _AddTransactionForm({
    this.existing,
    this.prefill,
    this.income = false,
    this.announceAdd = true,
    this.outerMessenger,
    this.onUndoable,
  });

  @override
  State<_AddTransactionForm> createState() => _AddTransactionFormState();
}

class _AddTransactionFormState extends State<_AddTransactionForm> {
  final _formKey = GlobalKey<FormState>();
  late _EntryKind _kind;
  late String _categoryId;
  late DateTime _date;

  /// The moment month figures count this row in ([Tx.countIn]); null = its
  /// own [_date].
  DateTime? _countIn;
  String? _accountId;

  /// What the account dropdown started as, so saving an edit only reassigns
  /// when the user actually changed it — assignAccount is not a harmless
  /// re-affirmation, it rewrites the transaction's account key.
  String? _initialAccountId;

  /// "Count as spending" for a row on a wallet ([Tx.walletCounted]).
  bool _walletCounted = false;

  /// The amount field's text as the sheet opened: an edit on a points
  /// wallet keeps the stored ₹ unless the points were retyped, so a
  /// rounded point count can't shift the amount.
  late final String _initialAmountText;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _noteCtrl;

  /// Paid to (Received from on income): [Tx.payee].
  late final TextEditingController _payeeCtrl;
  late final TextEditingController _senderCtrl;

  /// The read-only Original SMS, held so its selection can become a rule.
  late final TextEditingController _smsCtrl;

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

  /// The Subscription switch, once touched: [_subOn] and [_subCycle] then
  /// hold the user's choice, applied on save. Untouched, the switch shows
  /// what the merchant counts as already.
  bool _subTouched = false;
  bool _subOn = false;
  SubscriptionCycle _subCycle = SubscriptionCycle.monthly;

  /// The merchant the switch was touched for: editing Paid to or the note to
  /// another merchant drops the choice rather than carrying it over.
  String? _subTouchedKey;

  /// The user's Subscription choice when it differs from what the merchant
  /// counts as already, as the key and the choice; null otherwise. Off then
  /// on again, or a cycle picked back, is no change.
  ({String key, bool on, SubscriptionCycle cycle})? _subscriptionChange() {
    if (!_subTouched) return null;
    final key = _subscriptionKey();
    if (key == null || key != _subTouchedKey) return null;
    final now = _subscriptionNow(key);
    if (now.on == _subOn && (!_subOn || now.cycle == _subCycle)) return null;
    return (key: key, on: _subOn, cycle: _subCycle);
  }

  bool get isEditing => widget.existing != null;

  /// Paid to shows on every Expense and Income entry, imported rows too:
  /// many alerts name no merchant, and a typed payee then titles the row.
  bool get _showsPayee => _kind != _EntryKind.transfer;

  /// Sender shows when editing an SMS row, or a manual row that already
  /// holds one; Paid to asks the same question on new entries.
  bool get _showsSender =>
      isEditing &&
      (widget.existing!.source == TxSource.sms ||
          widget.existing!.sender.trim().isNotEmpty);

  /// Re-entrancy latch: a save on a large ledger runs a multi-MB encode on
  /// an isolate before the sheet pops, and the buttons stayed live that
  /// whole time — a double-tap (or Done on the Sender field plus a tap on
  /// Add) minted two rows. Stays true on success; the sheet is closing.
  bool _busy = false;

  /// The form's state as one comparable string, captured once after
  /// initState fills the fields — pop guards compare against it to know
  /// whether closing the sheet would discard anything the user typed.
  /// Taken again when Link to a purchase changes the row under a clean
  /// sheet, so the change it made does not count as typed.
  late String _initialFingerprint;

  String _fingerprint() => [
    _kind.name,
    _categoryId,
    _amountCtrl.text,
    _noteCtrl.text,
    _payeeCtrl.text,
    _senderCtrl.text,
    _isSplit.toString(),
    _shareCtrl.text,
    // Only what a save would keep: rows under an unticked split and a From
    // on another category are ignored by the save, so by the guard too.
    if (_kind == _EntryKind.expense && _isSplit)
      for (final p in _people) '${p.name.text}:${p.amount.text}',
    if (_categoryId == kRepaidToMeCategoryId) _fromCtrl.text,
    pendingTagsOf(_tags, _tagCtrl).join('|'),
    if (_subscriptionChange() case final s?) 'sub:${s.on}:${s.cycle.name}',
    _accountId ?? '',
    _date.toIso8601String(),
    _countIn?.toIso8601String() ?? '',
    _walletCounted.toString(),
  ].join('|');

  /// The picked account when it is a wallet.
  Account? _wallet(FinanceProvider finance) {
    final id = _accountId;
    final a = id == null ? null : finance.accountById(id);
    return a != null && a.isWallet ? a : null;
  }

  /// ₹ per point of the picked account, when it is a points wallet.
  double? _walletPointValue(FinanceProvider finance) {
    final w = _wallet(finance);
    return w?.pointsOf(1) == null ? null : w!.pointValue;
  }

  /// ₹ per point while the amount field takes points: a points wallet, and
  /// not a group split, whose shares are money owed in ₹.
  double? _perPoint(FinanceProvider finance) =>
      _kind == _EntryKind.expense && _isSplit
      ? null
      : _walletPointValue(finance);

  /// Runs [change] (a new account, or the split switched) and re-expresses
  /// a typed amount between ₹ and points, so the value itself stays.
  void _keepAmount(FinanceProvider finance, void Function() change) {
    final before = _perPoint(finance);
    change();
    final after = _perPoint(finance);
    final typed = parseAmount(_amountCtrl.text);
    if (typed == null || before == after) return;
    final rupees = before == null ? typed : typed * before;
    _amountCtrl.text = after == null
        ? rupees.toStringAsFixed(2)
        : fmtFieldNumber(rupees / after);
  }

  void _pickAccount(FinanceProvider finance, String? id) =>
      _keepAmount(finance, () => _accountId = id);

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    final prefill = e == null ? widget.prefill : null;
    final startCategory =
        e?.category ??
        (prefill == null ? null : categoryById(prefill.categoryId));
    if (startCategory == null) {
      _kind = widget.income && e == null
          ? _EntryKind.income
          : _EntryKind.expense;
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
    _countIn = e?.countIn;
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
    _payeeCtrl = TextEditingController(text: e?.payee ?? '');
    _senderCtrl = TextEditingController(text: e?.sender ?? '');
    _smsCtrl = TextEditingController(text: e?.smsBody ?? '');
    _isSplit = e?.myShare != null;
    _tags = [...?e?.tags];
    _shareCtrl = TextEditingController(
      text: e?.myShare == null ? '' : e!.myShare!.toStringAsFixed(2),
    );
    // Preselect the account this transaction already resolves to.
    final finance = context.read<FinanceProvider>();
    if (e?.acctKey != null) {
      _accountId = finance.accountForKey(e!.acctKey)?.id;
    }
    _initialAccountId = _accountId;
    _walletCounted = e?.walletCounted ?? false;
    // On a points wallet the field shows points.
    final perPoint = _perPoint(finance);
    if (perPoint != null && startAmount != null) {
      _amountCtrl.text = fmtFieldNumber(startAmount / perPoint);
    }
    _initialAmountText = _amountCtrl.text;
    _initialFingerprint = _fingerprint();
    // A new entry folds the rarely used fields away, unless one already
    // holds something.
    _moreOpen =
        _tags.isNotEmpty ||
        _countIn != null ||
        (!isEditing && _subscriptionShowsOn());
  }

  /// Whether the Subscription switch would show on as the sheet opens:
  /// the merchant already counts as one.
  bool _subscriptionShowsOn() {
    final key = _subscriptionKey();
    return key != null && _subscriptionNow(key).on;
  }

  /// A new entry's "More details" fold: Tags, Subscription and Count in.
  /// Editing shows them all, as it always has.
  late bool _moreOpen;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
    _payeeCtrl.dispose();
    _senderCtrl.dispose();
    _smsCtrl.dispose();
    _shareCtrl.dispose();
    _fromCtrl.dispose();
    for (final p in _people) {
      p.dispose();
    }
    _tagCtrl.dispose();
    super.dispose();
  }

  /// The entry as it would be saved, for its merchant (the recurring key
  /// and label the Subscription switch works on).
  Tx _draft() =>
      (widget.existing ??
              Tx(
                id: '_draft',
                type: _type,
                categoryId: _categoryId,
                amount: 0,
                note: '',
                date: _date,
              ))
          .copyWith(
            type: _type,
            categoryId: _categoryId,
            note: _noteCtrl.text.trim(),
            payee: _showsPayee ? normalizePayee(_payeeCtrl.text) : null,
          );

  /// The key a Subscription mark would use, or null when the switch has
  /// nothing to mark (not an expense, a transfer, or no merchant).
  String? _subscriptionKey() =>
      _kind == _EntryKind.expense ? recurringKeyOf(_draft()) : null;

  Set<String> _hiddenUpcoming() {
    try {
      return context.read<SettingsProvider>().hiddenUpcoming;
    } on ProviderNotFoundException {
      return const {};
    }
  }

  /// Whether [key] counts as a subscription now, and its cycle.
  ({bool on, SubscriptionCycle cycle}) _subscriptionNow(String key) {
    final finance = context.read<FinanceProvider>();
    final pinned = finance.subscriptionPins[key];
    if (pinned != null) return (on: true, cycle: pinned);
    final summary = cachedSubscriptions(finance, _hiddenUpcoming());
    final listed = [
      ...summary.active,
      ...summary.stopped,
    ].any((i) => i.hit.key == key);
    return (on: listed, cycle: SubscriptionCycle.monthly);
  }

  /// Applies a Subscription [change]: a mark with its cycle, or off, which
  /// also hides a merchant the app would still spot on its own.
  Future<void> _applySubscription(
    FinanceProvider finance,
    SettingsProvider? settings,
    ({String key, bool on, SubscriptionCycle cycle}) change,
  ) async {
    final key = change.key;
    if (change.on) {
      await finance.setSubscriptionPins({key: change.cycle});
      await settings?.unhideUpcoming(key);
      return;
    }
    await finance.setSubscriptionPins({key: null});
    final spotted = detectRecurringPatterns(
      finance.countedTransactions,
      now: DateTime.now(),
    ).any((h) => h.key == key);
    if (spotted) await settings?.hideUpcoming(key);
  }

  List<Widget> _subscriptionField(BuildContext context) {
    final key = _subscriptionKey();
    if (key == null) return const [];
    final touched = _subTouched && key == _subTouchedKey;
    final now = touched ? null : _subscriptionNow(key);
    final on = now?.on ?? _subOn;
    final cycle = now?.cycle ?? _subCycle;
    final label = merchantDisplayLabel(
      _draft(),
      alias: context.read<FinanceProvider>().merchantAlias,
    );
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Subscription'),
        subtitle: Text('Every payment to $label counts'),
        value: on,
        onChanged: (v) => setState(() {
          _subTouched = true;
          _subTouchedKey = key;
          _subOn = v;
          _subCycle = cycle;
        }),
      ),
      if (on) ...[
        const SizedBox(height: 4),
        // Chips that wrap, as the reminder editor's Repeats: with four
        // cycles a one-row segmented button shrank each name to its own
        // size at 320dp.
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final c in SubscriptionCycle.values)
              ChoiceChip(
                label: Text(c.label),
                selected: c == cycle,
                onSelected: (_) => setState(() {
                  _subTouched = true;
                  _subTouchedKey = key;
                  _subOn = true;
                  _subCycle = c;
                }),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
    ];
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

  /// Picks the Count in moment. Starts on the 1st of the month after the
  /// row's date, the salary-on-the-30th case, and reaches the end of the
  /// next month.
  Future<void> _pickCountIn() async {
    final now = DateTime.now();
    final later = _date.isAfter(now) ? _date : now;
    final picked = await pickDateThenTime(
      context,
      initial: _countIn ?? DateTime(_date.year, _date.month + 1),
      firstDate: DateTime(2000),
      lastDate: DateTime(later.year, later.month + 2, 0, 23, 59),
    );
    if (picked == null || !mounted) return;
    setState(() => _countIn = picked);
  }

  Future<void> _save() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    final finance = context.read<FinanceProvider>();
    final typed = parseAmount(_amountCtrl.text)!;
    final perPoint = _perPoint(finance);
    // Points are stored as ₹. An edit that left the points and account as
    // they were keeps the stored ₹, which a rounded count could shift.
    final unchanged =
        isEditing &&
        _accountId == _initialAccountId &&
        _amountCtrl.text == _initialAmountText;
    final amount = perPoint == null
        ? typed
        : unchanged
        ? widget.existing!.amount
        : _paise(typed * perPoint);
    // A transfer has no switch: on a wallet it never counts.
    final onWallet = _wallet(finance) != null && _kind != _EntryKind.transfer;
    // The share is only meaningful on plain expenses; income and transfer
    // kinds hide the checkbox, so saving them always clears it. (A split
    // on a points wallet is entered in ₹: see [_perPoint].)
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
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    final outer = _outerMessenger();
    SettingsProvider? settings;
    try {
      settings = context.read<SettingsProvider>();
    } on ProviderNotFoundException {
      settings = null;
    }
    // Read before the save: the key follows the note as typed.
    final subChange = _subscriptionChange();
    // What the change overwrites, for the confirming save's Undo.
    final subBefore = subChange == null
        ? null
        : (
            key: subChange.key,
            pins: finance.subscriptionPinsBefore([subChange.key]),
            hidden: settings?.hiddenUpcoming.contains(subChange.key),
          );
    // Text typed in the tag field but not yet added is saved too.
    final tags = pendingTagsOf(_tags, _tagCtrl);
    setState(() => _busy = true);
    String? newId;
    // Opening, reading and saving a row still in review is a review: the
    // save confirms it.
    final confirms = isEditing && widget.existing!.pending;
    // A refund link made or undone in this sheet after it opened; the
    // snapshot the sheet started from does not have it.
    final refundOf = isEditing
        ? (_live(finance) ?? widget.existing!).refundOf
        : null;
    // Transfers carry no payee.
    final payee = _kind == _EntryKind.transfer
        ? ''
        : normalizePayee(_payeeCtrl.text);

    try {
      if (isEditing) {
        await finance.updateTransaction(
          widget.existing!.copyWith(
            pending: confirms ? false : null,
            // A refund turned into an expense refunds nothing.
            refundOf: _type == TxType.expense ? null : refundOf,
            clearRefundOf: _type == TxType.expense || refundOf == null,
            type: _type,
            categoryId: _categoryId,
            amount: amount,
            note: _noteCtrl.text.trim(),
            payee: payee,
            date: _date,
            sender: _senderCtrl.text.trim(),
            myShare: myShare,
            clearMyShare: myShare == null,
            tags: tags,
            people: people,
            repaidBy: from.isEmpty ? null : from,
            clearRepaidBy: from.isEmpty,
            countIn: _countIn,
            clearCountIn: _countIn == null,
            // "Unassigned" leaves the row where it is (no unassign on
            // save), so it keeps its own setting there.
            walletCounted: _accountId == null
                ? widget.existing!.walletCounted && _kind != _EntryKind.transfer
                : onWallet && _walletCounted,
            // existing is the snapshot from before the sheet cleared the
            // "new" marker; it must not put it back.
            unseen: false,
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
          payee: payee,
          date: _date,
          sender: _senderCtrl.text.trim(),
          myShare: myShare,
          tags: tags,
          people: people,
          repaidBy: from.isEmpty ? null : from,
          countIn: _countIn,
          walletCounted: onWallet && _walletCounted,
        );
        if (_accountId != null) await finance.assignAccount(id, _accountId!);
        newId = id;
      }
      if (subChange != null) {
        await _applySubscription(finance, settings, subChange);
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      rethrow;
    }
    // Offered whether or not the sheet is still mounted: the offer goes to
    // the host or the caller's messenger, read before the awaits.
    if (confirms) {
      // Without the "new" marker opening the sheet cleared, as on delete.
      final before = widget.existing!.copyWith(unseen: false);
      _offerUndo(
        'Saved and confirmed',
        () {
          finance.restoreEditedTransactions([before]);
          if (subBefore != null) {
            _undoSubscription(finance, settings, subBefore);
          }
        },
        icon: Icons.done_all,
        tone: AppToastTone.success,
        closes: true,
        outer: outer,
      );
    }
    // Every add says what it saved, with Undo. A Subscription mark made
    // while adding belongs to the merchant and stays.
    if (newId != null && widget.announceAdd) {
      final id = newId;
      _offerUndo(
        'Added ${categoryById(_categoryId, fallbackType: _type).label} · '
        '${fmtMoney(amount)}',
        () => finance.deleteTransaction(id),
        icon: Icons.add,
        tone: AppToastTone.success,
        closes: true,
        outer: outer,
      );
    }
    _close(navigator, route, newId);
  }

  /// Puts back what a Subscription change overwrote: the merchant's mark,
  /// and whether the upcoming list hid it ([hidden] null leaves that).
  static Future<void> _undoSubscription(
    FinanceProvider finance,
    SettingsProvider? settings,
    ({String key, Map<String, SubscriptionCycle?> pins, bool? hidden}) before,
  ) async {
    await finance.setSubscriptionPins(before.pins);
    final hidden = before.hidden;
    if (settings == null || hidden == null) return;
    if (hidden) {
      await settings.hideUpcoming(before.key);
    } else {
      await settings.unhideUpcoming(before.key);
    }
  }

  /// The caller's messenger, for an offer made as the sheet closes. Read
  /// while the sheet is mounted: an action that awaits may land after it.
  ScaffoldMessengerState? _outerMessenger() =>
      widget.outerMessenger ?? ScaffoldMessenger.maybeOf(context);

  /// Closes the sheet's [route] once an awaited action lands. Back is
  /// swallowed while [_busy], but the route can still go another way (a
  /// direct pop, the page beneath closing): then a pop would close the
  /// wrong route, so a route no longer active is left alone, and one
  /// under another route is removed in place.
  static void _close(
    NavigatorState navigator,
    ModalRoute<dynamic>? route, [
    String? result,
  ]) {
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop(result);
    } else {
      navigator.removeRoute(route, result);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    setState(() => _busy = true);
    final finance = context.read<FinanceProvider>();
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    final outer = _outerMessenger();
    // Without the "new" marker opening the sheet cleared, so Undo does not
    // bring it back.
    final tx = widget.existing!.copyWith(unseen: false);
    // Deleting one leg of a pair unlinks the other; the snapshot lets Undo
    // put both the row and the partner's link back.
    final partner = await finance.deleteTransaction(tx.id);
    // Immediate delete + Undo instead of a confirmation dialog. The offer
    // goes to the app-level messenger or the host sheet, so it outlives
    // this sheet, and is made even when the sheet is already gone.
    _offerUndo(
      'Deleted ${tx.category.label} · ${fmtMoney(tx.amount)}',
      () =>
          finance.restoreEditedTransactions([tx, ?partner], reAddMissing: true),
      icon: Icons.delete_outline,
      closes: true,
      outer: outer,
    );
    _close(navigator, route);
  }

  /// Offers Undo for a delete, Unpair, Unlink, a link, an add or a
  /// confirming save. [closes] marks an offer made as the sheet pops: it
  /// goes to [_AddTransactionForm.onUndoable] when the host takes it, else
  /// to [outer] (the caller's messenger, which outlives the sheet). The
  /// others leave the sheet open and show on its own messenger, above it,
  /// host or not.
  void _offerUndo(
    String message,
    VoidCallback undo, {
    required IconData icon,
    AppToastTone tone = AppToastTone.removal,
    bool closes = false,
    ScaffoldMessengerState? outer,
  }) {
    final host = widget.onUndoable;
    if (!closes) {
      if (mounted) {
        showUndoSnackBar(context, message, undo, icon: icon, tone: tone);
      }
      return;
    }
    if (host == null) {
      final messenger = outer ?? (mounted ? _outerMessenger() : null);
      if (messenger != null && messenger.mounted) {
        showUndoSnackBarOn(messenger, message, undo, icon: icon, tone: tone);
      }
      return;
    }
    // The icon names what is undone: a bin for a delete, a link for Unpair.
    // The host shows the toast, so the removal thud is its to give.
    host(message, undo, icon: icon, tone: tone);
  }

  /// [_pairedBanner] for the row as the ledger holds it: once Unpair or
  /// Delete clears the link the banner goes, rather than report the other
  /// leg missing while the sheet closes.
  List<Widget> _pairedBanners(BuildContext context) {
    final tx = _live(context.watch<FinanceProvider>());
    if (tx == null || tx.pairId == null) return const [];
    return [_pairedBanner(context, tx)];
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
    // Outlined, not tinted; two lines, so the other leg's date and time
    // are never cut off.
    final small = Theme.of(context).textTheme.bodySmall;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.link, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Paired transfer', style: small),
                Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: _busy
                ? null
                : () async {
                    // The same latch as Save and Delete: a second tap
                    // would pop the page beneath.
                    if (_busy) return;
                    setState(() => _busy = true);
                    // Both legs as they are: Undo puts back this exact pair.
                    final before = [tx, ?finance.pairPartnerOf(tx)];
                    final navigator = Navigator.of(context);
                    final route = ModalRoute.of(context);
                    final outer = _outerMessenger();
                    await finance.unpair(tx.pairId!);
                    // Categories stay as they are (transfer).
                    _offerUndo(
                      'Unpaired',
                      () => finance.restoreEditedTransactions(before),
                      icon: Icons.link_off,
                      closes: true,
                      outer: outer,
                    );
                    _close(navigator, route);
                  },
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
  }

  /// The edited row as the ledger holds it now: Link to a purchase changes
  /// it after the sheet opened. Null once it is gone.
  Tx? _live(FinanceProvider finance) {
    final id = widget.existing!.id;
    return finance.transactions.where((t) => t.id == id).firstOrNull ??
        finance.pendingTransactions.where((t) => t.id == id).firstOrNull;
  }

  /// An outlined box like [_pairedBanner]'s: [lines] under an [icon], the
  /// first in the text colour and the rest muted unless [muteTail] is off,
  /// with an optional [action] button.
  Widget _refundBox(
    BuildContext context, {
    required IconData icon,
    required List<String> lines,
    bool muteTail = true,
    Widget? action,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.fromLTRB(12, 8, action == null ? 12 : 4, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, line) in lines.indexed)
                  Text(
                    line,
                    style: i > 0 && muteTail
                        ? small?.copyWith(color: scheme.onSurfaceVariant)
                        : small,
                  ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }

  /// The refund side of the edited row: what a refund is linked to (or
  /// that its link broke), with Unlink; a purchase's refunds; or, on an
  /// income row linked to nothing, Link to a purchase.
  List<Widget> _refundBanners(BuildContext context) {
    // watch: Link to a purchase changes the row while the sheet is open.
    final finance = context.watch<FinanceProvider>();
    final tx = _live(finance);
    if (tx == null) return const [];
    // First: a refund that became a transfer still shows its broken link.
    if (tx.type == TxType.income && tx.refundOf != null) {
      final unlink = TextButton(
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        onPressed: () async {
          final before = tx;
          await finance.unlinkRefund(tx.id);
          if (!context.mounted) return;
          // The sheet stays open: the banner turns into Link to a purchase,
          // and closing still goes through the unsaved-changes guard.
          // Putting the row back re-links it, a link that broke included.
          _offerUndo(
            'Unlinked',
            () => finance.restoreEditedTransactions([before]),
            icon: Icons.link_off,
          );
        },
        child: const Text('Unlink'),
      );
      final purchase = finance.isLinkedRefund(tx)
          ? finance.refundPurchaseOf(tx)
          : null;
      if (purchase != null) {
        final merchant =
            finance.merchantLabelFor(purchase) ?? purchase.category.label;
        return [
          _refundBox(
            context,
            icon: Icons.link,
            lines: [
              'Refund for $merchant',
              '−${fmtMoney(purchase.amount)} · '
                  '${fmtDateCompact(purchase.date)}',
            ],
            action: unlink,
          ),
        ];
      }
      // A row still in review, or a wallet row left uncounted, is not
      // broken: its link holds once it is confirmed and counted.
      if (finance.refundLinkBroken(tx)) {
        return [
          _refundBox(
            context,
            icon: Icons.link_off,
            lines: const ['Not linked: the purchase changed'],
            action: unlink,
          ),
        ];
      }
      return const [];
    }
    // A transfer pair's leg is linked already; any other category,
    // transfers too, can be one side of a refund pair.
    if (tx.pairId != null) return const [];
    if (tx.type == TxType.expense) {
      final refunds = finance.refundsOf(tx);
      if (refunds.isEmpty) return const [];
      return [
        _refundBox(
          context,
          icon: Icons.undo,
          muteTail: false,
          lines: [
            for (final r in refunds)
              'Refunded ${fmtMoney(r.amount)} · ${fmtDateCompact(r.date)}',
          ],
        ),
      ];
    }
    // A repayment from a friend is not a refund.
    if (tx.categoryId == kRepaidToMeCategoryId) return const [];
    return [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: _busy ? null : () => _linkToPurchase(finance, tx),
          icon: const Icon(Icons.add_link, size: 18),
          label: const Text('Link to a purchase'),
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  /// Picks the purchase [refund] gives money back for and links it: the
  /// likely ones first ([refundCandidatesFor]), else every expense from
  /// the [kRefundWindowDays] before it with enough left to refund.
  Future<void> _linkToPurchase(FinanceProvider finance, Tx refund) async {
    final likely = [
      for (final c in refundCandidatesFor(
        refund,
        finance.transactions,
        remainingOf: finance.refundableLeftOf,
        counts: finance.countsInTotals,
      ))
        c.purchase,
    ];
    bool inWindow(Tx p) {
      final gap = refundDayGap(p, refund);
      return gap >= 0 && gap <= kRefundWindowDays;
    }

    // transactions is newest first already.
    final purchases = likely.isNotEmpty
        ? likely
        : [
            for (final p in finance.transactions)
              if (p.type == TxType.expense &&
                  p.pairId == null &&
                  p.categoryId != kPaidForOthersCategoryId &&
                  p.myShare == null &&
                  finance.countsInTotals(p) &&
                  inWindow(p) &&
                  finance.refundableLeftOf(p) >= refund.amount - 0.005)
                p,
          ];
    if (purchases.isEmpty) {
      showAppToast(
        context,
        'No purchase of ${fmtMoney(refund.amount)} or more in the '
        '$kRefundWindowDays days before it',
      );
      return;
    }
    final picked = await showPickerSheet<String>(
      context: context,
      title: 'Link to a purchase',
      subtitle: 'The refund comes off its spend',
      items: [
        for (final p in purchases)
          PickerItem(
            value: p.id,
            label:
                '${finance.merchantLabelFor(p) ?? p.category.label} · '
                '${fmtMoney(p.amount)} · ${fmtDateCompact(p.date)}',
            leading: Icon(p.category.icon, color: p.category.color, size: 20),
          ),
      ],
    );
    final purchaseId = picked?.value;
    if (purchaseId == null || !mounted) return;
    final clean = _fingerprint() == _initialFingerprint;
    // A confirmed refund the one-time pass offered leaves its list on Link;
    // Undo puts it back, as on the review sheet. Only one that was on it: a
    // row linked by hand never joins.
    final wasInReview = finance.refundReviewIds.contains(refund.id);
    final linked = await finance.linkRefund(refund.id, purchaseId);
    if (!mounted) return;
    if (!linked) {
      showAppToast(
        context,
        "Couldn't link: the purchase has changed",
        tone: AppToastTone.error,
      );
      return;
    }
    // Linking counts a wallet refund; the switch follows, so a save keeps
    // it counted.
    setState(() {
      _walletCounted = _live(finance)?.walletCounted ?? _walletCounted;
      if (clean) _initialFingerprint = _fingerprint();
    });
    _offerUndo(
      'Linked as a refund',
      () {
        finance.restoreEditedTransactions([refund]);
        if (wasInReview) finance.restoreRefundReviewId(refund.id);
      },
      icon: Icons.link,
      tone: AppToastTone.change,
    );
  }

  /// The Original SMS's selection toolbar: the usual buttons, plus Make
  /// rule once the selection holds at least 3 characters besides spaces.
  /// The rule dialog opens over this sheet and returns to it.
  Widget _smsContextMenu(BuildContext context, EditableTextState field) {
    final value = field.textEditingValue;
    final selection = value.selection;
    final selected = selection.isValid && !selection.isCollapsed
        ? selection.textInside(value.text)
        : '';
    final canMakeRule = selected.replaceAll(RegExp(r'\s'), '').length >= 3;
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: field.contextMenuAnchors,
      // Make rule first: the toolbar folds what does not fit into its ⋮
      // menu, and Copy, Select all, Share and the rest come after it.
      buttonItems: [
        if (canMakeRule)
          ContextMenuButtonItem(
            label: 'Make rule',
            onPressed: () {
              field.hideToolbar();
              showRuleDialog(
                this.context,
                patternSuggestion: selected.trim(),
                categorySuggestion: _categoryId,
              );
            },
          ),
        ...field.contextMenuButtonItems,
      ],
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

  /// Payees used before on this side, as one-tap chips: up to six, narrowed
  /// by what is typed, leaving out an exact match.
  List<Widget> _payeeSuggestions(BuildContext context) {
    final typed = _payeeCtrl.text.trim().toLowerCase();
    final names = [
      for (final n in context.read<FinanceProvider>().recentPayees(_type))
        if (n.toLowerCase() != typed && n.toLowerCase().contains(typed)) n,
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
              avatar: const Icon(Icons.history, size: 16),
              label: Text(n),
              onPressed: () => setState(() {
                _payeeCtrl.text = n;
                _payeeCtrl.selection = TextSelection.collapsed(
                  offset: n.length,
                );
              }),
            ),
        ],
      ),
    ];
  }

  /// Paid to on Expense, Received from on Income, with the recent payees
  /// under it. Nothing on a transfer ([_showsPayee]).
  List<Widget> _payeeField(BuildContext context) {
    if (!_showsPayee) return const [];
    final income = _kind == _EntryKind.income;
    return [
      TextFormField(
        controller: _payeeCtrl,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          labelText: income ? 'Received from' : 'Paid to',
          hintText: income
              ? 'Person, employer or service'
              : 'Shop, person or service',
        ),
        onChanged: (_) => setState(() {}),
      ),
      ..._payeeSuggestions(context),
      const SizedBox(height: 16),
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

  Widget _tagField(BuildContext context) => TagInput(
    tags: _tags,
    controller: _tagCtrl,
    suggestions: [
      for (final u in context.read<FinanceProvider>().allTags) u.tag,
    ],
    onChanged: (t) => setState(() => _tags = t),
    colorOf: context.read<FinanceProvider>().tagColor,
  );

  Widget _senderField() => TextFormField(
    controller: _senderCtrl,
    decoration: const InputDecoration(
      labelText: 'Sender (optional)',
      helperText: 'Who the money moved to or from. SMS imports fill this in.',
    ),
    textInputAction: TextInputAction.done,
    onFieldSubmitted: (_) => _save(),
  );

  /// Count in: month figures use another moment, the row keeps its own
  /// date (and so the account balance stays right). Same top gap either
  /// way, so setting or clearing it doesn't shift the buttons below.
  Widget _countInField() => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: _countIn == null
          ? TextButton(
              onPressed: _pickCountIn,
              child: const Text(
                'Count in another date ›',
                semanticsLabel: 'Count in another date',
              ),
            )
          : InputChip(
              avatar: const Icon(Icons.event_repeat_outlined, size: 18),
              label: Text('Counts in ${fmtCountIn(_countIn!)}'),
              onPressed: _pickCountIn,
              onDeleted: () => setState(() => _countIn = null),
              deleteButtonTooltipMessage: 'Count on its own date',
            ),
    ),
  );

  /// A new entry's fold for the fields most entries never need. Closed,
  /// its fields are not built at all, so nothing hidden can take focus.
  Widget _moreDetails(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // TalkBack says whether the fold is open. Merged, so the flags land
        // on the tile's own node rather than one above it.
        MergeSemantics(
          child: Semantics(
            button: true,
            expanded: _moreOpen,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('More details'),
              subtitle: Text(
                'Tags, subscription, count in another date',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
              trailing: AnimatedRotation(
                turns: _moreOpen ? 0.5 : 0,
                duration: motionDuration(
                  context,
                  const Duration(milliseconds: 200),
                ),
                child: const Icon(Icons.expand_more),
              ),
              onTap: () => setState(() => _moreOpen = !_moreOpen),
            ),
          ),
        ),
        AnimatedSize(
          duration: motionDuration(context, const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_moreOpen
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _tagField(context),
                      const SizedBox(height: 16),
                      ..._subscriptionField(context),
                      _countInField(),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// Editing scrolls the whole form, as it always has. A new entry pins
  /// Add in a footer under the scrolling form: the sheet sits on the
  /// keyboard's inset, so Add stays in view while typing.
  Widget _layout(Widget form) {
    if (isEditing) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: form,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: form,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: const Text('Add'),
          ),
        ),
      ],
    );
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
        // A save, delete or Unpair in flight closes the sheet itself when
        // it lands; closing it here too would close the page beneath.
        if (_busy) return;
        final navigator = Navigator.of(context);
        if (_fingerprint() == _initialFingerprint) {
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
              // The error style bulk Delete uses: this throws input away.
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError,
                ),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Discard'),
              ),
            ],
          ),
        );
        if (discard == true && mounted) navigator.pop();
      },
      child: SafeArea(
        child: _layout(
          Form(
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
                // above Delete, a mis-tap hazard, since saving an SMS import
                // still in review also confirms it.
                if (isEditing) ...[
                  FilledButton(
                    onPressed: _busy ? null : _save,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    // A pending row's save confirms it, and the label says so.
                    child: Text(
                      widget.existing!.pending
                          ? 'Save and confirm'
                          : 'Save changes',
                    ),
                  ),
                  const SizedBox(height: 16),
                  ..._pairedBanners(context),
                  ..._refundBanners(context),
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
                  onSelectionChanged: (s) => setState(
                    // Split or not decides ₹ vs points on a points wallet.
                    () => _keepAmount(context.read<FinanceProvider>(), () {
                      _kind = s.first;
                      _categoryId = _categoriesFor(_kind).first.id;
                      // Splits are an expense-only concept.
                      if (_kind != _EntryKind.expense) _isSplit = false;
                    }),
                  ),
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
                  // A points wallet takes points and says what they're worth.
                  decoration: switch (_perPoint(
                    context.watch<FinanceProvider>(),
                  )) {
                    null => const InputDecoration(
                      labelText: 'Amount',
                      prefixText: '₹ ',
                    ),
                    final perPoint => InputDecoration(
                      labelText: 'Points',
                      helperText: switch (parseAmount(_amountCtrl.text)) {
                        final p? => '= ${fmtMoney(p * perPoint)}',
                        null => '${fmtPerPoint(perPoint)} each',
                      },
                    ),
                  },
                  validator: (v) {
                    // parseAmount, not double.tryParse: people type "1,500".
                    final parsed = parseAmount(v ?? '');
                    if (parsed == null || parsed <= 0) {
                      return _perPoint(context.read<FinanceProvider>()) == null
                          ? 'Enter an amount greater than 0'
                          : 'Enter points greater than 0';
                    }
                    // Points are stored in ₹: a value that rounds to ₹0
                    // would be a row no backup could restore.
                    final perPoint = _perPoint(context.read<FinanceProvider>());
                    if (perPoint != null && _paise(parsed * perPoint) <= 0) {
                      return 'Worth less than ₹0.01; enter more points';
                    }
                    return null;
                  },
                  // Keeps the split field's helper text (the live remainder)
                  // and the points helper in step while typing.
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                ..._payeeField(context),
                // Hidden on a points wallet, unless the row is (or was, as
                // the sheet opened) a split: it stays editable, in ₹, and an
                // accidental untick can be undone.
                if (_kind == _EntryKind.expense &&
                    (_isSplit ||
                        widget.existing?.myShare != null ||
                        _walletPointValue(context.read<FinanceProvider>()) ==
                            null)) ...[
                  CheckboxListTile(
                    value: _isSplit,
                    onChanged: (v) => setState(
                      () => _keepAmount(
                        context.read<FinanceProvider>(),
                        () => _isSplit = v ?? false,
                      ),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Group split payment'),
                    subtitle: Text(
                      'You paid the full bill for the group. Only your own '
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
                  // Free text. The merchant is Paid to; on rows saved before
                  // it existed, the note stands in.
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                // A new entry has these under More details below.
                if (isEditing) ...[
                  _tagField(context),
                  const SizedBox(height: 16),
                  ..._subscriptionField(context),
                ],
                // The raw alert an SMS row was imported from — read-only so the
                // review flow can still see the full message, while the Note
                // field above stays purely the user's own text.
                if (widget.existing != null &&
                    widget.existing!.source == TxSource.sms &&
                    widget.existing!.smsBody.isNotEmpty) ...[
                  TextFormField(
                    controller: _smsCtrl,
                    readOnly: true,
                    minLines: 1,
                    maxLines: 4,
                    style: Theme.of(context).textTheme.bodySmall,
                    decoration: const InputDecoration(
                      labelText: 'Original SMS',
                    ),
                    contextMenuBuilder: _smsContextMenu,
                  ),
                  const SizedBox(height: 16),
                ],
                if (_showsSender) ...[
                  _senderField(),
                  const SizedBox(height: 16),
                ],
                Builder(
                  builder: (context) {
                    // watch, not read: an account created while the sheet is
                    // open must appear in the dropdown.
                    final finance = context.watch<FinanceProvider>();
                    // Open accounts only — but keep the row's own account
                    // even when closed, so editing an old transaction shows
                    // (and preserves) its real assignment.
                    // A transfer leg never goes on a wallet: the bank side
                    // would stay a transfer and the money be in no figure.
                    final paired = widget.existing?.pairId != null;
                    final accounts = [
                      for (final a in finance.openAccounts)
                        if (!paired || !a.isWallet || a.id == _accountId) a,
                      if (_accountId != null &&
                          (finance.accountById(_accountId!)?.isClosed ?? false))
                        finance.accountById(_accountId!)!,
                    ];
                    if (accounts.isEmpty) return const SizedBox.shrink();
                    final onWallet = _wallet(finance) != null;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          AppDropdownField<String>(
                            label: 'Account (optional)',
                            value: _accountId,
                            items: [
                              const PickerItem(
                                value: null,
                                label: 'Unassigned',
                              ),
                              for (final a in accounts)
                                PickerItem(
                                  value: a.id,
                                  label: a.displayName,
                                  leading: Icon(a.icon, size: 18),
                                ),
                            ],
                            onChanged: (v) =>
                                setState(() => _pickAccount(finance, v)),
                          ),
                          // Wallet rows stay out of spending and income
                          // unless turned on here. Not on a transfer, which
                          // is never spending or income. A ListTile with its
                          // own Switch, not a SwitchListTile: that merges
                          // the tip into the switch, so a screen reader
                          // could only toggle it (see settings_screen
                          // _TipSwitchTile).
                          if (onWallet && _kind != _EntryKind.transfer)
                            Builder(
                              builder: (context) {
                                final label = _kind == _EntryKind.income
                                    ? 'Count as income'
                                    : 'Count as spending';
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: InfoLabel(
                                    icon: true,
                                    label: Text(label),
                                    tip: InfoTip(
                                      title: label,
                                      // Both say which way cashback and a
                                      // bank top-up go, so they agree.
                                      message: _kind == _EntryKind.income
                                          ? 'Turn on for money that came '
                                                'from outside your accounts, '
                                                'such as cashback or a gift '
                                                'card. Leave off for a top-up '
                                                'from your bank.'
                                          : 'Turn on when this wallet money '
                                                'came from cashback, a gift '
                                                'card or rewards. Leave off '
                                                'when it was a bank top-up: '
                                                'that already counted as '
                                                'spending when it left the '
                                                'bank.',
                                    ),
                                  ),
                                  trailing: Semantics(
                                    label: label,
                                    child: Switch(
                                      value: _walletCounted,
                                      onChanged: (v) =>
                                          setState(() => _walletCounted = v),
                                    ),
                                  ),
                                  onTap: () => setState(
                                    () => _walletCounted = !_walletCounted,
                                  ),
                                );
                              },
                            ),
                        ],
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
                          setState(() {
                            final moved =
                                picked.year != _date.year ||
                                picked.month != _date.month ||
                                picked.day != _date.day;
                            _date = DateTime(
                              picked.year,
                              picked.month,
                              picked.day,
                              _date.hour,
                              _date.minute,
                            );
                            // A Count in chosen for the old day says nothing
                            // about the new one, as with bulk Date & time.
                            if (moved) _countIn = null;
                          });
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
                // A new entry's Add sits in the footer below the form.
                if (!isEditing) ...[
                  const SizedBox(height: 8),
                  _moreDetails(context),
                ],
                // When editing, Save sits at the top of the sheet — Delete
                // stays alone down here, well away from it.
                if (isEditing) ...[
                  _countInField(),
                  const SizedBox(height: 20),
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
