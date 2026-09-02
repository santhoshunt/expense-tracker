import 'dart:async';

import 'package:flutter/material.dart';
// ScrollCacheExtent is not yet re-exported through material.dart.
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/spend_budget.dart';
import '../providers/finance_provider.dart';
import '../providers/settings_provider.dart';
import '../services/app_icon_service.dart';
import '../services/app_lock_service.dart';
import '../services/backup_service.dart';
import '../services/drive_backup_service.dart';
import '../services/sms_import_service.dart';
import '../services/update_service.dart';
import '../services/notification_service.dart';
import '../services/notification_source.dart';
import '../services/sms_source.dart';
import '../utils/app_theme.dart';
import '../utils/contrast.dart';
import '../utils/figma_palette.dart';
import '../utils/format.dart';
import '../widgets/picker_sheet.dart';
import '../widgets/budget_dialog.dart';
import '../widgets/color_picker_dialog.dart';
import '../widgets/glossy.dart';
import 'classifiers_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: AmbientBackground(
        child: ListView(
          // Keep every child laid out: with the default cache extent,
          // stateful children (RCS tile, app icons, budget) are destroyed on
          // scroll-out and re-created on scroll-in, re-running their async
          // initState checks. The late setState changes their height, which
          // shifts the layout enough to evict them again — a destroy/recreate
          // loop that snaps the scroll position ~60lp every ~150ms while
          // dragging (the "heavy glitch"). The page is ~25 light children,
          // so laying them all out permanently is cheap. 100k px, not
          // double.infinity: the viewport inflates its SEMANTICS clip by the
          // cache extent, and an infinite rect trips a semantics assertion
          // (seen under widget tests). The page is a few thousand px tall,
          // so 100k keeps every child alive just the same.
          scrollCacheExtent: const ScrollCacheExtent.pixels(100000),
          // Release focus as soon as a drag starts: a focused text field
          // (budget cap) keeps re-scrolling itself into view on every
          // keyboard-inset change, which fights the user's gesture.
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          // Bottom inset so the last tile clears the system gesture bar on
          // edge-to-edge devices.
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            16 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            Text('Theme', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            GlassSegmented<ThemeMode>(
              options: const [
                (ThemeMode.system, 'System'),
                (ThemeMode.light, 'Light'),
                (ThemeMode.dark, 'Dark'),
              ],
              selected: settings.mode,
              onChanged: (m) => context.read<SettingsProvider>().setMode(m),
            ),
            const SizedBox(height: 24),
            Text(
              'Accent colour',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Used for buttons, highlights and selected states.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final preset in kAccentPresets)
                  _AccentSwatch(
                    name: preset.name,
                    color: preset.color,
                    selected: preset.color == settings.accent,
                    onTap: () => context.read<SettingsProvider>().setAccent(
                      preset.color,
                    ),
                  ),
                _CustomAccentSwatch(
                  // "Custom" is active when the accent matches no preset.
                  selected: !kAccentPresets.any(
                    (p) => p.color == settings.accent,
                  ),
                  current: settings.accent,
                  onTap: () async {
                    final provider = context.read<SettingsProvider>();
                    final c = await showColorPickerDialog(
                      context,
                      initial: settings.accent,
                      title: 'Accent colour',
                    );
                    if (c != null) await provider.setAccent(c);
                  },
                ),
              ],
            ),
            if (SmsSource().isSupported) ...[
              const SizedBox(height: 24),
              Text(
                'Automatic SMS import',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Scans new bank messages when you open the app. Daily runs '
                'on the first launch of each day, weekly every 7 days. '
                'Imports still land in the review queue.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              GlassSegmented<AutoImportFrequency>(
                options: [
                  for (final f in AutoImportFrequency.values) (f, f.label),
                ],
                selected: settings.autoImport,
                onChanged: (f) =>
                    context.read<SettingsProvider>().setAutoImport(f),
              ),
              const SizedBox(height: 12),
              const _NotificationCaptureTile(),
            ],
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
            Text(
              'Budget & alerts',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Set a monthly spending cap and get notified as you approach it. '
              'Checks run while the app is open (after imports or edits) — '
              'there is no always-on background monitoring.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const _BudgetSection(),
            const SizedBox(height: 24),
            Text(
              'Custom budgets',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Extra monthly limits beside the overall cap — e.g. "Personal '
              'spending" that leaves out family categories. Progress shows '
              'on the dashboard.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const _CustomBudgetsSection(),
            const SizedBox(height: 24),
            Text(
              'Cloud backup',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Backs up everything to a "Expense Tracker Backups" folder in '
              'your Google Drive on the chosen schedule. Backups include '
              'transactions, rules and settings — not the original SMS '
              'text. Restore via menu → Import → From Google Drive.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const _DriveBackupSection(),
            const SizedBox(height: 24),
            Text('Data', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Export or import your data as files, or wipe everything. '
              'Moved here from the home screen menu.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const _DataSection(),
            const SizedBox(height: 24),
            Text('Privacy', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'The lock re-arms on launch and after the app has been in the '
              'background for a couple of minutes.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            const _PrivacySection(),
            const SizedBox(height: 24),
            Text('Categories', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            FrostedPanel(
              radius: BorderRadius.circular(20),
              child: ListTile(
                leading: const Icon(Icons.category_outlined),
                title: const Text('Categories & groups'),
                subtitle: const Text('Moved — manage them in Classifiers'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ClassifiersScreen(initialTab: 3),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('About', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            const _AboutSection(),
          ],
        ),
      ),
    );
  }
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
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Google sign-in was cancelled or failed. Check that the OAuth '
            'client is set up for this app, then try again.',
          ),
          duration: Duration(seconds: 5),
        ),
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
      messenger.showSnackBar(SnackBar(content: Text('Saved to Drive: $name')));
    } catch (e) {
      // uploadNow also persisted the failure; mirror it locally so the
      // banner appears without leaving and re-entering Settings.
      if (mounted) setState(() => _lastError = '$e');
      messenger.showSnackBar(
        SnackBar(content: Text('Drive backup failed: $e')),
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
              trailing: TextButton(
                onPressed: _disconnect,
                child: const Text('Disconnect'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('Frequency'),
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
              title: const Text('Back up now'),
              enabled: !_uploading,
              onTap: _backupNow,
            ),
          ],
        ],
      ),
    );
  }
}

/// User-defined spend limits: list with edit/delete plus an add flow.
/// The category/group pickers live in the dialog; progress renders on the
/// dashboard.
class _CustomBudgetsSection extends StatelessWidget {
  const _CustomBudgetsSection();

  @override
  Widget build(BuildContext context) {
    final finance = context.watch<FinanceProvider>();
    final scheme = Theme.of(context).colorScheme;

    String subtitle(SpendBudget b) {
      final n = b.categoryIds.length;
      final scope = b.mode == BudgetMode.include
          ? 'Only $n ${n == 1 ? 'category' : 'categories'}'
          : (n == 0
                ? 'All spending'
                : 'All except $n ${n == 1 ? 'category' : 'categories'}');
      return '$scope · ${fmtMoneyCompact(b.limit)}/month';
    }

    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (finance.budgets.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Text(
                  'No custom budgets yet.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final b in finance.budgets)
              ListTile(
                dense: true,
                onTap: () => showBudgetDialog(context, existing: b),
                leading: CircleAvatar(
                  radius: 16,
                  backgroundColor: scheme.primary.withValues(alpha: 0.15),
                  child: Icon(
                    Icons.track_changes,
                    color: categoryGlyphColor(context, scheme.primary),
                    size: 18,
                  ),
                ),
                title: Text(b.name),
                subtitle: Text(
                  subtitle(b),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                trailing: IconButton(
                  tooltip: 'Delete budget',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _confirmDelete(context, b),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add budget'),
                onPressed: () => showBudgetDialog(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, SpendBudget b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${b.name}"?'),
        content: const Text('Transactions are not affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<FinanceProvider>().deleteBudget(b.id);
    }
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
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not change the app icon on this device.',
                    ),
                  ),
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

/// Monthly cap amount, master alert toggle and the 80/90/overshoot threshold
/// switches. Enabling alerts requests notification permission.
class _BudgetSection extends StatefulWidget {
  const _BudgetSection();

  @override
  State<_BudgetSection> createState() => _BudgetSectionState();
}

class _BudgetSectionState extends State<_BudgetSection> {
  // Survives State re-creation: the "notifications blocked" row must not
  // appear/disappear a beat after the section rebuilds (height change
  // mid-scroll jerks the list).
  static bool? _lastKnownNotifEnabled;

  late final TextEditingController _capCtrl;
  late final FocusNode _capFocus;
  late final SettingsProvider _settings; // captured: dispose can't use context
  bool? _notifEnabled = _lastKnownNotifEnabled;

  @override
  void initState() {
    super.initState();
    _settings = context.read<SettingsProvider>();
    final budget = _settings.monthlyBudget;
    _capCtrl = TextEditingController(
      text: budget <= 0 ? '' : budget.toStringAsFixed(0),
    );
    // Commit on focus loss, NOT per keystroke: notifying listeners on every
    // character rebuilds the whole settings screen with the keyboard open,
    // and the keep-focused-field-visible logic then fights scroll gestures.
    _capFocus = FocusNode()..addListener(_onCapFocusChange);
    _checkNotifications();
  }

  void _onCapFocusChange() {
    if (!_capFocus.hasFocus) _commitCap();
  }

  /// Set when the cap field holds text that doesn't parse — the old
  /// `parseAmount(...) ?? 0` silently switched the budget off while the
  /// field kept showing whatever was typed.
  String? _capError;

  Future<void> _checkNotifications() async {
    final enabled = await NotificationService.instance.areEnabled;
    _lastKnownNotifEnabled = enabled;
    if (mounted) setState(() => _notifEnabled = enabled);
  }

  @override
  void deactivate() {
    // Commit here rather than in dispose(): committing notifies
    // SettingsProvider, and by dispose() this route is already being torn
    // down — marking the still-mounted Home widgets dirty at that point is a
    // framework error. setMonthlyBudget no-ops when the value is unchanged, so
    // an untouched field costs nothing.
    _commitCap(interactive: false);
    super.deactivate();
  }

  @override
  void dispose() {
    // Detach first: disposing a FocusNode fires a final focus-change, which
    // would otherwise re-enter _commitCap during teardown.
    _capFocus.removeListener(_onCapFocusChange);
    _capFocus.dispose();
    _capCtrl.dispose();
    super.dispose();
  }

  void _commitCap({bool interactive = true}) {
    // parseAmount, not double.tryParse: "50,000" must not read as null and
    // silently switch the budget off. Blank is the documented off switch;
    // anything else that fails to parse keeps the stored cap and shows an
    // error instead of quietly writing 0 ("50k" used to kill the budget
    // while the field still displayed 50k). During route teardown
    // (interactive: false) there is no screen to show the error on, so bad
    // input just keeps the previous cap.
    final text = _capCtrl.text.trim();
    final v = text.isEmpty ? 0.0 : parseAmount(text);
    if (v == null || v < 0) {
      if (interactive && mounted) {
        setState(() => _capError = 'Enter a number, e.g. 45000');
      }
      return;
    }
    if (_capError != null && interactive && mounted) {
      setState(() => _capError = null);
    }
    _settings.setMonthlyBudget(v);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    // Alerts apply to the monthly cap AND custom budgets — enable the switch
    // when either exists.
    final hasCustomBudgets = context.select<FinanceProvider, bool>(
      (f) => f.budgets.any((b) => b.limit > 0),
    );
    final hasCap = settings.monthlyBudget > 0 || hasCustomBudgets;

    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Padding(
        // Generous top inset: the cap field's floating label must not touch
        // the panel's clipped edge.
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
        child: Column(
          children: [
            TextField(
              controller: _capCtrl,
              focusNode: _capFocus,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: 'Monthly cap',
                prefixText: '₹ ',
                helperText: 'Leave blank to turn the budget off',
                errorText: _capError,
              ),
              // Unfocus (not just commit): pressing Done closes the keyboard
              // but leaves the field focused, and a focused field yanks the
              // scroll position back to itself ("keep caret visible") on
              // every later rebuild or inset change — the scroll-glitch bug.
              // Unfocusing also commits, via the focus listener.
              onSubmitted: (_) => _capFocus.unfocus(),
              onTapOutside: (_) => _capFocus.unfocus(),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Budget alerts'),
              subtitle: Text(
                hasCap
                    ? 'Notify as spending approaches the cap or a custom '
                          'budget limit'
                    : 'Set a cap or a custom budget to enable alerts',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              value: settings.budgetAlerts && hasCap,
              onChanged: hasCap
                  ? (on) async {
                      await context.read<SettingsProvider>().setBudgetAlerts(
                        on,
                      );
                      if (on) {
                        await NotificationService.instance.requestPermission();
                      }
                      await _checkNotifications();
                    }
                  : null,
            ),
            // Alerts silently go nowhere while notifications are blocked —
            // make that state visible with a fix-it button.
            if (hasCap && settings.budgetAlerts && _notifEnabled == false)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.notifications_off_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Notifications are blocked — alerts cannot be shown.',
                        // The one row here the user must not miss: bodyMedium
                        // + w600 (12px error-on-white was under AA).
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        await NotificationService.instance.requestPermission();
                        await _checkNotifications();
                      },
                      child: const Text('Allow'),
                    ),
                  ],
                ),
              ),
            if (hasCap && settings.budgetAlerts) ...[
              for (final (level, label) in const [
                (80, 'At 80% of budget'),
                (90, 'At 90% of budget'),
                (100, 'When over budget'),
              ])
                _ThresholdSwitch(
                  level: level,
                  label: label,
                  value: switch (level) {
                    80 => settings.alert80,
                    90 => settings.alert90,
                    _ => settings.alertOver,
                  },
                ),
            ],
            // Independent of the cap: card due dates and detected recurring
            // payments exist without any budget.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Payment reminders'),
              subtitle: Text(
                'Card bills and detected recurring payments, checked when '
                'the app opens',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              value: settings.upcomingReminders,
              onChanged: (on) async {
                await context.read<SettingsProvider>().setUpcomingReminders(on);
                if (on) {
                  await NotificationService.instance.requestPermission();
                }
                await _checkNotifications();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _ThresholdSwitch extends StatelessWidget {
  final int level;
  final String label;
  final bool value;
  const _ThresholdSwitch({
    required this.level,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      contentPadding: const EdgeInsets.only(left: 8),
      title: Text(label),
      value: value,
      onChanged: (on) =>
          context.read<SettingsProvider>().setAlertThreshold(level, on),
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
        title: const Text('Capture RCS alerts'),
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

class _AccentSwatch extends StatelessWidget {
  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _AccentSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: name,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2.5,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: selected ? 0.5 : 0.25),
                blurRadius: selected ? 12 : 6,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: selected ? Icon(Icons.check, color: onSwatch(color)) : null,
        ),
      ),
    );
  }
}

/// Rainbow swatch that opens the custom colour picker.
class _CustomAccentSwatch extends StatelessWidget {
  final bool selected;
  final Color current;
  final VoidCallback onTap;

  const _CustomAccentSwatch({
    required this.selected,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Custom',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: selected
                ? null
                : const SweepGradient(
                    colors: [
                      FigmaPalette.pink,
                      FigmaPalette.orange,
                      FigmaPalette.green,
                      FigmaPalette.blue,
                      FigmaPalette.purple,
                      FigmaPalette.pink,
                    ],
                  ),
            color: selected ? current : null,
            border: Border.all(
              color: selected ? scheme.onSurface : Colors.transparent,
              width: 2.5,
            ),
            boxShadow: [
              BoxShadow(
                color: current.withValues(alpha: selected ? 0.5 : 0.0),
                blurRadius: 12,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(
            selected ? Icons.check : Icons.colorize,
            // Selected = flat user-picked fill, so contrast is computed; the
            // unselected rainbow gradient always carries white fine.
            color: selected ? onSwatch(current) : Colors.white,
            size: 20,
          ),
        ),
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
            messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
          }
        case 'export_pdf':
          final path = await _withBusy(
            'Building PDF report…',
            () => BackupService.exportPdf(finance),
          );
          if (path != null && path.isNotEmpty) {
            messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
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
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                includeConfig
                    ? 'All data deleted; rules & categories reset to '
                          'defaults.'
                    : 'Transactions and accounts deleted. Rules, categories, '
                          'groups and budgets were kept.',
              ),
            ),
          );
        case 'export_csv':
          final path = await _withBusy(
            'Building CSV…',
            () => BackupService.exportCsv(finance),
          );
          if (path != null && path.isNotEmpty) {
            messenger.showSnackBar(SnackBar(content: Text('Saved to $path')));
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
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                replace
                    ? 'Restored $txAdded transactions.'
                    : 'Imported $txAdded new transactions.',
              ),
            ),
          );
        case 'import_csv':
          final replace = await _askImportMode();
          if (replace == null) return;
          final added = await _withBusy(
            'Importing CSV…',
            () => BackupService.importCsv(finance, replace: replace),
          );
          if (added == null) return; // picker cancelled
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                replace
                    ? 'Replaced transactions with $added rows from CSV.'
                    : 'Imported $added new transactions from CSV.',
              ),
            ),
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
            messenger.showSnackBar(
              const SnackBar(
                content: Text('Google sign-in was cancelled or failed.'),
              ),
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
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                replaceFromDrive
                    ? 'Restored ${restored.added} transactions from the '
                          'cloud backup '
                          '(${DriveBackupService.formatLastBackup(restored.backup.createdAt)}).'
                    : 'Imported ${restored.added} new transactions from the '
                          'cloud backup.',
              ),
            ),
          );
      }
    } on FormatException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Import failed: ${e.message}')),
      );
    } catch (_) {
      // Any import action, not just JSON — a failed CSV import used to report
      // that an *export* had failed.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            action.startsWith('import')
                ? 'Import failed: could not read that file.'
                : 'Export failed.',
          ),
        ),
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
    final txCount = finance.transactions.length;
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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Export…'),
            subtitle: Text(
              'Backup (JSON), transactions (CSV) or a PDF report',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickAndRun(
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
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Import…'),
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
            title: Text(
              'Delete all data',
              style: TextStyle(color: scheme.error),
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
/// cannot open. Disabling is immediate — reaching this screen already means
/// the app is unlocked.
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
    if (!on) {
      await settings.setAppLock(false);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      if (!await _lock.isSupported()) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Set up a screen lock (PIN or fingerprint) on this device '
              'first.',
            ),
          ),
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
    return FrostedPanel(
      radius: BorderRadius.circular(20),
      child: SwitchListTile(
        secondary: const Icon(Icons.lock_outline),
        title: const Text('App lock'),
        subtitle: Text(
          'Require fingerprint or device PIN when opening the app',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        value: enabled,
        onChanged: _busy ? null : _toggle,
      ),
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
        setState(
          () => _lastKnownVersion = '${info.version} (${info.buildNumber})',
        );
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
          messenger.showSnackBar(
            SnackBar(
              content: Text("You're on the latest version ($currentVersion)."),
            ),
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
          messenger.showSnackBar(SnackBar(content: Text(message)));
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
            title: const Text('Check for updates'),
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
