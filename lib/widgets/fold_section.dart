import 'package:flutter/material.dart';

import 'animated_fold.dart';
import 'glossy.dart';
import 'motion.dart';

/// A tappable heading that folds a panel of rows away: the Subscriptions
/// tab's Stopped and Hidden lists, the People page's settled ones.
class FoldSection extends StatelessWidget {
  final String title;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  const FoldSection({
    super.key,
    required this.title,
    required this.open,
    required this.onToggle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const Spacer(),
                    AnimatedRotation(
                      turns: open ? 0 : 0.5,
                      duration: motionDuration(
                        context,
                        const Duration(milliseconds: 250),
                      ),
                      curve: Curves.easeOutCubic,
                      child: Icon(
                        Icons.expand_less,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedFold(
            collapsed: !open,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FrostedPanel(
                radius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: children,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
