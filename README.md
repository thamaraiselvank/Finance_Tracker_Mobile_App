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
- **Already on the phone:** accounts, categories, transactions, budgets, and
  net worth from account balances.
- **Bank SMS → review inbox (Android):** after the user allows SMS access,
  Finverse reads SMS from banks and payment apps (letter sender IDs only;
  personal messages are never read into the app), first for the last 180
  days, then whenever the app is opened. Each payment waits in **More →
  Review inbox** (also shown on Home): swipe right to add it to Money, left
  to ignore, tap to edit; every action can be undone. Category choices are
  remembered per merchant, and account last digits are learned, so later
  payments arrive already filled in. The same payment seen twice (for example
  SMS plus a payment-app message) is merged.
  The parser is `lib/capture/sms_parser.dart`. If a real SMS isn't recognised,
  add an anonymised copy to `test/capture/sms_parser_test.dart` and fix the
  parser.
  Publishing on Google Play needs the SMS permission declaration
  ("SMS-based money management").
- **Not moved yet** (these show "not in the offline version yet"): investments,
  goals, debts, insurance, bills & recurring, tax, calculators, financial
  health, import and AI. Each later step moves more areas to the phone, and
  local data is never mixed with server data.

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
| `capture/` | SMS parser, category suggestions, SMS sync (reads new SMS on app open) |
| `local/local_capture.dart` | Review inbox: pending payments, duplicates, confirm / ignore / undo, learning |
| `android/.../SmsReader.kt` | Native SMS inbox reader (channel `finverse/sms`) |
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
