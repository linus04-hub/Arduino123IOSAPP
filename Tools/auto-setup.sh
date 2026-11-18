#!/bin/bash
# Richtet die automatische Aktualisierung der Citroën-App ein (einmalig).
#
# Im Terminal:
#   bash <(curl -fsSL https://raw.githubusercontent.com/linus04-hub/Arduino123IOSAPP/main/Tools/auto-setup.sh)
# Wieder entfernen:
#   bash <(curl -fsSL https://raw.githubusercontent.com/linus04-hub/Arduino123IOSAPP/main/Tools/auto-setup.sh) --entfernen
#
# Voraussetzungen: Xcode mit deiner Apple-ID angemeldet, die App einmal aus
# Xcode aufs iPhone gespielt, und in Xcode unter Window › Devices and Simulators
# beim iPhone „Connect via network“ angehakt.

set -uo pipefail

BASE="$HOME/.citroen-auto"
REPO="$BASE/repo"
URL="https://github.com/linus04-hub/Arduino123IOSAPP.git"
LABEL="de.linus.citroenanzeige.auto"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*"; exit 1; }

if [ "${1:-}" = "--entfernen" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    rm -f "$PLIST"
    rm -rf "$BASE"
    say "Automatik entfernt. Die App auf dem iPhone bleibt."
    exit 0
fi

[ -d "$DEVELOPER_DIR" ] || die "Xcode nicht gefunden. Erst Xcode aus dem App Store installieren."
mkdir -p "$BASE" "$HOME/Library/LaunchAgents"

# ── Projekt holen ──
say "Hole das Projekt von GitHub …"
if [ -d "$REPO/.git" ]; then
    git -C "$REPO" fetch -q origin main && git -C "$REPO" reset -q --hard origin/main \
        || die "Aktualisieren fehlgeschlagen."
else
    git clone -q --branch main "$URL" "$REPO" || die "Laden von GitHub fehlgeschlagen."
fi

# ── iPhone wählen ──
say "Suche dein iPhone …"
J=$(mktemp)
xcrun devicectl list devices --json-output "$J" >/dev/null 2>&1 \
    || die "Geräteliste nicht lesbar. Ist Xcode einmal geöffnet worden?"
python3 -c 1 >/dev/null 2>&1 || die "python3 fehlt. Im Terminal „xcode-select --install“ ausführen und danach dieses Skript noch einmal."
LIST=$(python3 - "$J" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for dev in d.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties") or {}
    if hw.get("platform") != "iOS" or hw.get("deviceType") != "iPhone":
        continue
    name = (dev.get("deviceProperties") or {}).get("name") or "iPhone"
    udid = hw.get("udid") or ""
    if udid:
        print(udid + "\t" + name.replace("\t", " "))
EOF
)
rm -f "$J"
[ -n "$LIST" ] || die "Kein iPhone gefunden. Einmal per Kabel anschließen und die App aus Xcode starten."

COUNT=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')
if [ "$COUNT" = 1 ]; then
    PICK="$LIST"
else
    echo "Mehrere iPhones gefunden:"
    printf '%s\n' "$LIST" | awk -F'\t' '{print "  " NR ") " $2}'
    printf 'Nummer: '
    read -r N </dev/tty
    PICK=$(printf '%s\n' "$LIST" | sed -n "${N}p")
    [ -n "$PICK" ] || die "Ungültige Auswahl."
fi
UDID=$(printf '%s' "$PICK" | cut -f1)
NAME=$(printf '%s' "$PICK" | cut -f2)
printf 'UDID=%q\nNAME=%q\n' "$UDID" "$NAME" > "$BASE/config"
echo "Gewählt: $NAME"

# ── Hintergrund-Job ──
cp "$REPO/Tools/auto-update.sh" "$BASE/auto-update.sh"
chmod +x "$BASE/auto-update.sh"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$BASE/auto-update.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>10800</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>$BASE/launchd.err</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
launchctl bootstrap "$DOMAIN" "$PLIST" || die "Hintergrund-Job ließ sich nicht starten."

# ── Erster Lauf jetzt, damit Rückfragen hier im Terminal erscheinen ──
say "Erster Durchlauf: bauen und aufs iPhone spielen (1 bis 5 Minuten) …"
echo "Fragt der Mac nach dem Schlüsselbund-Passwort: dein Mac-Passwort eingeben und „Immer erlauben“."
if FORCE=1 bash "$BASE/auto-update.sh"; then
    say "Fertig. Der Mac prüft jetzt alle 3 Stunden auf Updates und signiert rechtzeitig neu."
    echo "Protokoll: ~/.citroen-auto/auto.log"
else
    say "Der erste Durchlauf hat nicht geklappt. Die letzten Zeilen aus dem Protokoll:"
    tail -n 25 "$BASE/auto.log"
    echo
    echo "Die Automatik ist trotzdem eingerichtet und versucht es in 3 Stunden wieder."
fi
