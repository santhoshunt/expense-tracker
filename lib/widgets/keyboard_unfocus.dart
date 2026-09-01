import 'package:flutter/material.dart';

/// Clears focus only when it belongs to a text field — never stealing it
/// from other focusables (buttons, dropdown menus) that don't own a
/// keyboard or a selection handle. Returns whether focus was cleared.
bool unfocusEditableField() {
  final focus = FocusManager.instance.primaryFocus;
  final inEditable =
      focus?.context?.findAncestorStateOfType<EditableTextState>() != null;
  if (inEditable) focus!.unfocus();
  return inEditable;
}

/// Drops text-field focus the moment the user starts dragging the wrapped
/// scrollable — ScrollViewKeyboardDismissBehavior.onDrag for surfaces built
/// on SingleChildScrollView, which lacks that knob.
///
/// Exists because Flutter paints selection handles in an overlay the scroll
/// viewport does NOT clip: scroll a dialog while one of its fields is
/// focused and the blue teardrop detaches from the field and floats over
/// the dialog title. Unfocusing on the drag removes the handle and the
/// keyboard together, which is also what makes the scrolled-to content
/// readable.
class UnfocusOnScroll extends StatelessWidget {
  const UnfocusOnScroll({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollStartNotification>(
      onNotification: (n) {
        // depth 0 = the wrapped scroll view itself. Deeper notifications
        // come from a multiline TextField scrolling its own content —
        // unfocusing mid-drag there would blank the field being edited.
        // dragDetails == null is a programmatic scroll (e.g. the autofocus
        // reveal when the keyboard opens), not a user gesture.
        if (n.depth == 0 && n.dragDetails != null) unfocusEditableField();
        return false;
      },
      child: child,
    );
  }
}

/// Drops text-field focus when the software keyboard closes.
///
/// Android's "minimize keyboard" gesture (system back / the ⌄ key) hides the
/// keyboard but leaves the field focused, so Flutter keeps painting the blue
/// selection handle — which then floats over dialogs and drifts while
/// scrolling. Unfocusing when the bottom view inset collapses to zero removes
/// the handle everywhere in one place. Installed once via MaterialApp.builder.
class UnfocusOnKeyboardDismiss extends StatefulWidget {
  const UnfocusOnKeyboardDismiss({super.key, required this.child});

  final Widget child;

  @override
  State<UnfocusOnKeyboardDismiss> createState() =>
      _UnfocusOnKeyboardDismissState();
}

class _UnfocusOnKeyboardDismissState extends State<UnfocusOnKeyboardDismiss>
    with WidgetsBindingObserver {
  var _keyboardWasOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final open = View.of(context).viewInsets.bottom > 0;
    final closed = _keyboardWasOpen && !open;
    _keyboardWasOpen = open;
    if (closed) unfocusEditableField();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
