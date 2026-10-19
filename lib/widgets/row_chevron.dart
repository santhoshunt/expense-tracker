import 'package:flutter/material.dart';

import '../utils/text_scale.dart';

/// The trailing mark of a row that opens its editor on tap, dropped at
/// large text so the words get the width.
Widget? rowChevron(BuildContext context) => isLargeTextScale(context)
    ? null
    : Icon(
        Icons.chevron_right,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      );
