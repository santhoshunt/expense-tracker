import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'dispose_scope.dart';

/// One row of an anchored picker. A null [value] is a legitimate selectable
/// item ("Unassigned", "None (Other)") — dismissal is distinguished from a
/// null selection by [PickerResult]. [label] doubles as the search key.
class PickerItem<T> {
  final T? value;
  final String label;
  final Widget? leading;

  /// Non-selectable section label (EXPENSES / INCOME / …). Hidden when the
  /// search query empties its whole section.
  final bool isHeader;

  const PickerItem({
    this.value,
    required this.label,
    this.leading,
    this.isHeader = false,
  });

  const PickerItem.header(this.label)
    : value = null,
      leading = null,
      isHeader = true;
}

/// Wrapper distinguishing "picked the null-valued item" from "dismissed":
/// showAnchoredPicker returns null on dismissal and PickerResult(null) when
/// the user actually chose the null item.
class PickerResult<T> {
  final T? value;
  const PickerResult(this.value);
}

/// Compact rounded panel glued to the [link]'s target (the field) — the
/// dropdown look every stock menu here lacked: opens directly under the
/// field (above when the keyboard leaves no room), caps its height, pins a
/// search box on top for long lists, and highlights + auto-scrolls to the
/// current selection.
///
/// The panel is a [CompositedTransformFollower], so when the underlying
/// dialog/sheet reflows (keyboard opening, insets changing) it moves WITH
/// the field instead of floating at stale coordinates. [anchorContext] must
/// be inside the [CompositedTransformTarget] wrapping the field; it is used
/// only for the initial size / open-direction measurement.
Future<PickerResult<T>?> showAnchoredPicker<T>({
  required BuildContext anchorContext,
  required LayerLink link,
  required List<PickerItem<T>> items,
  T? selected,
  bool? searchable,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return Future.value(null);
  final anchorRect = box.localToGlobal(Offset.zero) & box.size;

  final selectableCount = items.where((i) => !i.isHeader).length;
  final showSearch = searchable ?? selectableCount > 8;

  return showDialog<PickerResult<T>>(
    context: anchorContext,
    // The panel carries its own shape; the barrier stays clear so the page
    // underneath keeps reading as context (menu behavior, not dialog).
    barrierColor: Colors.transparent,
    useRootNavigator: true,
    // No SafeArea wrapper: it shifted the whole coordinate space down by
    // the status-bar inset, so the panel opened visibly detached from its
    // field. The follower tracks the field itself; the height math below
    // accounts for the insets explicitly.
    useSafeArea: false,
    builder: (ctx) => _AnchoredPickerPanel<T>(
      link: link,
      anchorRect: anchorRect,
      items: items,
      selected: selected,
      showSearch: showSearch,
    ),
  );
}

class _AnchoredPickerPanel<T> extends StatefulWidget {
  final LayerLink link;
  final Rect anchorRect;
  final List<PickerItem<T>> items;
  final T? selected;
  final bool showSearch;

  const _AnchoredPickerPanel({
    required this.link,
    required this.anchorRect,
    required this.items,
    required this.selected,
    required this.showSearch,
  });

  @override
  State<_AnchoredPickerPanel<T>> createState() =>
      _AnchoredPickerPanelState<T>();
}

class _AnchoredPickerPanelState<T> extends State<_AnchoredPickerPanel<T>> {
  final _searchCtrl = TextEditingController();
  final _selectedKey = GlobalKey();
  var _query = '';
  var _scrolledToSelected = false;

  static const _maxPanelHeight = 360.0;
  static const _minPanelWidth = 220.0;

  @override
  void initState() {
    super.initState();
    // The current selection can sit far below the fold in a 40-row list.
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSelected());
  }

  void _ensureSelected() {
    if (_scrolledToSelected) return;
    final c = _selectedKey.currentContext;
    if (c != null) {
      _scrolledToSelected = true;
      Scrollable.ensureVisible(c, alignment: 0.4);
    }
  }

  /// Rows surviving the query: matching items, plus the selected item
  /// (deselecting must stay possible mid-search — filter-sheet precedent),
  /// plus headers that still own at least one visible row.
  List<PickerItem<T>> get _visible {
    if (_query.isEmpty) return widget.items;
    bool matches(PickerItem<T> i) =>
        i.label.toLowerCase().contains(_query) ||
        (i.value != null && i.value == widget.selected);
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final anchor = widget.anchorRect;

    // ALWAYS below the field — an open-above flip when space was cramped
    // read as inconsistent, so the panel now just shrinks instead (its list
    // scrolls internally). The keyboard (viewInsets) eats the bottom; when
    // it appears, the underlying dialog/sheet usually reflows the field
    // upward and the follower carries the panel with it, restoring room.
    final belowTop = anchor.bottom + 4;
    final spaceBelow = screen.height - media.viewInsets.bottom - belowTop - 8;
    final maxHeight = math.max(140.0, math.min(_maxPanelHeight, spaceBelow));

    final width = math.min(
      math.max(_minPanelWidth, anchor.width),
      screen.width - 16,
    );

    final visible = _visible;

    final panel = ConstrainedBox(
      // Tight width: the follower gives its child unbounded constraints, so
      // without minWidth the panel would shrink to its widest row instead
      // of matching the field.
      constraints: BoxConstraints(
        maxHeight: maxHeight,
        minWidth: width,
        maxWidth: width,
      ),
      child: Material(
        color: scheme.surfaceContainerHigh,
        elevation: 6,
        shadowColor: Colors.black54,
        borderRadius: BorderRadius.circular(AppRadius.card),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.showSearch)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
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
                              },
                            ),
                    ),
                    onChanged: (v) =>
                        setState(() => _query = v.trim().toLowerCase()),
                  ),
                ),
              ),
            Flexible(
              child: visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No matches.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      children: [
                        for (final item in visible)
                          item.isHeader
                              ? Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    10,
                                    14,
                                    4,
                                  ),
                                  child: Text(
                                    item.label.toUpperCase(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
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
      ),
    );

    // CompositedTransformFollower: the compositor re-anchors the panel to
    // the LIVE field position every frame. Static coordinates went stale
    // the moment the dialog/sheet underneath reflowed (keyboard opening),
    // leaving the panel floating away from its field.
    return DisposeScope(
      disposables: [_searchCtrl],
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: widget.link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 4),
              child: panel,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(PickerItem<T> item, ColorScheme scheme) {
    final isSelected = widget.selected != null && item.value == widget.selected;
    return Semantics(
      button: true,
      selected: isSelected,
      child: InkWell(
        key: isSelected ? _selectedKey : null,
        onTap: () => Navigator.pop(context, PickerResult<T>(item.value)),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: isSelected ? scheme.primary.withValues(alpha: 0.12) : null,
          child: Row(
            children: [
              if (item.leading != null) ...[
                item.leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: isSelected
                      ? const TextStyle(fontWeight: FontWeight.w600)
                      : null,
                ),
              ),
              if (isSelected)
                Icon(Icons.check, size: 16, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// Form-field anchor for [showAnchoredPicker]: renders through the app's
/// InputDecoration theme so it is indistinguishable from the dropdown
/// fields it replaces, but opens the compact anchored panel instead of the
/// stock full-height menu.
///
/// Stateful for one reason: the [LayerLink] gluing the open panel to this
/// field must survive rebuilds — recreated per-build it would unlink (and
/// hide) the panel the moment anything rebuilt underneath it.
class AppDropdownField<T> extends StatefulWidget {
  final List<PickerItem<T>> items;
  final T? value;
  final ValueChanged<T?> onChanged;
  final String label;
  final String? hint;

  /// null = automatic (search appears when >8 selectable items).
  final bool? searchable;

  const AppDropdownField({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    required this.label,
    this.hint,
    this.searchable,
  });

  @override
  State<AppDropdownField<T>> createState() => _AppDropdownFieldState<T>();
}

class _AppDropdownFieldState<T> extends State<AppDropdownField<T>> {
  final _link = LayerLink();

  @override
  Widget build(BuildContext context) {
    // The null-valued item ("Unassigned") is a real selection — find the
    // item by value, treating null-as-value distinctly from no-items-match.
    final selectedItem = widget.items
        .where((i) => !i.isHeader && i.value == widget.value)
        .firstOrNull;
    final hint = widget.hint;
    return CompositedTransformTarget(
      link: _link,
      child: Builder(
        builder: (fieldContext) => InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: () async {
            final result = await showAnchoredPicker<T>(
              anchorContext: fieldContext,
              link: _link,
              items: widget.items,
              selected: widget.value,
              searchable: widget.searchable,
            );
            if (result != null) widget.onChanged(result.value);
          },
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: widget.label,
              suffixIcon: const Icon(Icons.arrow_drop_down),
            ),
            isEmpty: selectedItem == null,
            child: selectedItem == null
                ? (hint == null ? null : Text(hint, maxLines: 1))
                : Row(
                    children: [
                      if (selectedItem.leading != null) ...[
                        selectedItem.leading!,
                        const SizedBox(width: 10),
                      ],
                      Flexible(
                        child: Text(
                          selectedItem.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
