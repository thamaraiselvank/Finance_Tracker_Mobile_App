# Finverse Mobile

Flutter (Android + iOS) version of the Finverse personal finance app.

```text
Finance_Tracker_Mobile_App/
├── mobile/    # Flutter app (Android + iOS)
└── backend/   # Copy of the FastAPI backend, kept for future mobile-specific changes
```

The original web project in `F:\Finance_Tracker_App` is untouched.

## Which backend does the app use?

By default the app talks to the **live deployed backend**:

```
https://finverse-api-1079638201272.asia-south1.run.app/api
```

Sign in with the same account you use on the web app; all data is shared.

The `backend/` folder here is a copy kept for future changes (for example a
localised version). It is **not** used by the app until you point the app at it:

```powershell
flutter run --dart-define=API_BASE_URL=http://<your-laptop-ip>:8000/api
```

(Use your laptop's Wi-Fi IP, not `127.0.0.1`, because the phone is a separate device.)

## Offline (phone-only) version, in progress

The app is moving to a **local-first** design: all data in an encrypted SQLite
database on the phone, no account and no server. Run it with:

```powershell
flutter run --dart-define=FINVERSE_MODE=local
flutter build apk --dart-define=FINVERSE_MODE=local
```

In this mode:

- There is no sign-in. A local profile is created on first launch, and an
  optional **App lock** (fingerprint / face / phone PIN) is in More → Profile.
- The database file is encrypted (SQLite3 Multiple Ciphers). Its random key is
  kept in the Android Keystore and never leaves the phone. Android auto-backup
  is off, because a restored file could not be decrypted on a new phone.
- **Already on the phone:** accounts, categories, transactions, budgets,
  Wealth holdings and net worth (stock prices refresh from Yahoo Finance's
  public quotes; only ticker symbols are sent), goals, debts and payoff plans,
  insurance, Bills & recurring, all calculators, the income-tax estimate,
  Financial health and the Financial check-up (rule-based, no AI).
- **Bank SMS → review inbox (Android):** after the user allows SMS access,
  Finverse reads SMS from banks and payment apps (letter sender IDs only;
  personal messages are never read into the app). After allowing access the
  user chooses how far back to read (only new messages, 15 days, 1 month,
  3 months or 6 months); after that only new SMS are read, whenever the app
  is opened, and older ones can be read later ("Read older SMS…"). Each
  payment waits in **More → Review inbox** (also shown on Home): swipe right
  to add it to Money (green), left to ignore (red), tap to edit; every action
  can be undone. Each card shows where it was seen (SMS · bank, Google Pay
  notification, screenshot; a payment seen twice is merged and shows both)
  and why it got its category ("Learned from your choice", "Built-in",
  "Guess · please check").
- **Learning (`lib/capture/rules.dart`):** confirming a payment teaches
  Finverse its type and category for that payee. Tapping the category opens
  "What is this payment?" (Income / Spending / Own money / Ignore, category,
  detail) with **Do the same for payments like this**, optionally **Add
  these to Money automatically** and **Also change the N already added**
  (balances corrected). Payments are recognised by the other side's UPI ID,
  then their name (also from NEFT / IMPS formats), then, for messages with
  no name, the message's wording without amounts, dates and numbers. Money
  in and money out are separate rules. Rules are listed, edited and deleted
  in **More → Auto-categorise rules**.
- **Own money (transfers):** broker funds (Zerodha's quarterly settlement,
  adding funds to Kite, Groww, Upstox…), credit card bill payments, ATM cash,
  wallet top-ups and self transfers are recognised by built-in rules. They
  move the account balance but never count as income or spending (totals,
  budgets, savings rate, Financial health, tax). Account last digits are
  learned too, so later payments arrive already filled in.
  The parser is `lib/capture/sms_parser.dart`. If a real SMS isn't recognised,
  add an anonymised copy to `test/capture/sms_parser_test.dart` and fix the
  parser.
  Publishing on Google Play needs the SMS permission declaration
  ("SMS-based money management").
- **UPI app notifications (Android):** after the user turns on Notification
  access for Finverse (button in the Review inbox), payment notifications from
  Google Pay, PhonePe, Paytm, BHIM, CRED, Amazon Pay and MobiKwik are queued,
  even while Finverse is closed, and go to the review inbox when it opens.
  Notifications from any other app, or without an amount, are dropped
  immediately. A notification and the bank SMS for the same payment become
  one item, with the SMS adding the account digits and UPI reference.
- **Share to Finverse:** share a payment screenshot or payment text from any
  app. Screenshots are read **on the phone** with Google ML Kit text
  recognition (offline OCR, no AI, nothing uploaded). The rules in
  `lib/capture/receipt_parser.dart` take the tallest amount on the screen,
  the name after "Paid to" / "Received from", the UPI reference, the bank and
  account digits, the note and the receipt's own date and time. The payment
  then waits in the review inbox like the others.
- **Import (More → Import), read on the phone, nothing uploaded:**
  - Bank statements as CSV, Excel (.xlsx, and bank ".xls" downloads that are
    really web pages) or PDF. Typed PDFs are read with PDFium (pdfrx);
    scanned pages are read with ML Kit's offline text recognition. A PDF
    password is used only to open the file and is never stored. Old binary
    .xls files must be saved as .xlsx or CSV first.
  - Every row gets the type and category an SMS for the same payment would
    get: your rules, then the built-in own-money rules (Zerodha settlements,
    ATM cash, card bills…), then a keyword guess. The payee is read from
    narrations like `UPI/DR/…/SWIGGY/…` or `NEFT CR-…-ZERODHA BROKING LTD-…`.
  - Payments already in the chosen account (from SMS, a notification, a
    screenshot or an earlier import, within 2 days and same amount) are
    marked "Already in Money" and left unticked; so are payments a rule says
    to ignore. Rows can be corrected, including "Own money in / out" and the
    category, before importing.
  - Broker holdings (Groww, Zerodha Console, Upstox, Angel One, any CSV /
    Excel): a holding already in Wealth (same ISIN or name) is updated
    instead of added twice.
  - Parsing is ported from `backend/app/services/importer.py` and checked
    against it (`test/parity/import_parity_test.dart`), with a few
    deliberate fixes listed at the top of `lib/import/statement_parser.dart`.
- **Not moved yet** (shows "not in the offline version yet"): the AI chat.
  Local data is never mixed with server data.
- Every ported calculation is checked against the Python backend with
  fixtures from `tools/parity/generate_fixtures.py` (calculators, tax, debt
  payoff plans, Bills & recurring calendar, Wealth summary, Financial health,
  Financial check-up, rounding). One intentional difference: the Debts
  screen's average interest rate is a plain average (the backend halved it by
  averaging with an empty liabilities table).

### Free and Pro (offline build)

One app for everyone; Pro features are locked until Pro is unlocked
(`lib/core/pro.dart`). Free: up to 3 accounts, 3 budgets, 5 bills &
recurring items, 30 automatic payments (SMS / UPI / screenshots) a month,
SIP / lumpsum / EMI calculators, CSV export, app lock and manual backup.
Pro: Wealth, Goals, Insights, Trends, Import, Tax, Financial health and
check-up, Debts, Insurance, auto-categorise rules, CAGR / FIRE calculators,
Excel / PDF export, automatic Drive backup, no limits. The cloud build has
everything open.

Buying is not connected yet (Google Play Billing is the next step). To test
both versions, build with the developer switch and use
**More → Developer → Pretend Pro**:

```powershell
flutter build apk --release --dart-define=FINVERSE_MODE=local --dart-define=FINVERSE_DEV=true
```

The Developer screen only exists in debug runs and builds with
`FINVERSE_DEV=true`; never pass it for the Play Store build.

The default build (without `FINVERSE_MODE`) is unchanged and still uses the
live backend with sign-in.

## Run on an Android phone

1. On the phone: enable **Developer options** and **USB debugging**.
2. Connect it by USB and tap **Allow** on the "Allow USB debugging?" prompt.
3. In PowerShell:

   ```powershell
   cd F:\Finance_Tracker_Mobile_App\mobile
   flutter devices      # your phone should be listed
   flutter run          # pick your phone if asked
   ```

The first build takes several minutes; later builds are much faster.
While `flutter run` is active, press `r` to hot-reload after code changes, `q` to quit.

## Build an installable APK

```powershell
flutter build apk --release
```

Output: `mobile\build\app\outputs\flutter-apk\app-release.apk`.
(The release build currently uses debug signing; set up a proper signing key
before publishing to the Play Store.)

## iOS

Building for iOS requires a Mac with Xcode. Copy this folder to the Mac, then:

```bash
cd mobile
flutter pub get
cd ios && pod install && cd ..
flutter run
```

## App structure (`mobile/lib`)

| Path | Purpose |
|---|---|
| `config.dart` | API base URL (overridable with `--dart-define`) |
| `core/api_client.dart` | HTTP client, bearer token, automatic token refresh |
| `core/app_state.dart` | Signed-in user, theme, hide-amounts, sign in/out |
| `core/format.dart` | Currency (₹ lakh/crore), dates, JSON number helpers |
| `services/services.dart` | The data layer: one interface per area (accounts, transactions, goals, tax…). Screens only talk to these, via `context.services` |
| `services/remote/` | Cloud implementations, which call the backend (default build) |
| `local/` | Phone-only implementations: encrypted SQLite database (`local_db.dart`, `schema.dart`), Money services (`local_money.dart`), profile and placeholders (`local_services.dart`), Python-compatible rounding (`py_round.dart`) |
| `core/app_lock.dart` | Fingerprint / PIN app lock for the phone-only version |
| `capture/` | SMS and notification parser, screenshot (OCR) receipt parser, category suggestions, SMS / notification sync, Share to Finverse |
| `local/local_capture.dart` | Review inbox: pending payments, duplicates, confirm / ignore / undo, learning |
| `import/` | Statement / holdings import on the phone: CSV / .xlsx / HTML-table reader, statement and holdings parsers, PDF reader (PDFium + ML Kit OCR), table layout from word positions, payee names from narrations |
| `local/local_import.dart` | Import service: suggested categories, "already in Money" detection, saving rows and holdings |
| `android/.../SmsReader.kt` | Native SMS inbox reader (channel `finverse/sms`) |
| `android/.../PaymentNotificationListener.kt` | Queues payment-app notifications (channel `finverse/capture`) |
| `android/.../MainActivity.kt` | Receives shared screenshots / text for "Share to Finverse" |
| `screens/` | Auth, onboarding, Home, Money, Wealth, Goals, Debts, Insurance, AI advisor, Calculators, Profile |
| `widgets/` | Shared UI: stat tiles, forms, empty/error states |

Which implementation is used is decided in one place, `main.dart`.

Login tokens are stored with `flutter_secure_storage` (Android Keystore / iOS Keychain).

## Python → Dart parity tests

The backend's logic is being rewritten in Dart so the app can run fully on the
phone. To prove the Dart version gives the same answers:

1. `tools/parity/generate_fixtures.py` runs the real backend code on sample
   inputs (including invalid ones) and saves inputs plus results to
   `mobile/test/parity/fixtures/*.json`.
2. Dart tests in `mobile/test/parity/` run the same inputs through the Dart
   code and fail with the exact field that differs.

Regenerate fixtures after changing backend logic or adding cases:

```powershell
python tools/parity/generate_fixtures.py
cd mobile; flutter test
```
