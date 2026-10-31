import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/dates.dart';
import '../utils/format.dart';
import 'category_chip_label.dart';
import 'dialog_expander.dart';
import 'dispose_scope.dart';
import 'icon_picker_sheet.dart';
import 'info_tip.dart';
import 'undo_snackbar.dart';

/// Create/edit dialog for a [SpendBudget]. Shared by the Cockpit's Budgets
/// tab and the dashboard's category rows, which open it pre-filled for one
/// category via the `preset*` parameters (ignored when [existing] is given).
///
/// [allowDelete] adds Delete when editing, which removes the budget with
/// Undo. Only the Cockpit list passes it: opened from a sheet, a delete
/// would leave the sheet showing a removed budget.
Future<void> showBudgetDialog(
  BuildContext context, {
  SpendBudget? existing,
  String? presetName,
  BudgetMode? presetMode,
  Set<String>? presetCategoryIds,
  bool allowDelete = false,
}) async {
  final finance = context.read<FinanceProvider>();
  final nameCtrl = TextEditingController(
    text: existing?.name ?? presetName ?? '',
  );
  final limitCtrl = TextEditingController(
    // Paise kept: a rounded figure would be saved back rounded.
    text: existing == null ? '' : fmtFieldNumber(existing.limit),
  );
  var mode = existing?.mode ?? presetMode ?? BudgetMode.exclude;
  final selected = {
    ...?existing?.categoryIds,
    if (existing == null) ...?presetCategoryIds,
  };
  // The picked icon's key, or null for Automatic.
  var iconKey = existing?.iconKey;
  // A tag budget counts every row with [tag], in any category; [range]
  // turns its monthly limit into one total for those days.
  var tag = existing?.tag;
  var range = existing?.range;
  var advancedOpen = existing?.range != null;
  final tags = finance.allTags;
  // A stored tag no row carries yet has no chip, so it shows in the field.
  final newTagCtrl = TextEditingController(
    text: tag != null && !tags.any((u) => tagKey(u.tag) == tagKey(tag!))
        ? tag
        : '',
  );
  // Delete pops the editor first; the budget then goes with Undo.
  var deleteRequested = false;

  // Groupable categories bucketed by parent group ("Other" last), so the
  // picker mirrors the dashboard's grouping. To sort is no budget's: it
  // holds payments waiting for their category.
  bool offered(TxCategory c) =>
      finance.isGroupable(c) && !isToSortCategory(c.id);
  final sections = <(String, List<TxCategory>)>[];
  for (final g in finance.groups) {
    final members = [
      for (final c in allCategories)
        if (offered(c) && finance.groupIdOf(c.id) == g.id) c,
    ];
    if (members.isNotEmpty) sections.add((g.label, members));
  }
  final ungrouped = [
    for (final c in allCategories)
      if (offered(c) && finance.groupIdOf(c.id) == null) c,
  ];
  if (ungrouped.isNotEmpty) sections.add(('Other', ungrouped));

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [nameCtrl, limitCtrl, newTagCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final limit = parseAmount(limitCtrl.text);
          // An include budget with nothing picked is 0 forever; an exclude
          // budget with nothing picked is simply "all spending" — valid.
          final valid =
              nameCtrl.text.trim().isNotEmpty &&
              limit != null &&
              limit > 0 &&
              (mode == BudgetMode.exclude ||
                  selected.isNotEmpty ||
                  tag != null);
          // What the icon button shows: the picked icon, else what
          // Automatic gives for the current mode and picks.
          final automaticIcon = budgetIcon(
            SpendBudget(
              id: '',
              name: '',
              limit: 0,
              mode: mode,
              categoryIds: selected,
              tag: tag,
            ),
          );
          final scheme = Theme.of(ctx).colorScheme;
          // Picking a category clears the tag: a budget counts one or the
          // other.
          void clearTag() {
            tag = null;
            newTagCtrl.clear();
          }

          Future<void> pickFrom() async {
            final r = range;
            if (r == null) return;
            final today = DateTime.now();
            final picked = await showDatePicker(
              context: ctx,
              initialDate: r.start,
              firstDate: DateTime(2000),
              lastDate: DateTime(today.year + 5, today.month, today.day),
            );
            if (picked == null) return;
            final start = DateTime(picked.year, picked.month, picked.day);
            var end = r.end;
            if (end.isBefore(start) ||
                end.isAfter(start.add(const Duration(days: 91)))) {
              end = start;
            }
            setState(() => range = DateTimeRange(start: start, end: end));
          }

          Future<void> pickTo() async {
            final r = range;
            if (r == null) return;
            final picked = await showDatePicker(
              context: ctx,
              initialDate: r.end,
              firstDate: r.start,
              lastDate: r.start.add(const Duration(days: 91)),
            );
            if (picked == null) return;
            setState(
              () => range = DateTimeRange(
                start: r.start,
                end: DateTime(picked.year, picked.month, picked.day),
              ),
            );
          }

          Widget dateField(String label, DateTime day, VoidCallback onTap) =>
              InkWell(
                borderRadius: BorderRadius.circular(AppRadius.control),
                onTap: onTap,
                child: InputDecorator(
                  decoration: InputDecoration(labelText: label),
                  // Shrinks rather than clips: the year stays in view on
                  // a narrow phone.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(fmtDate(day), maxLines: 1),
                  ),
                ),
              );
          Future<void> pickIcon() async {
            final picked = await showIconPickerSheet(
              ctx,
              selected: iconKey,
              automaticIcon: automaticIcon,
            );
            if (picked == null) return;
            setState(() => iconKey = picked.isEmpty ? null : picked);
          }

          return AlertDialog(
            title: Text(existing == null ? 'New budget' : 'Edit budget'),
            content: SingleChildScrollView(
              // Keeps the floating "Name" label from clipping at the top.
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      // The whole 48dp square takes the tap, not only the
                      // 40dp tile drawn in it.
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: Semantics(
                          button: true,
                          label: 'Budget icon',
                          // excludeSemantics drops the InkWell's own tap
                          // action too, so it is exposed here.
                          onTap: pickIcon,
                          excludeSemantics: true,
                          child: Tooltip(
                            message: 'Budget icon',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(
                                AppRadius.control,
                              ),
                              onTap: pickIcon,
                              child: Center(
                                child: Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: scheme.primary.withValues(
                                      alpha: 0.15,
                                    ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.control,
                                    ),
                                  ),
                                  child: Icon(
                                    kCategoryIconChoices[iconKey] ??
                                        automaticIcon,
                                    size: 21,
                                    color: categoryGlyphColor(
                                      ctx,
                                      scheme.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: nameCtrl,
                          // A preset name is already filled in; the limit is
                          // the field that still needs typing.
                          autofocus: existing == null && presetName == null,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            labelText: 'Name',
                            hintText: 'e.g. Personal spending',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: limitCtrl,
                    autofocus: existing == null && presetName != null,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: tag != null && range != null
                          ? 'Limit'
                          : 'Monthly limit',
                      prefixText: '₹ ',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  SegmentedButton<BudgetMode>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: BudgetMode.include,
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('Only these', maxLines: 1),
                        ),
                      ),
                      ButtonSegment(
                        value: BudgetMode.exclude,
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('All except', maxLines: 1),
                        ),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => setState(() {
                      mode = s.first;
                      if (mode == BudgetMode.exclude) clearTag();
                    }),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          mode == BudgetMode.include
                              ? tag == null
                                    ? 'Count rows that have any of the picks '
                                          'below.'
                                    : 'Every row tagged "$tag" counts, in any '
                                          'category, money-out transfers too.'
                              : 'All spending counts except the picked '
                                    'categories. Transfers never count.',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                      const InfoTip(
                        title: 'Only these or All except',
                        message:
                            'Only these: counts spending in the picked '
                            'categories, including money-out transfers you '
                            'pick. All except: counts all spending except the '
                            'picked categories, and transfers never count. '
                            'Pending imports never count. A tag counts every '
                            'row carrying it, in any category. Picking a tag '
                            'clears the categories, and picking a category '
                            'clears the tag.',
                      ),
                    ],
                  ),
                  if (mode == BudgetMode.include) ...[
                    const SizedBox(height: 12),
                    Text('Tags', style: Theme.of(ctx).textTheme.labelMedium),
                    const SizedBox(height: 8),
                    if (tags.isNotEmpty) ...[
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final u in tags)
                            FilterChip(
                              avatar: Icon(
                                Icons.sell,
                                size: 16,
                                color: categoryGlyphColor(
                                  ctx,
                                  finance.tagColor(u.tag) ??
                                      scheme.onSurfaceVariant,
                                ),
                              ),
                              label: Text(u.tag),
                              selected:
                                  tag != null && tagKey(tag!) == tagKey(u.tag),
                              onSelected: (v) => setState(() {
                                tag = v ? u.tag : null;
                                newTagCtrl.clear();
                                if (v) selected.clear();
                              }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: newTagCtrl,
                      maxLength: kMaxTagLength,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'New tag',
                        hintText: 'For a trip not tagged yet',
                        counterText: '',
                        prefixIcon: Icon(Icons.sell_outlined),
                      ),
                      onChanged: (v) => setState(() {
                        tag = normalizeTags([v]).firstOrNull;
                        if (tag != null) selected.clear();
                      }),
                    ),
                  ],
                  for (final (label, cats) in sections) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            label,
                            style: Theme.of(ctx).textTheme.labelMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() {
                            final ids = cats.map((c) => c.id).toSet();
                            if (selected.containsAll(ids)) {
                              selected.removeAll(ids);
                            } else {
                              selected.addAll(ids);
                              clearTag();
                            }
                          }),
                          child: Text(
                            selected.containsAll(cats.map((c) => c.id))
                                ? 'None'
                                : 'All',
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final c in cats)
                          FilterChip(
                            label: categoryChipLabel(c),
                            selected: selected.contains(c.id),
                            onSelected: (v) => setState(() {
                              if (v) {
                                selected.add(c.id);
                                clearTag();
                              } else {
                                selected.remove(c.id);
                              }
                            }),
                          ),
                      ],
                    ),
                  ],
                  if (mode == BudgetMode.include && tag != null) ...[
                    const Divider(height: 24),
                    DialogExpander(
                      title: 'Advanced',
                      open: advancedOpen,
                      onToggle: () =>
                          setState(() => advancedOpen = !advancedOpen),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Only between these dates'),
                            value: range != null,
                            onChanged: (on) => setState(() {
                              if (!on) {
                                range = null;
                                return;
                              }
                              final now = DateTime.now();
                              final today = DateTime(
                                now.year,
                                now.month,
                                now.day,
                              );
                              range = DateTimeRange(
                                start: today,
                                end: DateTime(
                                  today.year,
                                  today.month,
                                  today.day + 6,
                                ),
                              );
                            }),
                          ),
                          if (range case final r?) ...[
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: dateField('From', r.start, pickFrom),
                                ),
                                const SizedBox(width: 12),
                                Expanded(child: dateField('To', r.end, pickTo)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              daysCovered(r.start, r.end) == 1
                                  ? 'Limit is one total for this day, not '
                                        'monthly.'
                                  : 'Limit is one total for these '
                                        '${daysCovered(r.start, r.end)} '
                                        'days, not monthly.',
                              style: Theme.of(ctx).textTheme.bodySmall
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
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
                        if (existing == null) {
                          finance.addBudget(
                            name: nameCtrl.text.trim(),
                            limit: limit,
                            mode: mode,
                            categoryIds: tag == null ? {...selected} : const {},
                            iconKey: iconKey,
                            tag: tag,
                            range: tag == null ? null : range,
                          );
                        } else {
                          finance.updateBudget(
                            existing.copyWith(
                              name: nameCtrl.text.trim(),
                              limit: limit,
                              mode: mode,
                              categoryIds: tag == null
                                  ? {...selected}
                                  : const {},
                              iconKey: iconKey,
                              clearIconKey: iconKey == null,
                              tag: tag,
                              clearTag: tag == null,
                              range: range,
                              clearRange: tag == null || range == null,
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
    // The delete reads the alert marker across an await, so the Undo waits
    // on the same future for what it captured.
    final pending = finance.deleteBudget(existing.id);
    showUndoSnackBar(
      context,
      'Deleted budget "${existing.name}"',
      () async {
        final removed = await pending;
        if (removed != null) await finance.restoreBudget(removed);
      },
      icon: Icons.delete_outline,
      tone: AppToastTone.removal,
    );
  }
}
