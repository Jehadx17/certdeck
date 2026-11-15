#!/usr/bin/env bash
# Publishes the built release APK as the app update: every phone installs it the next time CertDeck opens or
# resumes online. Bump `version:` in app/pubspec.yaml, `flutter build apk --release --target-platform android-arm64`
# (arm64 only: ~20 MB instead of ~56 MB; every phone it goes to is 64-bit ARM), then run this.
# Also prints a browser download link for first installs.
set -euo pipefail
HOST=${CERTDECK_HOST:-$(cat "$(dirname "$0")/.host" 2>/dev/null)}; : "${HOST:?set CERTDECK_HOST or put user@host in deploy/.host}"
cd "$(git rev-parse --show-toplevel)"
APK=app/build/app/outputs/flutter-apk/app-release.apk
VERSION=$(sed -n 's/^version: *//p' app/pubspec.yaml)  # e.g. 1.2.0+3
NAME=${VERSION%+*} CODE=${VERSION#*+}
AAPT=$(ls -d ~/Android/Sdk/build-tools/*/aapt2 | tail -1)
BUILT=$("$AAPT" dump badging "$APK" | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p")
[ "$BUILT" = "$CODE" ] || { echo "APK is versionCode $BUILT but pubspec says $CODE: rebuild first"; exit 1; }
SHA=$(sha256sum "$APK" | cut -d' ' -f1)
LINK="certdeck-$NAME-$(python3 -c 'import secrets; print(secrets.token_urlsafe(9))').apk"

ssh "$HOST" mkdir -p /opt/certdeck/release
scp -q "$APK" "$HOST:/opt/certdeck/release/.upload.apk"
ssh "$HOST" "set -e; cd /opt/certdeck
  mv release/.upload.apk release/certdeck.apk && chmod 644 release/certdeck.apk
  printf '%s' '{\"version_code\": $CODE, \"version_name\": \"$NAME\", \"sha256\": \"$SHA\"}' > release/.latest.json
  mv release/.latest.json release/latest.json
  find dl -name 'certdeck-*.apk' -delete && ln release/certdeck.apk dl/$LINK"
echo "Published $NAME ($CODE). Phones update on their next open. Manual install: https://certdeck.mithaqstay.com/dl/$LINK"
