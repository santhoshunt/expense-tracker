import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/category_group.dart';
import '../models/transaction.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/text_scale.dart';
import '../widgets/dialog_expander.dart';
import '../widgets/hue_color_picker.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/dispose_scope.dart';
import '../widgets/row_chevron.dart';
import '../widgets/glossy.dart';
import '../widgets/info_tip.dart';
import '../widgets/section_header.dart';
import '../widgets/undo_snackbar.dart';

/// Category and group management: the Categories tab beside the Rules, and
/// the Groups tab beside Tags, in the Cockpit.
///
/// Moved here from Settings: creating categories is classification work, so
/// it lives next to the rules that use them. Groups (Needs/Wants/…) are the
/// parent layer for spend analytics; every expense or transfer category can
/// belong to one.
///
/// Rows open their editor on tap; Delete lives in the editor, with Undo.
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

  /// Label match only; the tile's subtitle still shows the group.
  bool _matches(TxCategory c, String q) =>
      q.isEmpty || c.label.toLowerCase().contains(q);

  /// Picks the category order of the add and edit sheets.
  Future<void> _pickOrder(CategoryOrder order) async {
    final picked = await showPickerSheet<CategoryOrder>(
      context: context,
      title: 'Order in add sheets',
      subtitle:
          'Sets the order of the category list when you add or edit a '
          'transaction. The first category in the list is picked by default '
          'for a new transaction. Most used ranks by the amounts of the last '
          'three months.',
      items: const [
        PickerItem(value: CategoryOrder.mostUsed, label: 'Most used first'),
        PickerItem(value: CategoryOrder.alphabetical, label: 'A to Z'),
      ],
      selected: order,
    );
    final v = picked?.value;
    if (v == null || !mounted) return;
    await context.read<SettingsProvider>().setCategoryOrder(v);
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final order = context.select<SettingsProvider, CategoryOrder>(
      (s) => s.categoryOrder,
    );
    final q = _search.trim().toLowerCase();
    final searching = q.isNotEmpty;
    final custom = [
      for (final c in customCategories)
        if (_matches(c, q)) c,
    ];
    final builtIn = [
      for (final c in kCategories)
        // Match against the override-applied definition: a renamed
        // built-in must be findable by its current name.
        if (_matches(categoryById(c.id), q)) c,
    ];
    final scheme = Theme.of(context).colorScheme;
    final large = isLargeTextScale(context);

    Widget header(String label) => UppercaseSectionHeader(
      label,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        // The order the add sheets list categories in, set beside the
        // categories themselves.
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
          child: ListTile(
            leading: large ? null : const Icon(Icons.swap_vert),
            title: const Text('Order in add sheets'),
            subtitle: Text(
              order == CategoryOrder.mostUsed ? 'Most used first' : 'A to Z',
            ),
            trailing: rowChevron(context),
            onTap: () => _pickOrder(order),
          ),
        ),
        const SizedBox(height: 16),
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
              hintText: 'Search categories',
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
          radius: BorderRadius.circular(AppRadius.card),
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
                // The tab's 'New category' button is the add flow.
                for (final c in custom)
                  _categoryTile(
                    context,
                    finance,
                    c,
                    onTap: () => showCategoryDialog(context, existing: c),
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

  Widget _categoryTile(
    BuildContext context,
    FinanceProvider finance,
    TxCategory c, {
    VoidCallback? onTap,
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
      // Tap edits, and a custom category's Delete lives in the editor.
      trailing: rowChevron(context),
    );
  }
}

/// "3 categories": how many categories [groupId] holds.
String _memberCountLabel(FinanceProvider finance, String groupId) {
  var n = 0;
  for (final c in allCategories) {
    if (finance.groupIdOf(c.id) == groupId) n++;
  }
  return n == 1 ? '1 category' : '$n categories';
}

/// The Groups tab: the parent buckets (Needs, Wants, …) the dashboard's By
/// group card adds up. Adding goes through the tab's 'New group' button.
class GroupsTab extends StatelessWidget {
  const GroupsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      children: [
        // Left-aligned: stretched across the list, the whole row would open
        // the tip.
        Align(
          alignment: Alignment.centerLeft,
          child: InfoLabel(
            label: Text(
              'Groups',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            tip: const InfoTip(
              title: 'Groups',
              message:
                  "Groups add up their categories' spending on the "
                  "dashboard's By group card, including money-out transfers "
                  'in those categories. Only expense and transfer categories '
                  'can join a group. Budgets do not depend on groups.',
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Parent buckets for your spending (e.g. Needs, Wants, Leisure). '
          'Grouped spending shows on the dashboard; ungrouped categories '
          'appear under "Other".',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
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
                    onTap: () => showGroupDialog(context, existing: g),
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
                    trailing: rowChevron(context),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Groups ──────────────────────────────────────────────────────────────────

/// The New group and Edit group dialog. Public so the Cockpit's add button
/// can open it. Editing offers Delete, which removes the group at once with
/// Undo.
Future<void> showGroupDialog(
  BuildContext context, {
  CategoryGroup? existing,
}) async {
  final labelCtrl = TextEditingController(text: existing?.label ?? '');
  var color = existing?.color ?? kNoCategoryColor;
  // Delete pops the editor first; the group then goes with Undo.
  var deleteRequested = false;

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
                HueColorPicker(
                  value: color,
                  onChanged: (c) => setState(() => color = c),
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
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
  if (deleteRequested && existing != null && context.mounted) {
    await _deleteGroupWithUndo(context, existing);
  }
}

/// Deletes [g] at once, with no confirm: its categories only become
/// ungrouped, and Undo puts back the members still free to rejoin.
Future<void> _deleteGroupWithUndo(BuildContext context, CategoryGroup g) async {
  final finance = context.read<FinanceProvider>();
  final d = await finance.deleteGroup(g.id);
  if (d == null || !context.mounted) return;
  showUndoSnackBar(
    context,
    'Deleted group "${g.label}"',
    () => finance.restoreGroup(d),
    icon: Icons.delete_outline,
    tone: AppToastTone.removal,
  );
}

// ── Categories ──────────────────────────────────────────────────────────────

/// Asks where [c]'s transactions go, then deletes it with Undo, which also
/// puts back its rules, group, budgets and remapped reminders.
Future<void> _confirmDeleteCategory(BuildContext context, TxCategory c) async {
  final finance = context.read<FinanceProvider>();
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
      builder: (ctx, setState) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          // Like every sibling dialog: landscape and large text overflow a
          // fixed column.
          scrollable: true,
          title: Text('Delete "${c.label}"?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Its transactions move to the category below. Rules '
                'targeting it are removed, and it leaves its group and any '
                'budgets it was in.',
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
            // Red like the ledger's bulk delete: this one moves rows.
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return;
  final d = await finance.deleteCategory(c.id, moveTo: moveTo);
  if (!context.mounted) return;
  final moved = d.movedRows.length;
  showUndoSnackBar(
    context,
    'Deleted category "${c.label}"'
    '${moved == 0 ? '' : ' · $moved transaction${moved == 1 ? '' : 's'} '
              'moved to ${categoryById(moveTo).label}'}',
    () => finance.restoreCategory(d),
    icon: Icons.delete_outline,
    tone: AppToastTone.removal,
  );
}

/// The category dialog's Icon and colour sheet: the icon grid, centred, and
/// the colour picker at [cell]-sized swatches, centred as one block.
Widget _lookSheetBody(
  BuildContext context, {
  required ColorScheme scheme,
  required double cell,
  required IconData icon,
  required Color color,
  required ValueChanged<IconData> onIcon,
  required ValueChanged<Color> onColor,
}) {
  final text = Theme.of(context).textTheme;
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Icon and colour', style: text.titleLarge),
      const SizedBox(height: 16),
      Text('Icon', style: text.labelMedium),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final entry in kCategoryIconChoices.entries)
            Semantics(
              button: true,
              selected: entry.value == icon,
              label: entry.key,
              // The InkWell's tap, exposed past excludeSemantics.
              onTap: () => onIcon(entry.value),
              excludeSemantics: true,
              child: _pickerTarget(
                InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  onTap: () => onIcon(entry.value),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: entry.value == icon
                          ? color.withValues(alpha: 0.25)
                          : scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      border: entry.value == icon
                          ? Border.all(color: color, width: 2)
                          : null,
                    ),
                    child: Icon(
                      entry.value,
                      size: 20,
                      color: entry.value == icon
                          ? color
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      const SizedBox(height: 16),
      // As wide as its swatch grid, so its label and None/Custom row line
      // up with the grid's left edge.
      Center(
        child: SizedBox(
          width: cell * kCategoryHueNames.length,
          child: HueColorPicker(value: color, onChanged: onColor, cell: cell),
        ),
      ),
      const SizedBox(height: 16),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Done'),
        ),
      ),
    ],
  );
}

/// Add/edit dialog for categories, including the parent-group picker.
/// Public so the Cockpit FAB can open it.
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
      existing != null && FinanceProvider.hasLockedStructure(existing.id);
  final isRepaid = existing?.id == kRepaidToMeCategoryId;
  final labelCtrl = TextEditingController(text: existing?.label ?? '');
  var type = existing?.type ?? TxType.expense;
  var isTransfer = existing?.isTransfer ?? false;
  var icon = existing?.icon ?? Icons.home;
  var color = existing?.color ?? kNoCategoryColor;
  String? groupId = existing == null ? null : finance.groupIdOf(existing.id);
  // Re-entrancy latch: the build-time duplicate check can't stop a
  // double-tap (both presses see the pre-add state), and Create awaits the
  // writes before popping — a second tap minted a duplicate category.
  var saving = false;
  // A failed save, said inside the dialog: a toast would draw behind it.
  String? saveError;
  // Transfer options start open when editing a transfer.
  var transferOpen = isTransfer;
  // Delete pops the editor first, then asks where the transactions go.
  var deleteRequested = false;

  // The icon grid and the colours, in one sheet over the dialog. A pick
  // sets both: the sheet shows it selected, and the dialog's circle,
  // mounted underneath, follows.
  Future<void> pickLook(BuildContext ctx, StateSetter setDialog) =>
      showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (_) => StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            void pick(VoidCallback change) {
              setDialog(change);
              setSheet(() {});
            }

            final scheme = Theme.of(sheetCtx).colorScheme;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              // A sheet is full width, unlike the dialog these grids came
              // from: the colour cells grow to fill it (up to 48dp), and the
              // icon rows centre, so neither leaves a wide gap on the right.
              child: LayoutBuilder(
                builder: (_, box) {
                  final cell = (box.maxWidth / kCategoryHueNames.length).clamp(
                    32.0,
                    48.0,
                  );
                  return _lookSheetBody(
                    sheetCtx,
                    scheme: scheme,
                    cell: cell,
                    icon: icon,
                    color: color,
                    onIcon: (v) => pick(() => icon = v),
                    onColor: (c) => pick(() => color = c),
                  );
                },
              ),
            );
          },
        ),
      );

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
            // The save error sits under the scrolling fields, so it stays in
            // view at large text instead of scrolling away.
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    // Top padding so the field's floating "Name" label isn't
                    // clipped by the scroll viewport's edge.
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Top-aligned: a duplicate-name error grows the field
                        // downward, and the circle stays beside the name.
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // The category as it will look; the icon grid and the
                            // colours open from it in one sheet.
                            _pickerTarget(
                              Semantics(
                                button: true,
                                label: 'Icon and colour',
                                // excludeSemantics drops the InkWell's own tap
                                // action too, so it is exposed here for screen
                                // readers.
                                onTap: () => pickLook(ctx, setState),
                                excludeSemantics: true,
                                child: InkWell(
                                  customBorder: const CircleBorder(),
                                  onTap: () => pickLook(ctx, setState),
                                  child: Container(
                                    width: 40,
                                    height: 40,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: color.withValues(alpha: 0.2),
                                      border: Border.all(
                                        color: color,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Icon(
                                      icon,
                                      size: 20,
                                      color: categoryGlyphColor(ctx, color),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Builder(
                                builder: (ctx) {
                                  // Two categories named "Home" are
                                  // indistinguishable in every dropdown, so the
                                  // duplicate is rejected up front.
                                  final name = labelCtrl.text
                                      .trim()
                                      .toLowerCase();
                                  final duplicate =
                                      name.isNotEmpty &&
                                      allCategories.any(
                                        (c) =>
                                            c.id != existing?.id &&
                                            c.label.trim().toLowerCase() ==
                                                name,
                                      );
                                  return TextField(
                                    controller: labelCtrl,
                                    autofocus: existing == null,
                                    textCapitalization:
                                        TextCapitalization.sentences,
                                    onChanged: (_) => setState(() {}),
                                    decoration: InputDecoration(
                                      labelText: 'Name',
                                      hintText: 'e.g. Home',
                                      errorText: duplicate
                                          ? 'A category with this name already '
                                                'exists'
                                          : null,
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                        // Only while creating: an existing category's circle
                        // already shows its own icon and colour.
                        if (existing == null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Tap the circle to pick an icon and colour',
                              style: Theme.of(ctx).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      ctx,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        const SizedBox(height: 16),
                        // Direction and transfer-ness are editable for everything
                        // except two kinds. The fallback "Other" categories are
                        // the app's hard-coded remap targets. Repaid to me
                        // must stay a money-in transfer so repayments never count
                        // as income.
                        if (isFallback)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              isRepaid
                                  ? 'Repaid to me always stays a money-in '
                                        'transfer, so repayments never count as '
                                        'income.'
                                  : 'Direction is fixed for the fallback "Other" '
                                        'categories.',
                              style: Theme.of(ctx).textTheme.bodySmall,
                            ),
                          ),
                        if (!isFallback) ...[
                          // No selected checkmark and single-line scale-down labels:
                          // "Money out" + icon + check wrapped in the narrow dialog.
                          Row(
                            children: [
                              Expanded(
                                child: SegmentedButton<TxType>(
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
                                      icon: const Icon(
                                        Icons.arrow_upward,
                                        size: 16,
                                      ),
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
                                      icon: const Icon(
                                        Icons.arrow_downward,
                                        size: 16,
                                      ),
                                    ),
                                  ],
                                  selected: {type},
                                  onSelectionChanged: (s) =>
                                      setState(() => type = s.first),
                                ),
                              ),
                              const InfoTip(
                                title: 'Direction',
                                message:
                                    'Changing direction re-types every transaction '
                                    'in this category. Switching a category that '
                                    'is not a transfer to income also removes it '
                                    'from its group and budgets.',
                              ),
                            ],
                          ),
                        ],
                        if (groupable && finance.groups.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          AppDropdownField<String>(
                            label: 'Group',
                            value: groupId,
                            items: [
                              const PickerItem(
                                value: null,
                                label: 'None (Other)',
                              ),
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
                        ],
                        // Most categories are plain spending or income; the switch
                        // waits behind an expander, open on a transfer.
                        if (!isFallback) ...[
                          const SizedBox(height: 4),
                          DialogExpander(
                            title: 'Transfer options',
                            open: transferOpen,
                            onToggle: () =>
                                setState(() => transferOpen = !transferOpen),
                            // Tip beside the tile, not in it: SwitchListTile
                            // merges its children's semantics and would swallow
                            // the tip.
                            child: Row(
                              children: [
                                Expanded(
                                  child: SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Transfer'),
                                    subtitle: Text(
                                      'Moves money, not income or spending',
                                      style: Theme.of(ctx).textTheme.bodySmall,
                                    ),
                                    value: isTransfer,
                                    onChanged: (v) =>
                                        setState(() => isTransfer = v),
                                  ),
                                ),
                                const InfoTip(
                                  title: 'Transfer',
                                  message:
                                      'Transfers are left out of income, spending, '
                                      'the monthly cap and "All except" budgets. '
                                      'Money-out transfers still count in a budget '
                                      'that picks them under "Only these", and in '
                                      "their group's total.",
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (saveError case final error?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error,
                      style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                        color: Theme.of(ctx).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              // Built-in categories cannot be deleted, only reset.
              if (existing != null && !isBuiltIn)
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
                        setState(() {
                          saving = true;
                          saveError = null;
                        });
                        final label = labelCtrl.text.trim();
                        // Await the saves BEFORE popping: a failure used to close
                        // the dialog anyway and vanish without a message.
                        final navigator = Navigator.of(ctx);
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
                        } catch (_) {
                          // No raw exception text: it means nothing to the
                          // user, and the fields are still there to retry.
                          if (!ctx.mounted) return;
                          setState(() {
                            saving = false;
                            saveError =
                                "Couldn't save the category. Try again.";
                          });
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
  if (deleteRequested && existing != null && context.mounted) {
    await _confirmDeleteCategory(context, existing);
  }
}
