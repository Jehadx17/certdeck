#!/bin/bash
# Builds CertDeck for iOS and installs it on the iPhone connected by USB. Run on macOS (see README → iOS).
# Re-run it to update the app; with a free Apple ID also every 7 days, when the signature expires (data is kept).
set -euo pipefail
cd "$(dirname "$0")"

xcodebuild -version >/dev/null 2>&1 || { echo "Install Xcode from the App Store, open it once, then: sudo xcodebuild -license accept"; exit 1; }
export PATH="$HOME/FlutterSDK/flutter/bin:$PATH"
if ! command -v flutter >/dev/null; then  # same Flutter as the Android build
  git clone -q -b 3.22.2 --depth 1 https://github.com/flutter/flutter.git "$HOME/FlutterSDK/flutter"
fi
if ! command -v pod >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh), then re-run"; exit 1; }
  brew install cocoapods
fi

# Signing team: CERTDECK_TEAM, else the team of your "Apple Development" certificate.
TEAM=${CERTDECK_TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p' | head -1)}
[ -n "$TEAM" ] || { echo "No signing certificate. Xcode → Settings → Accounts → add your Apple ID →" \
  "Manage Certificates… → + → Apple Development. Then re-run."; exit 1; }

DEVICES=$(mktemp)
xcrun devicectl list devices --json-output "$DEVICES" >/dev/null
UDID=$(python3 - "$DEVICES" <<'EOF'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
ok = [d["hardwareProperties"]["udid"] for d in devs
      if d["hardwareProperties"].get("platform") == "iOS" and d["connectionProperties"].get("pairingState") == "paired"]
print(ok[0] if ok else "")
EOF
)
[ -n "$UDID" ] || { echo "No paired iPhone. Connect it by USB, unlock it, tap Trust, and turn on" \
  "Settings → Privacy & Security → Developer Mode."; exit 1; }

flutter pub get
flutter build ios --release --config-only   # generated config + pod install
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination "id=$UDID" -derivedDataPath build/ios/dd \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build
xcrun devicectl device install app --device "$UDID" build/ios/dd/Build/Products/Release-iphoneos/Runner.app
echo "Installed. First time only: on the iPhone, Settings → General → VPN & Device Management → trust your Apple ID."
