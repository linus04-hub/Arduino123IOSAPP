#!/bin/bash
# Holt Fahrten, Messreihen, Logbuch, Tankbuch, Züge und Gasstöße der
# Citroën-App vom iPhone auf den Mac, für die Mac-App „Citroën Analyse“.
#
# Läuft stündlich mit (auto-update.sh) und auf Knopfdruck aus der Mac-App.
# Übers WLAN, wie das Installieren. Kopiert nur, was neu oder geändert ist.
# Ziel: ~/Library/Application Support/CitroenAnzeige/iPhone
# Protokoll: ~/.citroen-auto/sync.log

set -uo pipefail

BASE="$HOME/.citroen-auto"
CONF="$BASE/config"
LOG="$BASE/sync.log"
BUNDLE=de.linus.citroenanzeige
APPDATA="$HOME/Library/Application Support/CitroenAnzeige"
DEST="$APPDATA/iPhone"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" | tee -a "$LOG"; }

mkdir -p "$BASE" "$DEST"
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 3000 ]; then
    tail -n 1500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
[ -f "$CONF" ] || { log "Nicht eingerichtet: auto-setup.sh ausführen"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"                           # UDID, NAME

# Nicht zweimal gleichzeitig
if ! mkdir "$BASE/sync.lock" 2>/dev/null; then
    if [ -n "$(find "$BASE/sync.lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
        rmdir "$BASE/sync.lock"
        mkdir "$BASE/sync.lock" || exit 0
    else
        log "Abgleich läuft schon"
        exit 0
    fi
fi
J=$(mktemp)
trap 'rm -f "$J"; rmdir "$BASE/sync.lock" 2>/dev/null' EXIT

# ── Was liegt auf dem iPhone? ──
list_files() {
    xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" "$@" --json-output "$J" >> "$LOG" 2>&1
}
if ! list_files --username mobile && ! list_files; then
    log "${NAME:-iPhone} nicht erreichbar"
    exit 2
fi

# Liste: entfernter Pfad <TAB> Pfad hier. Nur Neues oder Geändertes.
LIST=$(python3 - "$J" "$DEST" <<'EOF'
import json, os, re, sys
data = json.load(open(sys.argv[1]))
dest = sys.argv[2]
found = {}

def walk(o):
    if isinstance(o, dict):
        path = None
        for k in ("relativePath", "path", "name", "url", "fileName"):
            v = o.get(k)
            if isinstance(v, str) and (v.endswith(".csv") or v.endswith(".json")):
                path = v
                break
        if path:
            size = None
            for k in ("size", "fileSize", "length"):
                if isinstance(o.get(k), (int, float)):
                    size = int(o[k])
                    break
            if path not in found or found[path] is None:
                found[path] = size
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

walk(data)

def local(p):
    p = p.replace("file://", "")
    for anchor in ("Documents/", "Library/Application Support/"):
        i = p.find(anchor)
        if i >= 0:
            return p[i:]
    name = os.path.basename(p)
    if re.match(r"\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d\.(csv|json)$", name):
        return "Documents/Fahrten/" + name
    if name in ("Vergaser.json", "Tankbuch.json"):
        return "Documents/" + name
    if name in ("Zuege.json", "Gasstoesse.json"):
        return "Library/Application Support/" + name
    if name == "aktuell.json" or re.match(r"[0-9A-Fa-f-]{36}\.json$", name):
        return "Documents/Messreihen/" + name
    return None

wanted = []
for p, size in found.items():
    rel = local(p)
    if not rel:
        continue
    ok = (rel.startswith("Documents/Fahrten/") or rel.startswith("Documents/Messreihen/")
          or rel in ("Documents/Vergaser.json", "Documents/Tankbuch.json",
                     "Library/Application Support/Zuege.json", "Library/Application Support/Gasstoesse.json"))
    if ok:
        wanted.append((p, rel, size))

csvs = sorted(r for _, r, _ in wanted if r.endswith(".csv"))
newest = set(csvs[-2:])
for p, rel, size in wanted:
    here = os.path.join(dest, rel)
    if not os.path.exists(here):
        need = True
    elif size is not None:
        need = os.path.getsize(here) != size
    else:
        # ohne Groesse: kleine Dateien immer, CSV nur die beiden neuesten (laufende Fahrt)
        need = rel.endswith(".json") or rel in newest
    if need:
        src = rel if ("Documents/" in p or "Library/" in p or "/" not in p) else p
        print(src + "\t" + rel)
EOF
)

copy_one() {
    xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer \
        --domain-identifier "$BUNDLE" "$@" >> "$LOG" 2>&1
}

n=0
fail=0
while IFS=$'\t' read -r SRC REL; do
    [ -n "$SRC" ] || continue
    TARGET="$DEST/$REL"
    mkdir -p "$(dirname "$TARGET")"
    rm -f "$TARGET.part"
    if { copy_one --user mobile --source "$SRC" --destination "$TARGET.part" \
         || copy_one --source "$SRC" --destination "$TARGET.part"; } && [ -f "$TARGET.part" ]; then
        mv -f "$TARGET.part" "$TARGET"
        n=$((n + 1))
    else
        rm -f "$TARGET.part"
        fail=$((fail + 1))
    fi
done <<< "$LIST"

date +%s > "$APPDATA/letzter-abgleich.txt"
if [ "$fail" -gt 0 ]; then
    log "Vom iPhone geholt: $n Dateien, $fail fehlgeschlagen (siehe ~/.citroen-auto/sync.log)"
    exit 3
fi
if [ "$n" -eq 0 ]; then
    log "Alles aktuell, nichts Neues auf dem iPhone"
else
    log "Vom iPhone geholt: $n Dateien"
fi
exit 0
