import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/spend_budget.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/format.dart';
import 'category_chip_label.dart';
import 'dispose_scope.dart';

/// Create/edit dialog for a [SpendBudget]. Shared by Settings ("Custom
/// budgets") and the dashboard's category rows, which open it pre-filled
/// for one category via the `preset*` parameters (ignored when [existing]
/// is given).
Future<void> showBudgetDialog(
  BuildContext context, {
  SpendBudget? existing,
  String? presetName,
  BudgetMode? presetMode,
  Set<String>? presetCategoryIds,
}) async {
  final finance = context.read<FinanceProvider>();
  final nameCtrl = TextEditingController(
    text: existing?.name ?? presetName ?? '',
  );
  final limitCtrl = TextEditingController(
    text: existing == null ? '' : existing.limit.toStringAsFixed(0),
  );
  var mode = existing?.mode ?? presetMode ?? BudgetMode.exclude;
  final selected = {
    ...?existing?.categoryIds,
    if (existing == null) ...?presetCategoryIds,
  };

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
          return AlertDialog(
            title: Text(existing == null ? 'New budget' : 'Edit budget'),
            content: SingleChildScrollView(
              // Keeps the floating "Name" label from clipping at the top.
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: nameCtrl,
                    // A preset name is already filled in; the limit is the
                    // field that still needs typing.
                    autofocus: existing == null && presetName == null,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Personal spending',
                    ),
                    onChanged: (_) => setState(() {}),
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
                  Text(
                    mode == BudgetMode.include
                        ? 'Only spending in the picked categories counts '
                              'toward this budget.'
                        : 'All spending counts except the picked '
                              'categories. Transfers never count.',
                    style: Theme.of(ctx).textTheme.bodySmall,
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
                          );
                        } else {
                          finance.updateBudget(
                            existing.copyWith(
                              name: nameCtrl.text.trim(),
                              limit: limit,
                              mode: mode,
                              categoryIds: {...selected},
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
