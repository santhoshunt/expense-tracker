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

enum _MenuItem {
  toggleYear,
  exportPdf,
  aboutYear,
  customise,
  cockpit,
  settings,
}

/// The app bar's ⋯: Cockpit and Settings on every tab and, [onDashboard],
/// what used to crowd the Dashboard's month row: Year view, the PDF export,
/// the Year view tip and Customise this page.
class HomeMenu extends StatelessWidget {
  final bool onDashboard;
  const HomeMenu({super.key, required this.onDashboard});

  @override
  Widget build(BuildContext context) {
    final header = AppNav.instance.dashboardHeader;
    PopupMenuItem<_MenuItem> item(_MenuItem v, IconData icon, String label) =>
        PopupMenuItem(
          value: v,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon),
            title: Text(label),
          ),
        );
    return ListenableBuilder(
      listenable: header,
      // The button's own context anchors the Year view tip.
      builder: (context, _) => PopupMenuButton<_MenuItem>(
        tooltip: 'More',
        icon: const Icon(Icons.more_vert),
        onSelected: (v) => switch (v) {
          _MenuItem.toggleYear => header.onToggleYear?.call(),
          _MenuItem.exportPdf => header.onExportPdf?.call(),
          _MenuItem.aboutYear => header.onAboutYear?.call(context),
          _MenuItem.customise => header.onCustomise?.call(),
          _MenuItem.cockpit => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const ClassifiersScreen()),
          ),
          _MenuItem.settings => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        },
        itemBuilder: (_) => [
          if (onDashboard) ...[
            item(
              _MenuItem.toggleYear,
              header.yearMode ? Icons.calendar_view_month : Icons.date_range,
              header.yearMode ? 'Month view' : 'Year view',
            ),
            item(
              _MenuItem.exportPdf,
              Icons.picture_as_pdf_outlined,
              header.yearMode
                  ? 'Export year report (PDF)'
                  : 'Export month report (PDF)',
            ),
            item(_MenuItem.aboutYear, Icons.info_outline, 'About Year view'),
            item(
              _MenuItem.customise,
              Icons.dashboard_customize_outlined,
              'Customise this page',
            ),
            const PopupMenuDivider(),
          ],
          item(_MenuItem.cockpit, Icons.tune, 'Cockpit'),
          item(_MenuItem.settings, Icons.settings_outlined, 'Settings'),
        ],
      ),
    );
  }
}
