# Expense Tracker

A personal finance app for Android, built with Flutter. It reads the alerts Indian banks and UPI apps send by SMS, turns them into transactions, and keeps everything on the phone.

The repo still has `web/` and `ios/` folders from the Flutter template, and the code guards the Android-only parts, but only the Android build is built, tested and released.

## What it does

- **Dashboard.** Three tabs:
  - Overview: balance, the month's income, spend and savings, budgets, upcoming bills, and who owes you. For the first week of a month it also shows a recap of the month before. A month-end forecast adds what is spent so far, the bills still due and your usual everyday spending for the days left, against the monthly budget.
  - Trends: the month's pace, and this month against last month and a usual month, overall and by category.
  - Breakdown: spend by category, tag, merchant and group, transfers, subscriptions, and a spending heatmap.
- **Transactions.** Search, and filter by type, category, tag and amount. Imported rows wait in a review queue and stay out of the totals until confirmed. Suspected spam has its own queue. Long-press starts a selection for bulk category, account, Count in, tags, date, subscription, transfer pairing or delete, with Undo on all but account changes. Count in puts a row in another month's figures, such as a salary paid on the 30th, while its own date and the account balance stay as they are. The add and edit sheet sets it too.
- **SMS import.** The app reads bank alerts from the inbox, and also captures them from messaging-app notifications. That second route is the only way to see RCS business chats. Auto-import runs Off, on each Launch, Daily, Weekly or on Every SMS. Daily and Weekly also check every 6 hours in the background, and Every SMS imports each alert about 30 seconds after it arrives. Duplicates are matched by the bank's reference number, or by bank, amount and a 3-minute window when an alert has none.
- **Cockpit.** One screen for classification rules ("if the SMS contains X, use category Y"; a rule pointing at Spam drops the message), import checks, categories and groups, budgets, reminders, tags and subscriptions.
- **Subscriptions.** The app spots monthly payments on its own: three or more to one merchant about a month apart. You can also mark any merchant as a monthly, quarterly or yearly subscription from its transaction or the selection bar, and it counts from the first payment.
- **Tags.** Up to five per transaction, for totals across categories such as a trip. Each tag can be renamed, merged into another, given a colour, or deleted.
- **Splits and people.** Mark a bill as split, name who owes what, and record or settle repayments on the People page.
- **Accounts and cards.** Accounts are created from the account numbers in alerts, or added by hand. Credit cards get a billing cycle, a due date and a paid state. Wallets hold money or points that can only be spent on one platform (Amazon Pay, Zomato Money, Swiggy coins), grouped by service with any number of logins each. They stay out of net balance, and a wallet transaction counts as spending only when you turn that on for it. A CSV restore brings wallet transactions back unassigned, so they count until you put them back on their wallet.
- **Home screen.** Widgets: Budget (compact and detailed), Month pace, Upcoming bills, and Today and Add. There is a Quick Settings tile and launcher shortcuts for adding an expense or importing SMS.
- **Notifications.** Budget thresholds, bills and reminders coming due, the monthly recap, and a count of rows waiting for review once more than 5 pile up. The recap and review notifications carry no amounts.
- **Backup.** Export as JSON (a full backup), CSV or a PDF statement, and import JSON or CSV. Google Drive can keep a daily, weekly or monthly backup.
- **Everything else.** App lock (fingerprint, face or device PIN), light and dark themes with several dark palettes, an accent colour, alternate launcher icons, and in-app updates from this repo's GitHub releases.

## Privacy

- All data lives in the app's own storage on the phone (`shared_preferences`).
- `android:allowBackup` is off, so Android's cloud backup and device-to-device transfer never copy it.
- Exports and Drive backups leave out the raw SMS text.
- Drive access uses the `drive.file` scope, which lets the app see only the files it created.
- The app makes network calls only to Google Drive, when you turn it on, and to the GitHub releases API for the update check.

## Permissions

| Permission | Why |
|---|---|
| `READ_SMS` | Reads bank alerts from the inbox. Asked for when you first import. |
| `RECEIVE_SMS` | Wakes the import when an SMS arrives. Asked for only when you pick Every SMS. |
| Notification access | Captures bank alerts from messaging-app notifications. You grant it in system settings. |
| `POST_NOTIFICATIONS` | Budget, bill, recap and review notifications. |
| `USE_BIOMETRIC` | App lock. |
| `RECEIVE_BOOT_COMPLETED` | Books the recap notification and background checks again after a reboot. |
| `REQUEST_INSTALL_PACKAGES`, `UPDATE_PACKAGES_WITHOUT_USER_ACTION` | In-app updates. The installer accepts only this app's package, signed with its own key, at a newer version. |
| `INTERNET` | Google Drive and the update check. |

WorkManager, which runs the background import, adds `WAKE_LOCK`, `ACCESS_NETWORK_STATE` and `FOREGROUND_SERVICE` on its own.

Android 13 and later hard-restrict `READ_SMS` for apps installed outside the Play Store: the permission dialog often never appears. The app detects this and walks you through the fix: app settings, then the ⋮ menu, then "Allow restricted settings", then Permissions, SMS, Allow.

## Project layout

```
lib/
  main.dart            App start, providers, and the background-import entry point
  models/              Transactions, categories, accounts, rules, budgets, reminders, subscription cycles
  providers/           FinanceProvider (the ledger and its persistence), SettingsProvider
  screens/             Home shell, dashboard, transactions, accounts, people, Cockpit, settings, add/edit sheet
  services/            SMS parser and import, background import, Drive backup, updates, widgets, notifications
  widgets/             Shared UI: charts, tiles, dialogs, the lock gate
  utils/               Formatting, dates, palettes, theme
android/app/src/main/kotlin/com/fabletest/expense_tracker/
  MainActivity.kt      Platform channels, permissions, launcher icons
  SmsBridge.kt         SMS inbox, notification buffer and widget refresh, shared with the background engine
  TxnNotificationListener.kt  Captures bank alerts from notifications
  BackgroundImport.kt, SmsImportWorker.kt, SmsArrivalReceiver.kt  Background import
  BudgetWidgetProvider.kt, HomeWidgets.kt  Home-screen widgets
  UpdateInstaller.kt   Verifies and installs downloaded updates
test/                  Unit and widget tests
```

## Build and release

Needs Flutter 3.44 (Dart 3.12) and JDK 17 or later.

```sh
flutter pub get
flutter run -d <android-device>
flutter build apk --release
```

A release build signs with the key named in `android/key.properties`. Without that file it falls back to the debug key, and a debug-signed APK cannot update an installed release.

To publish, push a tag such as `v1.24.0`. The Release workflow runs the tests, builds the APK, checks it carries the release key's certificate, and attaches `app-release.apk` to a GitHub release. Installed copies then find it through the in-app update check.

## Tests

```sh
flutter analyze
flutter test
```

CI runs both on every push to `main`.
