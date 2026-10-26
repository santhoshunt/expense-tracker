# Expense Tracker

A personal finance app for Android, built with Flutter. It reads the alerts Indian banks and UPI apps send by SMS, turns them into transactions, and keeps everything on the phone.

The repo still has `web/` and `ios/` folders from the Flutter template, and the code guards the Android-only parts, but only the Android build is built, tested and released.

## What it does

- **Dashboard.** Three tabs:
  - Overview: what is safe to spend today, the balance, the month's income, spend and savings, the monthly budget, budgets, Next 7 days, and who owes you. For the first week of a month it also shows a recap of the month before. The monthly budget card stacks confirmed spending, imports waiting for review and the bills due this month in one bar against the cap, with one verdict ("₹X left after these bills"). A month-end forecast adds your usual everyday spending for the days left. A past month sets that usual figure only if its everyday spending on the same remaining days, bills left out, reaches a quarter of the middle month's; below that it counts as missing records and is skipped. In this check one big purchase counts as no more than 4 typical ones. Next 7 days lists bills and reminders due within a week; a paid card bill stays on it with a Paid tag until its due date passes.
  - Trends: this month so far against last month (On track for the forecast figure, See chart for both months day by day), and against a usual month, overall and by category. A month with under a quarter of the middle spend counts as a gap in the records, so the usual month uses only the months after it. In this check one big purchase counts as no more than 4 typical ones, so a one-off month cannot push out the normal month beside it. A rise past double reads as "2.7 times".
  - Breakdown: spend by category, tag, merchant and group, transfers, subscriptions, and a spending heatmap. Each category, tag and merchant row has a ⋮ menu (See history, Set budget, See transactions, Edit tag, Rename). Tapping a future day on the heatmap sets a one-time reminder for it.
  - The month and its arrows head the Dashboard, with a Year or Month button beside them to switch views. Info tips open from dotted-underlined labels.
  - A "This week" row under the balance card shows the week's spending so far against a usual week. It opens the weekly digest: spent against the usual week, money in, a bar per day, the top categories, the biggest payments, bills due in the next 7 days and imports waiting for review, with arrows to earlier weeks.
  - Big bills ahead spreads quarterly, half-yearly and yearly bills into a monthly figure to set aside, with a bar for each of the next 12 months. It reads your reminders that have an amount and the subscriptions you marked; safe to spend and the forecast still count each bill in full when it falls due.
  - Any past month's recap opens from the ⋮ menu, with arrows to earlier months. The recap card itself shows on the Overview for the first 7 days of a month.
  - A budget's sheet steps to the next or previous budget with its arrows or a swipe. Its 6-month chart stays put while you step through months, and each budget can have its own icon.
  - Money in shows green and money out red in transaction lists; transfers stay plain. Dashboard totals are whole rupees in plain text, with colour on rings, bars and arrows. Amounts use Indian grouping (₹1,42,500.00).
- **The ⋮ menu.** The same two parts on every tab: "This page" (Year view, Weekly digest, the newest past month's recap, Month report (PDF) and Customise page on the Dashboard; Import from SMS, Select and Export CSV on Transactions; New account, Balance breakdown and Statement (PDF) on Accounts), then "App" (Cockpit, Who owes you). Settings has its own gear button beside the ⋮.
- **Add button.** A labelled Add button floats above the bottom bar ("New account" on Accounts) and folds to its icon while a list scrolls down. Every add shows "Added" with the category and amount, and Undo.
- **Transactions.** Search notes, merchants, categories and amounts, and filter by type, category, tag and amount. Sort and Filters buttons sit at the end of the search field, and a badge on Filters counts the filters that are on. Tabs for All, Income, Expenses and Transfers sit under the search. Each active filter shows as a chip with its own close button, plus Clear all when two or more are on. Rows are grouped by day and lead with who was paid (the merchant from the SMS, or the Paid to or Received from name typed in the add sheet, which offers recent names as chips), with the category and note below and the time under the amount. The message button on this tab opens the review sheet, and its badge and the tab's badge show how many items wait there: imports to review, suspected spam and counted refunds that look linked to a purchase. With nothing waiting the sheet offers Import from SMS, which the ⋮ menu also holds. An import counts at once, marked "new" until opened or Mark all seen, when its account already has rows and it is not suspected spam, a possible duplicate or half of a possible transfer. Its category comes from a rule; failing that, from the payments you have filed before (the same merchant, or words its name shares with them), shown as "guessed" until you keep or change it; failing that, it lands in To sort, which counts in your spending and waits for a category. A guessed row counts toward its budget at once, but budget and unusual spending alerts ignore it until you confirm it. Every other import waits in the review sheet, grouped by day, and stays out of the totals until confirmed; editing and saving one confirms it too. Confirm all asks first and then offers Undo. Suspected spam waits in a folded section at the bottom of the sheet, confirmed or discarded one at a time. A refund linked to its purchase takes that purchase's spend down in the purchase's own month instead of counting as income. A refund alert from the same merchant for the same amount, with only one purchase it could be, links itself; likelier matches are offered in the review sheet, and any income row can be linked from its edit sheet. Long-press starts a selection for bulk category, account, Count in, tags, date, subscription, transfer pairing or delete, with Undo on all but account changes. Count in puts a row in another month's figures, such as a salary paid on the 30th, while its own date and the account balance stay as they are. The add and edit sheet sets it too.
- **SMS import.** The app reads bank alerts from the inbox, and also captures them from messaging-app notifications. That second route is the only way to see RCS business chats. Auto-import runs Off, On open, Daily, Weekly or on Every SMS. Daily and Weekly also import from the 6-hourly background check, and Every SMS imports each alert about 30 seconds after it arrives. Duplicates are matched by the bank's reference number, or by bank, amount and a 3-minute window when an alert has none.
- **Cockpit.** Opens from the ⋮ menu or the card at the top of Settings, in four groups:
  - Categories and rules: classification rules ("if the SMS contains X, use category Y"; a rule pointing at Spam drops the message; select words in a transaction's Original SMS and tap Make rule to start one), with the built-in rules folded below yours and a Restore built-in rules button; categories, with their order in add sheets; import checks, led by Test a message (Settings, SMS filters opens them too); and Results, to check the category each transaction ended up with.
  - Groups and tags.
  - Budgets and bills: budgets, reminders and subscriptions.
  - Dashboard layout: which sections show on each Dashboard tab, and in what order.

  In every group, tapping a row edits it; Delete sits in the editor and offers Undo.
- **Subscriptions.** The app spots monthly payments on its own: three or more to one merchant about a month apart, and one bill paid early doesn't break the run. A payment of a reminder's amount from 15 days before its due date to 7 days after marks it paid. Reminders repeat monthly, quarterly, half-yearly or yearly, or fall due once on a date; a paid mark can be undone later from Cockpit. You can also mark any merchant as a monthly, quarterly, half-yearly or yearly subscription from its transaction or the selection bar, and it counts from the first payment.
- **Tags.** Up to five per transaction, for totals across categories such as a trip. Each tag can be renamed, merged into another, given a colour, or deleted.
- **Splits and people.** Mark a bill as split, name who owes what, and record or settle repayments on the Who owes you page, which leads with the total owed.
- **Split by category.** One payment can be divided across several money-out categories, spending and transfers alike: a ₹5,000 supermarket bill as ₹1,000 Groceries, ₹2,000 Luxury and ₹2,000 Paid for Others. Each part becomes its own row ("Groceries · 1 of 3") on the same account and date, so every total, budget and chart counts it by its own category, and the account balance moves once. Edit split changes the parts, Merge back joins them, and deleting a part deletes the whole payment, with Undo.
- **Accounts and cards.** Accounts are created from the account numbers in alerts, or added by hand. Credit cards get a billing cycle, a due date and a paid state. A debit card's alerts are recognised and get a Debit card account, linked to its bank account when that bank has only one account here; otherwise pick the account it draws from, or switch any account to Debit card by hand. Its spends then come out of that bank's balance, counted once in net balance. Wallets hold money or points that can only be spent on one platform (Amazon Pay, Zomato Money, Swiggy coins), grouped by service with any number of logins each. They stay out of net balance, and a wallet transaction counts as spending only when you turn that on for it. A CSV restore brings wallet transactions back unassigned, so they count until you put them back on their wallet.
- **Card rewards.** Settings, Card rewards (or a card's ⋮ menu, Rewards) sets what each credit card pays back: groups of categories at one rate, each with an optional cap per statement cycle, plus a rate for everything else. Rates are a percent for cashback or points per ₹100, with an optional ₹ value per point. The card's tile shows the estimate for the current cycle and the last one. Every card payment earns by default; untick Earns cashback in its edit sheet to leave one out. A payment split by category earns once, on its full amount, at its first part's rate.
- **Home screen.** Widgets: Budget (compact and detailed), Budgets list, Month pace, Upcoming, Today and Add, Recent, Spending split, Big bills (with the 12-month strip, or one line), This week (with a bar per day, or one line), Accounts (the accounts you pick when placing it, each with this month's spend, or the card's cycle spend, and what is left), and Quick actions (Expense, Income, Import SMS). They follow the app's card style, theme and red and green money; Upcoming and Recent rows carry their category's colour, and Upcoming marks bills that are close. Today, Recent and This week show how many imports wait for review and their total, and This week shows how much of its spend is To sort. Each opens its own part of the app, and the This week widget's review count opens the review sheet. There is a Quick Settings tile and launcher shortcuts for adding an expense or importing SMS.
- **Notifications.** Budget thresholds, bills and reminders coming due, the monthly recap, a Monday 9 AM note that last week's digest is ready, and a count of rows waiting for review once more than 5 pile up, whose tap opens the review sheet. A category whose month so far reaches 1.5 times its usual month, and at least ₹1,000 more, alerts once that month; the tap opens its history. The recap, weekly digest and review notifications carry no amounts. Budget, bill and unusual spending alerts arrive with the app closed too: every background import checks them, and a background check runs about every 6 hours whatever the Auto-import setting. The four alert switches (budget, unusual spending, weekly digest, payment reminders) sit on Settings, Notifications.
- **Backup.** Export as JSON (a full backup), CSV or a PDF statement, and import JSON or CSV. Google Drive can keep a daily, weekly or monthly backup.
- **Everything else.** App lock (fingerprint, face or device PIN), light and dark themes with several dark palettes, an accent colour, alternate launcher icons, and in-app updates from this repo's GitHub releases.

## Privacy

- All data lives in the app's own storage on the phone (`shared_preferences`).
- `android:allowBackup` is off, so Android's cloud backup and device-to-device transfer never copy it.
- Exports and Drive backups leave out the raw SMS text. JSON and Drive backups keep the merchant name read from each alert, so a restore keeps row titles, merchant renames and subscription marks. They also keep a hash of each deleted or discarded alert, never its text, so a rescan on the restored phone does not import it again.
- Drive access uses the `drive.file` scope, which lets the app see only the files it created.
- The app makes network calls only to Google Drive, when you turn it on, and to the GitHub releases API for the update check.

## Permissions

| Permission | Why |
|---|---|
| `READ_SMS` | Reads bank alerts from the inbox. Asked for when you first import. |
| `RECEIVE_SMS` | Wakes the import when an SMS arrives. Asked for only when you pick Every SMS. |
| Notification access | Captures bank alerts from messaging-app notifications. You grant it in system settings. |
| `POST_NOTIFICATIONS` | Budget, unusual spending, bill, recap, weekly digest and review notifications. |
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
