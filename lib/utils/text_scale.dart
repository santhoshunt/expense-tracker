import 'package:flutter/widgets.dart';

/// Above this text scale a layout gives way for the text: a transaction row
/// puts its amount on a line of its own under the category, and the list's
/// month header shortens the month name. Side by side, the amount's column
/// left the category a few letters ("Sh…").
const double kLargeTextScale = 1.6;

/// Whether the text scale here is past [kLargeTextScale].
bool isLargeTextScale(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) > kLargeTextScale;
