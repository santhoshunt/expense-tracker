import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/app_lock_service.dart';
import 'glossy.dart';

/// Whether returning to the foreground should re-lock: enabled, previously
/// backgrounded, and away longer than [threshold]. Pure — the gate's only
/// decision, kept testable without lifecycle plumbing.
bool shouldLock({
  required bool enabled,
  required DateTime? backgroundedAt,
  required DateTime now,
  Duration threshold = const Duration(minutes: 2),
}) {
  if (!enabled || backgroundedAt == null) return false;
  return now.difference(backgroundedAt) >= threshold;
}

/// Gates [child] behind the system biometric/PIN prompt when app lock is
/// enabled. Locks on cold start and re-locks after more than ~2 minutes in
/// the background; quick app switches pass through.
///
/// Wraps the app's whole Navigator (MaterialApp.builder), so the lock
/// screen covers every route: pages, sheets, dialogs and tooltips opened on
/// top used to stay visible over it. While locked the app stays alive but
/// offstage (not painted, hit-tested or announced), so unlocking returns to
/// the same page, tab and open popup.
class LockGate extends StatefulWidget {
  final Widget child;

  /// Injectable for tests; defaults to the real local_auth wrapper.
  final AppLockService? service;

  /// Injectable for tests (time away decides a re-lock).
  final DateTime Function() clock;

  const LockGate({
    super.key,
    required this.child,
    this.service,
    this.clock = DateTime.now,
  });

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  late final AppLockService _service = widget.service ?? AppLockService();
  late final SettingsProvider _settings;
  bool _locked = false;

  /// False until SettingsProvider has loaded: only then is the app lock
  /// preference known. Until then the child is the app's loading screen,
  /// which shows nothing private.
  bool _decided = false;
  DateTime? _backgroundedAt;

  /// The unlock prompt pauses/resumes the app itself — lifecycle events
  /// arriving while it is up must not re-arm the lock.
  bool _authInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settings = context.read<SettingsProvider>();
    if (_settings.loaded) {
      _decide();
    } else {
      _settings.addListener(_onSettings);
    }
  }

  void _onSettings() {
    if (!_settings.loaded) return;
    _settings.removeListener(_onSettings);
    setState(_decide);
  }

  /// The cold-start lock, once the preference is known.
  void _decide() {
    _decided = true;
    _locked = _settings.appLock;
    if (_locked) _attemptUnlock();
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettings);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authInProgress) return;
    // paused, not inactive: permission dialogs and the notification shade
    // pass through inactive without ever leaving the app.
    if (state == AppLifecycleState.paused) {
      _backgroundedAt ??= widget.clock();
      return;
    }
    if (state != AppLifecycleState.resumed || !_decided) return;
    final relock = shouldLock(
      enabled: _settings.appLock,
      backgroundedAt: _backgroundedAt,
      now: widget.clock(),
    );
    _backgroundedAt = null;
    if (relock && !_locked) {
      // A focused field would keep its keyboard up over the lock screen.
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => _locked = true);
      _attemptUnlock();
    }
  }

  Future<void> _attemptUnlock() async {
    if (_authInProgress) return;
    _authInProgress = true;
    try {
      final ok = await _service.authenticate();
      if (ok && mounted) setState(() => _locked = false);
    } finally {
      _authInProgress = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // One tree either way, so the app keeps its state across a lock.
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: _locked,
          child: TickerMode(enabled: !_locked, child: widget.child),
        ),
        if (_locked) _lockScreen(context),
      ],
    );
  }

  Widget _lockScreen(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 56, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                'Expense Tracker is locked',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _attemptUnlock,
                icon: const Icon(Icons.fingerprint),
                label: const Text('Unlock'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
