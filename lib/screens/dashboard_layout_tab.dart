import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dashboard_layout.dart';
import '../providers/settings_provider.dart';
import '../utils/app_theme.dart';
import '../widgets/glossy.dart';

/// Cockpit, Dashboard: one page's sections in their order, each with a
/// switch to show or hide it. Drag a row to move the section.
class DashboardLayoutTab extends StatelessWidget {
  final DashboardPage page;
  const DashboardLayoutTab({super.key, required this.page});

  Future<void> _reset(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset this page?'),
        content: Text(
          page == DashboardPage.overview
              ? 'Sections go back to their first order, all shown.'
              : 'Sections go back to their first order, all shown, and the '
                    'folded ones fold again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true) await settings.resetDashboardLayout(page);
  }

  @override
  Widget build(BuildContext context) {
    // The key changes with any order, hidden or fold change.
    context.select<SettingsProvider, String>((s) => s.dashboardLayoutKey);
    final settings = context.read<SettingsProvider>();
    final layout = settings.dashboardLayout(page);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final folds = page != DashboardPage.overview;
    // The one scrollable: dragging a row to the edge scrolls it, which a
    // list nested in another list does not.
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
      buildDefaultDragHandles: false,
      // The lifted row: its own rounded panel with a shadow, not the
      // default square slab (which also spans the gap under the row).
      proxyDecorator: (child, _, animation) => Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            // Behind the card only, not the 8dp gap the row carries.
            Positioned.fill(
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: const [
                    BoxShadow(
                      blurRadius: 12,
                      offset: Offset(0, 4),
                      color: Color(0x33000000),
                    ),
                  ],
                ),
              ),
            ),
            child,
          ],
        ),
      ),
      header: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          folds
              ? 'Drag to reorder. The arrow sets whether a section starts '
                    'open or folded. Hidden sections leave the dashboard '
                    'until you show them again.'
              : 'Drag to reorder. Hidden sections leave the dashboard until '
                    'you show them again.',
          style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ),
      footer: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            // Starts on the cards' left edge.
            style: flushTextButtonStyle,
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reset to default'),
            onPressed: () => _reset(context),
          ),
        ),
      ),
      itemCount: layout.order.length,
      // The target index already allows for the removed row.
      onReorderItem: (from, to) {
        final order = [...layout.order];
        final s = order.removeAt(from);
        order.insert(to, s);
        settings.setDashboardOrder(page, order);
      },
      itemBuilder: (context, i) {
        final s = layout.order[i];
        final shown = !layout.hidden.contains(s);
        return Padding(
          key: ValueKey('layout-${s.name}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: FrostedPanel(
            radius: BorderRadius.circular(16),
            child: ListTile(
              leading: ReorderableDragStartListener(
                index: i,
                // A full-size target; the list gives screen readers its
                // own move actions.
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.drag_indicator),
                ),
              ),
              title: Text(s.label),
              // The fold arrow stays, disabled, while the section is
              // hidden, so the switch beside it never moves.
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (folds) _StartsOpen(section: s, enabled: shown),
                  Semantics(
                    label: 'Show ${s.label}',
                    child: Switch(
                      value: shown,
                      onChanged: (v) => settings.setSectionHidden(s, !v),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Whether a section starts open or folded on the dashboard, as a 48dp
/// arrow beside its switch: up while it starts open, down while it starts
/// folded. The same stored state as tapping the section's heading there, so
/// the two always agree. Disabled while the section is hidden.
class _StartsOpen extends StatelessWidget {
  final DashboardSection section;
  final bool enabled;
  const _StartsOpen({required this.section, required this.enabled});

  @override
  Widget build(BuildContext context) {
    final open = context.select<SettingsProvider, bool>(
      (s) => s.sectionOpen(section),
    );
    final settings = context.read<SettingsProvider>();
    void toggle() => settings.setSectionOpen(section, !open);
    // One button for a screen reader, named by the section: the tooltip
    // alone would not say which section it folds.
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: '${section.label}, starts ${open ? 'open' : 'folded'}',
      excludeSemantics: true,
      onTap: enabled ? toggle : null,
      child: IconButton(
        tooltip: open ? 'Starts open' : 'Starts folded',
        icon: Icon(open ? Icons.expand_less : Icons.expand_more),
        onPressed: enabled ? toggle : null,
      ),
    );
  }
}
