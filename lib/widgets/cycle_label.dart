import 'package:flutter/material.dart';

/// A cycle name ("Quarterly") for a narrow segment or button: one line,
/// shrunk to fit rather than wrapped onto two.
Widget cycleLabel(String text) => FittedBox(
  fit: BoxFit.scaleDown,
  child: Text(text, maxLines: 1, softWrap: false),
);
