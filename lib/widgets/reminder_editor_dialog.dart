import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/format.dart';
import 'dispose_scope.dart';
import 'picker_sheet.dart';

/// Create/edit dialog for a manual [Reminder]: name, day of month, optional
/// expected amount, expense category. Shared by Settings ("Reminders") and
/// the dashboard's Upcoming card.
Future<void> showReminderEditor(
  BuildContext context, {
  Reminder? existing,
}) async {
  final finance = context.read<FinanceProvider>();
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final amountCtrl = TextEditingController(
    text: existing?.expectedAmount == null
        ? ''
        : existing!.expectedAmount!.toStringAsFixed(0),
  );
  var day = existing?.dayOfMonth ?? 1;
  var categoryId = existing?.categoryId ?? 'other_expense';

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
  if (!categoryItems.any((i) => i.value == categoryId)) {
    categoryId = 'other_expense';
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
          final valid = nameCtrl.text.trim().isNotEmpty && !amountBad;
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
                  AppDropdownField<int>(
                    label: 'Due day of month',
                    value: day,
                    items: [
                      for (var d = 1; d <= 31; d++)
                        PickerItem(value: d, label: '$d'),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => day = v);
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Expected amount (optional)',
                      prefixText: '₹ ',
                      errorText: amountBad ? 'Enter a positive number' : null,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  AppDropdownField<String>(
                    label: 'Category',
                    value: categoryId,
                    items: categoryItems,
                    onChanged: (v) {
                      if (v != null) setState(() => categoryId = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Shows in Upcoming from a week before the due day and '
                    'notifies on open when it is due. Mark it paid from the '
                    'Upcoming card each month.',
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
                        if (existing == null) {
                          finance.addReminder(
                            name: nameCtrl.text.trim(),
                            dayOfMonth: day,
                            expectedAmount: amount,
                            categoryId: categoryId,
                          );
                        } else {
                          finance.updateReminder(
                            existing.copyWith(
                              name: nameCtrl.text.trim(),
                              dayOfMonth: day,
                              expectedAmount: amount,
                              clearExpectedAmount: amount == null,
                              categoryId: categoryId,
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
