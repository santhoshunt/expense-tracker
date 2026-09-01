import 'package:flutter/widgets.dart';

/// Disposes [disposables] when this widget leaves the tree.
///
/// For the app's dialog helpers, which create their `TextEditingController`s as
/// locals before calling `showDialog`. The obvious cleanup —
///
/// ```dart
/// try { await showDialog(...); } finally { ctrl.dispose(); }
/// ```
///
/// — is wrong: `showDialog`'s future completes when the route is *popped*, but
/// the dialog stays mounted for its exit transition, and rebuilding a
/// `TextField` during that transition re-subscribes to the controller. The
/// result is "A TextEditingController was used after being disposed" on every
/// dismissal.
///
/// Wrapping the dialog instead ties disposal to unmount, which happens after
/// the transition has finished:
///
/// ```dart
/// final ctrl = TextEditingController();
/// await showDialog(
///   context: context,
///   builder: (ctx) => DisposeScope(
///     disposables: [ctrl],
///     child: AlertDialog(...),
///   ),
/// );
/// ```
class DisposeScope extends StatefulWidget {
  final List<ChangeNotifier> disposables;
  final Widget child;

  const DisposeScope({
    super.key,
    required this.disposables,
    required this.child,
  });

  @override
  State<DisposeScope> createState() => _DisposeScopeState();
}

class _DisposeScopeState extends State<DisposeScope> {
  @override
  void dispose() {
    for (final d in widget.disposables) {
      d.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
