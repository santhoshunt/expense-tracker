part of 'settings_screen.dart';

/// One Settings group on its own page, framed like the Settings root: the
/// ambient backdrop, a titled app bar and the same padded list.
class SettingsGroupPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsGroupPage({
    super.key,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: Text(title)),
        body: ListView(
          // Keep every child laid out. The stateful sections (app icons,
          // notification capture, Drive backup) finish an async check after
          // their first build and change height. With the default cache
          // extent, a section scrolled out is destroyed, re-created on
          // scroll-in and re-runs that check, and the late height change
          // evicts it again: a loop that snapped the scroll position ~60lp
          // every ~150ms while dragging. A group page is short, so laying
          // all of it out is cheap. 100k px, not double.infinity: the
          // viewport inflates its SEMANTICS clip by the cache extent, and an
          // infinite rect trips a semantics assertion (seen under widget
          // tests).
          scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
          padding: _settingsPadding(context),
          children: children,
        ),
      ),
    );
  }
}

/// Theme, dark theme, accent colour, the tilt glow and the app icon.
class _AppearancePage extends StatelessWidget {
  const _AppearancePage();

  @override
  Widget build(BuildContext context) {
    // Watched here, not in the Settings root: a pushed route is built once,
    // so values read by the root would go stale on this page.
    final settings = context.watch<SettingsProvider>();

    return SettingsGroupPage(
      title: 'Appearance',
      children: [
        InfoLabel(
          label: Text('Theme', style: Theme.of(context).textTheme.titleMedium),
          tip: const InfoTip(
            title: 'Theme',
            message:
                "System follows your phone's light or dark setting. A "
                'new install starts in Dark.',
          ),
        ),
        _RadioSetting<ThemeMode>(
          options: const [
            (ThemeMode.system, 'System'),
            (ThemeMode.light, 'Light'),
            (ThemeMode.dark, 'Dark'),
          ],
          selected: settings.mode,
          onChanged: (m) => context.read<SettingsProvider>().setMode(m),
        ),
        const SizedBox(height: 24),
        InfoLabel(
          label: Text(
            'Dark theme',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Dark theme',
            message:
                'Changes backgrounds, cards and text in dark mode. '
                "Picking a theme also replaces your accent colour with the "
                "theme's own, even a custom one.",
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Used in dark mode. Picking one also sets its accent colour.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final p in AppPalette.values)
              _PaletteTile(
                palette: p,
                selected: p == settings.palette,
                onTap: () => context.read<SettingsProvider>().setPalette(p),
              ),
          ],
        ),
        const SizedBox(height: 24),
        InfoLabel(
          label: Text(
            'Accent colour',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Accent colour',
            message:
                'Colours buttons, highlights and selected items in light '
                "and dark mode. Theme uses the current dark theme's "
                'accent. Picking another dark theme later resets the '
                "accent to that theme's.",
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Used for buttons, highlights and selected states. Theme '
          'follows the dark theme\'s own accent.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        HueColorPicker(
          title: 'Accent',
          value: settings.accent,
          onChanged: (c) => context.read<SettingsProvider>().setAccent(c),
          none: settings.palette.colors.accent,
          noneLabel: 'Theme',
          noneIsNeutral: false,
          customTitle: 'Accent colour',
          cell: 42,
        ),
        const SizedBox(height: 24),
        FrostedPanel(
          radius: BorderRadius.circular(20),
          child: _TipSwitchTile(
            icon: Icons.blur_on,
            label: 'Move glow with tilt',
            tip:
                'The glow behind each screen drifts a little as you tilt the '
                'phone. It uses the motion sensor, which needs no '
                'permission, and stops while the app is locked, in the '
                "background, or when Android's Remove animations is on.",
            subtitle: 'Shift the background glow as you tilt the phone',
            value: settings.tiltGlow,
            onChanged: (v) => context.read<SettingsProvider>().setTiltGlow(v),
          ),
        ),
        if (AppIconService().isSupported) ...[
          const SizedBox(height: 24),
          Text('App icon', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'The launcher icon on your home screen. Switching may briefly '
            'close the app on some devices.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          const _AppIconSection(),
        ],
      ],
    );
  }
}

/// Automatic SMS import frequency and notification capture. The Settings
/// root only offers this page where [SmsSource.isSupported].
class _SmsImportPage extends StatelessWidget {
  const _SmsImportPage();

  @override
  Widget build(BuildContext context) {
    final autoImport = context.select<SettingsProvider, AutoImportFrequency>(
      (s) => s.autoImport,
    );

    return SettingsGroupPage(
      title: 'SMS import',
      children: [
        InfoLabel(
          label: Text(
            'Automatic SMS import',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Automatic SMS import',
            link: InfoLink(
              prompt: 'Imports landing in the wrong category?',
              label: 'Open transaction rules',
              onTap: goCockpitRules,
            ),
            message:
                'Scans your SMS inbox when you open or return to the '
                'app, as often as this setting allows. Daily: the first '
                'open each day. Weekly: 7 days after the last automatic '
                'scan. The first scan reaches back 30 days. It needs SMS '
                'permission; without it, the scan is skipped. New rows '
                'wait in the review queue, and duplicates are skipped.',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Scans new bank messages when you open the app. Daily runs '
          'on the first launch of each day, weekly every 7 days. '
          'Imports still land in the review queue.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _RadioSetting<AutoImportFrequency>(
          options: [for (final f in AutoImportFrequency.values) (f, f.label)],
          selected: autoImport,
          onChanged: (f) => context.read<SettingsProvider>().setAutoImport(f),
        ),
        const SizedBox(height: 12),
        const _NotificationCaptureTile(),
      ],
    );
  }
}

/// Google Drive backup and the file-based export, import and wipe. They
/// share a page because the Drive description points at Data's import.
class _BackupDataPage extends StatelessWidget {
  const _BackupDataPage();

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: 'Backup and data',
      children: [
        InfoLabel(
          label: Text(
            'Cloud backup',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Cloud backup',
            message:
                'Uploads a backup file to the Expense Tracker Backups '
                'folder in your Google Drive. It holds transactions, '
                'accounts, rules, categories, budgets and most settings, '
                'but not SMS text, app lock, the app icon, the tilt glow '
                'or this schedule. The newest 7 backups are kept; older ones are '
                'deleted.',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Backs up your data to an "Expense Tracker Backups" folder in '
          'your Google Drive on the chosen schedule. Backups include '
          'transactions, rules and settings, but not the original SMS '
          'text. Restore from Data, Import, From Google Drive.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        const _DriveBackupSection(),
        const SizedBox(height: 24),
        Text('Data', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Export or import your data as files, or wipe everything.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        const _DataSection(),
      ],
    );
  }
}

/// App lock and hide income. The page title stands in for the old
/// "Privacy" heading.
class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: 'Privacy',
      children: [
        Text(
          'The lock re-arms on launch and after the app has been in the '
          'background for a couple of minutes.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        const _PrivacySection(),
      ],
    );
  }
}

/// Category order for the add and edit sheets, and the way into Cockpit.
class _CategoriesRulesPage extends StatelessWidget {
  const _CategoriesRulesPage();

  @override
  Widget build(BuildContext context) {
    final categoryOrder = context.select<SettingsProvider, CategoryOrder>(
      (s) => s.categoryOrder,
    );

    return SettingsGroupPage(
      title: 'Categories and rules',
      children: [
        InfoLabel(
          label: Text(
            'Category order',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Category order',
            link: InfoLink(
              prompt: 'Want different categories?',
              label: 'Edit categories',
              onTap: goCockpitCategories,
            ),
            message:
                'Sets the order of the category list when you add or edit '
                'a transaction. The first category in the list is picked '
                'by default for a new transaction.',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'How the category list is ordered when adding or editing a '
          'transaction. "Most used" ranks by the amounts of the last '
          'three months.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _RadioSetting<CategoryOrder>(
          options: [for (final o in CategoryOrder.values) (o, o.label)],
          selected: categoryOrder,
          onChanged: (o) =>
              context.read<SettingsProvider>().setCategoryOrder(o),
        ),
        const SizedBox(height: 24),
        Text('Cockpit', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        FrostedPanel(
          radius: BorderRadius.circular(20),
          child: ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Open Cockpit'),
            subtitle: const Text(
              'Rules, import filters, categories, budgets and reminders',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ClassifiersScreen()),
            ),
          ),
        ),
      ],
    );
  }
}

/// Version and the manual update check.
class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) {
    return const SettingsGroupPage(title: 'About', children: [_AboutSection()]);
  }
}
