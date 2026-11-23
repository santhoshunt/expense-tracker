import 'package:flutter/material.dart';

import '../services/backup_crypto.dart'
    show NewerBackupFormatException, WrongPassphraseException;
import '../utils/format.dart' show dayMonthFormat, fmtDate;

/// Why [text] cannot be a new backup passphrase, or null when it can (or is
/// still empty). Printable ASCII only: the same visible passphrase typed on
/// another keyboard can be other characters (composed letters, zero-width
/// marks), which would lock the user out on a new phone for good.
String? passphraseProblem(String text) {
  if (text.isEmpty) return null;
  if (text.codeUnits.any((c) => c < 0x20 || c > 0x7E)) {
    return 'Use English letters, digits and symbols only';
  }
  if (text.startsWith(' ') || text.endsWith(' ')) {
    return 'Remove the space at the start or end';
  }
  if (text.length < 8) return 'Use at least 8 characters';
  return null;
}

/// Asks for a new backup passphrase, twice. Returns it on Set, null on
/// Cancel or dismissal. Set stays disabled until the first field holds a
/// passphrase [passphraseProblem] accepts and both fields match.
Future<String?> showSetPassphraseDialog(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const SetPassphraseDialog(),
    );

/// The dialog [showSetPassphraseDialog] shows.
class SetPassphraseDialog extends StatefulWidget {
  const SetPassphraseDialog({super.key});

  @override
  State<SetPassphraseDialog> createState() => _SetPassphraseDialogState();
}

class _SetPassphraseDialogState extends State<SetPassphraseDialog> {
  final _first = TextEditingController();
  final _second = TextEditingController();

  /// One toggle shows or hides both fields.
  bool _shown = false;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  bool get _canSet =>
      _first.text.isNotEmpty &&
      passphraseProblem(_first.text) == null &&
      _first.text == _second.text;

  void _set() => Navigator.pop(context, _first.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      // The keyboard and large text overflow a small screen without it.
      scrollable: true,
      title: const Text('Set a backup passphrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          _PassphraseField(
            key: const ValueKey('passphrase-first'),
            controller: _first,
            label: 'Passphrase',
            autofocus: true,
            shown: _shown,
            onToggle: () => setState(() => _shown = !_shown),
            action: TextInputAction.next,
            errorText: passphraseProblem(_first.text),
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          _PassphraseField(
            key: const ValueKey('passphrase-second'),
            controller: _second,
            label: 'Repeat it',
            shown: _shown,
            action: TextInputAction.done,
            onChanged: () => setState(() {}),
            onSubmitted: () {
              if (_canSet) _set();
            },
          ),
          const SizedBox(height: 16),
          // The icon carries the warning colour; the text stays plain.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'If you forget it, backups made with it cannot be opened.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSet ? _set : null,
          child: const Text('Set'),
        ),
      ],
    );
  }
}

/// Asks for the passphrase of a protected backup made on [madeAt] (null
/// when unknown) and hands each entry to [open], which the caller runs
/// under its spinner. A wrong passphrase, or any other failure, keeps the
/// dialog open with a field error, so the user can try again without the
/// backup being fetched again. Returns what [open] returned, or null on
/// Cancel.
Future<T?> showRestorePassphraseDialog<T>(
  BuildContext context, {
  required DateTime? madeAt,
  required Future<T> Function(String passphrase) open,
}) => showDialog<T>(
  context: context,
  builder: (_) => RestorePassphraseDialog<T>(madeAt: madeAt, open: open),
);

/// The dialog [showRestorePassphraseDialog] shows.
class RestorePassphraseDialog<T> extends StatefulWidget {
  final DateTime? madeAt;
  final Future<T> Function(String passphrase) open;

  const RestorePassphraseDialog({
    super.key,
    required this.madeAt,
    required this.open,
  });

  @override
  State<RestorePassphraseDialog<T>> createState() =>
      _RestorePassphraseDialogState<T>();
}

class _RestorePassphraseDialogState<T>
    extends State<RestorePassphraseDialog<T>> {
  final _ctrl = TextEditingController();

  /// The last try's field error; cleared by typing.
  String? _error;
  bool _trying = false;
  bool _shown = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _canRestore => _ctrl.text.isNotEmpty && !_trying;

  Future<void> _restore() async {
    if (!_canRestore) return;
    setState(() => _trying = true);
    String? error;
    try {
      final opened = await widget.open(_ctrl.text);
      if (mounted) Navigator.pop(context, opened);
    } on WrongPassphraseException {
      error = 'That passphrase does not open this backup.';
    } on NewerBackupFormatException catch (e) {
      error = e.message;
    } catch (e) {
      debugPrint('Opening a protected backup failed: $e');
      error = 'This backup cannot be read.';
    } finally {
      if (mounted) {
        setState(() {
          _trying = false;
          _error = error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final madeAt = widget.madeAt;
    return AlertDialog(
      scrollable: true,
      title: const Text('Enter the backup passphrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            madeAt == null
                ? 'This backup is protected.'
                : 'This backup was made on ${_day(madeAt)} and is protected.',
          ),
          const SizedBox(height: 16),
          _PassphraseField(
            controller: _ctrl,
            label: 'Passphrase',
            autofocus: true,
            shown: _shown,
            onToggle: () => setState(() => _shown = !_shown),
            action: TextInputAction.done,
            errorText: _error,
            // A new entry clears the old verdict.
            onChanged: () => setState(() => _error = null),
            onSubmitted: _restore,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _trying ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canRestore ? _restore : null,
          child: const Text('Restore'),
        ),
      ],
    );
  }

  /// "23 Nov" this year, "23 Nov 2025" before, as the Drive picker writes it.
  static String _day(DateTime d) => d.year == DateTime.now().year
      ? dayMonthFormat.format(d)
      : fmtDate(d);
}

/// A passphrase field, obscured unless [shown]: no suggestions, no
/// autocorrect. With [onToggle] it carries the show or hide button.
class _PassphraseField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final bool shown;
  final VoidCallback? onToggle;
  final TextInputAction action;
  final String? errorText;
  final VoidCallback onChanged;
  final VoidCallback? onSubmitted;

  const _PassphraseField({
    super.key,
    required this.controller,
    required this.label,
    this.autofocus = false,
    required this.shown,
    this.onToggle,
    required this.action,
    this.errorText,
    required this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final onToggle = this.onToggle;
    return TextField(
      controller: controller,
      autofocus: autofocus,
      obscureText: !shown,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: action,
      onChanged: (_) => onChanged(),
      onSubmitted: (_) => onSubmitted?.call(),
      decoration: InputDecoration(
        labelText: label,
        errorText: errorText,
        errorMaxLines: 2,
        suffixIcon: onToggle == null
            ? null
            : IconButton(
                tooltip: shown ? 'Hide passphrase' : 'Show passphrase',
                icon: Icon(
                  shown
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: onToggle,
              ),
      ),
    );
  }
}
