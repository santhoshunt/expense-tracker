import 'package:flutter/material.dart';

import '../utils/app_theme.dart';
import 'app_nav.dart';
import 'classifiers_screen.dart';
import 'settings_screen.dart';

/// The Dashboard's app-bar title: the shown month or year between its
/// arrows, then a Year (or Month) button that switches the view; tapping
/// the label opens the month picker. Driven by [AppNav.dashboardHeader],
/// which the Dashboard keeps current.
class DashboardMonthTitle extends StatelessWidget {
  const DashboardMonthTitle({super.key});

  @override
  Widget build(BuildContext context) {
    final header = AppNav.instance.dashboardHeader;
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
            // The label is still the picker's button, without the ▾ so it
            // keeps its width beside the switch.
            child: Semantics(
              button: true,
              hint: header.yearMode ? 'Pick a year' : 'Pick a month',
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadius.control),
                onTap: header.onPick == null
                    ? null
                    : () => header.onPick?.call(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  // Shrinks rather than cutting the month short on a
                  // narrow screen with large text.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      header.label,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
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
          // The Month or Year switch, in sight; the ⋮ entry with its tip
          // stays.
          Tooltip(
            message: header.yearMode ? 'Show Month view' : 'Show Year view',
            child: TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(48, 40),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: header.onToggleView == null
                  ? null
                  : () => header.onToggleView?.call(),
              child: Text(header.yearMode ? 'Month' : 'Year'),
            ),
          ),
        ],
      ),
    );
  }
}

/// The app bar's Settings button, just before the ⋮ menu on every tab.
class SettingsButton extends StatelessWidget {
  const SettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Settings',
      icon: const Icon(Icons.settings_outlined),
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      ),
    );
  }
}

/// The app bar's ⋮, the same two sections on every tab: "This page", the
/// entries the shown [tab] publishes through [AppNav.pageMenu], then "App":
/// Cockpit and Who owes you. A tab with no entries shows App alone. Settings is
/// its own button beside it ([SettingsButton]).
class HomeMenu extends StatelessWidget {
  /// The shown home tab (a kHomeTab* index).
  final int tab;

  const HomeMenu({super.key, required this.tab});

  /// One 44dp row. The height is a minimum, so the row grows with large
  /// text. The menu sizes itself to its widest row's own width, rounded up
  /// to Flutter's 56dp menu width step, so it follows its longest label.
  /// A row with [trailing] stretches its label to fill the menu, which puts
  /// the trailing at the right edge.
  static PopupMenuItem<VoidCallback> _item(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Widget? trailing,
  }) => PopupMenuItem(
    value: onTap,
    height: 44,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Builder(
      builder: (context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // The muted icon colour the ListTile rows had.
          Icon(
            icon,
            size: 20,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Flexible(
            fit: trailing == null ? FlexFit.loose : FlexFit.tight,
            child: Text(label),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ],
      ),
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
          _item(Icons.people_outline, 'Who owes you', () => goPeople(context)),
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
