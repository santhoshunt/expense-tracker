import 'package:flutter/material.dart';

import 'keyboard_unfocus.dart';
import 'undo_snackbar.dart';

/// Opens an editor built on [EditorSheetBody] as a bottom sheet: full
/// height when it needs it, below the status bar, with a drag handle. The
/// builder's context, not the caller's, gives the keyboard inset, and the
/// sheet's own [ToastHost] sits above the keyboard.
///
/// The handle is [EditorSheetHandle], not the sheet's own: Flutter's drag
/// closes the route with a direct pop that skips [PopScope], so a dirty
/// editor would go without "Discard changes?".
Future<T?> showEditorSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  enableDrag: false,
  builder: (ctx) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const EditorSheetHandle(),
        Flexible(child: ToastHost(child: builder(ctx))),
      ],
    ),
  ),
);

/// A bottom sheet's drag handle that closes the sheet the way back does:
/// a drag down past [_closeDistance], or a fling, asks the route to pop,
/// so its [PopScope] runs ("Discard changes?" on a dirty editor) and a
/// clean sheet closes. 48dp tall, the size of the sheet's own handle.
class EditorSheetHandle extends StatefulWidget {
  const EditorSheetHandle({super.key});

  @override
  State<EditorSheetHandle> createState() => _EditorSheetHandleState();
}

class _EditorSheetHandleState extends State<EditorSheetHandle> {
  /// How far down a drag goes before letting go closes the sheet.
  static const _closeDistance = 48.0;

  /// A downward fling this fast closes it whatever the distance, the
  /// sheet's own threshold.
  static const _flingVelocity = 700.0;

  double _dragged = 0;

  /// The keyboard goes first, so "Discard changes?" gets the whole screen.
  void _close() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      onTap: _close,
      child: GestureDetector(
        key: const ValueKey('editor-sheet-handle'),
        // The whole strip takes the drag, not only the pill.
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => _dragged = 0,
        onVerticalDragUpdate: (d) => _dragged += d.primaryDelta ?? 0,
        onVerticalDragEnd: (d) {
          if (_dragged > _closeDistance ||
              (d.primaryVelocity ?? 0) > _flingVelocity) {
            _close();
          }
        },
        child: SizedBox(
          height: kMinInteractiveDimension,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shared editor: title left, ⋮ for Delete, a scrolling middle, one
/// pinned button that says what is missing. The pattern of the editor
/// audit, section 3.1.
///
/// [footerReason] is the one line above the button while it is disabled
/// ("Enter a name"); [footerExtra] is one more line the caller sizes to
/// one line, hidden while the keyboard is up so the pinned stack fits a
/// small phone. With [dirty] true, back, a scrim tap or a drag on the
/// [EditorSheetHandle] asks "Discard changes?" first. The add sheet keeps
/// its own guard and passes [dirty] false.
class EditorSheetBody extends StatelessWidget {
  final String title;

  /// The header ⋮ menu's items; no ⋮ when null.
  final List<PopupMenuEntry<String>>? menu;
  final ValueChanged<String>? onMenu;
  final String menuTooltip;
  final List<Widget> children;
  final String footerLabel;

  /// Null disables the button.
  final VoidCallback? onSave;
  final String? footerReason;
  final Widget? footerExtra;
  final bool dirty;

  /// A back arrow before the title, for a sheet that opened on a choice
  /// (the budget kind, the account type) and can go back to it. With
  /// [dirty] true it asks "Discard changes?" first.
  final VoidCallback? onBack;

  const EditorSheetBody({
    super.key,
    required this.title,
    this.onBack,
    this.menu,
    this.onMenu,
    this.menuTooltip = 'More actions',
    required this.children,
    required this.footerLabel,
    required this.onSave,
    this.footerReason,
    this.footerExtra,
    this.dirty = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    // Always mounted, so the first keystroke that makes the form dirty
    // does not rebuild the fields under a new parent and drop the focus.
    // Save and Delete pop imperatively, which bypasses it.
    return PopScope(
      canPop: !dirty,
      onPopInvokedWithResult: (didPop, _) async {
        // Not dirty: another scope blocked the pop (the add sheet's own
        // guard), and that one asks.
        if (didPop || !dirty) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard(context) && navigator.mounted) {
          navigator.pop();
        }
      },
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(onBack == null ? 20 : 4, 0, 8, 8),
              child: Row(
                children: [
                  if (onBack != null)
                    IconButton(
                      tooltip: 'Back',
                      icon: const Icon(Icons.arrow_back),
                      // Going back drops what the form holds, so a dirty
                      // form asks first, as back and the scrim do.
                      onPressed: dirty
                          ? () async {
                              if (await _confirmDiscard(context) &&
                                  context.mounted) {
                                onBack!();
                              }
                            }
                          : onBack,
                    ),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleLarge,
                      // Large text (1.3x and up): a second line, so "Add
                      // to Food & Dining rule" is not cut to "Add to Food".
                      // One while the keyboard is up, which leaves a small
                      // phone little room for the fields.
                      maxLines:
                          !keyboardUp &&
                              MediaQuery.textScalerOf(context).scale(1) >= 1.3
                          ? 2
                          : 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (menu != null)
                    PopupMenuButton<String>(
                      tooltip: menuTooltip,
                      icon: const Icon(Icons.more_vert),
                      itemBuilder: (_) => menu!,
                      onSelected: onMenu,
                    ),
                ],
              ),
            ),
            Flexible(
              child: UnfocusOnScroll(
                child: SingleChildScrollView(
                  // 12dp at the top keeps the first outlined field's
                  // floating label inside the scroll view.
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (footerReason != null) ...[
                    Text(
                      footerReason!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (!keyboardUp && footerExtra != null) ...[
                    footerExtra!,
                    const SizedBox(height: 4),
                  ],
                  FilledButton(
                    key: const ValueKey('editor-save'),
                    onPressed: onSave,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    // One line, shrunk rather than wrapped: at 2x text on
                    // 320dp "Create trip budget" took three lines and
                    // pushed the pinned stack past a small phone.
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(footerLabel, maxLines: 1),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The add sheet's "Discard changes?" question: true when Discard was
/// tapped.
Future<bool> _confirmDiscard(BuildContext context) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      // Scrollable: at 320x568 and 2x text the buttons need more height
      // than a small phone has.
      scrollable: true,
      title: const Text('Discard changes?'),
      content: const Text('What you typed here will be lost.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Keep editing'),
        ),
        // The error style bulk Delete uses: this throws input away.
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Discard'),
        ),
      ],
    ),
  );
  return discard == true;
}
