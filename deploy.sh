#!/bin/bash
set -euo pipefail

# =============================================================================
# Local Build & Deploy for Expo apps (replaces EAS Build)
# =============================================================================
#
# Usage: ./deploy.sh [project-dir] [--ios | --android | --both]
#
# Interactive CLI — prompts for anything it needs, caches answers in
# ~/.config/eascape/<project-slug>.env for next time.
#
# =============================================================================

# CocoaPods aborts without a UTF-8 locale ("Unicode Normalization not
# appropriate for ASCII-8BIT"), and a non-interactive shell (cron, an agent,
# ssh without a login profile) has none. Only when nothing at all is set.
if [[ -z "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" ]]; then
  export LANG=en_US.UTF-8
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}==> $1${NC}"; }
warn()  { echo -e "${YELLOW}==> $1${NC}"; }
error() { echo -e "${RED}==> $1${NC}"; exit 1; }
ask()   { echo -en "${CYAN}?${NC} ${BOLD}$1${NC} "; }

CONFIG_DIR="$HOME/.config/eascape"
mkdir -p "$CONFIG_DIR"

# =============================================================================
# Detect project
# =============================================================================

PROJECT_DIR=""
PLATFORM=""

# Parse args
for arg in "$@"; do
  case $arg in
    --ios)     PLATFORM="ios" ;;
    --android) PLATFORM="android" ;;
    --both)    PLATFORM="both" ;;
    *)
      if [[ -z "$PROJECT_DIR" ]]; then
        PROJECT_DIR="$arg"
      fi
      ;;
  esac
done

# Default to current directory
if [[ -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$(pwd)"
fi

# Resolve to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || error "Directory not found: $PROJECT_DIR"

# Verify it's an Expo project
if [[ ! -f "$PROJECT_DIR/app.json" ]] && [[ ! -f "$PROJECT_DIR/app.config.js" ]] && [[ ! -f "$PROJECT_DIR/app.config.ts" ]]; then
  error "Not an Expo project (no app.json/app.config.js found in $PROJECT_DIR)"
fi

cd "$PROJECT_DIR"

# Export production env vars from eas.json so they override .env (localhost)
if [[ -f "$PROJECT_DIR/eas.json" ]]; then
  log "Loading production env vars from eas.json..."
  eval "$(python3 -c "
import json, os, shlex
with open('eas.json') as f:
    eas = json.load(f)
env = eas.get('build', {}).get('production', {}).get('env', {})
for k, v in env.items():
    if k not in os.environ:
        print(f'export {k}={shlex.quote(v)}')
")"
fi

# Read app info from app.json
APP_NAME=$(python3 -c "
import json, os
for f in ['app.json', 'app.config.js']:
    if os.path.exists(f):
        if f.endswith('.json'):
            d = json.load(open(f))
            print(d.get('expo', d).get('name', ''))
        break
" 2>/dev/null)

APP_SLUG=$(python3 -c "
import json, os
for f in ['app.json', 'app.config.js']:
    if os.path.exists(f):
        if f.endswith('.json'):
            d = json.load(open(f))
            print(d.get('expo', d).get('slug', ''))
        break
" 2>/dev/null)

IOS_BUNDLE_ID=$(python3 -c "
import json, os
for f in ['app.json', 'app.config.js']:
    if os.path.exists(f):
        if f.endswith('.json'):
            d = json.load(open(f))
            e = d.get('expo', d)
            print(e.get('ios', {}).get('bundleIdentifier', ''))
        break
" 2>/dev/null)

ANDROID_PACKAGE=$(python3 -c "
import json, os
for f in ['app.json', 'app.config.js']:
    if os.path.exists(f):
        if f.endswith('.json'):
            d = json.load(open(f))
            e = d.get('expo', d)
            print(e.get('android', {}).get('package', ''))
        break
" 2>/dev/null)

if [[ -z "$APP_NAME" ]]; then
  ask "App name:"
  read APP_NAME
fi

if [[ -z "$APP_SLUG" ]]; then
  APP_SLUG=$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
fi

# Load cached config for this project
CONFIG_FILE="$CONFIG_DIR/${APP_SLUG}.env"
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
fi

echo ""
echo -e "${BOLD}$APP_NAME${NC} — Local Build & Deploy"
echo -e "Project: $PROJECT_DIR"
echo ""

# =============================================================================
# Platform selection
# =============================================================================

if [[ -z "$PLATFORM" ]]; then
  echo -e "  ${BOLD}1)${NC} iOS"
  echo -e "  ${BOLD}2)${NC} Android"
  echo -e "  ${BOLD}3)${NC} Both"
  echo ""
  ask "Platform [1/2/3]:"
  read PLATFORM_CHOICE
  case ${PLATFORM_CHOICE:-1} in
    1) PLATFORM="ios" ;;
    2) PLATFORM="android" ;;
    3) PLATFORM="both" ;;
    *) error "Invalid choice" ;;
  esac
fi

log "Platform: $PLATFORM"

# =============================================================================
# Save a config value
# =============================================================================
save_config() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    # Update existing
    local tmp
    tmp=$(mktemp)
    sed "s|^${key}=.*|${key}=\"${val}\"|" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
  else
    echo "${key}=\"${val}\"" >> "$CONFIG_FILE"
  fi
  chmod 600 "$CONFIG_FILE"
}

# =============================================================================
# Prompt for a value (uses cached, env, or asks)
# =============================================================================
require_value() {
  local var_name="$1" prompt="$2" secret="${3:-false}"
  local current_val="${!var_name:-}"

  if [[ -n "$current_val" ]]; then
    if [[ "$secret" == "true" ]]; then
      echo -e "  ${var_name}: ${CYAN}(cached)${NC}"
    else
      echo -e "  ${var_name}: ${CYAN}${current_val}${NC}"
    fi
    return
  fi

  if [[ "$secret" == "true" ]]; then
    ask "$prompt"
    read -s "$var_name"
    echo ""
  else
    ask "$prompt"
    read "$var_name"
  fi

  save_config "$var_name" "${!var_name}"
}

# =============================================================================
# iOS Build & Deploy
# =============================================================================

# Raise CocoaPods targets that sit below the app's own iOS deployment target.
#
# Xcode 27 made a deployment target below its supported range (15.0 and up) an
# error instead of a warning. React Native's post_install lifts each pod's
# native target to the app's minimum but not its resource-bundle targets, which
# keep the podspec's value (Google Mobile Ads and UMP: 12.0, AsyncStorage:
# 13.4), and the archive fails on them.
#
# Nothing embedded in the app has to run on an OS older than the app itself, so
# whatever is lower is raised to the app's target. Targets at or above it are
# left alone. ios/ is regenerated by every prebuild, so the app's repo is not
# touched.
raise_pod_deployment_targets() {
  python3 - <<'PODEOF'
import glob, re

SETTING = re.compile(r'(IPHONEOS_DEPLOYMENT_TARGET = )"?(\d+(?:\.\d+)*)"?;')


def version(text):
    return tuple(int(part) for part in text.split("."))


# The app's own target: every project in ios/ that is not CocoaPods'.
app_targets = set()
for path in glob.glob("ios/*.xcodeproj/project.pbxproj"):
    source = open(path, encoding="utf-8").read()
    app_targets.update(match.group(2) for match in SETTING.finditer(source))
if not app_targets:
    print("  Could not read the app's iOS deployment target; pod targets left as they are.")
    raise SystemExit(0)
floor = min(app_targets, key=version)

raised = {}


def lift(match):
    if version(match.group(2)) >= version(floor):
        return match.group(0)
    raised[match.group(2)] = raised.get(match.group(2), 0) + 1
    return match.group(1) + floor + ";"


for path in glob.glob("ios/Pods/*.xcodeproj/project.pbxproj"):
    source = open(path, encoding="utf-8").read()
    patched = SETTING.sub(lift, source)
    if patched != source:
        open(path, "w", encoding="utf-8").write(patched)

if raised:
    detail = ", ".join(
        "%d at %s" % (raised[old], old) for old in sorted(raised, key=version)
    )
    print("  Raised %d pod build configuration(s) to iOS %s (%s)."
          % (sum(raised.values()), floor, detail))
else:
    print("  All pod targets are already at iOS %s or above." % floor)
PODEOF
}

# The Delivery UUID altool prints after an upload, if it printed one.
altool_delivery_id() {
  sed -n 's/.*Delivery UUID: *\([0-9A-Fa-f-]\{36\}\).*/\1/p' <<< "$1" | tail -1
}

# True once App Store Connect lists this delivery as a build it has not
# rejected. The build record appears a little after altool returns (about a
# minute when this was written), so this keeps asking for up to three minutes.
delivery_on_app_store_connect() {
  local delivery_id="$1" attempt status
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    status=$(xcrun altool --build-status \
      --delivery-id "$delivery_id" \
      --apiKey "$ASC_KEY_ID" \
      --apiIssuer "$ASC_ISSUER_ID" 2>&1) || true
    if grep -qi "DELIVERY-UUID: *$delivery_id" <<< "$status"; then
      if grep -Eq "BUILD-STATUS: *(INVALID|FAILED)" <<< "$status"; then
        return 1
      fi
      return 0
    fi
    [[ "$attempt" -eq 12 ]] || sleep 15
  done
  return 1
}

# Whether an altool upload went through, judged from its output.
#
# The exit status is not enough: altool can exit 0 after printing an ERROR and
# no success line. The output alone is not enough either: altool retries
# transient network errors itself, so a run can log "ERROR: ... The request
# timed out" and still end with "UPLOAD SUCCEEDED" and a Delivery UUID. Calling
# that a failure stopped a --both run before Android while the build was
# sitting in App Store Connect (2026-10-10).
#
#   no "UPLOAD SUCCEEDED"                -> failed
#   "UPLOAD SUCCEEDED", no ERROR lines   -> succeeded
#   "UPLOAD SUCCEEDED" and ERROR lines   -> ask App Store Connect whether it
#                                           has the delivery
altool_upload_ok() {
  local output="$1" delivery_id
  grep -q "UPLOAD SUCCEEDED" <<< "$output" || return 1
  grep -q "ERROR" <<< "$output" || return 0

  delivery_id=$(altool_delivery_id "$output")
  if [[ -z "$delivery_id" ]]; then
    warn "altool reported success after logging errors, with no Delivery UUID to check."
    return 1
  fi
  warn "altool logged errors before reporting success. Confirming delivery $delivery_id with App Store Connect..."
  if delivery_on_app_store_connect "$delivery_id"; then
    log "App Store Connect has delivery $delivery_id."
    return 0
  fi
  warn "App Store Connect does not list delivery $delivery_id as a good build. Look there before re-running: a second upload of the same build number is rejected."
  return 1
}

build_ios() {
  log "Starting iOS build..."

  if ! command -v xcodebuild &>/dev/null; then
    error "Xcode not found. Install Xcode from the App Store first."
  fi

  # Check for signing identity
  local identity_count
  identity_count=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "valid identities found" || true)
  local has_identity
  has_identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Apple D" || true)
  if [[ "$has_identity" -eq 0 ]]; then
    warn "No Apple Developer signing certificate found in keychain."
    echo "  Open Xcode → Settings → Accounts → Manage Certificates"
    echo "  and create an Apple Distribution certificate."
    echo ""
    ask "Continue anyway? [y/N]:"
    read CONTINUE
    [[ "${CONTINUE:-n}" =~ ^[Yy] ]] || exit 1
  fi

  echo ""
  echo -e "${BOLD}iOS Configuration:${NC}"
  require_value APPLE_TEAM_ID "Apple Developer Team ID (10 chars, found at developer.apple.com/account):"
  require_value ASC_KEY_ID "App Store Connect API Key ID (from appstoreconnect.apple.com → Integrations → API Keys):"
  require_value ASC_ISSUER_ID "App Store Connect Issuer ID (shown above the keys list):"
  require_value ASC_KEY_PATH "Path to .p8 API key file:"
  echo ""

  if [[ -z "$IOS_BUNDLE_ID" ]]; then
    require_value IOS_BUNDLE_ID "iOS Bundle Identifier (e.g. com.myapp):"
  fi

  log "Running expo prebuild for iOS..."
  npx expo prebuild -p ios --clean

  local WORKSPACE
  WORKSPACE=$(find ios -maxdepth 1 -name "*.xcworkspace" | head -1)
  if [[ -z "$WORKSPACE" ]]; then
    error "No .xcworkspace found in ios/"
  fi

  log "Checking pod deployment targets..."
  raise_pod_deployment_targets

  # Find the right scheme — match app name, not random pod schemes
  local SCHEME
  SCHEME=$(xcodebuild -list -workspace "$WORKSPACE" -json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
schemes = data.get('workspace', {}).get('schemes', [])
app = '$APP_NAME'
match = next((s for s in schemes if s == app), None)
if not match:
    # Filter out common non-app schemes
    skip = ['Pods-', 'React', 'Expo', 'hermes', 'Yoga', 'RN', 'RCT', 'FB', 'EAS', 'EX']
    candidates = [s for s in schemes if not any(s.startswith(p) for p in skip)]
    match = candidates[0] if candidates else (schemes[0] if schemes else '')
print(match)
")

  if [[ -z "$SCHEME" ]]; then
    error "Could not determine Xcode scheme"
  fi

  # No Apple ID signed into Xcode on this Mac: let xcodebuild sign
  # automatically through the App Store Connect API key instead. (Not keyed on
  # the keychain: the first such archive leaves an Apple Development identity
  # behind, and the export still needs the key.)
  local AUTH_ARGS=()
  local xcode_accounts
  xcode_accounts=$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -c username || true)
  if [[ "$xcode_accounts" -eq 0 ]]; then
    AUTH_ARGS=(
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
  fi

  log "Building archive (scheme: $SCHEME)..."
  xcodebuild archive \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$BUILD_DIR/app.xcarchive" \
    -destination "generic/platform=iOS" \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    -quiet

  cat > "$BUILD_DIR/ExportOptions.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID}</string>
</dict>
</plist>
PLIST

  log "Exporting IPA..."
  # Start from an empty export dir: a stale IPA from a previous app/scheme in
  # here was once uploaded in place of the one just built.
  rm -rf "$BUILD_DIR/export"
  xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/app.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates \
    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    -quiet

  local IPA="$BUILD_DIR/export/$SCHEME.ipa"
  if [[ ! -f "$IPA" ]]; then
    error "Expected $IPA after export; found: $(find "$BUILD_DIR/export" -name '*.ipa' | tr '\n' ' ')"
  fi

  # Install API key where altool/notarytool expects it
  local API_KEY_DIR="$HOME/.appstoreconnect/private_keys"
  mkdir -p "$API_KEY_DIR"
  cp "$ASC_KEY_PATH" "$API_KEY_DIR/AuthKey_${ASC_KEY_ID}.p8" 2>/dev/null || true

  log "Uploading $(basename "$IPA") to App Store Connect..."
  # altool's exit status does not say whether it worked: see altool_upload_ok.
  local ALTOOL_OUT
  ALTOOL_OUT=$(xcrun altool --upload-app \
    -f "$IPA" \
    -t ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID" 2>&1 | tee /dev/stderr)
  if altool_upload_ok "$ALTOOL_OUT"; then
    log "iOS build uploaded to App Store Connect!"
    echo "  Go to https://appstoreconnect.apple.com to submit for review."
  else
    error "Upload to App Store Connect failed. Check the error above."
  fi
}

# =============================================================================
# Android Build & Deploy  (fully local - no EAS)
# =============================================================================

# Locate a JDK 17 and the Android SDK, exporting JAVA_HOME/ANDROID_HOME.
# Fails with the exact install command rather than dying deep inside Gradle.
ensure_android_toolchain() {
  if [[ -z "${JAVA_HOME:-}" ]] || [[ ! -x "${JAVA_HOME:-}/bin/javac" ]]; then
    local JDK17=""
    JDK17=$(/usr/libexec/java_home -v 17 2>/dev/null) || true
    if [[ -z "$JDK17" ]] && command -v brew &>/dev/null; then
      local BREW_JDK
      BREW_JDK="$(brew --prefix openjdk@17 2>/dev/null)/libexec/openjdk.jdk/Contents/Home"
      [[ -x "$BREW_JDK/bin/javac" ]] && JDK17="$BREW_JDK"
    fi
    [[ -n "$JDK17" ]] || error "JDK 17 not found. Install it with:
    brew install openjdk@17"
    export JAVA_HOME="$JDK17"
  fi
  export PATH="$JAVA_HOME/bin:$PATH"

  if [[ -z "${ANDROID_HOME:-}" ]]; then
    local CANDIDATE
    for CANDIDATE in "$HOME/Library/Android/sdk" "/opt/homebrew/share/android-commandlinetools"; do
      if [[ -d "$CANDIDATE" ]]; then export ANDROID_HOME="$CANDIDATE"; break; fi
    done
  fi
  [[ -n "${ANDROID_HOME:-}" ]] || error "Android SDK not found. Install it with:
    brew install --cask android-commandlinetools
    yes | sdkmanager --licenses"
  export ANDROID_SDK_ROOT="$ANDROID_HOME"
  export PATH="$ANDROID_HOME/platform-tools:$PATH"

  echo "  JDK: $JAVA_HOME"
  echo "  SDK: $ANDROID_HOME"
}

# Guard against uploading with the wrong upload key.
#
# Play App Signing accepts exactly one upload certificate. Signing with any
# other key is rejected, and recovering needs a support ticket. Pin the
# fingerprint in the app's config env (ANDROID_UPLOAD_CERT_SHA1) and this
# refuses to build when the keystore stops matching.
verify_upload_key() {
  local FINGERPRINT
  # The password goes through the environment (-storepass:env), never argv,
  # where `ps` would show it to every user on the machine.
  FINGERPRINT=$(ANDROID_KEYSTORE_PASSWORD="$ANDROID_KEYSTORE_PASSWORD" keytool -list -v \
    -keystore "$ANDROID_KEYSTORE_PATH" \
    -alias "$ANDROID_KEY_ALIAS" \
    -storepass:env ANDROID_KEYSTORE_PASSWORD 2>/dev/null \
    | grep -m1 "SHA1:" | sed 's/.*SHA1: *//' | tr -d ' \r')

  [[ -n "$FINGERPRINT" ]] || error "Could not read the certificate from $ANDROID_KEYSTORE_PATH (wrong password or alias?)"

  if [[ -z "${ANDROID_UPLOAD_CERT_SHA1:-}" ]]; then
    warn "ANDROID_UPLOAD_CERT_SHA1 is not pinned for this app."
    echo "  This keystore's cert: $FINGERPRINT"
    echo "  Compare it with Play Console > Test and release > App integrity >"
    echo "  Upload key certificate. If they match, pin it with:"
    echo "    echo 'ANDROID_UPLOAD_CERT_SHA1=\"$FINGERPRINT\"' >> $CONFIG_FILE"
    return
  fi

  if [[ "$FINGERPRINT" != "$ANDROID_UPLOAD_CERT_SHA1" ]]; then
    error "Upload key mismatch - refusing to build.
    keystore: $FINGERPRINT
    expected: $ANDROID_UPLOAD_CERT_SHA1
    Play would reject this AAB. Check ANDROID_KEYSTORE_PATH/ANDROID_KEY_ALIAS."
  fi
  log "Upload key verified ($FINGERPRINT)"
}

# Next Play versionCode = (highest Play has ever seen) + 1.
#
# Queried live from the Play API rather than tracked locally, so a failed build
# can never burn a number and nothing depends on EAS's remote counter. Checks
# uploaded bundles AND every track: a bundle that was uploaded but later
# superseded still occupies its versionCode forever.
next_version_code() {
  python3 - "$GOOGLE_SERVICE_ACCOUNT_KEY" "$ANDROID_PACKAGE" <<'VERSIONEOF'
import base64, json, sys, time, urllib.error, urllib.parse, urllib.request
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

key_path, package = sys.argv[1], sys.argv[2]
key = json.load(open(key_path))

# urlopen waits forever unless told otherwise. A connection to Google that
# opened and then never answered once held a build at this step for ten
# minutes, until the process was killed by hand (2026-10-13).
TIMEOUT_SECONDS = 30


def fetch(request, data=None):
    """One request, as JSON. A request that gets no answer is tried once more.

    An answer is never retried, a refusal included: HTTPError means Google
    replied. Anything else that goes wrong on the wire (a timeout, a reset, a
    failed lookup) is the transient kind, and a second connection usually
    gets through.
    """
    for attempt in (1, 2):
        try:
            with urllib.request.urlopen(request, data, timeout=TIMEOUT_SECONDS) as response:
                return json.load(response)
        except urllib.error.HTTPError:
            raise
        except OSError as error:
            if attempt == 2:
                raise
            print("  Play API did not answer (%s); trying once more..." % error, file=sys.stderr)


def b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


now = int(time.time())
header = b64(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
claims = b64(json.dumps({
    "iss": key["client_email"],
    "scope": "https://www.googleapis.com/auth/androidpublisher",
    "aud": "https://oauth2.googleapis.com/token",
    "iat": now,
    "exp": now + 3600,
}).encode())
signature = b64(
    serialization.load_pem_private_key(key["private_key"].encode(), None)
    .sign(header + b"." + claims, padding.PKCS1v15(), hashes.SHA256())
)
assertion = (header + b"." + claims + b"." + signature).decode()

token = fetch(
    "https://oauth2.googleapis.com/token",
    urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": assertion,
    }).encode(),
)["access_token"]

base = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/" + package


def api(path, method="GET"):
    request = urllib.request.Request(
        base + "/" + path,
        method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    return fetch(request)


edit = api("edits", method="POST")["id"]
highest = 0

for bundle in api("edits/%s/bundles" % edit).get("bundles") or []:
    highest = max(highest, int(bundle["versionCode"]))

for track in ("internal", "alpha", "beta", "production"):
    # A track Play refuses to describe has nothing to count. A track that
    # could not be asked about is different: skipping it could hand back a
    # versionCode that track already holds, so that failure stops the build.
    try:
        info = api("edits/%s/tracks/%s" % (edit, track))
    except urllib.error.HTTPError:
        continue
    for release in info.get("releases") or []:
        for code in release.get("versionCodes") or []:
            highest = max(highest, int(code))

# A brand-new Play app has no bundles and no releases yet; start at 1.
print(highest + 1)
VERSIONEOF
}

build_android() {
  log "Starting Android build..."

  echo ""
  echo -e "${BOLD}Android Configuration:${NC}"

  # Keystore setup
  if [[ -z "${ANDROID_KEYSTORE_PATH:-}" ]]; then
    ask "Android keystore path (or 'generate' to create one):"
    read ANDROID_KEYSTORE_PATH

    if [[ "$ANDROID_KEYSTORE_PATH" == "generate" ]]; then
      ANDROID_KEYSTORE_PATH="$CONFIG_DIR/${APP_SLUG}-release.keystore"
      ANDROID_KEY_ALIAS="release"

      ask "Keystore password:"
      read -s ANDROID_KEYSTORE_PASSWORD
      echo ""
      ANDROID_KEY_PASSWORD="$ANDROID_KEYSTORE_PASSWORD"

      log "Generating keystore at $ANDROID_KEYSTORE_PATH..."
      ANDROID_KEYSTORE_PASSWORD="$ANDROID_KEYSTORE_PASSWORD" keytool -genkeypair -v -storetype PKCS12 \
        -keystore "$ANDROID_KEYSTORE_PATH" \
        -alias "$ANDROID_KEY_ALIAS" \
        -keyalg RSA -keysize 2048 -validity 10000 \
        -storepass:env ANDROID_KEYSTORE_PASSWORD \
        -dname "CN=$APP_NAME"

      save_config ANDROID_KEYSTORE_PATH "$ANDROID_KEYSTORE_PATH"
      save_config ANDROID_KEY_ALIAS "$ANDROID_KEY_ALIAS"
      save_config ANDROID_KEYSTORE_PASSWORD "$ANDROID_KEYSTORE_PASSWORD"
      save_config ANDROID_KEY_PASSWORD "$ANDROID_KEY_PASSWORD"

      warn "IMPORTANT: Back up your keystore! You cannot update your app without it."
      warn "If this app is ALREADY on Play, a freshly generated keystore will be"
      warn "rejected as the wrong upload key. Export the existing upload keystore"
      warn "instead, or request an upload key reset from Google Play support."
    else
      save_config ANDROID_KEYSTORE_PATH "$ANDROID_KEYSTORE_PATH"
    fi
  fi

  require_value ANDROID_KEYSTORE_PATH "Android keystore path:"
  require_value ANDROID_KEYSTORE_PASSWORD "Keystore password:" true
  require_value ANDROID_KEY_ALIAS "Key alias [release]:"
  ANDROID_KEY_ALIAS="${ANDROID_KEY_ALIAS:-release}"
  require_value ANDROID_KEY_PASSWORD "Key password:" true
  echo ""

  if [[ ! -f "$ANDROID_KEYSTORE_PATH" ]]; then
    error "Keystore not found at: $ANDROID_KEYSTORE_PATH"
  fi

  if [[ -z "$ANDROID_PACKAGE" ]]; then
    require_value ANDROID_PACKAGE "Android package name (e.g. com.myapp):"
  fi

  require_value GOOGLE_SERVICE_ACCOUNT_KEY "Google Play service account JSON path:"
  if [[ ! -f "$GOOGLE_SERVICE_ACCOUNT_KEY" ]]; then
    error "Service account JSON not found at: $GOOGLE_SERVICE_ACCOUNT_KEY"
  fi

  if ! command -v fastlane &>/dev/null; then
    error "Fastlane not found. Install with: brew install fastlane"
  fi

  ensure_android_toolchain
  verify_upload_key

  log "Determining next versionCode from Play..."
  local VERSION_CODE
  VERSION_CODE=$(next_version_code) || error "Could not reach the Play API to determine the next versionCode."
  log "Next versionCode: $VERSION_CODE"

  log "Running expo prebuild for Android..."
  npx expo prebuild -p android --clean || error "expo prebuild failed."

  # prebuild regenerates android/ from app.json, which carries no versionCode,
  # so it always lands as 1. Stamp the Play-derived value in afterwards.
  # android/ is gitignored and disposable, so nothing in the repo is mutated.
  log "Stamping versionCode $VERSION_CODE into build.gradle..."
  python3 - "$VERSION_CODE" <<'STAMPEOF'
import re, sys

code = sys.argv[1]
path = "android/app/build.gradle"
source = open(path).read()
patched, count = re.subn(r"versionCode\s+\d+", "versionCode " + code, source, count=1)
if count != 1:
    sys.exit("could not find versionCode in " + path)
open(path, "w").write(patched)
STAMPEOF

  # Inject signing config. The four RELEASE_* values reach Gradle as project
  # properties through ORG_GRADLE_PROJECT_* on the gradlew call below, so the
  # passwords are never written into android/gradle.properties.

  local BUILD_GRADLE="android/app/build.gradle"
  if ! grep -q "signingConfigs.release" "$BUILD_GRADLE" 2>/dev/null; then
    log "Adding release signing config to build.gradle..."
    python3 << 'PYEOF'
import re, sys

with open("android/app/build.gradle", "r") as f:
    content = f.read()

signing_config = """
    signingConfigs {
        release {
            storeFile file(RELEASE_STORE_FILE)
            storePassword RELEASE_STORE_PASSWORD
            keyAlias RELEASE_KEY_ALIAS
            keyPassword RELEASE_KEY_PASSWORD
        }
    }
"""

content = content.replace(
    "    buildTypes {",
    signing_config + "\n    buildTypes {"
)

# Only the release buildType switches keys. A blanket replace would also point
# the debug buildType at the release keystore, so scope the swap to the release
# block: match `release {` and the first signingConfig line that follows it.
content, swapped = re.subn(
    r"(release\s*\{[^}]*?signingConfig\s+signingConfigs\.)debug",
    r"\1release",
    content,
    count=1,
    flags=re.DOTALL,
)
if swapped != 1:
    sys.exit("could not point the release buildType at signingConfigs.release")

with open("android/app/build.gradle", "w") as f:
    f.write(content)
PYEOF
  fi

  log "Building Android AAB (first run downloads Gradle deps; takes a while)..."
  ( cd android && \
    ORG_GRADLE_PROJECT_RELEASE_STORE_FILE="$ANDROID_KEYSTORE_PATH" \
    ORG_GRADLE_PROJECT_RELEASE_STORE_PASSWORD="$ANDROID_KEYSTORE_PASSWORD" \
    ORG_GRADLE_PROJECT_RELEASE_KEY_ALIAS="$ANDROID_KEY_ALIAS" \
    ORG_GRADLE_PROJECT_RELEASE_KEY_PASSWORD="$ANDROID_KEY_PASSWORD" \
    ./gradlew bundleRelease ) || error "Gradle build failed. See the output above."

  local AAB="android/app/build/outputs/bundle/release/app-release.aab"
  if [[ ! -f "$AAB" ]]; then
    error "AAB not found at expected path"
  fi

  cp "$AAB" "$BUILD_DIR/app-release.aab"

  log "Uploading to Play Store via Fastlane (track: ${PLAY_TRACK:-internal}, status: ${PLAY_RELEASE_STATUS:-completed})..."
  fastlane run upload_to_play_store \
    "aab:$BUILD_DIR/app-release.aab" \
    "track:${PLAY_TRACK:-internal}" \
    "release_status:${PLAY_RELEASE_STATUS:-completed}" \
    "json_key:$GOOGLE_SERVICE_ACCOUNT_KEY" \
    "package_name:$ANDROID_PACKAGE" \
    "skip_upload_metadata:true" \
    "skip_upload_images:true" \
    "skip_upload_screenshots:true" || error "Play upload failed. See the output above."

  log "Android AAB (versionCode $VERSION_CODE) uploaded to Play Store (${PLAY_TRACK:-internal} track)!"
  echo "  https://play.google.com/console"
}

# =============================================================================
# Run
# =============================================================================
BUILD_DIR="$PROJECT_DIR/build"
mkdir -p "$BUILD_DIR"

case $PLATFORM in
  ios)
    build_ios
    ;;
  android)
    build_android
    ;;
  both)
    build_ios
    echo ""
    build_android
    ;;
esac

echo ""
log "Done! $APP_NAME deployment complete."
