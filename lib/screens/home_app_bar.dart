import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'app_nav.dart';
import 'classifiers_screen.dart';
import 'settings_screen.dart';

/// The Dashboard's app-bar title: the shown month or year between its
/// arrows; tapping the label opens the month picker. Driven by
/// [AppNav.dashboardHeader], which the Dashboard keeps current.
class DashboardMonthTitle extends StatelessWidget {
  const DashboardMonthTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final header = AppNav.instance.dashboardHeader;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: header,
      builder: (context, _) => Row(
        children: [
          IconButton(
            tooltip: header.yearMode ? 'Previous year' : 'Previous month',
            visualDensity: VisualDensity.compact,
            // Read on tap, not at build: the header swaps its callbacks
            // without a rebuild when the Dashboard changes or goes.
            onPressed: header.onPrev == null
                ? null
                : () => header.onPrev?.call(),
            icon: const Icon(Icons.chevron_left),
          ),
          Flexible(
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.control),
              onTap: header.onPick == null ? null : () => header.onPick?.call(),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Shrinks rather than cutting the month short on a
                    // narrow screen with large text.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          header.label,
                          maxLines: 1,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 22,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: header.yearMode ? 'Next year' : 'Next month',
            visualDensity: VisualDensity.compact,
            onPressed: header.onNext == null
                ? null
                : () => header.onNext?.call(),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

/// The app bar's ⋮, the same two sections on every tab: "This page", the
/// entries the shown [tab] publishes through [AppNav.pageMenu], then "App":
/// Cockpit, People and Settings. A tab with no entries shows App alone.
class HomeMenu extends StatelessWidget {
  /// The shown home tab (a kHomeTab* index).
  final int tab;

  const HomeMenu({super.key, required this.tab});

  static PopupMenuItem<VoidCallback> _item(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Widget? trailing,
  }) => PopupMenuItem(
    value: onTap,
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      trailing: trailing,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<VoidCallback>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert),
      onSelected: (run) => run(),
      // Read when the menu opens, so it lists the tab's latest entries: the
      // button itself shows nothing that changes, so it listens to nothing.
      itemBuilder: (_) {
        final page = AppNav.instance.pageMenu.actionsFor(tab);
        return [
          if (page.isNotEmpty) ...[
            const _MenuSectionLabel('This page'),
            for (final a in page)
              _item(a.icon, a.label, a.onTap, trailing: a.trailing),
            const PopupMenuDivider(),
          ],
          const _MenuSectionLabel('App'),
          _item(
            Icons.tune,
            'Cockpit',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ClassifiersScreen()),
            ),
          ),
          _item(Icons.people_outline, 'People', () => goPeople(context)),
          _item(
            Icons.settings_outlined,
            'Settings',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ];
      },
    );
  }
}

/// A section's small muted name in the ⋮ menu ("This page", "App"). Not
/// selectable: it only heads the rows under it.
class _MenuSectionLabel extends PopupMenuEntry<VoidCallback> {
  final String label;
  const _MenuSectionLabel(this.label);

  @override
  double get height => 32;

  @override
  bool represents(VoidCallback? value) => false;

  @override
  State<_MenuSectionLabel> createState() => _MenuSectionLabelState();
}

class _MenuSectionLabelState extends State<_MenuSectionLabel> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        // The rows' own inset, so the label lines up with their icons.
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Text(
          widget.label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
