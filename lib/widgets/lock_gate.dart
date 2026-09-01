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
class LockGate extends StatefulWidget {
  final Widget child;

  /// Injectable for tests; defaults to the real local_auth wrapper.
  final AppLockService? service;

  const LockGate({super.key, required this.child, this.service});

  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  late final AppLockService _service = widget.service ?? AppLockService();
  late bool _locked;
  DateTime? _backgroundedAt;

  /// The unlock prompt pauses/resumes the app itself — lifecycle events
  /// arriving while it is up must not re-arm the lock.
  bool _authInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Safe: _Root only builds this once SettingsProvider has loaded.
    _locked = context.read<SettingsProvider>().appLock;
    if (_locked) _attemptUnlock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_authInProgress) return;
    // paused, not inactive: permission dialogs and the notification shade
    // pass through inactive without ever leaving the app.
    if (state == AppLifecycleState.paused) {
      _backgroundedAt ??= DateTime.now();
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    final relock = shouldLock(
      enabled: context.read<SettingsProvider>().appLock,
      backgroundedAt: _backgroundedAt,
      now: DateTime.now(),
    );
    _backgroundedAt = null;
    if (relock && !_locked) {
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
    if (!_locked) return widget.child;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: AmbientBackground(
        child: Center(
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
