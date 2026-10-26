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

/// A group page's heading that is its own tip. Left-aligned: stretched
/// across the list, the whole row would open the tip.
class _PageHeading extends StatelessWidget {
  final Widget label;
  final InfoTip tip;

  const _PageHeading({required this.label, required this.tip});

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: InfoLabel(label: label, tip: tip),
  );
}

/// Theme, dark theme, accent colour, the tilt glow, the app icon and the
/// month the year starts in.
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
        _PageHeading(
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
          subtitle: (m) => switch (m) {
            ThemeMode.system => "Follows your phone's light or dark setting",
            ThemeMode.light => 'Always light, whatever the phone uses',
            ThemeMode.dark => 'Always dark, whatever the phone uses',
          },
        ),
        const SizedBox(height: 24),
        _PageHeading(
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
        _PageHeading(
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
          radius: BorderRadius.circular(AppRadius.card),
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
        const SizedBox(height: 24),
        _PageHeading(
          label: Text(
            'Year starts in',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          tip: const InfoTip(
            title: 'Year starts in',
            message:
                "Where the dashboard's Year view and the year report start. "
                'April gives the Indian financial year, April to March, '
                'shown as FY 2026-27.',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'The first month of the year the dashboard adds up.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        _RadioSetting<YearStart>(
          options: [for (final y in YearStart.values) (y, y.label)],
          selected: settings.yearStart,
          onChanged: (y) => context.read<SettingsProvider>().setYearStart(y),
          subtitle: (y) => switch (y) {
            YearStart.january => 'Calendar year, January to December',
            YearStart.april => 'Financial year, April to March',
          },
        ),
      ],
    );
  }
}

/// Automatic SMS import frequency and notification capture. The Settings
/// root only offers this page where [SmsSource.isSupported].
class _SmsImportPage extends StatelessWidget {
  const _SmsImportPage();

  /// Every SMS listens for new messages, which takes the Receive SMS
  /// permission; without it the setting stays as it was.
  Future<void> _choose(BuildContext context, AutoImportFrequency f) async {
    final settings = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    if (f == AutoImportFrequency.everySms &&
        !await BackgroundImportScheduler.requestReceiveSms()) {
      showAppToastOn(
        messenger,
        "Android didn't allow reading new SMS, which Every SMS needs.",
        tone: AppToastTone.error,
      );
      return;
    }
    await settings.setAutoImport(f);
  }

  @override
  Widget build(BuildContext context) {
    final autoImport = context.select<SettingsProvider, AutoImportFrequency>(
      (s) => s.autoImport,
    );
    final filters = context.select<FinanceProvider, int>(
      (f) => f.importRules.length,
    );

    return SettingsGroupPage(
      title: 'SMS import',
      children: [
        _PageHeading(
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
                'scan. Daily and Weekly also scan about every 6 hours with '
                'the app closed. Every SMS: each new SMS is imported about a '
                'minute after it arrives, even with the app closed, and it '
                'needs the Receive SMS permission too. The first scan '
                'reaches back 30 days. It needs SMS permission; without '
                'it, the scan is skipped. New rows wait in the review '
                'sheet, and duplicates are skipped. When more than 5 are '
                'waiting, a notification says how many.',
          ),
        ),
        _RadioSetting<AutoImportFrequency>(
          options: [for (final f in AutoImportFrequency.values) (f, f.label)],
          selected: autoImport,
          onChanged: (f) => _choose(context, f),
          // The heading's tip has the detail: background checks, the
          // permission, the review sheet.
          subtitle: (f) => switch (f) {
            AutoImportFrequency.off => 'Never scans on its own',
            AutoImportFrequency.everyOpen =>
              'Each time you open or return to the app',
            AutoImportFrequency.daily => 'First open each day',
            AutoImportFrequency.weekly =>
              '7 days after the last automatic scan',
            AutoImportFrequency.everySms =>
              'Each new SMS, about a minute after it arrives',
          },
        ),
        const SizedBox(height: 12),
        // The import rules, on the Cockpit's Import tab.
        FrostedPanel(
          radius: BorderRadius.circular(AppRadius.card),
          child: ListTile(
            leading: const Icon(Icons.block),
            title: const Text('SMS filters'),
            subtitle: Text(
              'What gets ignored or flagged · $filters '
              '${filters == 1 ? 'rule' : 'rules'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => goCockpitImport(context),
          ),
        ),
        const SizedBox(height: 12),
        const _NotificationCaptureTile(),
      ],
    );
  }
}

/// Settings, Notifications: the alert switches, with the one sentence on
/// when alerts are checked.
class NotificationsPage extends StatelessWidget {
  const NotificationsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsGroupPage(
      title: 'Notifications',
      children: [
        Text(
          'Alerts are checked when the app opens and about every 6 hours '
          'while it is closed.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        const NotificationSwitches(),
      ],
    );
  }
}

/// The open credit cards, each opening its [CardRewardsPage].
class _CardRewardsListPage extends StatelessWidget {
  const _CardRewardsListPage();

  @override
  Widget build(BuildContext context) {
    final cards = context
        .watch<FinanceProvider>()
        .openAccounts
        .where((a) => a.isCard)
        .toList();
    final theme = Theme.of(context);
    return SettingsGroupPage(
      title: 'Card rewards',
      children: [
        Text(
          'What each credit card pays back. Its card on Accounts shows what '
          'the current cycle has earned.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        if (cards.isEmpty)
          Text(
            'No credit cards yet. Add one on Accounts, then set its rewards '
            'here.',
            style: theme.textTheme.bodyMedium,
          ),
        for (final (i, card) in cards.indexed)
          GroupedSurface(
            first: i == 0,
            last: i == cards.length - 1,
            child: ListTile(
              leading: Icon(card.icon),
              title: Text(card.displayName),
              subtitle: Text(switch (card.rewards) {
                null => 'Not set up',
                final r => cardRewardsSummary(r),
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openCardRewards(context, card.id),
            ),
          ),
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
        _PageHeading(
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
                'deleted. To restore, use Data, Import, From Google Drive.',
          ),
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

/// Version and the manual update check.
class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) {
    return const SettingsGroupPage(title: 'About', children: [_AboutSection()]);
  }
}
