import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../services/reminder_schedule.dart';
import '../utils/app_theme.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'dispose_scope.dart';
import 'info_tip.dart';
import 'picker_sheet.dart';
import 'undo_snackbar.dart';

/// Create/edit dialog for a manual [Reminder]: name, how often it repeats,
/// due day (and month), optional expected amount, expense category, and
/// whether it adds the expense itself. Shared by the Cockpit's Reminders
/// tab and the dashboard's Next 7 days card.
///
/// The [name], [dayOfMonth], [amount], [categoryId], [cycle] and
/// [anchorMonth] prefill a NEW reminder (the Subscriptions list's "Make a
/// reminder"); [existing] wins over them when editing. A given [onDate]
/// (the heatmap's "Set a reminder") opens on Once with that date.
///
/// [allowDelete] adds Delete when editing, which removes the reminder with
/// Undo. Only the Cockpit list passes it: opened from a sheet, a delete
/// would leave the sheet showing a removed reminder.
Future<void> showReminderEditor(
  BuildContext context, {
  Reminder? existing,
  String? name,
  int? dayOfMonth,
  double? amount,
  String? categoryId,
  SubscriptionCycle? cycle,
  int? anchorMonth,
  DateTime? onDate,
  bool allowDelete = false,
}) async {
  final finance = context.read<FinanceProvider>();
  final nameCtrl = TextEditingController(text: existing?.name ?? name ?? '');
  final startAmount = existing == null ? amount : existing.expectedAmount;
  final amountCtrl = TextEditingController(
    text: startAmount == null ? '' : startAmount.toStringAsFixed(0),
  );
  var day = (existing?.dayOfMonth ?? dayOfMonth ?? 1).clamp(1, 31);
  var selectedCategory = existing?.categoryId ?? categoryId ?? 'other_expense';
  var repeats = existing?.cycle ?? cycle ?? SubscriptionCycle.monthly;
  var month =
      (existing == null
              ? (anchorMonth ?? DateTime.now().month)
              : existing.anchorMonth)
          .clamp(1, 12);
  // A one-time date also sets the day and month, so switching to a
  // repeating choice keeps the same day instead of day 1.
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final startOnce = existing != null
      ? reminderOnceDate(existing)
      : (onDate == null
            ? null
            : DateTime(onDate.year, onDate.month, onDate.day));
  DateTime? onceDate = startOnce;
  var once = startOnce != null;
  if (startOnce != null) {
    day = startOnce.day;
    month = startOnce.month;
  }
  var autoAdd = existing?.autoAdd ?? false;
  // Delete pops the editor first; the reminder then goes with Undo.
  var deleteRequested = false;
  String? accountId = existing?.accountId;
  // Open accounts, plus a closed one this reminder already pays from, so a
  // rename does not quietly drop it.
  final kept = accountId == null ? null : finance.accountById(accountId);
  // No wallets: an expense added there would stay out of spending unless
  // turned on by hand, while the bill still reads as paid.
  final accounts = [
    for (final a in finance.openAccounts)
      if (!a.isWallet) a,
    if (kept != null &&
        !kept.isWallet &&
        !finance.openAccounts.any((a) => a.id == kept.id))
      kept,
  ];
  if (accountId != null && !accounts.any((a) => a.id == accountId)) {
    accountId = null;
  }

  // Money-out categories only; transfer ones are tagged so "To savings"
  // reads as what it is.
  final categoryItems = <PickerItem<String>>[
    const PickerItem.header('Expenses'),
    for (final c in allCategories)
      if (c.type == TxType.expense && !c.isTransfer)
        PickerItem(
          value: c.id,
          label: c.label,
          leading: Icon(c.icon, color: c.color, size: 20),
        ),
    const PickerItem.header('Transfers'),
    for (final c in allCategories)
      if (c.type == TxType.expense && c.isTransfer)
        PickerItem(
          value: c.id,
          label: '${c.label} · money out',
          leading: Icon(c.icon, color: c.color, size: 20),
        ),
  ];
  if (!categoryItems.any((i) => i.value == selectedCategory)) {
    selectedCategory = 'other_expense';
  }

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [nameCtrl, amountCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final amountText = amountCtrl.text.trim();
          final amount = amountText.isEmpty ? null : parseAmount(amountText);
          final amountBad =
              amountText.isNotEmpty && (amount == null || amount <= 0);
          // Adding the expense needs to know how much.
          final amountMissing = autoAdd && amountText.isEmpty;
          final shownDate = onceDate;
          final valid =
              nameCtrl.text.trim().isNotEmpty &&
              !amountBad &&
              !amountMissing &&
              (!once || shownDate != null);
          String dateText(DateTime? d) =>
              d == null ? 'Pick a date' : fmtDate(d);
          Future<void> pickDate() async {
            final last = DateTime(today.year + 5, today.month, today.day);
            // showDatePicker asserts on a start outside its range: an older
            // date being edited opens on today.
            final start = shownDate ?? today;
            final picked = await showDatePicker(
              context: ctx,
              initialDate: start.isBefore(today)
                  ? today
                  : (start.isAfter(last) ? last : start),
              firstDate: today,
              lastDate: last,
            );
            if (picked == null || !ctx.mounted) return;
            setState(() {
              onceDate = DateTime(picked.year, picked.month, picked.day);
              day = picked.day;
              month = picked.month;
            });
          }

          return AlertDialog(
            title: Text(existing == null ? 'New reminder' : 'Edit reminder'),
            content: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameCtrl,
                    autofocus: existing == null,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Money to home, EB bill',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  Text('Repeats', style: Theme.of(ctx).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  // Chips, not segments: four segments in a dialog this
                  // narrow each shrank their label to a different size.
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final r in _Repeat.values)
                        ChoiceChip(
                          label: Text(r.label),
                          selected:
                              r == (once ? _Repeat.once : _Repeat.of(repeats)),
                          onSelected: (_) => setState(() {
                            once = r == _Repeat.once;
                            repeats = r.cycle ?? repeats;
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (once)
                    // One button for a screen reader: the field's label,
                    // value and icon would otherwise read as three parts.
                    Semantics(
                      button: true,
                      label: 'Date, ${dateText(shownDate)}',
                      excludeSemantics: true,
                      onTap: pickDate,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(AppRadius.control),
                        onTap: pickDate,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Date',
                            suffixIcon: Icon(Icons.calendar_today, size: 18),
                          ),
                          child: Text(dateText(shownDate), maxLines: 1),
                        ),
                      ),
                    )
                  else
                    // Dropdowns carry their own arrow suffix, so each tip
                    // trails its field instead.
                    Row(
                      children: [
                        Expanded(
                          child: AppDropdownField<int>(
                            label: 'Due day',
                            value: day,
                            items: [
                              for (var d = 1; d <= 31; d++)
                                PickerItem(value: d, label: '$d'),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => day = v);
                            },
                          ),
                        ),
                        const InfoTip(
                          title: 'Due day',
                          message:
                              'Days 29 to 31 fall on the last day of shorter '
                              'months.',
                        ),
                      ],
                    ),
                  if (!once && repeats != SubscriptionCycle.monthly) ...[
                    const SizedBox(height: 16),
                    AppDropdownField<int>(
                      label: repeats == SubscriptionCycle.yearly
                          ? 'Due month'
                          : 'Due months',
                      // Yearly lists 12 months, half-yearly 6 pairs and
                      // quarterly 3 groups, each by its first month.
                      value: (month - 1) % repeats.months + 1,
                      items: [
                        for (var m = 1; m <= repeats.months; m++)
                          PickerItem(
                            value: m,
                            label: cycleMonthsLabel(m, repeats),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => month = v);
                      },
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: autoAdd
                          ? 'Amount'
                          : 'Expected amount (optional)',
                      prefixText: '₹ ',
                      errorText: amountBad
                          ? 'Enter a positive number'
                          : amountMissing
                          ? 'Needed to add it for you'
                          : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: AppDropdownField<String>(
                          label: 'Category',
                          value: selectedCategory,
                          items: categoryItems,
                          onChanged: (v) {
                            if (v != null) setState(() => selectedCategory = v);
                          },
                        ),
                      ),
                      const InfoTip(
                        title: 'Category',
                        message:
                            'Sets the icon and colour, and the category of '
                            'the expense Add it for me records.',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Add it for me on the due day'),
                    subtitle: const Text(
                      'Adds the expense itself. Use it for cash or bills '
                      'with no bank SMS.',
                    ),
                    value: autoAdd,
                    onChanged: (v) => setState(() => autoAdd = v),
                  ),
                  if (autoAdd) ...[
                    const SizedBox(height: 8),
                    AppDropdownField<String>(
                      label: 'Paid from',
                      value: accountId,
                      items: [
                        const PickerItem(value: null, label: 'No account'),
                        for (final a in accounts)
                          PickerItem(value: a.id, label: a.displayName),
                      ],
                      onChanged: (v) => setState(() => accountId = v),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    autoAdd
                        ? 'Shows on the Next 7 days card a week ahead, and '
                              'records the expense on the due day when you '
                              'open the app or a background import runs.'
                        : 'Shows on the Next 7 days card a week ahead, and '
                              'notifies from 2 days before. Alerts are checked '
                              'when the app opens and about every 6 hours '
                              'while it is closed. A bank SMS for this amount '
                              'near the due day marks it paid; otherwise mark '
                              'it paid from the Next 7 days card.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              if (existing != null && allowDelete)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  onPressed: () {
                    deleteRequested = true;
                    Navigator.pop(ctx);
                  },
                  child: const Text('Delete'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: !valid
                    ? null
                    : () {
                        // Once is stored as yearly on its own day and
                        // month, which is how an older build reads it.
                        final onceDay = once ? shownDate : null;
                        final onceKey = onceDay == null
                            ? null
                            : '${monthKey(onceDay)}-'
                                  '${onceDay.day.toString().padLeft(2, '0')}';
                        final saveCycle = onceDay == null
                            ? repeats
                            : SubscriptionCycle.yearly;
                        final saveDay = onceDay?.day ?? day;
                        // Quarterly and half-yearly keep the picked months'
                        // first one; monthly stores the current month,
                        // unused.
                        final anchor =
                            onceDay?.month ??
                            switch (repeats) {
                              SubscriptionCycle.monthly => DateTime.now().month,
                              // The picked month's place in its cycle, the
                              // rule the Due month(s) dropdown shows.
                              _ => (month - 1) % repeats.months + 1,
                            };
                        final account = autoAdd ? accountId : null;
                        if (existing == null) {
                          finance.addReminder(
                            name: nameCtrl.text.trim(),
                            dayOfMonth: saveDay,
                            expectedAmount: amount,
                            categoryId: selectedCategory,
                            cycle: saveCycle,
                            anchorMonth: anchor,
                            autoAdd: autoAdd,
                            accountId: account,
                            onDate: onceKey,
                          );
                        } else {
                          // The stored copy, not the one this dialog opened
                          // with: an import or a resume may have marked it
                          // paid meanwhile, and saving must not undo that.
                          final current = finance.reminders.firstWhere(
                            (x) => x.id == existing.id,
                            orElse: () => existing,
                          );
                          // A new one-time date starts unpaid: a mark kept
                          // from the old date or cycle would read as done
                          // the moment it saves.
                          final freshOnce =
                              onceKey != null && onceKey != current.onDate;
                          finance.updateReminder(
                            current.copyWith(
                              name: nameCtrl.text.trim(),
                              dayOfMonth: saveDay,
                              expectedAmount: amount,
                              clearExpectedAmount: amount == null,
                              categoryId: selectedCategory,
                              cycle: saveCycle,
                              anchorMonth: anchor,
                              autoAdd: autoAdd,
                              accountId: account,
                              clearAccountId: account == null,
                              onDate: onceKey,
                              clearOnDate: onceKey == null,
                              clearLastPaidMonth: freshOnce,
                            ),
                          );
                        }
                        Navigator.pop(ctx);
                      },
                child: Text(existing == null ? 'Create' : 'Save'),
              ),
            ],
          );
        },
      ),
    ),
  );
  if (deleteRequested && existing != null && context.mounted) {
    deleteReminderWithUndo(context, existing.id);
  }
}

/// Deletes the reminder [id] and offers Undo, which puts back the stored
/// copy as it was at the delete (a paid mark made since an editor opened
/// included) at the position it held in the list, not at the end. Nothing
/// happens when no reminder has [id].
void deleteReminderWithUndo(BuildContext context, String id) {
  final finance = context.read<FinanceProvider>();
  final index = finance.reminders.indexWhere((x) => x.id == id);
  if (index == -1) return;
  final removed = finance.reminders[index];
  finance.deleteReminder(id);
  showUndoSnackBar(
    context,
    'Deleted reminder "${removed.name}"',
    () => finance.restoreReminder(removed, index: index),
    icon: Icons.delete_outline,
    tone: AppToastTone.removal,
  );
}

/// The Repeats choices: Once first, then the repeating cycles.
enum _Repeat {
  once('Once', null),
  monthly('Monthly', SubscriptionCycle.monthly),
  quarterly('Quarterly', SubscriptionCycle.quarterly),
  halfYearly('Half-yearly', SubscriptionCycle.halfYearly),
  yearly('Yearly', SubscriptionCycle.yearly);

  final String label;

  /// Null for Once, which is stored as yearly with [Reminder.onDate].
  final SubscriptionCycle? cycle;

  const _Repeat(this.label, this.cycle);

  static _Repeat of(SubscriptionCycle c) =>
      values.firstWhere((r) => r.cycle == c);
}
