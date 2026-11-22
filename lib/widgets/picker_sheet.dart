import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'dispose_scope.dart';

/// One row of a picker sheet. A null [value] is a legitimate selectable
/// item ("Unassigned", "None (Other)") — dismissal is distinguished from a
/// null selection by [PickerResult]. [label] doubles as the search key.
class PickerItem<T> {
  final T? value;
  final String label;
  final Widget? leading;

  /// One line under the label ("4 transactions move").
  final String? subtitle;

  /// Non-selectable section label (EXPENSES / INCOME / …). Hidden when the
  /// search query empties its whole section.
  final bool isHeader;

  const PickerItem({
    this.value,
    required this.label,
    this.leading,
    this.subtitle,
    this.isHeader = false,
  });

  const PickerItem.header(this.label)
    : value = null,
      leading = null,
      subtitle = null,
      isHeader = true;
}

/// Wrapper distinguishing "picked the null-valued item" from "dismissed":
/// showPickerSheet returns null on dismissal and PickerResult(null) when
/// the user actually chose the null item.
class PickerResult<T> {
  final T? value;
  const PickerResult(this.value);
}

/// The app's one value-picker presentation: a modal bottom sheet with a
/// bold title, a search field, and full-width option rows — the selected
/// row tinted with the label in primary and a trailing check-circle. Short
/// lists yield short sheets; long ones cap at 75% of the screen and scroll,
/// auto-scrolled to the current selection.
///
/// [searchable] null shows the search from 8 selectable rows up. A null
/// [selected] ticks nothing unless [selectedIsSet] is true, which makes it
/// pick the null-valued row ("Not linked yet").
Future<PickerResult<T>?> showPickerSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required List<PickerItem<T>> items,
  T? selected,
  bool? searchable,
  bool selectedIsSet = false,
}) {
  return showModalBottomSheet<PickerResult<T>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.75,
    ),
    builder: (ctx) => Padding(
      // Builder's ctx, not the caller's: the sheet must track ITS OWN
      // keyboard inset so the search field stays visible while typing
      // (add-transaction sheet precedent).
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: _PickerSheetBody<T>(
        title: title,
        subtitle: subtitle,
        items: items,
        selected: selected,
        searchable: searchable ?? items.where((i) => !i.isHeader).length >= 8,
        selectedIsSet: selectedIsSet,
      ),
    ),
  );
}

class _PickerSheetBody<T> extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<PickerItem<T>> items;
  final T? selected;
  final bool searchable;
  final bool selectedIsSet;

  const _PickerSheetBody({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.selected,
    required this.searchable,
    required this.selectedIsSet,
  });

  @override
  State<_PickerSheetBody<T>> createState() => _PickerSheetBodyState<T>();
}

class _PickerSheetBodyState<T> extends State<_PickerSheetBody<T>> {
  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();
  final _selectedKey = GlobalKey();
  var _query = '';

  /// Counts reveals, so an older one still stepping down the list stops
  /// when a newer one starts.
  var _reveals = 0;

  /// The list's padding, a header's and a row's, and a row's least height:
  /// together they give the least offset a row can sit at.
  static const _listPadding = EdgeInsets.fromLTRB(12, 6, 12, 16);
  static const _headerPadding = EdgeInsets.fromLTRB(14, 12, 14, 4);
  static const _rowPadding = EdgeInsets.symmetric(vertical: 2);
  static const _rowMinHeight = 52.0;

  @override
  void initState() {
    super.initState();
    // The current selection can sit far below the fold in a 40-row list.
    _revealSelected(opening: true);
  }

  /// Brings the selected row into view after the next frame: centred a
  /// little above the middle on opening, and after a search only as far as
  /// needed, so the list does not jump on every key.
  void _revealSelected({required bool opening}) {
    final run = ++_reveals;
    void step(int attempt) {
      if (!mounted || run != _reveals || !_scroll.hasClients) return;
      final row = _selectedKey.currentContext;
      if (row != null) {
        if (opening) {
          Scrollable.ensureVisible(row, alignment: 0.4);
        } else {
          Scrollable.ensureVisible(
            row,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
          );
          Scrollable.ensureVisible(
            row,
            alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          );
        }
        return;
      }
      // The list builds only the rows in and near its view, so a row further
      // away has no context yet. The first step jumps to the least offset the
      // row can sit at, which puts it at or below the top of the view; each
      // later step moves one view down, until the row is built.
      final visible = _visible;
      final index = visible.indexWhere(_isSelected);
      final p = _scroll.position;
      if (index < 0 || attempt > visible.length) return;
      if (attempt > 0 && p.pixels >= p.maxScrollExtent) return;
      final target = attempt == 0
          ? visible
                .take(index)
                .fold(
                  _listPadding.top,
                  (sum, i) =>
                      sum +
                      (i.isHeader
                          ? _headerPadding.vertical
                          : _rowMinHeight + _rowPadding.vertical),
                )
          : p.pixels + p.viewportDimension;
      p.jumpTo(
        target.clamp(p.minScrollExtent, p.maxScrollExtent).toDouble(),
      );
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => step(attempt + 1))
        ..ensureVisualUpdate();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => step(0));
  }

  /// Rows surviving the query: items matching on their label or subtitle
  /// (a sender or date lives only there), plus the selected item
  /// (deselecting must stay possible mid-search — filter-sheet precedent),
  /// plus headers that still own at least one visible row.
  List<PickerItem<T>> get _visible {
    if (_query.isEmpty) return widget.items;
    bool matches(PickerItem<T> i) =>
        i.label.toLowerCase().contains(_query) ||
        (i.subtitle ?? '').toLowerCase().contains(_query) ||
        _isSelected(i);
    final out = <PickerItem<T>>[];
    for (var i = 0; i < widget.items.length; i++) {
      final item = widget.items[i];
      if (item.isHeader) {
        var anyVisible = false;
        for (var j = i + 1; j < widget.items.length; j++) {
          if (widget.items[j].isHeader) break;
          if (matches(widget.items[j])) {
            anyVisible = true;
            break;
          }
        }
        if (anyVisible) out.add(item);
      } else if (matches(item)) {
        out.add(item);
      }
    }
    return out;
  }

  /// A null [_PickerSheetBody.selected] picks the null-valued row only
  /// when the caller says null is the value.
  bool _isSelected(PickerItem<T> item) =>
      !item.isHeader &&
      (widget.selected != null || widget.selectedIsSet) &&
      item.value == widget.selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final visible = _visible;

    return DisposeScope(
      disposables: [_searchCtrl, _scroll],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (widget.subtitle != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(widget.subtitle!, style: textTheme.bodySmall),
            ),
          // A short list reads at a glance; search only gets in the way.
          if (widget.searchable)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              // Listen to the controller so the ✕ appears on the first
              // keystroke (main search bar precedent).
              child: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _searchCtrl,
                builder: (context, value, _) => TextField(
                  controller: _searchCtrl,
                  autofocus: false,
                  decoration: InputDecoration(
                    hintText: 'Search…',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                    suffixIcon: value.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                              _revealSelected(opening: false);
                            },
                          ),
                  ),
                  onChanged: (v) {
                    setState(() => _query = v.trim().toLowerCase());
                    _revealSelected(opening: false);
                  },
                ),
              ),
            ),
          Flexible(
            child: visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('No matches.', style: textTheme.bodySmall),
                  )
                : ListView(
                    controller: _scroll,
                    shrinkWrap: true,
                    padding: _listPadding,
                    children: [
                      for (final item in visible)
                        item.isHeader
                            ? Padding(
                                padding: _headerPadding,
                                child: Text(
                                  item.label.toUpperCase(),
                                  style: textTheme.labelSmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                    letterSpacing: 1.2,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            : _row(item, scheme),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(PickerItem<T> item, ColorScheme scheme) {
    final isSelected = _isSelected(item);
    return Semantics(
      button: true,
      selected: isSelected,
      child: Padding(
        padding: _rowPadding,
        child: Material(
          key: isSelected ? _selectedKey : null,
          color: isSelected
              ? scheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.control),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.pop(context, PickerResult<T>(item.value)),
            child: Container(
              constraints: const BoxConstraints(minHeight: _rowMinHeight),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  if (item.leading != null) ...[
                    item.leading!,
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: isSelected
                              // Plain text on the tinted row: the tint marks
                              // the choice.
                              ? TextStyle(
                                  color: scheme.onSurface,
                                  fontWeight: FontWeight.w600,
                                )
                              : null,
                        ),
                        if (item.subtitle != null)
                          Text(
                            item.subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    Icon(Icons.check_circle, size: 20, color: scheme.primary),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Form-field trigger for [showPickerSheet]: renders through the app's
/// InputDecoration theme so it reads as a dropdown field, but opens the
/// bottom-sheet picker instead of an attached menu.
class AppDropdownField<T> extends StatelessWidget {
  final List<PickerItem<T>> items;
  final T? value;
  final ValueChanged<T?> onChanged;
  final String label;
  final String? hint;

  /// A line under the field explaining the current choice.
  final String? helper;

  /// A leading icon inside the field, as a text field's prefix icon. With
  /// it, the value leaves out the chosen item's own icon: one icon per
  /// field, so the caller passes the chosen item's icon here.
  final Widget? icon;

  const AppDropdownField({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    required this.label,
    this.hint,
    this.helper,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    // The null-valued item ("Unassigned") is a real selection — find the
    // item by value, treating null-as-value distinctly from no-items-match.
    final selectedItem = items
        .where((i) => !i.isHeader && i.value == value)
        .firstOrNull;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.control),
      onTap: () async {
        // An open keyboard (amount field, sender field…) would sit under
        // the sheet and shove it up the moment it closed.
        FocusManager.instance.primaryFocus?.unfocus();
        final result = await showPickerSheet<T>(
          context: context,
          title: label,
          items: items,
          selected: value,
          // The field shows the null-valued row ("Not set") as chosen; so
          // does the sheet.
          selectedIsSet: selectedItem != null,
        );
        if (result != null) onChanged(result.value);
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          prefixIcon: icon,
          suffixIcon: const Icon(Icons.arrow_drop_down),
        ),
        isEmpty: selectedItem == null,
        child: selectedItem == null
            ? (hint == null ? null : Text(hint!, maxLines: 1))
            : Row(
                children: [
                  if (icon == null && selectedItem.leading != null) ...[
                    selectedItem.leading!,
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text(
                      selectedItem.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // A typed field's size, as in the fields around it.
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
