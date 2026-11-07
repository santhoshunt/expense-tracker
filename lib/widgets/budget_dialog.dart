import 'package:flutter/foundation.dart' show setEquals;
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
import 'editor_sheet.dart';
import 'grouped_surface.dart';
import 'icon_picker_sheet.dart';
import 'info_tip.dart';
import 'row_chevron.dart';
import 'undo_snackbar.dart';

/// Create/edit editor for a [SpendBudget]. Shared by the Cockpit's Budgets
/// tab and the dashboard's category rows, which open it pre-filled for one
/// category via the `preset*` parameters (ignored when [existing] is given).
///
/// A new budget with no presets asks its kind first (Monthly budget, Trip
/// or event); a preset opens the monthly form, and an edit opens the form
/// of its kind: the trip form for a budget with dates.
///
/// [allowDelete] adds Delete budget to the header ⋮ when editing, which
/// removes the budget with Undo. Only the Cockpit list passes it: opened
/// from a sheet, a delete would leave the sheet showing a removed budget.
Future<void> showBudgetDialog(
  BuildContext context, {
  SpendBudget? existing,
  String? presetName,
  BudgetMode? presetMode,
  Set<String>? presetCategoryIds,
  bool allowDelete = false,
}) async {
  final finance = context.read<FinanceProvider>();
  final kind = existing != null
      ? (existing.range != null ? _BudgetKind.trip : _BudgetKind.monthly)
      : presetMode == null && presetName == null
      ? null
      : _BudgetKind.monthly;
  // True when Delete budget was picked: the sheet closes first, then the
  // budget goes with Undo.
  final deleteRequested = await showEditorSheet<bool>(
    context,
    builder: (_) => _BudgetSheet(
      kind: kind,
      existing: existing,
      presetName: presetName,
      presetMode: presetMode,
      presetCategoryIds: presetCategoryIds,
      allowDelete: allowDelete,
    ),
  );
  if (deleteRequested == true && existing != null && context.mounted) {
    _deleteWithUndo(context, finance, existing);
  }
}

enum _BudgetKind { monthly, trip }

/// One sheet route for every budget editor: the kind list while [kind] is
/// null, then that kind's form in the same route, so a single pop closes
/// it and the form's back arrow returns to the list.
class _BudgetSheet extends StatefulWidget {
  final _BudgetKind? kind;
  final SpendBudget? existing;
  final String? presetName;
  final BudgetMode? presetMode;
  final Set<String>? presetCategoryIds;
  final bool allowDelete;

  const _BudgetSheet({
    required this.kind,
    this.existing,
    this.presetName,
    this.presetMode,
    this.presetCategoryIds,
    this.allowDelete = false,
  });

  @override
  State<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends State<_BudgetSheet> {
  late _BudgetKind? _kind = widget.kind;

  @override
  Widget build(BuildContext context) {
    // Back drops what the form held, after "Discard changes?" when it
    // holds edits (EditorSheetBody asks): the kind can still change.
    final onBack = widget.kind == null
        ? () => setState(() => _kind = null)
        : null;
    return switch (_kind) {
      null => _kindList(context),
      _BudgetKind.monthly => _MonthlyBudgetForm(
        existing: widget.existing,
        presetName: widget.presetName,
        presetMode: widget.presetMode,
        presetCategoryIds: widget.presetCategoryIds,
        allowDelete: widget.allowDelete,
        onBack: onBack,
      ),
      _BudgetKind.trip => _TripBudgetForm(
        existing: widget.existing,
        allowDelete: widget.allowDelete,
        onBack: onBack,
      ),
    };
  }

  /// "New budget": the two kinds, each opening its own form.
  Widget _kindList(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(
      _BudgetKind kind, {
      required IconData icon,
      required String title,
      required String subtitle,
      required bool first,
    }) => GroupedSurface(
      first: first,
      last: !first,
      child: ListTile(
        key: ValueKey('budget-kind-${kind.name}'),
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: rowChevron(context),
        onTap: () => setState(() => _kind = kind),
      ),
    );
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The editor sheet's header row, so the title does not jump when
          // a form replaces the list.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Text(
              'New budget',
              style: theme.textTheme.titleLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row(
                    _BudgetKind.monthly,
                    icon: Icons.calendar_month,
                    title: 'Monthly budget',
                    subtitle: 'A limit that resets each month',
                    first: true,
                  ),
                  row(
                    _BudgetKind.trip,
                    icon: Icons.luggage,
                    title: 'Trip or event',
                    subtitle: 'One total for a few days, counting what you tag',
                    first: false,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Deletes [budget] and offers Undo on [context]'s messenger.
void _deleteWithUndo(
  BuildContext context,
  FinanceProvider finance,
  SpendBudget budget,
) {
  // The delete reads the alert marker across an await, so the Undo waits
  // on the same future for what it captured.
  final pending = finance.deleteBudget(budget.id);
  showUndoSnackBar(
    context,
    'Deleted budget "${budget.name}"',
    () async {
      final removed = await pending;
      if (removed != null) await finance.restoreBudget(removed);
    },
    icon: Icons.delete_outline,
    tone: AppToastTone.removal,
  );
}

/// The header ⋮ of an edited budget, when the caller allows Delete.
List<PopupMenuEntry<String>>? _deleteMenu(
  BuildContext context,
  SpendBudget? existing,
  bool allowDelete,
) => existing != null && allowDelete
    ? [
        PopupMenuItem(
          value: 'delete',
          child: Text(
            'Delete budget',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ]
    : null;

/// Groupable categories bucketed by parent group ("Other" last), so the
/// picker mirrors the dashboard's grouping. To sort is no budget's: it
/// holds payments waiting for their category.
List<(String, List<TxCategory>)> _categorySections(FinanceProvider finance) {
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
  return sections;
}

/// The budget's icon button: the picked icon, else what Automatic gives.
/// The whole 48dp square takes the tap, not only the 40dp tile drawn in it.
Widget _budgetIconButton(
  BuildContext context, {
  required IconData icon,
  required VoidCallback onTap,
}) {
  final scheme = Theme.of(context).colorScheme;
  return SizedBox(
    width: 48,
    height: 48,
    child: Semantics(
      button: true,
      label: 'Budget icon',
      // excludeSemantics drops the InkWell's own tap action too, so it is
      // exposed here.
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: 'Budget icon',
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: onTap,
          child: Center(
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Icon(
                icon,
                size: 21,
                color: categoryGlyphColor(context, scheme.primary),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A monthly budget: Name with its icon, Monthly limit, and What counts
/// folded. An undated tag budget (made before trips had their own form)
/// opens here too and keeps its tag unless 'Count categories instead'.
class _MonthlyBudgetForm extends StatefulWidget {
  final SpendBudget? existing;
  final String? presetName;
  final BudgetMode? presetMode;
  final Set<String>? presetCategoryIds;
  final bool allowDelete;

  /// Back to the kind list; only on a new budget.
  final VoidCallback? onBack;

  const _MonthlyBudgetForm({
    this.existing,
    this.presetName,
    this.presetMode,
    this.presetCategoryIds,
    this.allowDelete = false,
    this.onBack,
  });

  @override
  State<_MonthlyBudgetForm> createState() => _MonthlyBudgetFormState();
}

class _MonthlyBudgetFormState extends State<_MonthlyBudgetForm> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _limitCtrl;
  late BudgetMode _mode;
  late final Set<String> _selected;
  // The picked icon's key, or null for Automatic.
  String? _iconKey;
  // An undated tag budget's tag: every row carrying it counts.
  String? _tag;
  bool _open = false;
  late final List<(String, List<TxCategory>)> _sections;

  // What the form opened with: back with nothing changed closes it
  // without asking.
  late final String _initialName;
  late final String _initialLimit;
  late final BudgetMode _initialMode;
  late final Set<String> _initialSelected;
  late final String? _initialIconKey;
  late final String? _initialTag;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameCtrl = TextEditingController(
      text: existing?.name ?? widget.presetName ?? '',
    );
    _limitCtrl = TextEditingController(
      // Paise kept: a rounded figure would be saved back rounded.
      text: existing == null ? '' : fmtFieldNumber(existing.limit),
    );
    _mode = existing?.mode ?? widget.presetMode ?? BudgetMode.exclude;
    _selected = {
      ...?existing?.categoryIds,
      if (existing == null) ...?widget.presetCategoryIds,
    };
    _iconKey = existing?.iconKey;
    _tag = existing?.tag;
    _sections = _categorySections(context.read<FinanceProvider>());
    _initialName = _nameCtrl.text;
    _initialLimit = _limitCtrl.text;
    _initialMode = _mode;
    _initialSelected = {..._selected};
    _initialIconKey = _iconKey;
    _initialTag = _tag;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _limitCtrl.dispose();
    super.dispose();
  }

  /// The folded line: "All spending except Rent, EMI", "Only Food &
  /// Dining", "Everything tagged #Goa trip".
  String _whatCounts() {
    if (_tag case final tag?) return 'Everything tagged #$tag';
    final names = [
      for (final c in allCategories)
        if (_selected.contains(c.id)) c.label,
    ];
    final listed = names.length <= 2
        ? names.join(', ')
        : '${names.take(2).join(', ')} and ${names.length - 2} more';
    if (_mode == BudgetMode.exclude) {
      return names.isEmpty ? 'All spending' : 'All spending except $listed';
    }
    return names.isEmpty ? 'None' : 'Only $listed';
  }

  void _save(FinanceProvider finance, double limit) {
    final existing = widget.existing;
    final tag = _tag;
    if (existing == null) {
      finance.addBudget(
        name: _nameCtrl.text.trim(),
        limit: limit,
        mode: _mode,
        categoryIds: tag == null ? {..._selected} : const {},
        iconKey: _iconKey,
        tag: tag,
      );
    } else {
      finance.updateBudget(
        existing.copyWith(
          name: _nameCtrl.text.trim(),
          limit: limit,
          mode: _mode,
          categoryIds: tag == null ? {..._selected} : const {},
          iconKey: _iconKey,
          clearIconKey: _iconKey == null,
          tag: tag,
          clearTag: tag == null,
          clearRange: tag == null,
        ),
      );
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final existing = widget.existing;
    final limit = parseAmount(_limitCtrl.text);
    // An include budget with nothing picked is 0 forever; an exclude
    // budget with nothing picked is simply "all spending", valid.
    final reason = _nameCtrl.text.trim().isEmpty
        ? 'Enter a name'
        : limit == null || limit <= 0
        ? 'Enter a limit above ₹0'
        : _mode == BudgetMode.include && _selected.isEmpty && _tag == null
        ? 'Pick at least one category'
        : null;
    final dirty =
        _nameCtrl.text != _initialName ||
        _limitCtrl.text != _initialLimit ||
        _mode != _initialMode ||
        !setEquals(_selected, _initialSelected) ||
        _iconKey != _initialIconKey ||
        _tag != _initialTag;
    // What the icon button shows: the picked icon, else what Automatic
    // gives for the current mode and picks.
    final automaticIcon = budgetIcon(
      SpendBudget(
        id: '',
        name: '',
        limit: 0,
        mode: _mode,
        categoryIds: _selected,
        tag: _tag,
      ),
    );
    Future<void> pickIcon() async {
      final picked = await showIconPickerSheet(
        context,
        selected: _iconKey,
        automaticIcon: automaticIcon,
      );
      if (picked == null || !mounted) return;
      setState(() => _iconKey = picked.isEmpty ? null : picked);
    }

    return EditorSheetBody(
      title: existing == null ? 'New monthly budget' : 'Edit budget',
      onBack: widget.onBack,
      menu: _deleteMenu(context, existing, widget.allowDelete),
      menuTooltip: 'Budget actions',
      onMenu: (_) => Navigator.pop(context, true),
      footerLabel: existing == null ? 'Create budget' : 'Save',
      footerReason: reason,
      dirty: dirty,
      onSave: reason != null ? null : () => _save(finance, limit!),
      children: [
        Row(
          children: [
            _budgetIconButton(
              context,
              icon: kCategoryIconChoices[_iconKey] ?? automaticIcon,
              onTap: pickIcon,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('budget-name'),
                controller: _nameCtrl,
                // A preset name is already filled in; the limit is the
                // field that still needs typing.
                autofocus: existing == null && widget.presetName == null,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.next,
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
          key: const ValueKey('budget-limit'),
          controller: _limitCtrl,
          autofocus: existing == null && widget.presetName != null,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Monthly limit',
            prefixText: '₹ ',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        GroupedSurface(
          first: true,
          last: true,
          child: DialogExpander(
            key: const ValueKey('budget-what-counts'),
            title: 'What counts',
            value: _whatCounts(),
            keepClosed: false,
            open: _open,
            onToggle: () => setState(() {
              FocusScope.of(context).unfocus();
              _open = !_open;
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _tag == null
                    ? _categoryPicks(context)
                    : _tagPick(context, _tag!),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// An undated tag budget's fold: its tag, and the way back to
  /// categories. No category chips while the tag holds, so a tap cannot
  /// clear it unnoticed.
  List<Widget> _tagPick(BuildContext context, String tag) {
    final scheme = Theme.of(context).colorScheme;
    final finance = context.read<FinanceProvider>();
    return [
      Text(
        'Every row tagged "$tag" counts, in any category, money-out '
        'transfers too.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 8),
      Align(
        alignment: Alignment.centerLeft,
        child: Chip(
          avatar: Icon(
            Icons.sell,
            size: 16,
            color: categoryGlyphColor(
              context,
              finance.tagColor(tag) ?? scheme.onSurfaceVariant,
            ),
          ),
          label: Text(tag),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          style: flushTextButtonStyle,
          onPressed: () => setState(() => _tag = null),
          child: const Text('Count categories instead'),
        ),
      ),
    ];
  }

  /// Only these or All except, its explainer, and the category chips by
  /// group with All and None.
  List<Widget> _categoryPicks(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return [
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
        selected: {_mode},
        onSelectionChanged: (s) => setState(() => _mode = s.first),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Text(
              _mode == BudgetMode.include
                  ? 'Count rows that have any of the picks below.'
                  : 'All spending counts except the picked categories. '
                        'Transfers never count.',
              style: text.bodySmall,
            ),
          ),
          const InfoTip(
            title: 'Only these or All except',
            message:
                'Only these: counts spending in the picked categories, '
                'including money-out transfers you pick. All except: counts '
                'all spending except the picked categories, and transfers '
                'never count. Pending imports never count. A tag counts '
                'every row carrying it, in any category.',
          ),
        ],
      ),
      for (final (label, cats) in _sections) ...[
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: Text(label, style: text.labelMedium)),
            TextButton(
              onPressed: () => setState(() {
                final ids = cats.map((c) => c.id).toSet();
                if (_selected.containsAll(ids)) {
                  _selected.removeAll(ids);
                } else {
                  _selected.addAll(ids);
                }
              }),
              child: Text(
                _selected.containsAll(cats.map((c) => c.id)) ? 'None' : 'All',
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
                selected: _selected.contains(c.id),
                onSelected: (v) => setState(() {
                  if (v) {
                    _selected.add(c.id);
                  } else {
                    _selected.remove(c.id);
                  }
                }),
              ),
          ],
        ),
      ],
    ];
  }
}

/// The longest trip: To stays at most this many days after From.
const int _kMaxTripDays = 91;

/// A trip or event: one total for some days, counting every payment
/// tagged with its tag. Saves as a dated tag budget.
class _TripBudgetForm extends StatefulWidget {
  final SpendBudget? existing;
  final bool allowDelete;

  /// Back to the kind list; only on a new budget.
  final VoidCallback? onBack;

  const _TripBudgetForm({this.existing, this.allowDelete = false, this.onBack});

  @override
  State<_TripBudgetForm> createState() => _TripBudgetFormState();
}

class _TripBudgetFormState extends State<_TripBudgetForm> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _limitCtrl;
  // Empty means the trip name.
  late final TextEditingController _tagCtrl;
  late DateTimeRange _range;
  bool _tagOpen = false;

  // What the form opened with: back with nothing changed closes it
  // without asking.
  late final String _initialName;
  late final String _initialLimit;
  late final String _initialTag;
  late final DateTimeRange _initialRange;

  static DateTime _today() => DateUtils.dateOnly(DateTime.now());

  static DateTime _plusDays(DateTime d, int days) =>
      DateTime(d.year, d.month, d.day + days);

  /// Today and the next six days: a new trip's dates.
  static DateTimeRange _nextWeek() {
    final today = _today();
    return DateTimeRange(start: today, end: _plusDays(today, 6));
  }

  /// The coming Saturday and Sunday, or today to Sunday on a weekend.
  static DateTimeRange _weekend() {
    final today = _today();
    final start = today.weekday >= DateTime.saturday
        ? today
        : _plusDays(today, DateTime.saturday - today.weekday);
    return DateTimeRange(
      start: start,
      end: _plusDays(today, DateTime.sunday - today.weekday),
    );
  }

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _nameCtrl = TextEditingController(text: existing?.name ?? '');
    _limitCtrl = TextEditingController(
      // Paise kept: a rounded figure would be saved back rounded.
      text: existing == null ? '' : fmtFieldNumber(existing.limit),
    );
    _tagCtrl = TextEditingController(text: existing?.tag ?? '');
    _range = existing?.range ?? _nextWeek();
    _initialName = _nameCtrl.text;
    _initialLimit = _limitCtrl.text;
    _initialTag = _tagCtrl.text;
    _initialRange = _range;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _limitCtrl.dispose();
    _tagCtrl.dispose();
    super.dispose();
  }

  /// The tag the trip counts: the Tag field, else the trip name.
  String? get _tag => normalizeTags([
    _tagCtrl.text.trim().isEmpty ? _nameCtrl.text : _tagCtrl.text,
  ]).firstOrNull;

  Future<void> _pickDates() async {
    final today = _today();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(2000),
      lastDate: DateTime(today.year + 5, today.month, today.day),
    );
    if (picked == null || !mounted) return;
    final start = DateUtils.dateOnly(picked.start);
    var end = DateUtils.dateOnly(picked.end);
    final latest = _plusDays(start, _kMaxTripDays);
    if (end.isAfter(latest)) end = latest;
    setState(() => _range = DateTimeRange(start: start, end: end));
  }

  void _save(FinanceProvider finance, String tag, double limit) {
    final existing = widget.existing;
    final name = _nameCtrl.text.trim();
    if (existing == null) {
      finance.addBudget(
        name: name,
        limit: limit,
        mode: BudgetMode.include,
        categoryIds: const {},
        tag: tag,
        range: _range,
      );
    } else {
      finance.updateBudget(
        existing.copyWith(name: name, limit: limit, tag: tag, range: _range),
      );
    }
    // False when the tag exists already, so harmless: the add sheet
    // offers a new trip's tag before any payment carries it.
    finance.addSavedTag(tag, null);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final finance = context.read<FinanceProvider>();
    final theme = Theme.of(context);
    final existing = widget.existing;
    final limit = parseAmount(_limitCtrl.text);
    final tag = _tag;
    // No tag left after normalising ("||"): Create stayed disabled with
    // nothing to say why.
    final reason = _nameCtrl.text.trim().isEmpty
        ? 'Enter a trip name'
        : tag == null
        ? 'Enter a trip name with letters or numbers'
        : limit == null || limit <= 0
        ? 'Enter a limit above ₹0'
        : null;
    final dirty =
        _nameCtrl.text != _initialName ||
        _limitCtrl.text != _initialLimit ||
        _tagCtrl.text != _initialTag ||
        _range != _initialRange;
    final days = daysCovered(_range.start, _range.end);
    final weekend = _weekend();
    final nextWeek = _nextWeek();
    final known =
        tag != null &&
        [
          for (final u in finance.allTags) u.tag,
          ...finance.savedTags,
        ].any((t) => tagKey(t) == tagKey(tag));
    final suggestions = finance.tagSuggestions.take(8).toList();
    return EditorSheetBody(
      title: existing == null ? 'New trip budget' : 'Edit trip budget',
      onBack: widget.onBack,
      menu: _deleteMenu(context, existing, widget.allowDelete),
      menuTooltip: 'Budget actions',
      onMenu: (_) => Navigator.pop(context, true),
      footerLabel: existing == null ? 'Create trip budget' : 'Save',
      footerReason: reason,
      footerExtra: tag == null
          ? null
          : Text(
              'Counts every payment tagged #$tag from '
              '${fmtDayRange(_range, DateTime.now())}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      dirty: dirty,
      onSave: reason != null ? null : () => _save(finance, tag!, limit!),
      children: [
        TextField(
          key: const ValueKey('trip-name'),
          controller: _nameCtrl,
          autofocus: existing == null,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Trip name',
            hintText: 'e.g. Goa trip',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        InkWell(
          key: const ValueKey('trip-dates'),
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: _pickDates,
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Dates',
              helperText: 'Up to 3 months',
            ),
            // Wraps at large text on a narrow phone rather than cutting
            // the end date.
            child: Text(
              '${fmtDateCompact(_range.start)} to '
              '${fmtDateCompact(_range.end)} · '
              '$days ${days == 1 ? 'day' : 'days'}',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('This weekend'),
              selected: _range == weekend,
              onSelected: (_) => setState(() => _range = weekend),
            ),
            ChoiceChip(
              label: const Text('Next 7 days'),
              selected: _range == nextWeek,
              onSelected: (_) => setState(() => _range = nextWeek),
            ),
            ChoiceChip(
              label: const Text('Pick dates…'),
              selected: _range != weekend && _range != nextWeek,
              onSelected: (_) => _pickDates(),
            ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('trip-limit'),
          controller: _limitCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(
            labelText: 'Total limit',
            prefixText: '₹ ',
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        GroupedSurface(
          first: true,
          last: true,
          child: DialogExpander(
            key: const ValueKey('trip-tag'),
            title: 'Tag',
            value: tag == null ? 'None' : '# $tag${known ? '' : ' (new)'}',
            keepClosed: false,
            open: _tagOpen,
            onToggle: () => setState(() {
              FocusScope.of(context).unfocus();
              _tagOpen = !_tagOpen;
            }),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const ValueKey('trip-tag-field'),
                    controller: _tagCtrl,
                    maxLength: kMaxTagLength,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Tag',
                      // The trip name, which an empty field stands for.
                      hintText: _nameCtrl.text.trim().isEmpty
                          ? null
                          : _nameCtrl.text.trim(),
                      counterText: '',
                      prefixIcon: const Icon(Icons.sell_outlined),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  if (suggestions.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final t in suggestions)
                          ChoiceChip(
                            // A tag reads "# Name" everywhere; TalkBack
                            // would read the "#" as "number".
                            label: Text('# $t', semanticsLabel: 'Tag $t'),
                            selected: tag != null && tagKey(tag) == tagKey(t),
                            onSelected: (_) =>
                                setState(() => _tagCtrl.text = t),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
