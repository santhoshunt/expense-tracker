import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/settings_provider.dart';
import '../services/update_downloader.dart';
import '../services/update_installer.dart';
import '../services/update_service.dart';
import 'undo_snackbar.dart';

/// The app's own package, named in the sheet's list of checks.
const kAppPackage = 'com.fabletest.expense_tracker';

/// Lets the user pick one of [updates] and install it: the exact download
/// URL and the checks made before installing are on screen before the tap.
/// Nothing downloads or installs until Download & install.
Future<void> showUpdateSheet(
  BuildContext context,
  UpdateList updates, {
  UpdateInstaller? installer,
  UpdateDownloader? downloader,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => UpdateSheet(
    updates: updates,
    installer: installer ?? ChannelUpdateInstaller.instance,
    downloader: downloader ?? UpdateDownloader(),
  ),
);

enum _Step { choose, needsPermission, downloading, installing }

class UpdateSheet extends StatefulWidget {
  final UpdateList updates;
  final UpdateInstaller installer;
  final UpdateDownloader downloader;

  const UpdateSheet({
    super.key,
    required this.updates,
    required this.installer,
    required this.downloader,
  });

  @override
  State<UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<UpdateSheet> with WidgetsBindingObserver {
  late ReleaseOption _picked = widget.updates.newer.first;
  final Set<String> _notesOpen = {};
  _Step _step = _Step.choose;
  int _received = 0;
  DownloadCancel? _cancel;

  /// True from the tap until the download has started: a second tap in
  /// that window must not start a second download.
  bool _starting = false;

  /// The running (or winding-down cancelled) attempt; a new one waits for
  /// it, so two attempts never share the updates folder.
  Future<void>? _attempt;

  /// Completes when the app is back in front; see [_whenResumed].
  Completer<void>? _resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cancel?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final resumed = _resumed;
    _resumed = null;
    resumed?.complete();
    // Back from the system settings page: if the switch is now on, the
    // user is returned to the list to tap Download & install again.
    if (_step != _Step.needsPermission) return;
    widget.installer.canInstall().then((ok) {
      if (ok && mounted) setState(() => _step = _Step.choose);
    });
  }

  /// Android shows its confirm screen only for an app in front, so an
  /// install finished downloading in the background waits for the return.
  Future<void> _whenResumed() async {
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) return;
    await (_resumed ??= Completer<void>()).future;
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _start() async {
    // A second tap can land before the rebuild hides the button.
    if (_starting || _step != _Step.choose) return;
    _starting = true;
    try {
      await _attempt;
      if (!await widget.installer.canInstall()) {
        if (mounted) setState(() => _step = _Step.needsPermission);
        return;
      }
      if (!mounted) return;
      setState(() {
        _step = _Step.downloading;
        _received = 0;
      });
    } finally {
      _starting = false;
    }
    final run = _attempt = _run(_picked, _cancel = DownloadCancel());
    await run;
    if (identical(_attempt, run)) _attempt = null;
  }

  Future<void> _run(ReleaseOption option, DownloadCancel cancel) async {
    final messenger = ScaffoldMessenger.of(context);
    final settings = context.read<SettingsProvider>();
    String? problem;
    try {
      final apk = await widget.downloader.download(
        option,
        cancel: cancel,
        onProgress: (received, _) {
          if (mounted && !cancel.cancelled) {
            setState(() => _received = received);
          }
        },
      );
      if (cancel.cancelled || !mounted) return;
      setState(() => _step = _Step.installing);
      await _whenResumed();
      if (cancel.cancelled || !mounted) return;
      await settings.setUpdateInstallingTag(option.tag);
      problem = await widget.installer.install(apk);
      if (problem != null) await settings.setUpdateInstallingTag(null);
    } on UpdateDownloadException catch (e) {
      if (cancel.cancelled) return;
      problem = e.message;
    } finally {
      // The install session holds its own copy once committed.
      await widget.downloader.cleanup();
    }
    // Null: the install is under way (success closes the app) or the
    // system stopped reporting; either way the sheet has nothing left.
    if (mounted) Navigator.of(context).pop();
    if (problem == null) return;
    showAppToastOn(
      messenger,
      problem,
      tone: AppToastTone.error,
      actionLabel: 'Release page',
      onAction: () => launchUrl(
        Uri.parse(option.pageUrl),
        mode: LaunchMode.externalApplication,
      ),
      duration: const Duration(seconds: 8),
    );
  }

  void _cancelDownload() {
    _cancel?.cancel();
    setState(() => _step = _Step.choose);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final busy = _step == _Step.downloading || _step == _Step.installing;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Choose a version',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              Text('On ${widget.updates.currentVersion}', style: muted),
            ],
          ),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: _picked.tag,
            onChanged: (tag) {
              if (busy || tag == null) return;
              setState(
                () => _picked = widget.updates.newer.firstWhere(
                  (o) => o.tag == tag,
                ),
              );
            },
            child: Column(
              children: [
                for (final o in widget.updates.newer) _versionTile(o, muted),
              ],
            ),
          ),
          const Divider(height: 24),
          Text('Downloads from', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(_picked.downloadUrl, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            "then GitHub's file storage "
            '(release-assets.githubusercontent.com)',
            style: muted,
          ),
          const SizedBox(height: 12),
          Text(
            'Before installing, the app checks',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          for (final check in const [
            'It is this app ($kAppPackage)',
            "It is signed with this app's key",
            'It is newer than the installed version',
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 16,
                    color: muted?.color,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(check, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          ..._stepBody(theme, muted),
        ],
      ),
    );
  }

  Widget _versionTile(ReleaseOption o, TextStyle? muted) {
    final date = o.publishedAt == null
        ? null
        : DateFormat('d MMM yyyy').format(o.publishedAt!);
    final open = _notesOpen.contains(o.tag);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RadioListTile<String>(
          value: o.tag,
          contentPadding: EdgeInsets.zero,
          title: Text(o.tag),
          subtitle: Text([?date, '${_mb(o.sizeBytes)} MB'].join(' · ')),
          secondary: o.notes.isEmpty
              ? null
              : IconButton(
                  tooltip: open ? 'Hide notes' : 'Show notes',
                  icon: Icon(open ? Icons.expand_less : Icons.expand_more),
                  onPressed: () => setState(
                    () =>
                        open ? _notesOpen.remove(o.tag) : _notesOpen.add(o.tag),
                  ),
                ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(48, 0, 8, 8),
            child: Text(o.notes, style: muted),
          ),
      ],
    );
  }

  List<Widget> _stepBody(ThemeData theme, TextStyle? muted) {
    switch (_step) {
      case _Step.choose:
        return [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Download & install'),
              ),
            ],
          ),
        ];
      case _Step.needsPermission:
        return [
          Text(
            'Android needs your OK first. Turn on "Allow from this source" '
            'for Expense Tracker, then come back here. You can turn it off '
            'again after updating.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _step = _Step.choose),
                child: const Text('Back'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: widget.installer.openInstallSettings,
                child: const Text('Open settings'),
              ),
            ],
          ),
        ];
      case _Step.downloading:
        final total = _picked.sizeBytes;
        return [
          LinearProgressIndicator(value: total == 0 ? null : _received / total),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Downloading ${_mb(_received)} of ${_mb(total)} MB',
                  style: muted,
                ),
              ),
              TextButton(
                onPressed: _cancelDownload,
                child: const Text('Cancel'),
              ),
            ],
          ),
        ];
      case _Step.installing:
        return [
          const LinearProgressIndicator(),
          const SizedBox(height: 8),
          Text(
            'Checking and installing. The app closes when it is done; open '
            'it again to finish.',
            style: muted,
          ),
        ];
    }
  }
}
