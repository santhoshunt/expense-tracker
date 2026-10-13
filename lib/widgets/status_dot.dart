import 'package:flutter/material.dart';

/// The small coloured dot before a figure or line that carries a state
/// (over budget, due soon, under the cap): the colour sits on the dot, and
/// the text beside it stays in the plain text colour.
class StatusDot extends StatelessWidget {
  final Color color;
  final double size;

  const StatusDot({super.key, required this.color, this.size = 6});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, color: color),
  );
}
