# CLAUDE.md — Finverse Mobile

Read this first in every new chat. It covers what the project is, what is
done, how the code is organised, and what comes next. Feature details for
users are in [README.md](README.md); this file is for working on the code.

## What we are building

**Finverse** is a personal-finance app (Flutter, Android first). It started
as the mobile version of a web app with a FastAPI backend. We are turning it
into a **local-first, offline app**:

- All data lives in an **encrypted SQLite database on the phone**. There is no
  account, no sign-in and no server.
- Users should not have to type transactions: payments arrive automatically
  from **bank SMS, UPI app notifications and shared screenshots** into a
  swipe **review inbox**.
- **Privacy is the selling point**: data never leaves the phone. The only
  "sync" is an encrypted backup the user controls (a file or their own Google
  Drive).
- **No AI anywhere in the offline build.** Insights, categories and the
  check-up are rule-based. (The user decided on 2026-11-24 to skip the AI chat.)
- It will be sold on Google Play as **Free + Pro** (one app, Pro features locked).

## Two builds from one codebase

| Build | Command | Behaviour |
|---|---|---|
| **Cloud** (current default) | `flutter build apk --release` | Old app: sign-in, live backend at Cloud Run, everything unlocked, AI advisor. No SMS/notification/share capture. |
| **Local / offline** (the product) | `flutter build apk --release --dart-define=FINVERSE_MODE=local` | No login page: opens straight to Home (or onboarding the first time). Encrypted on-phone DB, optional app lock, capture, Free/Pro. |
| Local + developer tools | add `--dart-define=FINVERSE_DEV=true` | Adds More → Developer → **Pretend Pro**. **Never** use this for the Play Store build. |

- The mode is read in [mobile/lib/config.dart](mobile/lib/config.dart) (`AppConfig.isLocal`).
- **When you test an offline-only feature, build with `FINVERSE_MODE=local`.**
  The plain build is the cloud app and does not include capture at all.
- Never mix local and server data. Anything not available offline shows "not in
  the offline version yet" (`NotAvailableYetException`).
- Plan: make the offline build the default once wrap-up is done.

## Repository layout

```text
Finance_Tracker_Mobile_App/
├── mobile/            Flutter app (all active work happens here)
├── backend/           Copy of the FastAPI backend. Reference spec for porting
│                      logic to Dart; not used by the offline build
├── tools/parity/      generate_fixtures.py: runs the backend code on sample
│                      inputs and saves JSON fixtures for the Dart parity tests
├── release/           Finished APKs (Finverse-v1.0.0-*.apk), committed
├── signing/           Release keystore + notes (git-ignored, NEVER commit or print)
└── hs_err_*.log, replay_*.log   Gradle/JVM crash dumps (git-ignored, safe to delete)
```

The original web project is in `F:\Finance_Tracker_App`. Do not touch it.

## Architecture (mobile/lib)

**The key rule:** screens talk only to the interfaces in
[services/services.dart](mobile/lib/services/services.dart) (through
`context.services`). [main.dart](mobile/lib/main.dart) is the **only** place
that chooses between `remoteServices(ApiClient())` (cloud) and
`localServices(LocalDb…)` (offline). Optional services (`capture`, `backup`,
`insights`) are `null` in the cloud build, and the UI hides those features.

| Folder | What is in it |
|---|---|
| `core/` | `app_state.dart` (profile, theme, hide amounts; `isLocal` means no sign-in), `app_lock.dart` (fingerprint/PIN gate wrapping the whole navigator), `pro.dart` (`ProStatus`, `FreeLimits`, lock screens), `format.dart` (₹ lakh/crore), `api_client.dart` (cloud only) |
| `services/` | Interfaces + `remote/` implementations (cloud) |
| `local/` | Offline implementations: `local_db.dart` (SQLite3MultipleCiphers, key in Android Keystore), `schema.dart` (migrations; **current schema v7**), `local_money.dart`, `local_planning.dart`, `local_plans.dart`, `local_wealth.dart`, `local_capture.dart` (review inbox), `local_import.dart`, `local_backup.dart`, `local_insights.dart` (InsightEngine), Dart ports of backend maths (`finance_math`, `debt_math`, `tax_estimator`, `health_engine`, `assessment`, `py_round` = Python-compatible rounding) |
| `capture/` | `sms_parser.dart`, `receipt_parser.dart` (OCR'd screenshots), `rules.dart` (learning rules), `categorizer.dart`, `sms_sync.dart`, `app_capture.dart` (notification sync, Share to Finverse, ML Kit OCR) |
| `import/` | Statement and holdings import: CSV / xlsx / HTML-xls / PDF (pdfrx + ML Kit OCR for scanned pages) |
| `backup/` | Encrypted backup file (ChaCha20 SQLite, PBKDF2 600k), Google Drive appDataFolder, auto backup |
| `export/` | Excel / CSV / PDF export (bundled Roboto for the ₹ sign) |
| `insights/` | `insight_alerts.dart`: phone notifications (flutter_local_notifications) |
| `screens/compare_screen.dart`, `screens/wealth_overview.dart` | Compare months; extra Wealth cards. Data from `InsightsService.compareMonths` / `wealthOverview` (InsightEngine in `local_insights.dart`) |
| `screens/`, `widgets/` | UI |

Native Android (Kotlin, `mobile/android/app/src/main/kotlin/com/finverse/finance_tracker_mobile/`):
- `SmsReader.kt`: channel `finverse/sms`, reads bank SMS (letter sender IDs only).
- `PaymentNotificationListener.kt`: queues UPI-app notifications (channel `finverse/capture`, `drainNotifications`).
- `MainActivity.kt`: `FlutterFragmentActivity` (needed by local_auth). Receives shares: the image is decoded and saved as a JPEG in `cache/shared/`, then given to Dart via `takeShared`.

Package / applicationId: `com.finverse.finance_tracker_mobile`. Release signing
reads `mobile/android/key.properties` (git-ignored) and falls back to debug signing if it is missing.

## History: what has been done (branch `local-first`)

All work is on the **`local-first`** branch (pushed to origin). `main` still has only the first commit.

| Commit | Step | What |
|---|---|---|
| 5d7eeb0 | — | First commit: Flutter cloud app + backend copy |
| fc8b8e1 | 0 | Services layer + Python→Dart parity fixtures |
| 77b1e88 | 1 | Encrypted on-phone DB, local Money (accounts, categories, transactions, budgets), profile, app lock |
| 2225e07 | 2 | Bank SMS capture, history scan, swipe review inbox, learned categories |
| 4388a20 | 3 | UPI notification listener + Share to Finverse (ML Kit OCR, rule-based ReceiptParser) |
| 6828f3c | 4a | Calculators + income tax on the phone |
| b0c8ffd | 4b | Goals, debts, insurance |
| 51ab14c | 4c | Wealth holdings, Bills & recurring |
| 1f74f57 | 4d | Financial health + rule-based Financial check-up |
| c35e5d3 | fix | R8 release build: `-dontwarn` for optional ML Kit scripts (`proguard-rules.pro`) |
| a657a53 | 3.5 | Smarter inbox: capture rules (UPI ID / name / wording → type+category+account, auto-add, ignore), own-money TRANSFERs, choosing how much SMS history to read |
| 8dce235 | 5 | Import statements and holdings on the phone |
| 63e57d2 | 6 | Encrypted backup & restore (file + Google Drive), Excel/CSV/PDF export |
| a32bf37 | 7 | Smart insights + phone notifications (rules, no AI) |
| 164f0c8 | 8* | Step 8 (AI chat) **skipped**. Instead: Trends & comparisons screen, vs-last-month tiles, daily net-worth snapshots (schema v6); AI advisor hidden offline |
| 659de4b | — | Free and Pro: locks, free limits, upgrade screen, Pretend Pro switch |
| e36d606 | fix | Share to Finverse: decode shared images natively and save as JPEG; friendly error text (did not fix the crash, see 398d5a8) |
| 398d5a8 | fix | **Real share/OCR crash fix:** AGP 9 R8 strict mode stripped ML Kit registrar constructors → `android.r8.strictFullModeForKeepRules=false` + keep rules |
| 1944b09 | fix | "Read older SMS" brings back payments deleted from Money / ignored by hand (`ingest(restore: true)`); SMS card says what a read found |
| 644aa61 | — | Compare months (category → subcategory → payees), 7 more insight rules, Wealth overview (net worth chart, cushion, debt ratios, best/worst holdings, accounts) |
| a386301 | — | Phone-test feedback: inbox Ignore all / choose several / 2-second Undo; passive income from holdings (asset-linked INCOME schedules, auto-add payouts); goal kinds for purchases + monthly saving tracker (schema v7: `goals.goal_kind`, Big purchases category); Money subcategory drill-down; net worth time frames; calculator charts |

Run `git log --stat` for the details. The commit messages describe each feature.

### Free vs Pro (offline build)
Free: 3 accounts, 3 budgets, 5 bills/recurring, 30 auto-captured payments a month,
SIP/lumpsum/EMI calculators, CSV export, app lock, manual backup.
Pro: Wealth, Goals, Insights, Trends, Import, Tax, Health & check-up, Debts,
Insurance, auto-categorise rules, CAGR/FIRE, Excel/PDF export, auto Drive backup, no limits.
Limits live in `FreeLimits` in [core/pro.dart](mobile/lib/core/pro.dart). For now
`isPro` comes only from Pretend Pro; Play Billing is not connected yet.

## What comes next (open items)

1. **User's phone test** of the offline build, then fix what they find
   (first one found and fixed: e36d606, the share crash).
2. **Tune the SMS / receipt / statement parsers** on real (masked) data. When
   a real message isn't recognised, add an anonymised copy to
   `mobile/test/capture/sms_parser_test.dart` (or `receipt_parser_test.dart`),
   then fix the parser.
3. **Google Play Billing** to set `ProStatus.isPro` from a real purchase.
4. **Google Drive backup setup** (user action): in Google Cloud, create an
   Android OAuth client for `com.finverse.finance_tracker_mobile` with the
   release SHA-1, and enable the Drive API. As of 2026-11-24 this was not done,
   so Drive backup will not sign in until it is.
5. **Make the offline build the default**, and prepare for Play Store: SMS
   permission declaration ("SMS-based money management"), notification-listener
   disclosure, privacy policy, proper release signing.
6. Later: merge `local-first` into `main` (only when the user asks).

## How to work in this repo

- **Workflow the user wants:** finish a piece of work, run analyze/tests/build
  yourself, then **commit and push to `local-first`** and keep going without
  asking "shall I commit?". Summarise what changed. The user tests on their
  phone, so explain things simply and say which APK to install.
- **Verify every change:**
  ```powershell
  cd mobile
  flutter analyze
  flutter test                      # ~300+ tests, all must pass
  flutter build apk --release --dart-define=FINVERSE_MODE=local --dart-define=FINVERSE_DEV=true
  ```
  Output: `mobile/build/app/outputs/flutter-apk/app-release.apk`. A release
  build is needed to catch R8/ProGuard problems, and the first Gradle run
  sometimes fails for no clear reason, so retry once before investigating.
- **Porting backend logic:** treat `backend/app/services/*.py` as the spec. Add
  cases to `tools/parity/generate_fixtures.py`, run
  `python tools/parity/generate_fixtures.py`, and add or extend a test in
  `mobile/test/parity/`. Document any deliberate difference at the top of the Dart file.
- **Database changes:** add a new migration at the end of
  [local/schema.dart](mobile/lib/local/schema.dart) (never edit old ones).
  Restoring a backup migrates old files, so keep `local_backup` working.
- **New offline feature:** add a method to the interface in `services.dart`,
  implement it in `local/` (and in `remote/` or throw
  `NotAvailableYetException`), and gate Pro features with `ProStatus`/`FreeLimits`.
- **Commits on Windows:** PowerShell 5.1 breaks inline multi-line `-m` messages.
  Use the Bash tool with `git commit -F - <<'EOF' … EOF`, or `git commit -F <file>`.
- **Never commit or print** anything from `signing/`, `key.properties` or `.env`.
- **Release-only crashes:** the project uses AGP 9 (R8 full mode). Anything a
  library creates by reflection needs keep rules. To check, unzip the APK and run
  `dexdump` (Android SDK `build-tools/37.0.0`) on `classes*.dex` to see whether
  a class still has its `<init>`. There is no working emulator on this PC
  (no hypervisor driver), so the user tests on their phone.
- **Deleting captured payments** in Money marks them `IGNORED` (not erased) so
  automatic SMS reads never bring them back; only "Read older SMS" restores them.
- Writing style the user prefers: plain, simple English in UI text and in
  explanations; no jargon in user-facing messages; no raw stack traces in the UI.
