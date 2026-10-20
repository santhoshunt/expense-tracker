import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/format.dart';
import 'category_chip_label.dart';
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
  // Delete pops the editor first; the budget then goes with Undo.
  var deleteRequested = false;

  // Groupable categories bucketed by parent group ("Other" last), so the
  // picker mirrors the dashboard's grouping.
  final sections = <(String, List<TxCategory>)>[];
  for (final g in finance.groups) {
    final members = [
      for (final c in allCategories)
        if (finance.isGroupable(c) && finance.groupIdOf(c.id) == g.id) c,
    ];
    if (members.isNotEmpty) sections.add((g.label, members));
  }
  final ungrouped = [
    for (final c in allCategories)
      if (finance.isGroupable(c) && finance.groupIdOf(c.id) == null) c,
  ];
  if (ungrouped.isNotEmpty) sections.add(('Other', ungrouped));

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [nameCtrl, limitCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          final limit = parseAmount(limitCtrl.text);
          // An include budget with nothing picked is 0 forever; an exclude
          // budget with nothing picked is simply "all spending" — valid.
          final valid =
              nameCtrl.text.trim().isNotEmpty &&
              limit != null &&
              limit > 0 &&
              (mode == BudgetMode.exclude || selected.isNotEmpty);
          // What the icon button shows: the picked icon, else what
          // Automatic gives for the current mode and picks.
          final automaticIcon = budgetIcon(
            SpendBudget(
              id: '',
              name: '',
              limit: 0,
              mode: mode,
              categoryIds: selected,
            ),
          );
          final scheme = Theme.of(ctx).colorScheme;
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
                    decoration: const InputDecoration(
                      labelText: 'Monthly limit',
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
                    onSelectionChanged: (s) => setState(() => mode = s.first),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          mode == BudgetMode.include
                              ? 'Only spending in the picked categories '
                                    'counts toward this budget.'
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
                            'Pending imports never count.',
                      ),
                    ],
                  ),
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
                              } else {
                                selected.remove(c.id);
                              }
                            }),
                          ),
                      ],
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
                            categoryIds: {...selected},
                            iconKey: iconKey,
                          );
                        } else {
                          finance.updateBudget(
                            existing.copyWith(
                              name: nameCtrl.text.trim(),
                              limit: limit,
                              mode: mode,
                              categoryIds: {...selected},
                              iconKey: iconKey,
                              clearIconKey: iconKey == null,
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
