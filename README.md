# Expense Tracker

A cross-platform (Web, Android, iOS) Flutter app to track expenses, income, and savings goals.

## Features

- **Dashboard** — available balance, a month selector with income/spend stat cards, a category donut chart, category progress bars, and an income-vs-expense bar chart for the last 6 months.
- **Transactions** — add, edit (tap), and delete income and expense entries. Grouped by month with per-month income/expense totals; sortable (date/amount, both directions) within each section; search by note/sender; filter by All / Income / Expenses, categories, and amount range; quick-jump controls for top / bottom / any month.
- **Classifiers** — user-defined rules: "if the SMS contains *text* → category X" (case-insensitive). A rule targeting **Spam** drops matching messages from import entirely. Managed on their own page (rule icon in the app bar).
- **Spam handling** — heuristically suspicious imports (promos, mandates, links) land in a separate "Suspected spam" queue that is excluded from *Confirm all*: each entry must be confirmed or discarded individually.
- **Savings goals** — create goals with target amounts, add or withdraw money, and track progress. Money in goals is deducted from the available balance.
- **SMS auto-import (Android only)** — opt-in scan of bank/UPI alert SMS with a selectable range (since last scan / 7 / 30 / 90 / 365 days / custom calendar range). A rule-based parser extracts amount, direction (word-boundary verb matching), merchant, date, and bank reference; OTPs, promos, e-mandates, collect requests, and failed transactions are filtered out. Matches land in a review queue (excluded from totals); duplicates are skipped by bank reference id. Imported entries carry the SMS sender id and the full original message in the note.
- **Sender field** — every transaction has an optional "sender" (who the money moved to/from); SMS imports fill it automatically with the bank/UPI sender id.
- **Backup & restore** — export as JSON (full backup, re-importable with merge/replace), CSV (transactions, re-importable), or a PDF statement (Unicode ₹ via bundled Noto Sans, summary cards, category share table, month-grouped transaction tables with subtotals). On Android a save-location dialog is shown; web triggers a browser download. "Delete all data" (with confirmation) lives in the same ⋮ menu.
- **Persistence** — all data is stored locally on-device via `shared_preferences` (localStorage on web). No account or network needed.
- **Light & dark theme** — follows system setting.

## Project structure

```
lib/
  main.dart                      App entry, theming, provider wiring
  models/transaction.dart        Tx, TxCategory, SavingsGoal models + categories
  providers/finance_provider.dart State + persistence + aggregations
  screens/                       Home (nav shell), dashboard, transactions, savings, add/edit sheet
  services/sms_parser.dart       Pure-Dart bank/UPI SMS parser (filters + field extraction)
  services/sms_source.dart       Platform channel to the Android SMS inbox
  services/sms_import_service.dart  Import run: permission → query → parse → dedupe
  widgets/                       Transaction tile, custom-painted monthly bar chart
  utils/format.dart              Currency/date formatters
test/                            Provider, SMS parser corpus, and import/dedup tests
```

The Android side of SMS reading is a ~100-line `MethodChannel` in
`android/app/src/main/kotlin/.../MainActivity.kt` (runtime `READ_SMS` permission +
inbox query) — no third-party SMS plugin. Note: Google Play restricts `READ_SMS`;
this feature is intended for personal/sideloaded builds.

**Sideloaded installs and the SMS permission**: Android 10+ marks `READ_SMS` as
hard-restricted — for apps installed outside the Play Store the permission dialog
is often suppressed and the request is auto-denied. The app detects this and shows
a walkthrough: open app settings → ⋮ menu → "Allow restricted settings"
(Android 13+) → Permissions → SMS → Allow, then retry the import.

## Run & build

```sh
flutter pub get

# Run (pick a device)
flutter run -d chrome            # web
flutter run -d <android-device>  # android
flutter run -d <ios-device>      # ios (requires macOS)

# Release builds
flutter build web --release      # output: build/web
flutter build apk --release      # output: build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle          # for Play Store
flutter build ipa                # iOS — must be run on macOS with Xcode
```

To serve the web build locally: `cd build/web` then any static server, e.g.
`python -m http.server 8080`.

## Tests

```sh
flutter test
```
