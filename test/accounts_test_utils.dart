import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:expense_tracker/providers/finance_provider.dart';
import 'package:expense_tracker/providers/settings_provider.dart';
import 'package:expense_tracker/screens/accounts_screen.dart';

/// The Accounts screen over [p], with every card open: account cards start
/// collapsed (1.33), and these tests read the full details.
Widget accountsApp(FinanceProvider p) {
  final s = SettingsProvider();
  for (final a in [...p.accounts, ...p.closedAccounts]) {
    s.setAccountExpanded(a.id, true);
  }
  return MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: p),
      ChangeNotifierProvider.value(value: s),
    ],
    child: MaterialApp(
      home: Scaffold(body: AccountsScreen(onViewAccount: (_) {})),
    ),
  );
}
