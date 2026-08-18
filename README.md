# expo-deploy

Local build & deploy for Expo apps — a self-hosted replacement for EAS Build/Submit.

Builds happen on your machine with your own toolchain and signing keys; nothing
touches Expo's servers. One script, both stores.

## Usage

```bash
./deploy.sh <project-dir> --ios       # build + upload to App Store Connect
./deploy.sh <project-dir> --android   # build + upload to Google Play (internal track)
./deploy.sh <project-dir> --both
```

Interactive on first run; answers are cached per app in
`~/.config/expo-deploy/<slug>.env` (chmod 600, never committed).

## What it does

**iOS** — `expo prebuild` → `xcodebuild archive` → export IPA → `altool` upload
to App Store Connect (App Store Connect API key auth).

**Android** — `expo prebuild` → stamp versionCode → Gradle `bundleRelease` →
fastlane `upload_to_play_store`. Key behaviors:

- **versionCode from the Play API**: max across uploaded bundles and all four
  tracks, +1. Self-healing — a failed build can never burn a number, and no
  local/remote counter to drift.
- **Upload-key pinning**: set `ANDROID_UPLOAD_CERT_SHA1` in the app's env and
  the script refuses to build if the keystore's cert doesn't match — a wrong
  key otherwise means a Play rejection and a support-ticket recovery.
- **Toolchain preflight**: resolves JDK 17 (incl. Homebrew's off-PATH
  `openjdk@17`) and the Android SDK, failing with exact install commands.
- `PLAY_TRACK` (default `internal`) and `PLAY_RELEASE_STATUS` (default
  `completed`) override the upload target.

## Prerequisites

macOS with: Xcode, `brew install openjdk@17 fastlane`,
`brew install --cask android-commandlinetools` (+ `sdkmanager` platforms/build-tools/NDK),
Node for `npx expo`. Android needs a Play service-account JSON and your upload
keystore; iOS needs an ASC API key.

## Per-app config (`~/.config/expo-deploy/<slug>.env`)

```
APPLE_TEAM_ID / ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH
GOOGLE_SERVICE_ACCOUNT_KEY
ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD / ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD
ANDROID_UPLOAD_CERT_SHA1
```

Secrets live only in these files — the script contains none.

## Gotchas learned the hard way

- Don't pipe the script through `tee`/`tail` — the pipeline's exit status masks
  build failures. Redirect to a file instead.
- A release build needs several GB of scratch; "No space left on device"
  surfaces as dozens of Gradle lock errors. Read the FIRST "What went wrong".
- If migrating off EAS: export the EAS-managed upload keystore first. A freshly
  generated keystore is rejected by Play App Signing.
