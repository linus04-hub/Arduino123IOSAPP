#!/bin/bash
# Citroën-App automatisch aktualisieren und neu signieren.
#
# Läuft jede Stunde im Hintergrund (eingerichtet von auto-setup.sh):
#   1. holt den neuesten Stand von GitHub (Zweig main)
#   2. baut und installiert die App aufs iPhone, wenn es eine neue Version gibt
#      oder die Signatur abläuft. Ab 36 h vor Ablauf wird versucht, ob Apple
#      schon eine neue Signatur ausstellt; installiert wird nur, wenn sie
#      wirklich länger gilt. Spätestens nach dem Ablauf holt Xcode eine neue.
#   3. meldet das Ergebnis als Mitteilung auf dem Mac
#   4. baut bei neuer Version auch die Mac-App „Citroën Analyse“ nach ~/Applications
#   5. holt die Daten vom iPhone für die Mac-App (sync-data.sh)
# Die App auf dem iPhone wird nur bei Bedarf ersetzt.
#
# Von Hand sofort ausführen:  FORCE=1 bash ~/.citroen-auto/auto-update.sh
# Protokoll:                   ~/.citroen-auto/auto.log

set -uo pipefail

BASE="$HOME/.citroen-auto"
REPO="$BASE/repo"
LOG="$BASE/auto.log"
STATE="$BASE/state"
CONF="$BASE/config"
APP=CitroenAnzeige
BUNDLE=de.linus.citroenanzeige
MAC_APP="$HOME/Applications/Citroën Analyse.app"
RENEW_BEFORE=$((36 * 60 * 60))          # ab 36 h vor Ablauf neu versuchen
FORCE="${FORCE:-0}"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "$LOG"; }
notify() { osascript -e "display notification \"$1\" with title \"Citroën\"" >/dev/null 2>&1 || true; }
sync_data() {
    [ -f "$BASE/sync-data.sh" ] || cp "$REPO/Tools/sync-data.sh" "$BASE/sync-data.sh" 2>/dev/null || return 0
    bash "$BASE/sync-data.sh" >/dev/null 2>&1 || true
}
fail() {
    log "FEHLER: $1"
    notify "$1"
    sync_data
    exit 1
}
when() { LC_TIME=de_DE.UTF-8 date -r "$1" '+%a %d.%m. %H:%M'; }

mkdir -p "$BASE"
# Protokoll klein halten
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ]; then
    tail -n 1000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# Nicht zweimal gleichzeitig laufen
if ! mkdir "$BASE/lock" 2>/dev/null; then
    # Sperre älter als 1 h: hängengeblieben, freigeben
    if [ -n "$(find "$BASE/lock" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
        rmdir "$BASE/lock" 2>/dev/null
        mkdir "$BASE/lock" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
trap 'rmdir "$BASE/lock" 2>/dev/null' EXIT

[ -d "$DEVELOPER_DIR" ] || fail "Xcode nicht gefunden"
[ -f "$CONF" ] || fail "Nicht eingerichtet: auto-setup.sh ausführen"
# shellcheck source=/dev/null
source "$CONF"                           # UDID, NAME
[ -d "$REPO/.git" ] || fail "Projektordner fehlt: auto-setup.sh erneut ausführen"

LAST_COMMIT=""
LAST_MAC=""
EXPIRES=0
# shellcheck source=/dev/null
[ -f "$STATE" ] && source "$STATE"

# ── 1. Neuesten Stand holen ──
cd "$REPO" || fail "Projektordner fehlt"
if git fetch -q origin main 2>>"$LOG"; then
    if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
        # Hier wird nichts von Hand geändert, deshalb einfach auf den Stand von GitHub setzen
        git reset -q --hard origin/main || fail "Aktualisieren fehlgeschlagen"
        log "Neuer Stand: $(git log -1 --format='%h %s')"
    fi
else
    log "GitHub nicht erreichbar, nur Signatur prüfen"
fi
HEAD_COMMIT="$(git rev-parse HEAD)"

save_state() {
    {
        echo "LAST_COMMIT=$LAST_COMMIT"
        echo "LAST_MAC=$LAST_MAC"
        echo "EXPIRES=$EXPIRES"
    } > "$STATE"
}

# ── Mac-App „Citroën Analyse“ ──
if [ "$HEAD_COMMIT" != "$LAST_MAC" ] || [ ! -d "$MAC_APP" ]; then
    if grep -q "CitroenMac" "$REPO/$APP.xcodeproj/project.pbxproj" 2>/dev/null; then
        log "Baue Mac-App …"
        if xcodebuild -quiet -project "$REPO/$APP.xcodeproj" -scheme CitroenMac -configuration Release \
            -destination 'platform=macOS' -derivedDataPath "$BASE/build-mac" build >> "$LOG" 2>&1; then
            mkdir -p "$HOME/Applications"
            rm -rf "$MAC_APP.neu"
            if ditto "$BASE/build-mac/Build/Products/Release/CitroenAnalyse.app" "$MAC_APP.neu"; then
                rm -rf "$MAC_APP"
                mv "$MAC_APP.neu" "$MAC_APP"
                LAST_MAC="$HEAD_COMMIT"
                save_state
                log "Mac-App aktualisiert: ~/Applications/Citroën Analyse"
            fi
        else
            log "Mac-App: Bauen fehlgeschlagen"
        fi
    fi
fi

# ── 2. Muss etwas passieren? ──
NOW=$(date +%s)
REASON=""
EARLY=0
if [ "$FORCE" = 1 ]; then
    REASON="von Hand gestartet"
elif [ "$HEAD_COMMIT" != "$LAST_COMMIT" ]; then
    REASON="neue Version"
elif [ "$NOW" -ge "$EXPIRES" ]; then
    REASON="Signatur abgelaufen"
elif [ $((EXPIRES - NOW)) -lt $RENEW_BEFORE ]; then
    REASON="Signatur läuft bald ab"
    EARLY=1
fi
if [ -z "$REASON" ]; then
    log "Nichts zu tun, gültig bis $(when "$EXPIRES")"
    sync_data
    exit 0
fi
log "Starte: $REASON"

# ── 3. Bauen ──
log "Baue …"
xcodebuild -quiet \
    -project "$REPO/$APP.xcodeproj" \
    -scheme "$APP" \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$BASE/build" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build >> "$LOG" 2>&1 || fail "Bauen fehlgeschlagen, siehe ~/.citroen-auto/auto.log"

APP_PATH="$BASE/build/Build/Products/Release-iphoneos/$APP.app"
[ -d "$APP_PATH" ] || fail "App nach dem Bauen nicht gefunden"

NEW_EXPIRES=0
EXP_TEXT=$(security cms -D -i "$APP_PATH/embedded.mobileprovision" 2>/dev/null \
    | plutil -extract ExpirationDate raw -o - - 2>/dev/null)
if [ -n "$EXP_TEXT" ]; then
    NEW_EXPIRES=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$EXP_TEXT" +%s 2>/dev/null || echo 0)
fi
if [ "$NEW_EXPIRES" -le "$NOW" ]; then
    # Ablaufdatum nicht lesbar: von 7 Tagen ausgehen, sonst würde jeder Lauf neu installieren
    NEW_EXPIRES=$((NOW + 7 * 86400 - 3600))
    log "Ablaufdatum nicht lesbar, nehme 7 Tage an"
fi
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP_PATH/Info.plist" 2>/dev/null || echo "?")
BUILD=$(plutil -extract CFBundleVersion raw -o - "$APP_PATH/Info.plist" 2>/dev/null || echo "?")

# Vor Ablauf nur installieren, wenn die neue Signatur wirklich länger gilt.
# Sonst würde die App ohne Nutzen neu gestartet.
if [ "$EARLY" = 1 ] && [ "$NEW_EXPIRES" -le $((EXPIRES + 3600)) ]; then
    log "Noch keine neue Signatur von Apple (gilt bis $(when "$EXPIRES")), nächster Versuch in 1 h"
    sync_data
    exit 0
fi

# ── 4. Aufs iPhone ──
log "Installiere auf ${NAME:-iPhone} …"
xcrun devicectl device install app --device "$UDID" "$APP_PATH" >> "$LOG" 2>&1 \
    || fail "${NAME:-iPhone} nicht erreichbar. Gleiches WLAN, entsperrt? Nächster Versuch in 1 h."

LAST_COMMIT="$HEAD_COMMIT"
EXPIRES="$NEW_EXPIRES"
save_state

MSG="Version $VERSION ($BUILD) installiert"
[ "$NEW_EXPIRES" -gt 0 ] && MSG="$MSG, gültig bis $(when "$NEW_EXPIRES")"
log "$MSG"
notify "$MSG"

sync_data

# Neueste Fassung der Skripte für den nächsten Lauf übernehmen
cp "$REPO/Tools/auto-update.sh" "$BASE/auto-update.sh" 2>/dev/null || true
cp "$REPO/Tools/sync-data.sh" "$BASE/sync-data.sh" 2>/dev/null || true
exit 0
