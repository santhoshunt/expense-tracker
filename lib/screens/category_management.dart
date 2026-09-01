import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/category_group.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/glossy.dart';
import '../widgets/section_header.dart';

/// Category & group management — the Categories tab in Classifiers.
///
/// Moved here from Settings: creating categories is classification work, so
/// it lives next to the rules that use them. Groups (Needs/Wants/…) are the
/// parent layer for spend analytics; every expense or transfer category can
/// belong to one.
/// Pads a picker swatch out to a 48dp tap target without growing its
/// visual — Material's minimum; the raw 32–40dp swatches were hard to hit.
Widget _pickerTarget(Widget child) =>
    SizedBox(width: 48, height: 48, child: Center(child: child));

class CategoriesTab extends StatefulWidget {
  const CategoriesTab({super.key});

  @override
  State<CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends State<CategoriesTab> {
  final _searchCtrl = TextEditingController();
  // No debounce — a few dozen categories, same reasoning as the Rules tab.
  String _search = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Label or parent-group match (the tile's subtitle shows the group, so
  /// "savings" finding grouped members reads naturally).
  bool _matches(FinanceProvider finance, TxCategory c, String q) {
    if (q.isEmpty) return true;
    if (c.label.toLowerCase().contains(q)) return true;
    final groupId = finance.groupIdOf(c.id);
    final group = groupId == null
        ? null
        : finance.groups.where((g) => g.id == groupId).firstOrNull;
    return group != null && group.label.toLowerCase().contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final q = _search.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final custom = [
      for (final c in customCategories)
        if (_matches(finance, c, q)) c,
    ];
    final builtIn = [
      for (final c in kCategories)
        // Match against the override-applied definition — a renamed
        // built-in must be findable by its current name.
        if (_matches(finance, categoryById(c.id), q)) c,
    ];
    final scheme = Theme.of(context).colorScheme;

    Widget header(String label) => UppercaseSectionHeader(
      label,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
      children: [
        Text('Groups', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Parent buckets for your spending (e.g. Needs, Wants, Leisure). '
          'Grouped spending shows on the dashboard; ungrouped categories '
          'appear under "Other".',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        FrostedPanel(
          radius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (finance.groups.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Text(
                      'No groups yet.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                for (final g in finance.groups)
                  ListTile(
                    dense: true,
                    onTap: () => _showGroupDialog(context, existing: g),
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: g.color.withValues(alpha: 0.15),
                      child: Icon(
                        Icons.workspaces_outlined,
                        color: categoryGlyphColor(context, g.color),
                        size: 18,
                      ),
                    ),
                    title: Text(g.label),
                    subtitle: Text(
                      _memberCountLabel(finance, g.id),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      tooltip: 'Delete group',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () => _confirmDeleteGroup(context, g),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                  child: TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Add group'),
                    onPressed: () => _showGroupDialog(context),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Categories', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Add your own income and expense categories (e.g. Home, Pets), '
          'or transfer categories (e.g. Chit) that move money without '
          'counting as income or spending. Built-in categories can be '
          'renamed, restyled and grouped, but not deleted.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        // Rebuild on every controller change so the ✕ appears with the
        // first keystroke (same idiom as the Rules tab search).
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchCtrl,
          builder: (context, value, _) => TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
            decoration: InputDecoration(
              hintText: 'Search categories and groups',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: value.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() => _search = '');
                      },
                    ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FrostedPanel(
          radius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (searching && custom.isEmpty && builtIn.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
                    child: Text(
                      'Nothing matches your search.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                if (!searching || custom.isNotEmpty) header('Your categories'),
                if (custom.isEmpty && !searching)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                    child: Text(
                      'No custom categories yet.',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                for (final c in custom)
                  _categoryTile(
                    context,
                    finance,
                    c,
                    onTap: () => showCategoryDialog(context, existing: c),
                    onDelete: () => _confirmDeleteCategory(context, c),
                  ),
                if (!searching)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                    child: TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add category'),
                      onPressed: () => showCategoryDialog(context),
                    ),
                  ),
                if (builtIn.any((c) => c.id != kSpamCategoryId))
                  header('Built-in'),
                for (final c in builtIn)
                  if (c.id != kSpamCategoryId)
                    _categoryTile(
                      context,
                      finance,
                      // Show the override, not the pristine definition.
                      categoryById(c.id),
                      onTap: () => showCategoryDialog(
                        context,
                        existing: categoryById(c.id),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _memberCountLabel(FinanceProvider finance, String groupId) {
    var n = 0;
    for (final c in allCategories) {
      if (finance.groupIdOf(c.id) == groupId) n++;
    }
    return n == 1 ? '1 category' : '$n categories';
  }

  Widget _categoryTile(
    BuildContext context,
    FinanceProvider finance,
    TxCategory c, {
    VoidCallback? onTap,
    VoidCallback? onDelete,
  }) {
    final groupId = finance.groupIdOf(c.id);
    final group = groupId == null
        ? null
        : finance.groups.where((g) => g.id == groupId).firstOrNull;
    final kind = c.isTransfer
        ? (c.type == TxType.income
              ? 'Transfer · money in'
              : 'Transfer · money out')
        : (c.type == TxType.income ? 'Income' : 'Expense');
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: CircleAvatar(
        radius: 16,
        backgroundColor: c.color.withValues(alpha: 0.15),
        child: Icon(
          c.icon,
          color: categoryGlyphColor(context, c.color),
          size: 18,
        ),
      ),
      title: Text(c.label),
      subtitle: Text(
        group == null ? kind : '$kind · ${group.label}',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: onDelete == null
          ? null
          : IconButton(
              tooltip: 'Delete category',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: onDelete,
            ),
    );
  }

  // ── Groups ────────────────────────────────────────────────────────────────

  Future<void> _confirmDeleteGroup(
    BuildContext context,
    CategoryGroup g,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${g.label}"?'),
        content: const Text(
          'Categories in this group become ungrouped (shown under "Other"). '
          'Budgets are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<FinanceProvider>().deleteGroup(g.id);
    }
  }

  Future<void> _showGroupDialog(
    BuildContext context, {
    CategoryGroup? existing,
  }) async {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    var color = existing?.color ?? kCategoryColorChoices.first;

    await showDialog(
      context: context,
      builder: (ctx) => DisposeScope(
        disposables: [labelCtrl],
        child: StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(existing == null ? 'New group' : 'Edit group'),
            content: SingleChildScrollView(
              // Keeps the floating "Name" label from clipping at the top.
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: labelCtrl,
                    autofocus: existing == null,
                    textCapitalization: TextCapitalization.sentences,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'e.g. Leisure',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Colour', style: Theme.of(ctx).textTheme.labelMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final (i, choice) in kCategoryColorChoices.indexed)
                        Semantics(
                          button: true,
                          selected: choice == color,
                          label: 'Colour ${i + 1}',
                          excludeSemantics: true,
                          child: _pickerTarget(
                            InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => setState(() => color = choice),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: choice,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: choice == color
                                        ? Theme.of(ctx).colorScheme.onSurface
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: choice == color
                                    ? Icon(
                                        Icons.check,
                                        size: 16,
                                        color: onSwatch(choice),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              // Disabled while the name is empty instead of a silent no-op.
              FilledButton(
                onPressed: labelCtrl.text.trim().isEmpty
                    ? null
                    : () {
                        final label = labelCtrl.text.trim();
                        final finance = ctx.read<FinanceProvider>();
                        if (existing == null) {
                          finance.addGroup(label: label, color: color);
                        } else {
                          finance.updateGroup(
                            CategoryGroup(
                              id: existing.id,
                              label: label,
                              color: color,
                            ),
                          );
                        }
                        Navigator.pop(ctx);
                      },
                child: Text(existing == null ? 'Create' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Categories ────────────────────────────────────────────────────────────

  Future<void> _confirmDeleteCategory(
    BuildContext context,
    TxCategory c,
  ) async {
    // Same-direction destinations only, so rows keep their type. "Other"
    // (the historical hard-coded target) leads as the default.
    final fallbackId = c.type == TxType.expense
        ? 'other_expense'
        : 'other_income';
    final targets = [
      categoryById(fallbackId),
      for (final t in allCategories)
        if (t.type == c.type && t.id != c.id && t.id != fallbackId) t,
    ];
    var moveTo = fallbackId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          // Like every sibling dialog: landscape + large text overflow a
          // fixed column.
          scrollable: true,
          title: Text('Delete "${c.label}"?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Its transactions move to the category below; rules '
                'targeting it are removed.',
              ),
              const SizedBox(height: 16),
              AppDropdownField<String>(
                label: 'Move transactions to',
                items: [
                  for (final t in targets)
                    PickerItem(
                      value: t.id,
                      label: t.isTransfer ? '${t.label} · transfer' : t.label,
                      leading: Icon(t.icon, color: t.color, size: 20),
                    ),
                ],
                value: moveTo,
                onChanged: (v) => setState(() => moveTo = v ?? fallbackId),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<FinanceProvider>().deleteCategory(
        c.id,
        moveTo: moveTo,
      );
    }
  }
}

/// Add/edit dialog for categories, including the parent-group picker.
/// Public so the Classifiers FAB can open it.
///
/// Built-in categories are fully editable too — name, icon, colour,
/// direction and transfer-ness — except the two fallback "Other"
/// categories, whose direction is structural (they are the app's remap
/// targets). A direction change re-types the category's transactions.
Future<void> showCategoryDialog(
  BuildContext context, {
  TxCategory? existing,
}) async {
  final finance = context.read<FinanceProvider>();
  final isBuiltIn = existing != null && finance.isBuiltinCategory(existing.id);
  final isFallback =
      existing != null && FinanceProvider.isFallbackCategory(existing.id);
  final labelCtrl = TextEditingController(text: existing?.label ?? '');
  var type = existing?.type ?? TxType.expense;
  var isTransfer = existing?.isTransfer ?? false;
  var icon = existing?.icon ?? Icons.home;
  var color = existing?.color ?? kCategoryColorChoices.first;
  String? groupId = existing == null ? null : finance.groupIdOf(existing.id);
  // Re-entrancy latch: the build-time duplicate check can't stop a
  // double-tap (both presses see the pre-add state), and Create awaits the
  // writes before popping — a second tap minted a duplicate category.
  var saving = false;

  await showDialog(
    context: context,
    builder: (ctx) => DisposeScope(
      disposables: [labelCtrl],
      child: StatefulBuilder(
        builder: (ctx, setState) {
          // Live groupability: flipping to plain income hides the group row.
          final groupable = type == TxType.expense || isTransfer;
          return AlertDialog(
            title: Text(existing == null ? 'New category' : 'Edit category'),
            content: SingleChildScrollView(
              // Top padding so the field's floating "Name" label isn't
              // clipped by the scroll viewport's edge.
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Builder(
                    builder: (ctx) {
                      // Two categories named "Home" are indistinguishable in
                      // every dropdown — reject the duplicate up front.
                      final name = labelCtrl.text.trim().toLowerCase();
                      final duplicate =
                          name.isNotEmpty &&
                          allCategories.any(
                            (c) =>
                                c.id != existing?.id &&
                                c.label.trim().toLowerCase() == name,
                          );
                      return TextField(
                        controller: labelCtrl,
                        autofocus: existing == null,
                        textCapitalization: TextCapitalization.sentences,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: 'Name',
                          hintText: 'e.g. Home',
                          errorText: duplicate
                              ? 'A category with this name already exists'
                              : null,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // Direction and transfer-ness are editable for everything
                  // except the fallback "Other" categories — those are the
                  // app's hard-coded remap targets.
                  if (isFallback)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Direction is fixed for the fallback "Other" '
                        'categories.',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                  if (!isFallback) ...[
                    // No selected checkmark and single-line scale-down labels:
                    // "Money out" + icon + check wrapped in the narrow dialog.
                    SegmentedButton<TxType>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: TxType.expense,
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              isTransfer ? 'Money out' : 'Expense',
                              maxLines: 1,
                            ),
                          ),
                          icon: const Icon(Icons.arrow_upward, size: 16),
                        ),
                        ButtonSegment(
                          value: TxType.income,
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              isTransfer ? 'Money in' : 'Income',
                              maxLines: 1,
                            ),
                          ),
                          icon: const Icon(Icons.arrow_downward, size: 16),
                        ),
                      ],
                      selected: {type},
                      onSelectionChanged: (s) => setState(() => type = s.first),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Transfer'),
                      subtitle: Text(
                        'Affects account balance only — not counted as income '
                        'or expense (like "To savings" or "Card bill").',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                      value: isTransfer,
                      onChanged: (v) => setState(() => isTransfer = v),
                    ),
                  ],
                  if (groupable && finance.groups.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    AppDropdownField<String>(
                      label: 'Group',
                      value: groupId,
                      items: [
                        const PickerItem(value: null, label: 'None (Other)'),
                        for (final g in finance.groups)
                          PickerItem(
                            value: g.id,
                            label: g.label,
                            leading: Icon(
                              Icons.workspaces_outlined,
                              size: 18,
                              color: g.color,
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => groupId = v),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 4),
                  Text('Icon', style: Theme.of(ctx).textTheme.labelMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final entry in kCategoryIconChoices.entries)
                        Semantics(
                          button: true,
                          selected: entry.value == icon,
                          label: entry.key,
                          excludeSemantics: true,
                          child: _pickerTarget(
                            InkWell(
                              borderRadius: BorderRadius.circular(
                                AppRadius.control,
                              ),
                              onTap: () => setState(() => icon = entry.value),
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: entry.value == icon
                                      ? color.withValues(alpha: 0.25)
                                      : Theme.of(
                                          ctx,
                                        ).colorScheme.surfaceContainerHigh,
                                  borderRadius: BorderRadius.circular(
                                    AppRadius.control,
                                  ),
                                  border: entry.value == icon
                                      ? Border.all(color: color, width: 2)
                                      : null,
                                ),
                                child: Icon(
                                  entry.value,
                                  size: 20,
                                  color: entry.value == icon
                                      ? color
                                      : Theme.of(
                                          ctx,
                                        ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('Colour', style: Theme.of(ctx).textTheme.labelMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final (i, choice) in kCategoryColorChoices.indexed)
                        Semantics(
                          button: true,
                          selected: choice == color,
                          label: 'Colour ${i + 1}',
                          excludeSemantics: true,
                          child: _pickerTarget(
                            InkWell(
                              customBorder: const CircleBorder(),
                              onTap: () => setState(() => color = choice),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: choice,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: choice == color
                                        ? Theme.of(ctx).colorScheme.onSurface
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: choice == color
                                    ? Icon(
                                        Icons.check,
                                        size: 16,
                                        color: onSwatch(choice),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              if (isBuiltIn && finance.isBuiltinOverridden(existing.id))
                // Reset restores the original definition INCLUDING direction —
                // the provider re-types this category's transactions to match
                // and drops the category from its group and any budgets. One
                // tap next to Cancel used to do all that unasked: confirm it.
                TextButton(
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (dCtx) => AlertDialog(
                        title: Text('Reset "${existing.label}"?'),
                        content: const Text(
                          'The built-in name, icon, colour and direction '
                          'come back. If you changed its direction, its '
                          'transactions switch back too, and the category '
                          'is removed from its group and any budgets.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dCtx, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(dCtx, true),
                            child: const Text('Reset'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true || !ctx.mounted) return;
                    Navigator.pop(ctx);
                    await finance.resetBuiltinCategory(existing.id);
                  },
                  child: const Text('Reset'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              // Disabled while the name is empty or duplicate instead of a
              // silent no-op, and while a save is already in flight.
              FilledButton(
                onPressed:
                    saving ||
                        labelCtrl.text.trim().isEmpty ||
                        allCategories.any(
                          (c) =>
                              c.id != existing?.id &&
                              c.label.trim().toLowerCase() ==
                                  labelCtrl.text.trim().toLowerCase(),
                        )
                    ? null
                    : () async {
                        setState(() => saving = true);
                        final label = labelCtrl.text.trim();
                        // Await the saves BEFORE popping: a failure used to close
                        // the dialog anyway and vanish without a message.
                        final navigator = Navigator.of(ctx);
                        final messenger = ScaffoldMessenger.of(context);
                        try {
                          final effectiveGroupable =
                              type == TxType.expense || isTransfer;
                          final chosenGroup = effectiveGroupable
                              ? groupId
                              : null;
                          if (existing == null) {
                            final id = await finance.addCategory(
                              label: label,
                              type: type,
                              icon: icon,
                              color: color,
                              isTransfer: isTransfer,
                            );
                            if (chosenGroup != null) {
                              await finance.assignCategoryToGroup(
                                id,
                                chosenGroup,
                              );
                            }
                          } else if (isBuiltIn) {
                            await finance.overrideBuiltinCategory(
                              id: existing.id,
                              label: label,
                              icon: icon,
                              color: color,
                              type: type,
                              isTransfer: isTransfer,
                            );
                            if (effectiveGroupable) {
                              await finance.assignCategoryToGroup(
                                existing.id,
                                chosenGroup,
                              );
                            }
                          } else {
                            await finance.updateCategory(
                              TxCategory(
                                id: existing.id,
                                label: label,
                                type: type,
                                icon: icon,
                                color: color,
                                isTransfer: isTransfer,
                              ),
                            );
                            // updateCategory already detaches non-groupable ids.
                            if (effectiveGroupable) {
                              await finance.assignCategoryToGroup(
                                existing.id,
                                chosenGroup,
                              );
                            }
                          }
                          navigator.pop();
                        } catch (e) {
                          setState(() => saving = false);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text('Could not save category: $e'),
                            ),
                          );
                        }
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
