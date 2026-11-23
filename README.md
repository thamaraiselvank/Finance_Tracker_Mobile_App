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
| `services/remote/` | Current implementations, which call the backend. They are being replaced one by one with local (SQLite) versions |
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
