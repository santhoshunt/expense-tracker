import 'package:flutter/material.dart';

import '../models/transaction.dart';
import 'app_theme.dart';

/// The colour of a money figure: income green, money out in
/// `scheme.error`, a transfer in the plain text colour (it moves money,
/// it is neither), and a row left out of the totals muted.
Color moneyColor(
  BuildContext context, {
  required TxType type,
  bool transfer = false,
  bool counted = true,
}) {
  final scheme = Theme.of(context).colorScheme;
  if (!counted) return scheme.onSurfaceVariant;
  if (transfer) return scheme.onSurface;
  return type == TxType.income ? AppColors.of(context).green : scheme.error;
}

/// The colour of a signed figure such as a net or a difference: green
/// above zero, `scheme.error` below it, the plain text colour at zero.
Color signedMoneyColor(BuildContext context, double signed) {
  final scheme = Theme.of(context).colorScheme;
  if (signed > 0) return AppColors.of(context).green;
  if (signed < 0) return scheme.error;
  return scheme.onSurface;
}
