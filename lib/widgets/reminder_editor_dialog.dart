import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../services/reminder_schedule.dart';
import '../utils/format.dart';
import 'cycle_label.dart';
import 'dispose_scope.dart';
import 'info_tip.dart';
import 'picker_sheet.dart';

/// Create/edit dialog for a manual [Reminder]: name, how often it repeats,
/// due day (and month), optional expected amount, expense category, and
/// whether it adds the expense itself. Shared by Settings ("Reminders") and
/// the dashboard's Upcoming card.
///
/// The [name], [dayOfMonth], [amount], [categoryId], [cycle] and
/// [anchorMonth] prefill a NEW reminder (the Subscriptions list's "Make a
/// reminder"); [existing] wins over them when editing.
Future<void> showReminderEditor(
  BuildContext context, {
  Reminder? existing,
  String? name,
  int? dayOfMonth,
  double? amount,
  String? categoryId,
  SubscriptionCycle? cycle,
  int? anchorMonth,
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
  var autoAdd = existing?.autoAdd ?? false;
  String? accountId = existing?.accountId;
  // Open accounts, plus a closed one this reminder already pays from, so a
  // rename does not quietly drop it.
  final kept = accountId == null ? null : finance.accountById(accountId);
  final accounts = [
    ...finance.openAccounts,
    if (kept != null && !finance.openAccounts.any((a) => a.id == kept.id)) kept,
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
          final valid =
              nameCtrl.text.trim().isNotEmpty && !amountBad && !amountMissing;
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
                  SegmentedButton<SubscriptionCycle>(
                    showSelectedIcon: false,
                    segments: [
                      for (final c in SubscriptionCycle.values)
                        ButtonSegment(value: c, label: cycleLabel(c.label)),
                    ],
                    selected: {repeats},
                    onSelectionChanged: (s) =>
                        setState(() => repeats = s.first),
                  ),
                  const SizedBox(height: 16),
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
                  if (repeats != SubscriptionCycle.monthly) ...[
                    const SizedBox(height: 16),
                    AppDropdownField<int>(
                      label: repeats == SubscriptionCycle.yearly
                          ? 'Due month'
                          : 'Due months',
                      value: repeats == SubscriptionCycle.yearly
                          ? month
                          : (month - 1) % 3 + 1,
                      items: [
                        if (repeats == SubscriptionCycle.yearly)
                          for (var m = 1; m <= 12; m++)
                            PickerItem(value: m, label: reminderMonthName(m))
                        else
                          for (var m = 1; m <= 3; m++)
                            PickerItem(value: m, label: quarterMonthsLabel(m)),
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
                          PickerItem(value: a.id, label: a.name),
                      ],
                      onChanged: (v) => setState(() => accountId = v),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    autoAdd
                        ? 'Shows in Upcoming a week ahead, and records the '
                              'expense on the due day when you open the app '
                              'or a background import runs.'
                        : 'Shows in Upcoming a week ahead, and notifies from '
                              '2 days before, when you open the app. A bank SMS '
                              'for this amount near the due day marks it paid; '
                              'otherwise mark it paid from the Upcoming card.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: !valid
                    ? null
                    : () {
                        // Quarterly keeps the picked months' first one;
                        // monthly stores the current month, unused.
                        final anchor = switch (repeats) {
                          SubscriptionCycle.monthly => DateTime.now().month,
                          SubscriptionCycle.quarterly => (month - 1) % 3 + 1,
                          SubscriptionCycle.yearly => month,
                        };
                        final account = autoAdd ? accountId : null;
                        if (existing == null) {
                          finance.addReminder(
                            name: nameCtrl.text.trim(),
                            dayOfMonth: day,
                            expectedAmount: amount,
                            categoryId: selectedCategory,
                            cycle: repeats,
                            anchorMonth: anchor,
                            autoAdd: autoAdd,
                            accountId: account,
                          );
                        } else {
                          // The stored copy, not the one this dialog opened
                          // with: an import or a resume may have marked it
                          // paid meanwhile, and saving must not undo that.
                          final current = finance.reminders.firstWhere(
                            (x) => x.id == existing.id,
                            orElse: () => existing,
                          );
                          finance.updateReminder(
                            current.copyWith(
                              name: nameCtrl.text.trim(),
                              dayOfMonth: day,
                              expectedAmount: amount,
                              clearExpectedAmount: amount == null,
                              categoryId: selectedCategory,
                              cycle: repeats,
                              anchorMonth: anchor,
                              autoAdd: autoAdd,
                              accountId: account,
                              clearAccountId: account == null,
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
}
