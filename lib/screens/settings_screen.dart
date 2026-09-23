import 'dart:async';

import 'package:flutter/material.dart';
// ScrollCacheExtent is not yet re-exported through material.dart.
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/app_icon_service.dart';
import '../services/app_lock_service.dart';
import '../services/backup_service.dart';
import '../services/drive_backup_service.dart';
import '../services/sms_import_service.dart';
import '../services/update_service.dart';
import '../services/notification_source.dart';
import '../services/sms_source.dart';
import '../utils/app_palettes.dart';
import '../utils/app_theme.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/undo_snackbar.dart';
import '../widgets/hue_color_picker.dart';
import '../widgets/glossy.dart';
import '../widgets/info_tip.dart';
import 'app_nav.dart';
import 'classifiers_screen.dart';

part 'settings_pages.dart';

/// List padding shared by the Settings root and its group pages. The bottom
/// inset lets the last tile clear the system gesture bar on edge-to-edge
/// devices.
EdgeInsets _settingsPadding(BuildContext context) => EdgeInsets.fromLTRB(
  16,
  16,
  16,
  16 + MediaQuery.viewPaddingOf(context).bottom,
);

/// Settings root: one row per group, each opening a [SettingsGroupPage]
/// (built in settings_pages.dart). A group with no supported section on
/// this device is left out.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final groups = <(IconData, String, String, WidgetBuilder)>[
      (
        Icons.palette_outlined,
        'Appearance',
        AppIconService().isSupported
            ? 'Theme, accent colour, glow, app icon'
            : 'Theme, accent colour, glow',
        (_) => const _AppearancePage(),
      ),
      if (SmsSource().isSupported)
        (
          Icons.sms_outlined,
          'SMS import',
          'Scan frequency, notification capture',
          (_) => const _SmsImportPage(),
        ),
      (
        Icons.cloud_outlined,
        'Backup and data',
        'Google Drive, export, import, delete',
        (_) => const _BackupDataPage(),
      ),
      (
        Icons.lock_outline,
        'Privacy',
        'App lock, hide income',
        (_) => const _PrivacyPage(),
      ),
      (
        Icons.category_outlined,
        'Categories and rules',
        'Category order, Cockpit',
        (_) => const _CategoriesRulesPage(),
      ),
      (
        Icons.info_outline,
        'About',
        'Version, updates',
        (_) => const _AboutPage(),
      ),
    ];

    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          padding: _settingsPadding(context),
          children: [
            for (final (i, (icon, title, gist, page)) in groups.indexed) ...[
              if (i > 0) const SizedBox(height: 12),
              FrostedPanel(
                radius: BorderRadius.circular(20),
                child: ListTile(
                  leading: Icon(icon),
                  title: Text(title),
                  subtitle: Text(gist),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      Navigator.push(context, MaterialPageRoute(builder: page)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Radio rows for a choice-type setting: one dense row per option. Replaced
/// the line-tab GlassSegmented here — tabs read as navigation, not as
/// picking a stored option.
class _RadioSetting<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onChanged;

  const _RadioSetting({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => RadioGroup<T>(
    groupValue: selected,
    onChanged: (v) {
      if (v != null) onChanged(v);
    },
    // Transparent Material: ListTiles paint splashes on the NEAREST
    // Material, and the AmbientBackground ColoredBox behind this page
    // otherwise hides them (same fix FrostedPanel documents).
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          for (final (value, label) in options)
            RadioListTile<T>(
              dense: true,
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              title: Text(label),
              value: value,
            ),
        ],
      ),
    ),
  );
}

/// Google Drive backup: connect / status / frequency / back-up-now.
/// Mirrors the Orbit app's section. Scheduled uploads run silently from
/// app launch, so the one thing this section must never hide is a recorded
/// failure — hence the amber banner.
class _DriveBackupSection extends StatefulWidget {
  const _DriveBackupSection();

  @override
  State<_DriveBackupSection> createState() => _DriveBackupSectionState();
}

class _DriveBackupSectionState extends State<_DriveBackupSection> {
  bool _loading = true;
  GoogleSignInAccount? _account;
  String _freq = 'daily';
  DateTime? _lastBackup;
  String? _lastError;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
    // "Last backup: Just now" goes stale while Settings sits open — the
    // relative label is recomputed per build, but nothing was rebuilding.
    _clockTick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Timer? _clockTick;

  @override
  void dispose() {
    _clockTick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final svc = context.read<DriveBackupService>();
    GoogleSignInAccount? account;
    try {
      account = await svc.currentUser;
    } catch (_) {
      // Platform channel unavailable (tests / unsupported OS) → signed out.
      account = null;
    }
    final freq = await svc.getFrequency();
    final last = await svc.lastBackupAt();
    final error = await svc.lastError();
    if (!mounted) return;
    setState(() {
      _account = account;
      _freq = freq;
      _lastBackup = last;
      _lastError = error;
      _loading = false;
    });
  }

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    final svc = context.read<DriveBackupService>();
    GoogleSignInAccount? account;
    try {
      account = await svc.signIn();
    } catch (e) {
      account = null;
      debugPrint('Drive sign-in failed: $e');
    }
    if (!mounted) return;
    if (account == null) {
      showAppToastOn(
        messenger,
        'Google sign-in was cancelled or failed. Check that the OAuth '
        'client is set up for this app, then try again.',
        tone: AppToastTone.error,
        duration: const Duration(seconds: 5),
      );
      return;
    }
    // Full reload, not just the account: last-backup / error state is
    // account-scoped and must reflect the newly connected account.
    await _load();
  }

  Future<void> _disconnect() async {
    await context.read<DriveBackupService>().signOut();
    // signOut cleared the account-scoped prefs; re-read everything so a
    // stale "backup failed" banner can't sit above "Connect Google account".
    if (mounted) await _load();
  }

  Future<void> _backupNow() async {
    if (_uploading) return;
    final messenger = ScaffoldMessenger.of(context);
    final svc = context.read<DriveBackupService>();
    final finance = context.read<FinanceProvider>();
    final settings = context.read<SettingsProvider>();
    setState(() => _uploading = true);
    try {
      final name = await svc.uploadNow(
        finance,
        settings: settings.toBackupMap(),
      );
      final last = await svc.lastBackupAt();
      if (!mounted) return;
      setState(() {
        _lastBackup = last;
        _lastError = null; // success clears the recorded failure
      });
      showAppToastOn(
        messenger,
        'Saved to Drive: $name',
        tone: AppToastTone.success,
        icon: Icons.cloud_done_outlined,
      );
    } catch (e) {
      // uploadNow also persisted the failure; mirror it locally so the
      // banner appears without leaving and re-entering Settings.
      if (mounted) setState(() => _lastError = '$e');
      showAppToastOn(
        messenger,
        'Drive backup failed: $e',
        tone: AppToastTone.error,
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const FrostedPanel(
        radius: BorderRadius.all(Radius.circular(AppRadius.section)),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: LinearProgressIndicator(),
        ),
      );
    }
    return FrostedPanel(
      radius: BorderRadius.circular(AppRadius.section),
      child: Column(
        children: [
          if (_lastError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.cloud_off_outlined,
                      size: 18,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'The last Drive backup failed: $_lastError',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_account == null)
            ListTile(
              leading: const Icon(Icons.cloud_off_outlined),
              title: const Text('Connect Google account'),
              subtitle: const Text(
                'Off until connected — nothing is uploaded.',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: _connect,
            )
          else ...[
            ListTile(
              leading: Icon(Icons.cloud_done_outlined, color: scheme.primary),
              title: Text(
                _account!.email,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                'Last backup: '
                '${DriveBackupService.formatLastBackup(_lastBackup)}',
              ),
              trailing: InfoLabel(
                label: TextButton(
                  onPressed: _disconnect,
                  child: const Text('Disconnect'),
                ),
                tip: const InfoTip(
                  title: 'Disconnect',
                  message:
                      'Signs this app out of Google Drive. Backups already in '
                      'your Drive stay there.',
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: const InfoLabel(
                label: Text('Frequency'),
                tip: InfoTip(
                  title: 'Frequency',
                  message:
                      'Checked when the app starts fresh. Returning to it does '
                      'not check, so backups run only on days you open the '
                      'app. '
                      'Daily waits at least 23 hours, weekly 6 days, monthly '
                      '28 days. An empty ledger is never uploaded on schedule.',
                ),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(DriveBackupService.freqLabel(_freq)),
                  const Icon(Icons.arrow_drop_down),
                ],
              ),
              onTap: () async {
                final result = await showPickerSheet<String>(
                  context: context,
                  title: 'Frequency',
                  items: [
                    for (final f in const ['daily', 'weekly', 'monthly'])
                      PickerItem(
                        value: f,
                        label: DriveBackupService.freqLabel(f),
                      ),
                  ],
                  selected: _freq,
                );
                final v = result?.value;
                if (v == null || !context.mounted) return;
                // Optimistic like every other setting: the visible value
                // must not snap back while the prefs write completes.
                setState(() => _freq = v);
                await context.read<DriveBackupService>().setFrequency(v);
              },
            ),
            ListTile(
              leading: _uploading
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : const Icon(Icons.cloud_upload_outlined),
              title: const InfoLabel(
                label: Text('Back up now'),
                tip: InfoTip(
                  title: 'Back up now',
                  message:
                      'Uploads right away, even when there are no '
                      'transactions. Only 7 backups are kept, so repeated '
                      'empty uploads can push out older good ones.',
                ),
              ),
              enabled: !_uploading,
              onTap: _backupNow,
            ),
          ],
        ],
      ),
    );
  }
}

/// Launcher-icon picker: previews of the default (provided) receipt logo and
/// the alternates, applied via Android activity-alias switching.
class _AppIconSection extends StatefulWidget {
  const _AppIconSection();

  @override
  State<_AppIconSection> createState() => _AppIconSectionState();
}

class _AppIconSectionState extends State<_AppIconSection> {
  // Survives State re-creation so a rebuilt section renders the settled
  // value immediately instead of flashing 'default' until the async check
  // returns — a late size/style change mid-scroll jerks the list.
  static String? _lastKnownCurrent;

  final _service = AppIconService();
  late String _current = _lastKnownCurrent ?? 'default';

  @override
  void initState() {
    super.initState();
    _service.current().then((v) {
      _lastKnownCurrent = v;
      if (mounted) setState(() => _current = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        for (final icon in kAppIcons)
          InkWell(
            borderRadius: BorderRadius.circular(AppRadius.card),
            onTap: () async {
              // Only mark the tile selected when the launcher switch really
              // landed — on locked-down ROMs the call fails and the old
              // unconditional update showed the wrong icon as current (and
              // cached it in the static) until the next Settings visit.
              final messenger = ScaffoldMessenger.of(context);
              final ok = await _service.select(icon.key);
              if (!ok) {
                showAppToastOn(
                  messenger,
                  'Could not change the app icon on this device.',
                  tone: AppToastTone.error,
                );
                return;
              }
              _lastKnownCurrent = icon.key;
              if (mounted) setState(() => _current = icon.key);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    border: Border.all(
                      color: icon.key == _current
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: icon.key == _current ? 2.5 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.control),
                    child: Image.asset(
                      icon.previewAsset,
                      width: 64,
                      height: 64,
                      // Decode at display size: the source PNGs are 256×256
                      // and this settings list keeps every child resident.
                      cacheWidth: 128,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  icon.label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: icon.key == _current
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One dark theme choice: a miniature of its background, a card in its text
/// colours, and its accent, framed like the app-icon tiles.
class _PaletteTile extends StatelessWidget {
  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  const _PaletteTile({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = palette.colors;
    Widget bar(double width, Color color) => Container(
      width: width,
      height: 5,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: '${palette.label} theme',
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.card),
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: Container(
                width: 76,
                height: 64,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: c.bg,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(22, c.textSecondary),
                          const SizedBox(height: 4),
                          bar(36, c.textPrimary),
                        ],
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(child: bar(double.infinity, c.surface2)),
                        const SizedBox(width: 5),
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              palette.label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Enable/status tile for notification capture — the only way to import RCS
/// business-chat alerts, which are invisible to the SMS provider. Re-checks
/// access when the app resumes (the grant happens on a system settings page).
class _NotificationCaptureTile extends StatefulWidget {
  const _NotificationCaptureTile();

  @override
  State<_NotificationCaptureTile> createState() =>
      _NotificationCaptureTileState();
}

class _NotificationCaptureTileState extends State<_NotificationCaptureTile>
    with WidgetsBindingObserver {
  // Survive State re-creation: the granted/denied layouts differ in height,
  // and a late flip after rebuild jerks the list mid-scroll.
  static bool? _lastKnownAccess;
  static DateTime? _lastKnownCapture;

  final _source = NotificationSource();
  bool? _hasAccess = _lastKnownAccess;
  DateTime? _lastCapture = _lastKnownCapture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final v = await _source.hasAccess();
    final last = v ? await _source.lastCapture() : null;
    _lastKnownAccess = v;
    _lastKnownCapture = last;
    if (mounted) {
      setState(() {
        _hasAccess = v;
        _lastCapture = last;
      });
    }
  }

  static String _fmtDateTime(DateTime t) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${t.day} ${months[t.month - 1]}, $hh:$mm';
  }

  /// "never", "just now", "38 min ago", "5 h ago" or "3 Jul, 14:20".
  String _lastCaptureLabel() {
    final t = _lastCapture;
    if (t == null) return 'no alert captured yet';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'last alert just now';
    if (d.inHours < 1) return 'last alert ${d.inMinutes} min ago';
    if (d.inHours < 24) return 'last alert ${d.inHours} h ago';
    return 'last alert ${_fmtDateTime(t)}';
  }

  /// Millis-or-zero prefs value → "never" or a short timestamp.
  static String _fmtMillis(Object? v) {
    final ms = (v is num) ? v.toInt() : 0;
    if (ms <= 0) return 'never';
    return _fmtDateTime(DateTime.fromMillisecondsSinceEpoch(ms));
  }

  /// Per-stage capture-chain state, so "nothing imported" reports pinpoint
  /// the dead stage without another debugging round-trip.
  Future<void> _showDiagnostics() async {
    final d = await _source.diagnostics();
    if (!mounted) return;
    final connectedAt = (d['connectedAt'] as num?)?.toInt() ?? 0;
    final disconnectedAt = (d['disconnectedAt'] as num?)?.toInt() ?? 0;
    final String connected;
    if (connectedAt <= 0) {
      connected = 'never connected — capture is not running';
    } else if (disconnectedAt > connectedAt) {
      connected = 'disconnected ${_fmtMillis(disconnectedAt)}';
    } else {
      connected = 'connected since ${_fmtMillis(connectedAt)}';
    }
    final rows = <(String, String)>[
      ('Listener', connected),
      ('Notifications seen', '${d['eventsTotal'] ?? 0}'),
      ('From messaging apps', '${d['eventsWatched'] ?? 0}'),
      ('With an amount (₹/Rs)', '${d['eventsMoney'] ?? 0}'),
      ('Captured', '${d['storedTotal'] ?? 0}'),
      ('Waiting for import', '${d['bufferSize'] ?? 0}'),
      ('Last capture', _fmtMillis(d['lastCapture'])),
      ('Last message seen', (d['lastSample'] as String?) ?? '—'),
    ];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('RCS capture diagnostics'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (label, value) in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: Theme.of(ctx).textTheme.labelMedium),
                      Text(value, style: Theme.of(ctx).textTheme.bodySmall),
                    ],
                  ),
                ),
              Text(
                'Counts reset only when app data is cleared. If "last message '
                'seen" shows hidden/redacted text instead of the bank alert, '
                'Android is withholding sensitive notification content from '
                'the listener.',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _source.openAccessSettings(),
            child: const Text('System settings'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final granted = _hasAccess == true;
    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(
          granted
              ? Icons.notifications_active
              : Icons.notifications_off_outlined,
          color: granted ? scheme.primary : scheme.onSurfaceVariant,
        ),
        title: InfoLabel(
          label: const Text('Capture RCS alerts'),
          tip: InfoTip(
            title: 'Capture RCS alerts',
            message:
                'Picks up bank alerts from messaging-app notifications that '
                'mention an amount in ₹, Rs or INR, which the SMS scan cannot '
                'see. It works even when automatic import is Off: captured '
                'alerts import each time you open the app. To stop it, revoke '
                'notification access in Android settings.',
            link: InfoLink(
              prompt: 'Change what this app can read?',
              label: 'Open notification access',
              onTap: (_) => _source.openAccessSettings(),
            ),
          ),
        ),
        subtitle: Text(
          granted
              ? 'On — new bank alerts are captured as they arrive and added '
                    'on the next import; older messages cannot be backfilled '
                    '(${_lastCaptureLabel()}). Tap for diagnostics.'
              : 'RCS chats (verified senders like "Yes Bank") are not '
                    'readable as SMS. Grant notification access to capture '
                    'them as they arrive. No backfill of older messages.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        trailing: granted
            ? null
            : FilledButton(
                onPressed: () => _source.openAccessSettings(),
                child: const Text('Enable'),
              ),
        onTap: granted ? _showDiagnostics : null,
      ),
    );
  }
}

/// Export / import / delete-all, moved here from the home screen's ⋮ menu.
/// The handlers are ports of the old home_screen methods; format choice now
/// goes through the standard picker sheet instead of nested submenus.
class _DataSection extends StatefulWidget {
  const _DataSection();

  @override
  State<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends State<_DataSection> {
  final _smsImport = SmsImportService();

  Future<void> _pickAndRun({
    required String title,
    required List<PickerItem<String>> items,
  }) async {
    final result = await showPickerSheet<String>(
      context: context,
      title: title,
      items: items,
    );
    final action = result?.value;
    if (action != null && mounted) await _handleBackupAction(action);
  }

  /// Runs [work] behind a modal spinner so a full-ledger export/import isn't
  /// a frozen, feedback-free screen. The barrier also blocks a second tap
  /// while the first operation is still writing.
  Future<T> _withBusy<T>(String label, Future<T> Function() work) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: Dialog(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                  const SizedBox(width: 16),
                  Flexible(child: Text(label)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    try {
      return await work();
    } finally {
      if (navigator.mounted) navigator.pop();
    }
  }

  /// Which dates a CSV/PDF export should cover. `cancelled` aborts the
  /// export; a null range with cancelled=false means everything.
  Future<({bool cancelled, DateTimeRange? range})> _askExportRange() async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Export which dates?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: const Text('All transactions'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'range'),
            child: const Text('Choose dates…'),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return (cancelled: true, range: null);
    if (choice == 'all') return (cancelled: false, range: null);
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (picked == null) return (cancelled: true, range: null);
    return (cancelled: false, range: picked);
  }

  Future<void> _handleBackupAction(String action) async {
    final messenger = ScaffoldMessenger.of(context);
    final finance = context.read<FinanceProvider>();
    try {
      switch (action) {
        case 'export_json':
          final path = await _withBusy(
            'Building backup…',
            () => BackupService.exportJson(
              finance,
              settings: context.read<SettingsProvider>(),
            ),
          );
          if (path != null && path.isNotEmpty) {
            showAppToastOn(
              messenger,
              'Saved to $path',
              tone: AppToastTone.success,
              icon: Icons.download_done,
            );
          }
        case 'export_pdf':
          final sel = await _askExportRange();
          if (sel.cancelled) return;
          final path = await _withBusy(
            'Building PDF report…',
            () => BackupService.exportPdf(finance, range: sel.range),
          );
          if (path != null && path.isNotEmpty) {
            showAppToastOn(
              messenger,
              'Saved to $path',
              tone: AppToastTone.success,
              icon: Icons.download_done,
            );
          }
        case 'delete_all':
          final includeConfig = await _confirmDeleteAll();
          if (includeConfig == null) return;
          // Same busy barrier as every other branch: the wipe persists up to
          // seven blobs, and no second action must land mid-write.
          await _withBusy('Deleting…', () async {
            await finance.clearAll(includeConfig: includeConfig);
            await _smsImport.resetLastScan();
          });
          showAppToastOn(
            messenger,
            includeConfig
                ? 'All data deleted; rules & categories reset to defaults.'
                : 'Transactions and accounts deleted. Rules, categories, '
                      'groups and budgets were kept.',
            tone: AppToastTone.removal,
            icon: Icons.delete_forever_outlined,
          );
        case 'export_csv':
          final sel = await _askExportRange();
          if (sel.cancelled) return;
          final path = await _withBusy(
            'Building CSV…',
            () => BackupService.exportCsv(finance, range: sel.range),
          );
          if (path != null && path.isNotEmpty) {
            showAppToastOn(
              messenger,
              'Saved to $path',
              tone: AppToastTone.success,
              icon: Icons.download_done,
            );
          }
        case 'import_json':
          final replace = await _askImportMode();
          if (replace == null) return;
          final txAdded = await _withBusy(
            'Importing backup…',
            () => BackupService.importJson(
              finance,
              replace: replace,
              settings: context.read<SettingsProvider>(),
            ),
          );
          if (txAdded == null) return; // picker cancelled
          showAppToastOn(
            messenger,
            replace
                ? 'Restored $txAdded transactions.'
                : 'Imported $txAdded new transactions.',
            tone: AppToastTone.success,
            icon: Icons.file_download_done,
          );
        case 'import_csv':
          final replace = await _askImportMode();
          if (replace == null) return;
          final added = await _withBusy(
            'Importing CSV…',
            () => BackupService.importCsv(finance, replace: replace),
          );
          if (added == null) return; // picker cancelled
          showAppToastOn(
            messenger,
            replace
                ? 'Replaced transactions with $added rows from CSV.'
                : 'Imported $added new transactions from CSV.',
            tone: AppToastTone.success,
            icon: Icons.file_download_done,
          );
        case 'import_drive':
          final driveService = context.read<DriveBackupService>();
          // Interactive sign-in only when the silent path has no account —
          // and before the busy dialog, so the account chooser isn't
          // fighting a barrier.
          var account = await driveService.currentUser;
          if (!mounted) return;
          account ??= await driveService.signIn();
          if (account == null) {
            showAppToastOn(
              messenger,
              'Google sign-in was cancelled or failed.',
              tone: AppToastTone.error,
            );
            return;
          }
          final replaceFromDrive = await _askImportMode();
          if (replaceFromDrive == null || !mounted) return;
          final settingsProvider = context.read<SettingsProvider>();
          final restored = await _withBusy('Restoring cloud backup…', () async {
            final backup = await driveService.downloadLatest();
            final added = await finance.importData(
              backup.data,
              replace: replaceFromDrive,
            );
            // Same rule as the file import: the preference block only
            // applies on replace — merge keeps the device's own settings.
            final block = backup.data['settings'];
            if (replaceFromDrive && block is Map<String, dynamic>) {
              await settingsProvider.applyBackupMap(block);
            }
            return (backup: backup, added: added);
          });
          showAppToastOn(
            messenger,
            replaceFromDrive
                ? 'Restored ${restored.added} transactions from the '
                      'cloud backup '
                      '(${DriveBackupService.formatLastBackup(restored.backup.createdAt)}).'
                : 'Imported ${restored.added} new transactions from the '
                      'cloud backup.',
            tone: AppToastTone.success,
            icon: Icons.cloud_download_outlined,
          );
      }
    } on FormatException catch (e) {
      showAppToastOn(
        messenger,
        'Import failed: ${e.message}',
        tone: AppToastTone.error,
      );
    } catch (_) {
      // Any import action, not just JSON — a failed CSV import used to report
      // that an *export* had failed.
      showAppToastOn(
        messenger,
        action.startsWith('import')
            ? 'Import failed: could not read that file.'
            : 'Export failed.',
        tone: AppToastTone.error,
      );
    }
  }

  /// null = cancelled; otherwise whether rules & config are wiped too.
  Future<bool?> _confirmDeleteAll() async {
    // Confirmed + pending, without filtering or sorting either list.
    final count = context.read<FinanceProvider>().transactionCount;
    var includeConfig = false;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          scrollable: true,
          icon: Icon(
            Icons.warning_amber_rounded,
            color: Theme.of(ctx).colorScheme.error,
          ),
          title: const Text('Delete all data?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This permanently deletes $count transaction${count == 1 ? '' : 's'} '
                'and all accounts. '
                'This cannot be undone — consider exporting a JSON backup first.',
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text(
                  'Also delete rules, categories, groups '
                  '& budgets',
                ),
                subtitle: const Text('Resets them to the built-in defaults'),
                value: includeConfig,
                onChanged: (v) => setState(() => includeConfig = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, includeConfig),
              child: const Text('Delete everything'),
            ),
          ],
        ),
      ),
    );
  }

  /// true = replace everything, false = merge, null = cancelled.
  /// States the blast radius in numbers — the sibling delete-all dialog
  /// counts what it destroys, and Replace destroys exactly as much.
  Future<bool?> _askImportMode() {
    final finance = context.read<FinanceProvider>();
    // Confirmed + pending: Replace clears the whole ledger, and
    // `transactions` alone leaves out rows still awaiting review.
    final txCount = finance.transactionCount;
    final acctCount = finance.accounts.length;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // Two paragraphs + three actions overflow a landscape viewport.
        scrollable: true,
        title: const Text('Import backup'),
        content: Text(
          'Merge keeps your current data and adds entries from the backup '
          'that are not already present.\n\n'
          'Replace deletes your current $txCount transaction'
          '${txCount == 1 ? '' : 's'} and $acctCount account'
          '${acctCount == 1 ? '' : 's'} (including manually created ones), '
          'then restores only the backup.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
  }

  /// The export picker, shared by the Export tile and the Delete all tip's
  /// "Export a backup" link.
  void _showExport() => _pickAndRun(
    title: 'Export',
    items: const [
      PickerItem(
        value: 'export_json',
        label: 'Backup (JSON)',
        leading: Icon(Icons.data_object, size: 20),
      ),
      PickerItem(
        value: 'export_csv',
        label: 'Transactions (CSV)',
        leading: Icon(Icons.table_chart_outlined, size: 20),
      ),
      PickerItem(
        value: 'export_pdf',
        label: 'Report (PDF)',
        leading: Icon(Icons.picture_as_pdf_outlined, size: 20),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const InfoLabel(
              label: Text('Export…'),
              tip: InfoTip(
                title: 'Export…',
                message:
                    'Backup (JSON): everything needed to restore, without SMS '
                    'text. Transactions (CSV): confirmed and pending rows, for '
                    'spreadsheets. Report (PDF): confirmed rows only, and it '
                    'shows income totals even with Hide income on.',
              ),
            ),
            subtitle: Text(
              'Backup (JSON), transactions (CSV) or a PDF report',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showExport,
          ),

          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const InfoLabel(
              label: Text('Import…'),
              tip: InfoTip(
                title: 'Import…',
                message:
                    'Merge adds only what is new; anything already in the app '
                    'wins. Replace clears transactions and accounts first; a '
                    'JSON or Drive backup also replaces your rules, '
                    'categories, budgets and settings. A CSV without row ids '
                    'gets new ids, so merging the same CSV twice creates '
                    'duplicates. Imported rows do not carry their original '
                    'SMS text.',
              ),
            ),
            subtitle: Text(
              'From a backup file, a CSV, or Google Drive',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickAndRun(
              title: 'Import',
              items: const [
                PickerItem(
                  value: 'import_json',
                  label: 'Backup (JSON)',
                  leading: Icon(Icons.data_object, size: 20),
                ),
                PickerItem(
                  value: 'import_csv',
                  label: 'Transactions (CSV)',
                  leading: Icon(Icons.table_chart_outlined, size: 20),
                ),
                PickerItem(
                  value: 'import_drive',
                  label: 'From Google Drive',
                  leading: Icon(Icons.cloud_download_outlined, size: 20),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: scheme.error),
            title: InfoLabel(
              label: Text(
                'Delete all data',
                style: TextStyle(color: scheme.error),
              ),
              tip: InfoTip(
                title: 'Delete all data',
                message:
                    'Always deletes transactions and accounts. With the box '
                    'ticked, it also resets rules, import rules, categories, '
                    'groups and budgets to the defaults and clears reminders '
                    'and merchant names. It never touches your monthly cap, '
                    'theme, other settings or Drive backups. The next SMS scan '
                    're-imports the last 30 days.',
                link: InfoLink(
                  prompt: 'Want a copy first?',
                  label: 'Export a backup',
                  onTap: (_) => _showExport(),
                ),
              ),
            ),
            onTap: () => _handleBackupAction('delete_all'),
          ),
        ],
      ),
    );
  }
}

/// App lock toggle. Enabling requires one successful authentication first:
/// a device that cannot authenticate must never be able to arm a lock it
/// cannot open. Disabling requires one too, so someone holding the unlocked
/// phone (the lock only re-arms after 2 minutes away) cannot switch it off.
/// The exception is a device that can no longer authenticate at all (screen
/// lock removed): the lock could never be opened again, so it turns off
/// without a prompt.
class _PrivacySection extends StatefulWidget {
  const _PrivacySection();

  @override
  State<_PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends State<_PrivacySection> {
  final _lock = AppLockService();
  bool _busy = false;

  Future<void> _toggle(bool on) async {
    if (_busy) return;
    final settings = context.read<SettingsProvider>();
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (!on) {
        // No prompt possible (screen lock removed since): the lock could
        // never be opened again, so let it go rather than trap the user.
        if (await _lock.canAuthenticate() == false ||
            await _lock.authenticate()) {
          await settings.setAppLock(false);
        }
        return;
      }
      if (!await _lock.isSupported()) {
        showAppToastOn(
          messenger,
          'Set up a screen lock (PIN or fingerprint) on this device first.',
        );
        return;
      }
      if (await _lock.authenticate()) await settings.setAppLock(true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = context.select<SettingsProvider, bool>((s) => s.appLock);
    final hideIncome = context.select<SettingsProvider, bool>(
      (s) => s.hideIncome,
    );
    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Column(
        children: [
          _TipSwitchTile(
            icon: Icons.lock_outline,
            label: 'App lock',
            tip:
                'Asks for your fingerprint or device PIN when the app opens, '
                'or returns after 2 minutes away. It does not hide '
                'notification text, the home-screen widget or the app preview '
                'in recent apps. This setting is not included in backups.',
            subtitle: 'Require fingerprint or device PIN when opening the app',
            value: enabled,
            onChanged: _busy ? null : _toggle,
          ),
          _TipSwitchTile(
            icon: Icons.visibility_off_outlined,
            label: 'Hide income',
            tip:
                'Hides income totals on the dashboard, in month headers and '
                'in the balance breakdown. The balance figure still shows, '
                'and exports and the PDF report still include income.',
            subtitle:
                'Hide income totals on the dashboard and in monthly '
                'summaries. Individual transactions still show their amounts.',
            value: hideIncome,
            onChanged: (v) => context.read<SettingsProvider>().setHideIncome(v),
          ),
        ],
      ),
    );
  }
}

/// A switch row with an "i" after its label. Not a SwitchListTile: that
/// merges every descendant into one semantics node, which would swallow the
/// tip's own button (a screen reader could only toggle the switch). The row
/// tap still toggles, as a SwitchListTile's does.
class _TipSwitchTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tip;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _TipSwitchTile({
    required this.icon,
    required this.label,
    required this.tip,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return ListTile(
      enabled: onChanged != null,
      leading: Icon(icon),
      title: InfoLabel(
        label: Text(label),
        tip: InfoTip(title: label, message: tip),
      ),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      // Named so the switch is not announced as an unlabelled toggle.
      trailing: Semantics(
        label: label,
        child: Switch(value: value, onChanged: onChanged),
      ),
      onTap: onChanged == null ? null : () => onChanged(!value),
    );
  }
}

/// Version + manual update check against the GitHub releases API.
class _AboutSection extends StatefulWidget {
  const _AboutSection();

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  /// Settled-value convention (see _AppIconSectionState): the version can't
  /// change within a process, and a static survives the tile being rebuilt,
  /// so the async lookup runs once and never shifts tile height again.
  static String? _lastKnownVersion;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    if (_lastKnownVersion == null) _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        // Version name only: the Android build number in parentheses read
        // as noise next to it.
        setState(() => _lastKnownVersion = info.version);
      }
    } catch (_) {
      // Leave the placeholder; the tile is informational only.
    }
  }

  Future<void> _checkForUpdates() async {
    if (_checking) return;
    setState(() => _checking = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await UpdateService().check();
      if (!mounted) return;
      switch (result) {
        case UpToDate(:final currentVersion):
          showAppToastOn(
            messenger,
            "You're on the latest version ($currentVersion).",
            tone: AppToastTone.success,
            icon: Icons.verified_outlined,
          );
        case UpdateAvailable(:final latestTag, :final htmlUrl):
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Update available'),
              content: Text(
                'Version $latestTag is out. The release page on GitHub has '
                'the APK.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Not now'),
                ),
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    launchUrl(
                      Uri.parse(htmlUrl),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  child: const Text('View release'),
                ),
              ],
            ),
          );
        case CheckFailed(:final message):
          showAppToastOn(messenger, message, tone: AppToastTone.error);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Version'),
            subtitle: Text(_lastKnownVersion ?? '…'),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: InfoLabel(
              label: const Text('Check for updates'),
              tip: InfoTip(
                title: 'Check for updates',
                message:
                    'Compares this version with the latest release on GitHub. '
                    'It does not download or install anything; View release '
                    'opens the page in your browser.',
                link: InfoLink(
                  prompt: 'See what changed in each version?',
                  label: 'All releases on GitHub',
                  onTap: (_) => launchUrl(
                    Uri.parse(UpdateService.releasesPageUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
            ),
            subtitle: Text(
              'Compares with the latest GitHub release',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.chevron_right),
            onTap: _checking ? null : _checkForUpdates,
          ),
        ],
      ),
    );
  }
}
