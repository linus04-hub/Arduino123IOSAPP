#!/bin/bash
# Baut CitroenAnzeige.ipa (unsigniert) fuer SideStore/AltStore.
# SideStore signiert die App beim Installieren mit deiner Apple-ID.
#
# Voraussetzung: Xcode (aus dem App Store), einmal gestartet.
# XcodeGen wird bei Bedarf ueber Homebrew installiert.
set -euo pipefail
cd "$(dirname "$0")"

APP=CitroenAnzeige

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "→ Installiere XcodeGen …"
    brew install xcodegen
  else
    echo "XcodeGen fehlt und Homebrew ist nicht installiert."
    echo "Homebrew: https://brew.sh  – danach: brew install xcodegen"
    exit 1
  fi
fi

echo "→ Erzeuge Xcode-Projekt …"
xcodegen generate --quiet

echo "→ Baue App (Release, iPhone) …"
rm -rf build Payload "$APP.ipa"
# Auf GitHub setzt der Workflow BUILD_NUMBER, damit jede Version eine neue
# Build-Nummer bekommt (AltStore erkennt daran Updates). Lokal bleibt es beim
# Wert aus project.yml.
BUILD_SETTING=""
if [ -n "${BUILD_NUMBER:-}" ]; then
  BUILD_SETTING="CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
fi
xcodebuild -quiet \
  -project "$APP.xcodeproj" \
  -target "$APP" \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$PWD/build" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  $BUILD_SETTING \
  build

echo "→ Packe .ipa …"
mkdir -p Payload
cp -R "build/Release-iphoneos/$APP.app" Payload/
zip -qry "$APP.ipa" Payload
rm -rf Payload

echo ""
echo "Fertig: $PWD/$APP.ipa"
echo "Per AirDrop aufs iPhone schicken und in AltStore oder SideStore mit + installieren."
