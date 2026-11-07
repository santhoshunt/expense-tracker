import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/reminder.dart';
import '../models/subscription_cycle.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../services/reminder_schedule.dart';
import '../services/upcoming_monitor.dart';
import '../utils/app_theme.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'dialog_expander.dart';
import 'dispose_scope.dart';
import 'editor_sheet.dart';
import 'grouped_surface.dart';
import 'info_tip.dart';
import 'picker_sheet.dart';
import 'undo_snackbar.dart';

/// Create/edit sheet for a manual [Reminder]: name, optional expected
/// amount, how often it repeats, due day (and month), category, and, folded,
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
    // Paise kept: a rounded figure would be saved back rounded.
    text: startAmount == null ? '' : fmtFieldNumber(startAmount),
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

  // Money-out categories, transfer ones tagged so "To savings" reads as what
  // it is, then income ones: a salary reminder adds to the expected balance
  // on the Ahead tab and is never a bill.
  final categoryItems = <PickerItem<String>>[
    const PickerItem.header('Expenses'),
    for (final c in allCategories)
      if (c.type == TxType.expense && !c.isTransfer && !isToSortCategory(c.id))
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
    const PickerItem.header('Income'),
    for (final c in allCategories)
      if (c.type == TxType.income && !c.isTransfer && !isToSortCategory(c.id))
        PickerItem(
          value: c.id,
          label: c.label,
          leading: Icon(c.icon, color: c.color, size: 20),
        ),
  ];
  if (!categoryItems.any((i) => i.value == selectedCategory)) {
    selectedCategory = 'other_expense';
  }

  // Every field, compared with how the sheet opened for "Discard changes?".
  Object fields() => (
    nameCtrl.text.trim(),
    amountCtrl.text.trim(),
    once,
    onceDate,
    repeats,
    day,
    month,
    selectedCategory,
    autoAdd,
    accountId,
  );
  final opened = fields();
  // The Add it for me fold starts closed; its line shows what is set.
  var autoOpen = false;

  // The reminder as the fields stand: what Create and Save write, and what
  // the summary line reads.
  Reminder draft({required double? amount, required bool income}) {
    // Once is stored as yearly on its own day and month, which is how an
    // older build reads it.
    final onceDay = once ? onceDate : null;
    final onceKey = onceDay == null
        ? null
        : '${monthKey(onceDay)}-${onceDay.day.toString().padLeft(2, '0')}';
    // Quarterly and half-yearly keep the picked months' first one; monthly
    // stores the current month, unused.
    final anchor =
        onceDay?.month ??
        switch (repeats) {
          SubscriptionCycle.monthly => DateTime.now().month,
          // The picked month's place in its cycle, the rule the Due
          // month(s) dropdown shows.
          _ => (month - 1) % repeats.months + 1,
        };
    // Money expected in adds nothing for the user.
    final adds = autoAdd && !income;
    // The stamps a save gives it (addReminder, updateReminder), so the
    // summary line never names a due date the saved reminder skips.
    final todayKey =
        '${monthKey(today)}-${today.day.toString().padLeft(2, '0')}';
    return Reminder(
      id: existing?.id ?? '',
      name: nameCtrl.text.trim(),
      dayOfMonth: onceDay?.day ?? day,
      expectedAmount: amount,
      categoryId: selectedCategory,
      lastPaidMonth: existing?.lastPaidMonth,
      cycle: onceDay == null ? repeats : SubscriptionCycle.yearly,
      anchorMonth: anchor,
      autoAdd: adds,
      accountId: adds ? accountId : null,
      autoSince: adds
          ? (existing?.autoAdd == true ? existing!.autoSince : todayKey)
          : null,
      // An older saved reminder with no stamp keeps none: a save never
      // adds one.
      createdOn: existing == null ? todayKey : existing.createdOn,
      onDate: onceKey,
    );
  }

  void save(BuildContext ctx, Reminder d) {
    if (existing == null) {
      finance.addReminder(
        name: d.name,
        dayOfMonth: d.dayOfMonth,
        expectedAmount: d.expectedAmount,
        categoryId: d.categoryId,
        cycle: d.cycle,
        anchorMonth: d.anchorMonth,
        autoAdd: d.autoAdd,
        accountId: d.accountId,
        onDate: d.onDate,
      );
    } else {
      // The stored copy, not the one this sheet opened with: an import or a
      // resume may have marked it paid meanwhile, and saving must not undo
      // that.
      final current = finance.reminders.firstWhere(
        (x) => x.id == existing.id,
        orElse: () => existing,
      );
      // A new one-time date starts unpaid: a mark kept from the old date or
      // cycle would read as done the moment it saves.
      final freshOnce = d.onDate != null && d.onDate != current.onDate;
      finance.updateReminder(
        current.copyWith(
          name: d.name,
          dayOfMonth: d.dayOfMonth,
          expectedAmount: d.expectedAmount,
          clearExpectedAmount: d.expectedAmount == null,
          categoryId: d.categoryId,
          cycle: d.cycle,
          anchorMonth: d.anchorMonth,
          autoAdd: d.autoAdd,
          accountId: d.accountId,
          clearAccountId: d.accountId == null,
          onDate: d.onDate,
          clearOnDate: d.onDate == null,
          clearLastPaidMonth: freshOnce,
        ),
      );
    }
    Navigator.pop(ctx);
  }

  await showEditorSheet<void>(
    context,
    builder: (ctx) => DisposeScope(
      disposables: [nameCtrl, amountCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final theme = Theme.of(ctx);
          final scheme = theme.colorScheme;
          final amountText = amountCtrl.text.trim();
          final amount = amountText.isEmpty ? null : parseAmount(amountText);
          final amountBad =
              amountText.isNotEmpty && (amount == null || amount <= 0);
          // Money expected in: nothing to add for the user.
          final income =
              categoryById(
                    selectedCategory,
                    fallbackType: TxType.expense,
                  ).type ==
                  TxType.income &&
              !isTransferCategory(selectedCategory);
          // Adding the expense needs to know how much.
          final amountMissing = autoAdd && !income && amountText.isEmpty;
          final shownDate = onceDate;
          final nameMissing = nameCtrl.text.trim().isEmpty;
          // The amount's error and the date field's "Pick a date" already
          // say what is missing there; the footer only names what no field
          // shows, so no message is on screen twice.
          final reason = nameMissing ? 'Enter a name' : null;
          final canSave =
              !nameMissing &&
              !amountBad &&
              !amountMissing &&
              !(once && shownDate == null);
          final d = draft(amount: amountBad ? null : amount, income: income);
          // The footnote's full text, now the Repeats tip.
          final repeatsHelp = income
              ? 'Shows on the Next 7 days card a week ahead and adds to the '
                    'expected balance on the Ahead tab from the day after it '
                    'is due. Mark it paid from the Next 7 days card once it '
                    'arrives.'
              : autoAdd
              ? 'Shows on the Next 7 days card a week ahead, and records the '
                    'expense on the due day when you open the app or a '
                    'background import runs.'
              : 'Shows on the Next 7 days card a week ahead, and notifies '
                    'from 2 days before. Alerts are checked when the app '
                    'opens and about every 6 hours while it is closed. A bank '
                    'SMS for this amount near the due day marks it paid; '
                    'otherwise mark it paid from the Next 7 days card.';
          final paidFrom = accountId == null
              ? null
              : accounts.where((a) => a.id == accountId).firstOrNull;
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

          // Due day keeps its tip at its end: a dropdown has its own arrow.
          final dueDay = Row(
            children: [
              Expanded(
                child: AppDropdownField<int>(
                  key: const ValueKey('reminder-day'),
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
                    'Days 29 to 31 fall on the last day of shorter months.',
              ),
            ],
          );
          final dueMonths = repeats == SubscriptionCycle.monthly
              ? null
              : AppDropdownField<int>(
                  key: const ValueKey('reminder-months'),
                  label: repeats == SubscriptionCycle.yearly
                      ? 'Due month'
                      : 'Due months',
                  // Yearly lists 12 months, half-yearly 6 pairs and
                  // quarterly 3 groups, each by its first month.
                  value: (month - 1) % repeats.months + 1,
                  items: [
                    for (var m = 1; m <= repeats.months; m++)
                      PickerItem(value: m, label: cycleMonthsLabel(m, repeats)),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => month = v);
                  },
                );
          // Stacked at large text, where half a 320dp row holds a few
          // letters, and on a narrow phone, where half a row cuts "Jan,
          // Apr, Jul, Oct" even at normal text.
          final stacked =
              MediaQuery.textScalerOf(ctx).scale(1) > 1.3 ||
              MediaQuery.sizeOf(ctx).width < 360;

          return EditorSheetBody(
            title: existing == null ? 'New reminder' : 'Edit reminder',
            menu: existing != null && allowDelete
                ? [
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(
                        'Delete reminder',
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  ]
                : null,
            menuTooltip: 'Reminder actions',
            // The reminder then goes with Undo, once the sheet is closed.
            onMenu: (_) {
              deleteRequested = true;
              Navigator.pop(ctx);
            },
            footerLabel: existing == null ? 'Create' : 'Save',
            footerReason: reason,
            // Once with no date has no due day to sum up yet.
            footerExtra: once && shownDate == null
                ? null
                : Text(
                    reminderSummaryLine(d, DateTime.now()),
                    // Two: a date already passed this month adds a
                    // sentence about it.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
            onSave: canSave ? () => save(ctx, d) : null,
            dirty: fields() != opened,
            children: [
              TextField(
                key: const ValueKey('reminder-name'),
                controller: nameCtrl,
                autofocus: existing == null,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Money to home, EB bill',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('reminder-amount'),
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: autoAdd && !income
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
              // A label row of its own: the chips under it take their own
              // taps.
              InfoLabel(
                icon: true,
                label: Text('Repeats', style: theme.textTheme.labelLarge),
                tip: InfoTip(title: 'Repeats', message: repeatsHelp),
              ),
              const SizedBox(height: 8),
              // Chips, not segments: four segments in a sheet this narrow
              // each shrank their label to a different size.
              Wrap(
                key: const ValueKey('reminder-repeats'),
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
                // One button for a screen reader: the field's label, value
                // and icon would otherwise read as three parts.
                Semantics(
                  button: true,
                  label: 'Date, ${dateText(shownDate)}',
                  excludeSemantics: true,
                  onTap: pickDate,
                  child: InkWell(
                    key: const ValueKey('reminder-date'),
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
              else if (dueMonths == null)
                dueDay
              else if (stacked) ...[
                dueDay,
                const SizedBox(height: 16),
                dueMonths,
              ] else
                Row(
                  children: [
                    Expanded(child: dueDay),
                    const SizedBox(width: 8),
                    Expanded(child: dueMonths),
                  ],
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: AppDropdownField<String>(
                      key: const ValueKey('reminder-category'),
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
              if (!income) ...[
                const SizedBox(height: 16),
                // On a filled surface, as the other editors' folds.
                GroupedSurface(
                  first: true,
                  last: true,
                  child: DialogExpander(
                    key: const ValueKey('reminder-fold-auto'),
                    title: 'Add it for me',
                    value: autoAdd
                        ? 'On · from ${paidFrom?.displayName ?? 'No account'}'
                        : 'Off',
                    open: autoOpen,
                    keepClosed: false,
                    onToggle: () => setState(() => autoOpen = !autoOpen),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // A ListTile with a Switch, the shared switch row.
                          ListTile(
                            key: const ValueKey('reminder-auto'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Add it for me on the due day'),
                            subtitle: const Text(
                              'Adds the expense itself. Use it for cash or bills '
                              'with no bank SMS.',
                            ),
                            // Named so the switch is not announced as an
                            // unlabelled toggle.
                            trailing: Semantics(
                              label: 'Add it for me on the due day',
                              child: Switch(
                                value: autoAdd,
                                onChanged: (v) => setState(() => autoAdd = v),
                              ),
                            ),
                            onTap: () => setState(() => autoAdd = !autoAdd),
                          ),
                          if (autoAdd) ...[
                            const SizedBox(height: 8),
                            AppDropdownField<String>(
                              key: const ValueKey('reminder-account'),
                              label: 'Paid from',
                              value: accountId,
                              items: [
                                const PickerItem(
                                  value: null,
                                  label: 'No account',
                                ),
                                for (final a in accounts)
                                  PickerItem(value: a.id, label: a.displayName),
                              ],
                              onChanged: (v) => setState(() => accountId = v),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
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

/// Three plain actions for a manual reminder due on [due]: mark it paid (or,
/// for Add it for me, add it now), edit it, delete it. Opened from a row of
/// the dashboard's Next 7 days card and from a Due row of the heatmap's day
/// sheet. (showPickerSheet was rejected here: a list of actions, not
/// values.)
void showReminderActions(BuildContext context, Reminder r, DateTime due) {
  final finance = context.read<FinanceProvider>();
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      return SafeArea(
        // Scrolls: four rows outgrow a short screen at large text.
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(r.name, style: Theme.of(ctx).textTheme.titleMedium),
                subtitle: Text('Due ${fmtDate(due)}'),
              ),
              if (r.autoAdd)
                // It records its own expense: paying early means recording
                // it now, since marking it paid alone would leave it out.
                ListTile(
                  leading: const Icon(Icons.add_task),
                  title: const Text('Add it now'),
                  subtitle: const Text(
                    'Paid early: records it today, not on the due day',
                  ),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final messenger = ScaffoldMessenger.of(context);
                    final before = r;
                    final txId = await finance.addReminderPaymentNow(
                      r.id,
                      due,
                      DateTime.now(),
                    );
                    if (txId == null) return;
                    showAppToastOn(
                      messenger,
                      'Added ${r.name}',
                      tone: AppToastTone.success,
                      icon: Icons.add_task,
                      actionLabel: 'Undo',
                      onAction: () async {
                        await finance.deleteTransactions([txId]);
                        await finance.updateReminder(before);
                      },
                      duration: const Duration(seconds: 5),
                    );
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.check_circle_outline),
                  title: const Text('Mark paid'),
                  onTap: () {
                    Navigator.pop(ctx);
                    final before = r;
                    finance.markReminderPaid(r.id, due);
                    showUndoSnackBar(
                      context,
                      '${r.name} marked paid',
                      () => finance.updateReminder(before),
                      icon: Icons.task_alt,
                      tone: AppToastTone.success,
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  showReminderEditor(context, existing: r);
                },
              ),
              // Red on the icon and its word, on the sheet's plain surface.
              ListTile(
                leading: Icon(Icons.delete_outline, color: scheme.error),
                title: Text('Delete', style: TextStyle(color: scheme.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  deleteReminderWithUndo(context, r.id);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// The reminder editor's one-line summary above its button, for [draft]'s
/// next due date as of [now]: when it notifies ("Notifies from 2 days
/// before 5 Dec"), when Add it for me records it, or, for money expected
/// in, when Next 7 days starts showing it.
///
/// A new reminder ([draft] with no id) names the next occurrence on or after
/// today. Its createdOn stamp only rules out earlier months: an earlier day
/// of this month still reads as an unpaid occurrence inside the grace days
/// (made on 7 Nov, due on the 1st: 1 Nov). Read as paid here, the line names
/// 1 Dec instead, then says the saved reminder lists 1 Nov as overdue, as
/// the app will.
String reminderSummaryLine(Reminder draft, DateTime now) {
  var due = reminderNextDue(draft, now);
  final today = DateTime(now.year, now.month, now.day);
  DateTime? overdue;
  if (draft.id.isEmpty && due.isBefore(today)) {
    final passed = due;
    due = reminderNextDue(draft.copyWith(lastPaidMonth: monthKey(due)), now);
    if (due != passed) overdue = passed;
  }
  final then = overdue == null
      ? ''
      : '. ${fmtDateCompact(overdue)} shows as overdue until you mark it '
            'paid.';
  if (reminderIsIncome(draft)) {
    final shows = DateTime(due.year, due.month, due.day - 7);
    return 'Shows on Next 7 days from ${fmtDateCompact(shows)}$then';
  }
  if (draft.autoAdd) return 'Adds it for you on ${fmtDateCompact(due)}$then';
  return 'Notifies from ${UpcomingMonitor.reminderWindowDays} days before '
      '${fmtDateCompact(due)}$then';
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
